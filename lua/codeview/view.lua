---@brief The file view of a session.
---
--- The view shows the diff of one changed file of the session in the main
--- window, next to the sidebar. It reads both sides of the file from the
--- backend, runs |codeview.diff| on them, and renders the result with the
--- style of the `diff.style` option.
---
--- Two styles show the same diff:
---
--- - "inline": one unified diff in one buffer, from |codeview.inline|.
--- - "split": two aligned buffers in two windows, from |codeview.split|.
---
--- |codeview.view.set_style()| changes the style of the file that is open. It
--- keeps the diff, so the backend reads the file once for both styles, and it
--- keeps the cursor on the same line of the file through the line maps.
---
--- The buffers of the view are read-only. The style module owns their content,
--- their highlights, and their line maps. The view owns the windows, the
--- keymaps, and the state of the collapsed sections.
---
--- The view keeps the buffers of one file. A second open replaces them, so the
--- tab page never holds the buffers of two files.

local config = require("codeview.config")
local diff_mod = require("codeview.diff")
local layout = require("codeview.layout")
local errors = require("codeview.error")
local highlight = require("codeview.highlight")
local inline = require("codeview.inline")
local linemap = require("codeview.linemap")
local panel = require("codeview.panel")
local split = require("codeview.split")
local tree = require("codeview.tree")

local api = vim.api

local M = {}

---@alias codeview.view.Style "inline"|"split"

---@class codeview.view.Anchor
---@field line integer? Line in the file.
---@field side codeview.linemap.Side? Side that holds the line.
---@field hunk integer? Hunk of a header row, which holds no file line.
---@field gap integer? Collapsed section of a filler row, which holds no file line.

---@class codeview.view.State
---@field session codeview.Session Session that owns the view.
---@field index integer Position of the file in the file list of the session.
---@field path string Path of the file.
---@field status codeview.vcs.Status Status of the file in the range.
---@field rev string Revision that the content comes from.
---@field old_rev string? Revision of the old side. Nil for an added file.
---@field new_rev string? Revision of the new side. Nil for a deleted file.
---@field diff codeview.diff.File Diff that the buffers show.
---@field style codeview.view.Style Style of the render.
---@field map codeview.LineMap Map of the buffer rows of `buf`.
---@field old_map codeview.LineMap? Map of the buffer rows of `old_buf`. Split style only.
---@field expanded table<integer, boolean> Collapsed sections that show their lines.
---@field buf integer Buffer of the diff. In the split style it holds the new side.
---@field win integer Window that shows the buffer.
---@field old_buf integer? Buffer of the old side. Split style only.
---@field old_win integer? Window of the old side. Split style only.
---@field guards integer[] Autocmds that watch the windows of the style.

---@class codeview.view.OpenOpts
---@field force boolean? True renders a diff that is above the `diff.max_lines` limit.

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
      style = view.style,
      buf = view.buf,
    },
  })
end

---Report whether a window can hold the view.
---@param win integer? Window handle.
---@return boolean
local function usable(win)
  if type(win) ~= "number" or not api.nvim_win_is_valid(win) then
    return false
  end
  return api.nvim_win_get_config(win).relative == "" and not panel.is_panel_win(win)
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
  -- Every window of the tab page is a panel. `win = -1` splits the tab page
  -- itself, so the new window takes the room of the whole editor and not the
  -- half of a sidebar.
  local ok, win = pcall(api.nvim_open_win, buf, true, { split = "right", win = -1 })
  if not ok then
    win = api.nvim_open_win(buf, true, { split = "right", win = current })
  end
  session:add_window(win)
  return win
end

---Line of the working copy that a row of the view points at.
---
--- The file on disk holds the new side of the review, so a row of the old
--- side has no line of its own. The nearest row of the new side answers for
--- it, which puts the cursor at the place of the change.
---@param view codeview.view.State
---@param row integer Row of the buffer, from 1.
---@return integer line Line of the file, from 1.
local function working_line(view, row)
  local rows = view.map.rows
  local record = rows[row]
  if record and record.new then
    return record.new
  end
  for step = 1, #rows do
    local before, after = rows[row - step], rows[row + step]
    if before and before.new then
      return before.new
    end
    if after and after.new then
      return after.new
    end
  end
  return 1
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

  ---@param value string|string[]|false Key of the configuration. False disables the map.
  ---@param action fun()
  local function add(value, action)
    for _, lhs in ipairs(config.keys(value)) do
      vim.keymap.set("n", lhs, action, { buffer = buf, nowait = true, silent = true, desc = "codeview: file view" })
    end
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
  add(keys.edit_file, function()
    M.edit()
  end)
  add(keys.toggle_style, function()
    M.toggle_style()
  end)
  add(keys.close, function()
    session:close()
  end)

  -- The comment keys need the visual mode too. The module owns them.
  require("codeview.comments").set_keymaps(session, buf)
end

---Make the buffer of one side of a file.
---
--- The buffer holds the diff, so its filetype is the filetype of the diff. A
--- buffer variable keeps the filetype of the file itself, for a later
--- milestone.
---@param session codeview.Session
---@param path string Path of the side in its revision.
---@param side codeview.linemap.Side? Side of a side-by-side view. Nil for the inline view.
---@return integer buf
local function make_buf(session, path, side)
  local buf = api.nvim_create_buf(false, true)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  -- The old side of a split view needs its own name, because the two sides can
  -- hold the same path.
  local name = string.format("codeview://%d/%s", session.id, path)
  pcall(api.nvim_buf_set_name, buf, side == "old" and name .. "@old" or name)

  vim.b[buf].codeview_filetype = vim.filetype.match({ filename = path, buf = buf }) or ""
  vim.b[buf].codeview_side = side
  vim.bo[buf].filetype = inline.filetype

  set_keymaps(session, buf)
  session:add_buffer(buf)
  return buf
end

---Number of buffers that gave their name back.
---@type integer
local releases = 0

---Take the name of a buffer that goes away.
---
--- The new buffer of a file wants the name of the buffer that it replaces,
--- and two buffers cannot hold one name. The old buffer therefore takes a
--- name of its own until its delete, which follows right after.
---@param buf integer?
local function release_name(buf)
  if buf and api.nvim_buf_is_valid(buf) then
    releases = releases + 1
    pcall(api.nvim_buf_set_name, buf, string.format("codeview://released/%d", releases))
  end
end

---Windows of the view, while they show the buffers of the view.
---
--- The order is old side first, so that a caller reaches the left window with
--- the first entry.
---@param view codeview.view.State
---@return integer[] wins
local function view_windows(view)
  local out = {}
  if view.old_win and view.old_buf and api.nvim_win_is_valid(view.old_win) then
    if api.nvim_win_get_buf(view.old_win) == view.old_buf then
      out[#out + 1] = view.old_win
    end
  end
  if api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == view.buf then
    out[#out + 1] = view.win
  end
  return out
end

---Window of the view that holds the new side.
---@param view codeview.view.State
---@return integer? win
local function view_window(view)
  if api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == view.buf then
    return view.win
  end
  return nil
end

---Report whether the cursor is in a window of the view.
---@param view codeview.view.State
---@return boolean
local function has_focus(view)
  return vim.tbl_contains(view_windows(view), api.nvim_get_current_win())
end

---Map of one side of the view.
---@param view codeview.view.State
---@param side codeview.linemap.Side
---@return codeview.LineMap map
local function map_of(view, side)
  if side == "old" and view.old_map then
    return view.old_map
  end
  return view.map
end

---Row of the cursor in the view.
---
--- Both sides of a split view hold the same rows, so one row number answers
--- for both windows.
---@param view codeview.view.State
---@return integer row Row from 1. The first row without a window.
local function cursor_row(view)
  local wins = view_windows(view)
  local current = api.nvim_get_current_win()
  for _, win in ipairs(wins) do
    if win == current then
      return api.nvim_win_get_cursor(win)[1]
    end
  end
  local win = view_window(view) or wins[1]
  if not win then
    return 1
  end
  return api.nvim_win_get_cursor(win)[1]
end

---Position of the cursor in the diff.
---
--- The map of the window with the cursor answers first. A row that this side
--- does not hold, for example a filler row, falls back to the other side.
---
--- A hunk header and the row of a collapsed section hold no file line. They
--- keep their number in both styles, so the anchor names the hunk or the
--- section. It also keeps the closest file line above the row, for the case
--- that the new render holds no row of the same kind.
---@param view codeview.view.State
---@return codeview.view.Anchor? anchor Nil on a row that no map holds.
local function anchor_of(view)
  local row = cursor_row(view)
  local maps = { view.map, view.old_map }
  if view.old_map and api.nvim_get_current_win() == view.old_win then
    maps = { view.old_map, view.map }
  end
  for _, map in ipairs(maps) do
    local line, side = map:file_line(row)
    if line and side then
      return { line = line, side = side }
    end
  end

  local map = maps[1]
  local record = map:row(row)
  if not record then
    return nil
  end
  ---@type codeview.view.Anchor
  local anchor = { gap = record.gap, hunk = record.kind == "header" and record.hunk or nil }
  for above = row - 1, 1, -1 do
    local line, side = map:file_line(above)
    if line and side then
      anchor.line, anchor.side = line, side
      break
    end
  end
  if not anchor.gap and not anchor.hunk and not anchor.line then
    return nil
  end
  return anchor
end

---Move the cursor of the view to one buffer row.
---
--- Both windows of a split view move, because the row of a change is the same
--- number on both sides.
---@param view codeview.view.State
---@param row integer Buffer row, from 1.
---@return integer? row Nil when no window shows the view.
local function go_to(view, row)
  local moved = nil
  for _, win in ipairs(view_windows(view)) do
    if pcall(api.nvim_win_set_cursor, win, { row, 0 }) then
      moved = row
    end
  end
  return moved
end

---Move the cursor to the row of an anchor.
---
--- A hunk header and the row of a collapsed section keep their number, so the
--- call finds them again by that number. Every other anchor takes the row of
--- its file line, or of the closest line above it.
---@param view codeview.view.State
---@param anchor codeview.view.Anchor?
---@return integer? row
local function place(view, anchor)
  if not anchor then
    return nil
  end
  local map = map_of(view, anchor.side or "new")
  if anchor.gap then
    for lnum, record in ipairs(map.rows) do
      if record.kind == "filler" and record.gap == anchor.gap then
        return go_to(view, lnum)
      end
    end
  end
  if anchor.hunk then
    local first = map:hunk_rows(anchor.hunk)
    if first then
      return go_to(view, first)
    end
  end
  if not anchor.line or not anchor.side then
    return nil
  end
  local row = map:nearest_row(anchor.line, anchor.side)
  if not row then
    return nil
  end
  return go_to(view, row)
end

---Write the diff into the buffers of the style.
---@param view codeview.view.State
local function draw(view)
  if view.style == "split" then
    local build = split.render(view.old_buf --[[@as integer]], view.buf, view.diff, { expanded = view.expanded })
    view.map = build.new.map
    view.old_map = build.old.map
    split.bind(view.old_win --[[@as integer]], view.win)
    return
  end
  view.map = inline.render(view.buf, view.diff, { expanded = view.expanded }).map
  view.old_map = nil
end

---Render the diff of the view again.
---
--- The cursor keeps its file line, so a collapse, an expand, or a change of
--- the style does not move the reader.
---@param view codeview.view.State
---@param anchor codeview.view.Anchor? Line to keep. The line of the cursor by default.
---@return codeview.view.State view
local function rerender(view, anchor)
  if not api.nvim_buf_is_valid(view.buf) then
    return view
  end
  if not anchor and #view_windows(view) > 0 then
    anchor = anchor_of(view)
  end
  draw(view)
  -- The comments are extmarks over the new rows. They never change the text of
  -- the buffer, so the line map of the render stays correct. The comments of a
  -- pull request use their own namespace, next to the local ones.
  require("codeview.comments").decorate(view)
  require("codeview.remote").decorate(view)
  place(view, anchor)
  return view
end

---Close the windows and delete the buffers of a view.
---
--- The session forgets the windows and the buffers again, so that its lists
--- hold the handles that live, and not one pair per file of the review.
---@param view codeview.view.State
local function unmount(view)
  for _, id in ipairs(view.guards) do
    pcall(api.nvim_del_autocmd, id)
  end
  view.guards = {}

  if view.old_win then
    if api.nvim_win_is_valid(view.old_win) then
      pcall(api.nvim_win_close, view.old_win, true)
    end
    view.session:remove_window(view.old_win)
  end
  view.old_win = nil

  local buffers = { view.buf }
  if view.old_buf then
    buffers[#buffers + 1] = view.old_buf
  end
  view.old_buf = nil
  for _, buf in ipairs(buffers) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
    view.session:remove_buffer(buf)
  end
end

---Bring the view back after the user closes one window of the split style.
---
--- The definition follows |mount()|.
---@type fun(view: codeview.view.State)
local repair_split

---Watch the two windows of the side-by-side style.
---
--- The windows show one diff together, so the view does not stay in the split
--- style with one window.
---@param view codeview.view.State
---@param wins integer[] Windows of the style.
local function watch_split(view, wins)
  local group = view.session:augroup()
  for _, win in ipairs(wins) do
    view.guards[#view.guards + 1] = api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      once = true,
      desc = "Repair the codeview diff after a window of the split closes",
      callback = function()
        -- The window is still open here. The repair runs after the close.
        vim.schedule(function()
          repair_split(view)
        end)
      end,
    })
  end
end

---Map the load key on the buffers of a diff that the line limit stopped.
---
--- The key is free in the diff buffer of every other file, because a diff that
--- the view shows needs no second read. |<CR>| then keeps its own action.
---@param view codeview.view.State
local function set_load_key(view)
  if not view.diff.limited then
    return
  end
  for _, buf in ipairs({ view.buf, view.old_buf }) do
    if buf and api.nvim_buf_is_valid(buf) then
      for _, lhs in ipairs(config.keys(config.get().keymaps.load_diff)) do
        vim.keymap.set("n", lhs, function()
          M.load_diff()
        end, { buffer = buf, nowait = true, silent = true, desc = "codeview: file view" })
      end
    end
  end
end

---Open the windows and the buffers of one style.
---
--- The split style puts the old side in a new window at the left of the window
--- of the view.
---@param view codeview.view.State
---@param style codeview.view.Style
---@param win_hint integer? Window that the view had before.
local function mount(view, style, win_hint)
  local session = view.session
  view.style = style

  local buf = make_buf(session, view.path, style == "split" and "new" or nil)
  local win = usable(win_hint) and win_hint or target_window(session, buf)
  if api.nvim_win_get_buf(win) ~= buf then
    api.nvim_win_set_buf(win, buf)
  end
  view.buf, view.win = buf, win

  if style ~= "split" then
    view.old_buf, view.old_win, view.old_map = nil, nil, nil
    inline.attach_window(win)
    set_load_key(view)
    return
  end

  local old_buf = make_buf(session, view.diff.old_path ~= "" and view.diff.old_path or view.path, "old")
  local ok, old_win = pcall(api.nvim_open_win, old_buf, false, { split = "left", win = win })
  if not ok then
    -- The tab page has no room for the second window. Keep the inline style.
    pcall(api.nvim_buf_delete, old_buf, { force = true })
    view.style = "inline"
    view.old_buf, view.old_win, view.old_map = nil, nil, nil
    inline.attach_window(win)
    set_load_key(view)
    return
  end
  session:add_window(old_win)
  view.old_buf, view.old_win = old_buf, old_win
  split.attach_window(old_win)
  split.attach_window(win)
  watch_split(view, { old_win, win })
  set_load_key(view)
end

---Bring the view back after the user closes one window of the split style.
---
--- A window alone shows one side of the diff, with filler rows that align to
--- nothing. The view takes the inline style in the window that stays. The call
--- keeps the `diff.style` option, so the next file opens side by side again.
---@param view codeview.view.State
function repair_split(view)
  if state ~= view or view.style ~= "split" or not view.session:is_active() then
    return
  end
  local wins = view_windows(view)
  if #wins > 1 then
    return
  end
  if #wins == 0 then
    -- Both windows are gone. The view goes with them.
    unmount(view)
    state = nil
    return
  end

  local keep = view_window(view)
  if not keep then
    -- The new side closed. The window of the old side takes the inline diff.
    keep = view.old_win
    view.old_win = nil
  end
  local focus = keep == api.nvim_get_current_win()

  unmount(view)
  mount(view, "inline", usable(keep) and keep or nil)
  rerender(view)
  if focus and api.nvim_win_is_valid(view.win) then
    api.nvim_set_current_win(view.win)
  end
  announce(view)
end

---Report whether a view still holds a buffer.
---
--- The buffers of a view wipe when their window closes. A view without a
--- buffer shows nothing, and it cannot come back.
---@param view codeview.view.State
---@return boolean
local function alive(view)
  if api.nvim_buf_is_valid(view.buf) then
    return true
  end
  -- The split style keeps the diff while one side lives. |repair_split()|
  -- moves it into the window that stays.
  return view.old_buf ~= nil and api.nvim_buf_is_valid(view.old_buf)
end

---Read the file that the view shows.
---@return codeview.view.State? view Nil when no file is open.
function M.current()
  if state and not state.session:is_active() then
    state = nil
  end
  if state and not alive(state) then
    unmount(state)
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
---@param opts? codeview.view.OpenOpts
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return codeview.view.State? view
---@return codeview.Error? err
function M.open(session, index, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
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

  ---Put the diff into the buffers of the style and show it.
  ---
  --- The buffers of the file that was open go first, because a new buffer
  --- takes the same name after a second open of the same file.
  ---@param result codeview.diff.File
  ---@return codeview.view.State
  local function show(result)
    local previous = state
    local keep = previous and previous.win or nil
    highlight.setup()

    ---@type codeview.view.State
    local view = {
      session = session,
      index = index,
      path = file.path,
      status = file.status,
      rev = rev,
      old_rev = old_rev,
      new_rev = new_rev,
      diff = result,
      -- The commit message holds one side only, so the side-by-side style has
      -- nothing to put in the other window.
      style = file.virtual and "inline" or config.get().diff.style,
      map = linemap.new(),
      old_map = nil,
      expanded = {},
      buf = -1,
      win = -1,
      guards = {},
    }
    -- The new file takes the window of the file that was open, and the old
    -- buffers go away after that. The other order closes the window first,
    -- which gives its room to the sidebar and splits the sidebar on the next
    -- open. See |codeview.layout.keep()|.
    layout.keep(function()
      if previous then
        release_name(previous.buf)
        release_name(previous.old_buf)
      end
      mount(view, view.style, keep)
      if previous then
        unmount(previous)
      end
    end)
    state = view
    rerender(view)
    announce(view)
    return view
  end

  local ticket = ticket_of()
  -- A forced open removes the line limit, so the diff of a large file renders.
  local diff_opts = opts.force and { max_lines = 0 } or nil

  if file.virtual then
    -- A commit document reads the files of its commit from the backend, so it
    -- takes the same sync and async form as a diff.
    local message = require("codeview.message")
    if not cb then
      local document, err = message.for_commit(session, file)
      if not document then
        return nil, err
      end
      return show(document), nil
    end
    pending = { session = session, index = index, ticket = ticket }
    message.for_commit(session, file, function(document, err)
      if not fresh(ticket) then
        return
      end
      pending = nil
      if not session:is_active() then
        return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the session is closed"))
      end
      if not document then
        return done(cb, nil, err)
      end
      done(cb, show(document), nil)
    end)
    return nil, nil
  end

  if not cb then
    local result, err = diff_mod.for_file(session, file, diff_opts)
    if not result then
      return nil, err
    end
    return show(result), nil
  end

  pending = { session = session, index = index, ticket = ticket }
  diff_mod.for_file(session, file, diff_opts, function(result, err)
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

---Renderer of the style of a view.
---@param view codeview.view.State
---@return table module |codeview.inline| or |codeview.split|.
local function renderer(view)
  return view.style == "split" and split or inline
end

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
    local gap = renderer(view).gap_at(view.buf, cursor_row(view))
    if not gap then
      return false
    end
    id = gap.id
  end
  if not renderer(view).gaps(view.buf)[id] then
    return false
  end
  if expanded == nil then
    expanded = not view.expanded[id]
  end
  view.expanded[id] = expanded or nil
  rerender(view)
  return true
end

---Collapsed section that hides one line of a side.
---@param view codeview.view.State
---@param line integer Line in the file, from 1.
---@param side codeview.linemap.Side Side that holds the line.
---@return codeview.layout.Gap? gap Nil when no section hides the line.
local function gap_over(view, line, side)
  for _, gap in ipairs(renderer(view).gaps(view.buf)) do
    local first = gap[side]
    if first and not view.expanded[gap.id] and line >= first and line < first + gap.count then
      return gap
    end
  end
  return nil
end

---Move the cursor to one line of the file that the view shows.
---
--- A collapsed section that hides the line shows its lines again, so that the
--- cursor lands on the line itself. Without a row for the line the cursor goes
--- to the closest row.
---@param line integer Line in the file, from 1.
---@param side codeview.linemap.Side? Side that holds the line. "new" by default.
---@param opts? { focus?: boolean } `focus = true` puts the cursor in the diff window.
---@return integer? row Buffer row of the cursor. Nil when no file is open.
function M.go_to_line(line, side, opts)
  opts = opts or {}
  local view = M.current()
  if not view or type(line) ~= "number" then
    return nil
  end
  side = side == "old" and "old" or "new"

  if not map_of(view, side):buf_row(line, side) then
    local gap = gap_over(view, line, side)
    if gap then
      view.expanded[gap.id] = true
      rerender(view)
    end
  end

  local map = map_of(view, side)
  local row = map:buf_row(line, side) or map:nearest_row(line, side) or map:next_row(line, side)
  if not row then
    return nil
  end
  go_to(view, row)

  if opts.focus then
    local win = view.win
    if side == "old" and view.old_win and api.nvim_win_is_valid(view.old_win) then
      win = view.old_win
    end
    if api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
    end
  end
  return row
end

---Show the hidden lines of every collapsed section.
---@return boolean changed False when no file is open.
function M.expand_all()
  local view = M.current()
  if not view then
    return false
  end
  for _, gap in ipairs(renderer(view).gaps(view.buf)) do
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

---Render the diff of the file that the line limit stopped.
---
--- The call reads the file again, without the limit. It does nothing on a diff
--- that the view shows already.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return boolean started False when the view shows no limited diff.
function M.load_diff(cb)
  local view = M.current()
  if not view or not view.diff.limited then
    return false
  end
  M.open(view.session, view.index, { force = true }, cb or function(_, err)
    if err then
      notify(tostring(err))
    end
  end)
  return true
end

--- Diff style ------------------------------------------------------------------

---Read the style of the view, or the style of the next file.
---@return codeview.view.Style style
function M.style()
  local view = M.current()
  return view and view.style or config.get().diff.style
end

---Change the diff style.
---
--- The call keeps the diff of the file that is open, so the backend reads no
--- file again. The cursor keeps its line of the file: the call reads the line
--- from the map of the old style and finds its row in the map of the new
--- style. The cursor moves to the window of that side.
---
--- The new style also becomes the `diff.style` option, so the next file opens
--- in the same style.
---@param style codeview.view.Style? Style to set. The other style by default.
---@return codeview.view.Style? style Style after the call. Nil for an invalid name.
function M.set_style(style)
  local cfg = config.get().diff
  if style == nil then
    style = M.style() == "split" and "inline" or "split"
  end
  if style ~= "inline" and style ~= "split" then
    return nil
  end
  cfg.style = style

  local view = M.current()
  if not view or view.style == style then
    return style
  end
  if view.diff and view.diff.message then
    -- The commit message has one side. The option keeps the new value for the
    -- next file, but this view stays inline.
    notify("the commit message has no side-by-side style")
    return view.style
  end

  local anchor = anchor_of(view)
  local focused = has_focus(view)
  -- The window of the view holds the new buffer before the old one goes away.
  -- A close first would give the room of the window to the sidebar.
  local held = { buf = view.buf, old_buf = view.old_buf, old_win = view.old_win, guards = view.guards }
  view.guards = {}
  layout.keep(function()
    release_name(held.buf)
    release_name(held.old_buf)
    mount(view, style, view.win)
    unmount({
      session = view.session,
      guards = held.guards,
      buf = held.buf ~= view.buf and held.buf or nil,
      old_buf = held.old_buf ~= view.old_buf and held.old_buf or nil,
      old_win = held.old_win ~= view.old_win and held.old_win or nil,
    })
  end)
  rerender(view, anchor)

  if focused then
    local win = view.win
    -- A hunk header and the row of a section sit on both sides. Only a row of
    -- the old file moves the cursor to the left window.
    local on_old = anchor and anchor.side == "old" and not anchor.hunk and not anchor.gap
    if style == "split" and on_old and view.old_win then
      win = view.old_win
    end
    if api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
    end
  end
  announce(view)
  return style
end

---Switch between the inline style and the side-by-side style.
---@return codeview.view.Style? style Style after the call.
function M.toggle_style()
  return M.set_style(nil)
end

---Delete the buffers of the view and close the window of the old side.
---
--- The call cancels a request that runs, so that a late answer of the backend
--- does not open a window again.
---@return boolean closed False when no file is open.
function M.close()
  ticket_of()
  if not state then
    return false
  end
  local view = state
  state = nil
  unmount(view)
  return true
end

---Open the file of the review in the working copy.
---
--- The call leaves the review and edits the real file: the window of the diff
--- takes the file on disk, with the cursor on the line of the diff. The file
--- holds the state of the working copy, and not the revision of the review, so
--- the line is the line of the change and not always the same text.
---
--- The window leaves the session, so a later close of the session keeps the
--- file open.
---@param opts? { path?: string, line?: integer, win?: integer }
---@return boolean opened False with a message when there is no file to edit.
function M.edit(opts)
  opts = opts or {}
  local session = require("codeview.session").current()
  if not session or not session:is_active() then
    notify("no review session")
    return false
  end

  local view = M.current()
  local path = opts.path or (view and view.path)
  if not path then
    notify("no file of the review")
    return false
  end
  if require("codeview.message").is(path) then
    notify("a commit message is no file of the working copy")
    return false
  end

  local full = vim.fs.joinpath(session.repo.root, path)
  if vim.fn.filereadable(full) ~= 1 then
    notify("the working copy holds no " .. path)
    return false
  end

  local win = opts.win or (view and view.win) or api.nvim_get_current_win()
  local line = opts.line
  if not line and view and api.nvim_win_is_valid(win) then
    local cursor = api.nvim_win_get_cursor(win)
    line = working_line(view, cursor[1])
  end

  if not usable(win) then
    win = target_window(session, api.nvim_create_buf(false, true))
  end
  -- The window holds a file of the user from here on, so the session must not
  -- close it. The diff buffers wipe themselves once no window shows them, and
  -- |M.current()| drops a state whose buffers are gone, so the view needs no
  -- close call here. A close would take this window with it.
  session:remove_window(win)
  if view and view.old_win and view.old_win ~= win and api.nvim_win_is_valid(view.old_win) then
    -- The side-by-side style holds a second window. One file needs one window.
    session:remove_window(view.old_win)
    pcall(api.nvim_win_close, view.old_win, true)
  end

  api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(full))
  if line then
    local last = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
    pcall(api.nvim_win_set_cursor, win, { math.min(line, last), 0 })
    pcall(vim.cmd, "normal! zz")
  end
  return true
end

return M
