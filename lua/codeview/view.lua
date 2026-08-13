---@brief The file view of a session.
---
--- The view shows the diff of one changed file of the session in the main
--- window, next to the sidebar. It reads both sides of the file from the
--- backend, runs |codeview.diff| on them, and renders the result with the
--- style of the `diff.style` option. This milestone holds the inline style.
---
--- The buffer of the view is read-only. |codeview.inline| owns its content,
--- its highlights, and its line map. The view owns the window, the keymaps,
--- and the state of the collapsed sections.
---
--- The view keeps one buffer. A second open replaces the buffer, so the tab
--- page never holds more than one view buffer.

local config = require("codeview.config")
local diff_mod = require("codeview.diff")
local errors = require("codeview.error")
local highlight = require("codeview.highlight")
local inline = require("codeview.inline")
local linemap = require("codeview.linemap")
local panel = require("codeview.panel")
local tree = require("codeview.tree")

local api = vim.api

local M = {}

---@class codeview.view.State
---@field session codeview.Session Session that owns the view.
---@field index integer Position of the file in the file list of the session.
---@field path string Path of the file.
---@field status codeview.vcs.Status Status of the file in the range.
---@field rev string Revision that the content comes from.
---@field old_rev string? Revision of the old side. Nil for an added file.
---@field new_rev string? Revision of the new side. Nil for a deleted file.
---@field diff codeview.diff.File Diff that the buffer shows.
---@field map codeview.LineMap Map between the buffer rows and the file lines.
---@field expanded table<integer, boolean> Collapsed sections that show their lines.
---@field buf integer Buffer that holds the diff.
---@field win integer Window that shows the buffer.

---File that the view shows now.
---@type codeview.view.State?
local state = nil

---Number of open calls of this Neovim. It names the newest request.
---@type integer
local requests = 0

---Request that runs now.
---
--- The next-file and previous-file steps count from this request, so that a
--- second key press moves on while the backend still reads the file.
---@type { session: codeview.Session, index: integer, ticket: integer }?
local pending = nil

---Take the number of a new request. Older answers stop at |fresh()|.
---@return integer ticket
local function ticket_of()
  requests = requests + 1
  pending = nil
  return requests
end

---Report whether an answer belongs to the newest request.
---@param ticket integer
---@return boolean
local function fresh(ticket)
  return ticket == requests
end

---Request that the next step counts from.
---@param session codeview.Session
---@return integer? index Nil while no request of the session runs.
local function pending_index(session)
  if pending and pending.session == session and fresh(pending.ticket) and session:is_active() then
    return pending.index
  end
  return nil
end

---Return a value in the sync form, or send it to the callback.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@param value codeview.view.State?
---@param err codeview.Error?
---@return codeview.view.State?, codeview.Error?
local function done(cb, value, err)
  if not cb then
    return value, err
  end
  vim.schedule(function()
    cb(value, err)
  end)
  return nil, nil
end

---Send a User event for the file that opened.
---@param view codeview.view.State
local function announce(view)
  pcall(api.nvim_exec_autocmds, "User", {
    pattern = "CodeViewFileOpened",
    data = {
      session = view.session.id,
      index = view.index,
      path = view.path,
      status = view.status,
      buf = view.buf,
    },
  })
end

---Report whether a window can hold the view.
---@param win integer Window handle.
---@return boolean
local function usable(win)
  return api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == "" and not panel.is_panel_win(win)
end

---Window for the content of a file.
---
--- The view keeps its window. Without one it takes the current window, or the
--- first window of the tab page that is not a panel. A tab page with panels
--- only gets a new split.
---@param session codeview.Session
---@param buf integer Buffer for a new window.
---@return integer win
local function target_window(session, buf)
  if state and state.session == session and usable(state.win) then
    return state.win
  end
  local current = api.nvim_get_current_win()
  if usable(current) then
    return current
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if usable(win) then
      return win
    end
  end
  local win = api.nvim_open_win(buf, true, { split = "right", win = current })
  session:add_window(win)
  return win
end

---Report a message of an action of the view.
---@param message string
local function notify(message)
  vim.notify("codeview: " .. message, vim.log.levels.INFO)
end

---Buffer-local keymaps of the view.
---@param session codeview.Session
---@param buf integer
local function set_keymaps(session, buf)
  local keys = config.get().keymaps

  ---@param lhs string|false Key of the configuration. False disables the map.
  ---@param action fun()
  local function add(lhs, action)
    if type(lhs) ~= "string" or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, action, { buffer = buf, nowait = true, silent = true, desc = "codeview: file view" })
  end

  ---@param _ codeview.view.State?
  ---@param err codeview.Error?
  local function report(_, err)
    if err then
      notify(tostring(err))
    end
  end

  add(keys.next_file, function()
    M.next(session, report)
  end)
  add(keys.prev_file, function()
    M.prev(session, report)
  end)
  add(keys.next_hunk, function()
    if not M.next_hunk() then
      notify("no hunk after this one")
    end
  end)
  add(keys.prev_hunk, function()
    if not M.prev_hunk() then
      notify("no hunk before this one")
    end
  end)
  add(keys.expand_context, function()
    if not M.toggle_context() then
      notify("no collapsed section on this line")
    end
  end)
  add(keys.expand_all, function()
    M.expand_all()
  end)
  add(keys.collapse_all, function()
    M.collapse_all()
  end)
  add(keys.close, function()
    session:close()
  end)
end

---Make the buffer for one file.
---
--- The buffer holds the diff, so its filetype is the filetype of the diff. A
--- buffer variable keeps the filetype of the file itself, for a later
--- milestone.
---@param session codeview.Session
---@param file codeview.vcs.FileChange
---@return integer buf
local function make_buf(session, file)
  local buf = api.nvim_create_buf(false, true)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  pcall(api.nvim_buf_set_name, buf, string.format("codeview://%d/%s", session.id, file.path))

  vim.b[buf].codeview_filetype = vim.filetype.match({ filename = file.path, buf = buf }) or ""
  vim.bo[buf].filetype = inline.filetype

  set_keymaps(session, buf)
  session:add_buffer(buf)
  return buf
end

---Window of the view, while it shows the buffer of the view.
---@param view codeview.view.State
---@return integer? win
local function view_window(view)
  if api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == view.buf then
    return view.win
  end
  return nil
end

---Render the diff of the view again.
---
--- The cursor keeps its file line, so a collapse or an expand of a section
--- does not move the reader.
---@param view codeview.view.State
---@return codeview.view.State view
local function rerender(view)
  if not api.nvim_buf_is_valid(view.buf) then
    return view
  end
  local win = view_window(view)
  local line, side
  if win then
    line, side = view.map:file_line(api.nvim_win_get_cursor(win)[1])
  end

  local build = inline.render(view.buf, view.diff, { expanded = view.expanded })
  view.map = build.map

  if win and line and side then
    local row = build.map:nearest_row(line, side)
    if row then
      pcall(api.nvim_win_set_cursor, win, { row, 0 })
    end
  end
  return view
end

---Read the file that the view shows.
---@return codeview.view.State? view Nil when no file is open.
function M.current()
  if state and not state.session:is_active() then
    state = nil
  end
  return state
end

---Position of one file in the file list of a session.
---
--- The step follows the order of the sidebar tree, not the order of the
--- backend. It starts at the file of the request that runs, or at the file
--- that the view shows. Without an open file a forward step starts before the
--- first file, and a backward step starts after the last file.
---@param session codeview.Session
---@param delta integer Number of files to move. Use 1 or -1.
---@return integer? index Nil at the end of the list.
function M.step(session, delta)
  local order = tree.order(session:changed_files())
  if #order == 0 then
    return nil
  end

  local from = pending_index(session)
  if not from then
    local view = M.current()
    from = view and view.session == session and view.index or nil
  end

  local position
  if from then
    for at, index in ipairs(order) do
      if index == from then
        position = at
        break
      end
    end
  end
  position = position or (delta > 0 and 0 or #order + 1)

  local at = position + delta
  if at < 1 or at > #order then
    return nil
  end
  return order[at]
end

---Show one changed file of the session.
---
--- Without a callback the call blocks and returns `view, err`. With a
--- callback it returns at once and calls `cb(view, err)`.
---
--- One request runs at a time. A second open, a close of the view, or a close
--- of the session cancels the request that runs. The callback of a request
--- that another call cancels does not run.
---@param session codeview.Session
---@param index integer Position of the file in the file list of the session.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return codeview.view.State? view
---@return codeview.Error? err
function M.open(session, index, cb)
  if type(session) ~= "table" or type(session.file) ~= "function" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the first argument must be a session"))
  end
  if not session:is_active() then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the session is closed"))
  end
  local file = session:file(index)
  if not file then
    return done(cb, nil, errors.new(errors.codes.NOT_FOUND, "no changed file at position " .. tostring(index)))
  end

  local old_rev, new_rev = diff_mod.revisions(session, file)
  -- The view reports the revision that the file itself comes from. A deleted
  -- file has no new side, so it comes from the base of the range.
  local rev = new_rev or old_rev

  ---Put the diff into a buffer and show it.
  ---
  --- The buffer of the file that was open goes first, because the new buffer
  --- takes the same name after a second open of the same file.
  ---@param result codeview.diff.File
  ---@return codeview.view.State
  local function show(result)
    local previous = state and state.buf
    if previous and api.nvim_buf_is_valid(previous) then
      pcall(api.nvim_buf_delete, previous, { force = true })
    end
    highlight.setup()
    local buf = make_buf(session, file)
    local win = target_window(session, buf)
    if api.nvim_win_get_buf(win) ~= buf then
      api.nvim_win_set_buf(win, buf)
    end
    inline.attach_window(win)

    state = {
      session = session,
      index = index,
      path = file.path,
      status = file.status,
      rev = rev,
      old_rev = old_rev,
      new_rev = new_rev,
      diff = result,
      map = linemap.new(),
      expanded = {},
      buf = buf,
      win = win,
    }
    rerender(state)
    announce(state)
    return state
  end

  local ticket = ticket_of()

  if not cb then
    local result, err = diff_mod.for_file(session, file)
    if not result then
      return nil, err
    end
    return show(result), nil
  end

  pending = { session = session, index = index, ticket = ticket }
  diff_mod.for_file(session, file, function(result, err)
    if not fresh(ticket) then
      return
    end
    pending = nil
    if not session:is_active() then
      cb(nil, errors.new(errors.codes.INVALID_ARG, "the session is closed"))
      return
    end
    if not result then
      cb(nil, err)
      return
    end
    cb(show(result), nil)
  end)
  return nil, nil
end

--- Diff navigation --------------------------------------------------------------

---Move the cursor of the view to one buffer row.
---@param view codeview.view.State
---@param row integer Buffer row, from 1.
---@return integer? row Nil when the window does not show the view.
local function go_to(view, row)
  local win = view_window(view)
  if not win then
    return nil
  end
  local ok = pcall(api.nvim_win_set_cursor, win, { row, 0 })
  if not ok then
    return nil
  end
  return row
end

---Row of the cursor in the view.
---@param view codeview.view.State
---@return integer row Row from 1. The first row without a window.
local function cursor_row(view)
  local win = view_window(view)
  if not win then
    return 1
  end
  return api.nvim_win_get_cursor(win)[1]
end

---Move the cursor to the first row of the next hunk.
---@param opts? { wrap?: boolean } `wrap = true` continues at the first hunk.
---@return integer? row Nil when no hunk follows, or when no file is open.
function M.next_hunk(opts)
  local view = M.current()
  if not view then
    return nil
  end
  local row = view.map:next_hunk(cursor_row(view), opts)
  if not row then
    return nil
  end
  return go_to(view, row)
end

---Move the cursor to the first row of the previous hunk.
---@param opts? { wrap?: boolean } `wrap = true` continues at the last hunk.
---@return integer? row Nil when no hunk is above the cursor, or when no file is open.
function M.prev_hunk(opts)
  local view = M.current()
  if not view then
    return nil
  end
  local row = view.map:prev_hunk(cursor_row(view), opts)
  if not row then
    return nil
  end
  return go_to(view, row)
end

--- Collapsed sections -----------------------------------------------------------

---Show or hide the lines of one collapsed section.
---@param id integer? Number of the section. The section under the cursor by default.
---@param expanded boolean? State to set. The other state by default.
---@return boolean changed False without a section.
function M.toggle_context(id, expanded)
  local view = M.current()
  if not view then
    return false
  end
  if not id then
    local gap = inline.gap_at(view.buf, cursor_row(view))
    if not gap then
      return false
    end
    id = gap.id
  end
  if not inline.gaps(view.buf)[id] then
    return false
  end
  if expanded == nil then
    expanded = not view.expanded[id]
  end
  view.expanded[id] = expanded or nil
  rerender(view)
  return true
end

---Show the hidden lines of every collapsed section.
---@return boolean changed False when no file is open.
function M.expand_all()
  local view = M.current()
  if not view then
    return false
  end
  for _, gap in ipairs(inline.gaps(view.buf)) do
    view.expanded[gap.id] = true
  end
  rerender(view)
  return true
end

---Hide the lines of every section again.
---@return boolean changed False when no file is open.
function M.collapse_all()
  local view = M.current()
  if not view then
    return false
  end
  view.expanded = {}
  rerender(view)
  return true
end

---Render the diff of the view again.
---@return codeview.view.State? view Nil when no file is open.
function M.render()
  local view = M.current()
  if not view then
    return nil
  end
  return rerender(view)
end

---Read the line map of the file that the view shows.
---@return codeview.LineMap? map Nil when no file is open.
function M.map()
  local view = M.current()
  return view and view.map or nil
end

---Read the diff of the file that the view shows.
---@return codeview.diff.File? diff Nil when no file is open.
function M.diff()
  local view = M.current()
  return view and view.diff or nil
end

---Show the next changed file of the session.
---@param session codeview.Session
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return codeview.view.State? view
---@return codeview.Error? err
function M.next(session, cb)
  local index = M.step(session, 1)
  if not index then
    return done(cb, nil, errors.new(errors.codes.NOT_FOUND, "no file after this one"))
  end
  return M.open(session, index, cb)
end

---Show the previous changed file of the session.
---@param session codeview.Session
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return codeview.view.State? view
---@return codeview.Error? err
function M.prev(session, cb)
  local index = M.step(session, -1)
  if not index then
    return done(cb, nil, errors.new(errors.codes.NOT_FOUND, "no file before this one"))
  end
  return M.open(session, index, cb)
end

---Delete the buffer of the view.
---
--- The call cancels a request that runs, so that a late answer of the backend
--- does not open a window again.
---@return boolean closed False when no file is open.
function M.close()
  ticket_of()
  if not state then
    return false
  end
  local buf = state.buf
  state = nil
  if api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  return true
end

return M
