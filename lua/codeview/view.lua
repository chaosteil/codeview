---@brief The file view of a session.
---
--- The view shows one changed file of the session in the main window, next to
--- the sidebar. It reads the content of the file from the backend: the head
--- revision of the range, or the base revision for a file that the range
--- deletes.
---
--- This milestone shows the content of the file. M4 renders a diff into the
--- same window, with the same navigation.
---
--- The view keeps one buffer. A second open replaces the buffer, so the tab
--- page never holds more than one view buffer.

local config = require("codeview.config")
local errors = require("codeview.error")
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
---@field buf integer Buffer that holds the content.
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
      vim.notify("codeview: " .. tostring(err), vim.log.levels.INFO)
    end
  end

  add(keys.next_file, function()
    M.next(session, report)
  end)
  add(keys.prev_file, function()
    M.prev(session, report)
  end)
  add(keys.close, function()
    session:close()
  end)
end

---Make the buffer for one file.
---@param session codeview.Session
---@param file codeview.vcs.FileChange
---@param content string Content of the file at the revision of the view.
---@return integer buf
local function make_buf(session, file, content)
  local buf = api.nvim_create_buf(false, true)
  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  pcall(api.nvim_buf_set_name, buf, string.format("codeview://%d/%s", session.id, file.path))

  local filetype = vim.filetype.match({ filename = file.path, buf = buf })
  if filetype then
    vim.bo[buf].filetype = filetype
  end

  set_keymaps(session, buf)
  session:add_buffer(buf)
  return buf
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

  local rev = session.range.to
  if file.status == "deleted" and session.range.from then
    rev = session.range.from
  end

  ---Put the content into a buffer and show it.
  ---
  --- The buffer of the file that was open goes first, because the new buffer
  --- takes the same name after a second open of the same file.
  ---@param content string
  ---@return codeview.view.State
  local function show(content)
    local previous = state and state.buf
    if previous and api.nvim_buf_is_valid(previous) then
      pcall(api.nvim_buf_delete, previous, { force = true })
    end
    local buf = make_buf(session, file, content)
    local win = target_window(session, buf)
    if api.nvim_win_get_buf(win) ~= buf then
      api.nvim_win_set_buf(win, buf)
    end

    state = {
      session = session,
      index = index,
      path = file.path,
      status = file.status,
      rev = rev,
      buf = buf,
      win = win,
    }
    announce(state)
    return state
  end

  local ticket = ticket_of()

  if not cb then
    local content, err = session.repo:file_content(rev, file.path)
    if not content then
      return nil, err
    end
    return show(content), nil
  end

  pending = { session = session, index = index, ticket = ticket }
  session.repo:file_content(rev, file.path, function(content, err)
    if not fresh(ticket) then
      return
    end
    pending = nil
    if not session:is_active() then
      cb(nil, errors.new(errors.codes.INVALID_ARG, "the session is closed"))
      return
    end
    if not content then
      cb(nil, err)
      return
    end
    cb(show(content), nil)
  end)
  return nil, nil
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
