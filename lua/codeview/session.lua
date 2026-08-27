---@brief The review session.
---
--- A session holds the backend handle, the resolved range, the commits of the
--- range, and the files that the range changes. It also owns the windows,
--- buffers, and autocmds that the later views create, and closes them again.
---
--- The plugin keeps one active session. |codeview.session.open()| closes the
--- session that runs, after the new session has its data. A failed open keeps
--- the old session.
---
--- `open()` takes an optional callback, like the backend calls. Without a
--- callback it blocks and returns `session, err`. With a callback it returns
--- at once and calls `cb(session, err)` on the main loop.
---
--- A session reads its data again with |codeview.Session:refresh()|. On a
--- review of the working-copy commit, |codeview.Session:reload()| also takes
--- the new state of the working copy.

local config = require("codeview.config")
local errors = require("codeview.error")
local util = require("codeview.util")
local vcs = require("codeview.vcs")

local api = vim.api

local chain = util.chain
local done = util.done
local short = util.short

local M = {}

---@class codeview.Session
---@field id integer Number of the session. It counts from 1.
---@field repo codeview.vcs.Repo Repository handle of the backend.
---@field range codeview.vcs.Range Range with resolved commit ids.
---@field spec string Text that names the range.
---@field files codeview.vcs.FileChange[] Files that the range changes.
---@field commits codeview.vcs.Commit[] Commits of the range, newest first.
---@field store_key string? Key text of the comment store. A pull request session sets it.
---@field pr codeview.pr.Info? Pull request that the session reviews. Nil for a local range.
---@field opened_at integer Time of the open call, in seconds since the epoch.
---@field closed boolean True after |codeview.Session:close()|.
---@field private windows integer[] Windows that close with the session.
---@field private buffers integer[] Buffers that close with the session.
---@field private callbacks fun(session: codeview.Session)[] Handlers of the close event.
---@field private group integer? Autocmd group, made on demand.
local Session = {}
Session.__index = Session

---Session that runs now.
---@type codeview.Session?
local current = nil

---Number of sessions that this Neovim opened.
---@type integer
local counter = 0

---@alias codeview.session.Step codeview.util.Step

---Wrap one backend call, so that it keeps its result in a table.
---@param fn codeview.session.Step Call in the sync form and in the async form.
---@param store table Table that receives the result.
---@param key string Field of the result.
---@return codeview.session.Step
local function into(fn, store, key)
  ---@param value any?
  ---@param err codeview.Error?
  ---@return any?, codeview.Error?
  local function keep(value, err)
    if value == nil then
      return nil, err or errors.new(errors.codes.COMMAND_FAILED, "the " .. key .. " call gave no answer")
    end
    store[key] = value
    return value, nil
  end

  return function(cb)
    if not cb then
      return keep(fn())
    end
    fn(function(value, err)
      cb(keep(value, err))
    end)
    return nil, nil
  end
end

---Text that names a range.
---
--- The text of the user comes first. A range table without text gets a label
--- of short commit ids, because its resolved ids are long.
---@param range codeview.vcs.Range Range with resolved revisions.
---@param input string|codeview.vcs.Range|codeview.vcs.RangeSpec Argument of the open call.
---@param label string? Text of the caller. It wins over the argument.
---@return string
local function label_of(range, input, label)
  if type(label) == "string" and vim.trim(label) ~= "" then
    return vim.trim(label)
  end
  if type(input) == "string" and vim.trim(input) ~= "" then
    return vim.trim(input)
  end
  if type(input) == "table" and type(input.spec) == "string" and input.spec ~= "" then
    return input.spec
  end
  if range.from then
    return short(range.from) .. ".." .. short(range.to)
  end
  return short(range.to)
end

---File list of a session, with one entry per commit at the head.
---
--- The commits read before the code, the way a reviewer reads the message of
--- a change first. The `commit_message` option removes them, and a range
--- without a commit gets none.
---@param files codeview.vcs.FileChange[]
---@param commits codeview.vcs.Commit[]
---@return codeview.vcs.FileChange[]
local function with_message(files, commits)
  if not config.get().commit_message or #(commits or {}) == 0 then
    return files
  end
  local out = require("codeview.message").entries(commits)
  vim.list_extend(out, files)
  return out
end

---Send a User event for a session.
---
--- The payload holds plain values only. `nvim_exec_autocmds()` copies the
--- data through the API layer, which drops the metatable of the session. A
--- handler reads the session itself with |codeview.session.current()|.
---@param name string Name of the User event.
---@param session codeview.Session
local function announce(name, session)
  pcall(api.nvim_exec_autocmds, "User", {
    pattern = name,
    data = {
      id = session.id,
      spec = session.spec,
      files = #session.files,
      commits = #session.commits,
    },
  })
end

--- Open and close ------------------------------------------------------------

---@class codeview.session.OpenOpts
---@field repo codeview.vcs.Repo? Repository handle. Without it the session detects one.
---@field dir string? Directory for the detection. The current directory by default.
---@field backend "auto"|"git"|"jj"? Backend for the detection. The configuration value by default.
---@field label string? Text that names the session. The revision argument by default.
---@field store_key string? Key text of the comment store. The resolved range by default.
---@field pr codeview.pr.Info? Pull request that the session reviews.

---Open a review session.
---
--- The argument is user text (`a`, `a..b`, `a...b`), a parsed spec from
--- |codeview.vcs.parse_range()|, or a range table with resolved revisions.
---@param spec string|codeview.vcs.Range|codeview.vcs.RangeSpec Revision argument.
---@param opts? codeview.session.OpenOpts
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session Nil after an error.
---@return codeview.Error? err
function M.open(spec, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}

  if type(spec) ~= "string" and type(spec) ~= "table" then
    return done(
      cb,
      nil,
      errors.new(errors.codes.INVALID_ARG, "the range must be a string or a table, not " .. type(spec))
    )
  end

  local state = { repo = opts.repo }
  local steps = {}
  if not state.repo then
    steps[#steps + 1] = into(function(step_cb)
      return vcs.detect(opts.dir, { backend = opts.backend }, step_cb)
    end, state, "repo")
  end
  steps[#steps + 1] = into(function(step_cb)
    return state.repo:resolve_range(spec, step_cb)
  end, state, "range")
  steps[#steps + 1] = into(function(step_cb)
    return state.repo:changed_files(state.range, step_cb)
  end, state, "files")
  steps[#steps + 1] = into(function(step_cb)
    return state.repo:log({ range = state.range }, step_cb)
  end, state, "commits")

  ---Build the session, after every call gave its answer.
  ---@return codeview.Session
  local function build()
    M.close()
    counter = counter + 1
    local session = setmetatable({
      id = counter,
      repo = state.repo,
      range = state.range,
      spec = label_of(state.range, spec, opts.label),
      files = with_message(state.files, state.commits),
      commits = state.commits,
      store_key = opts.store_key,
      pr = opts.pr,
      opened_at = os.time(),
      closed = false,
      windows = {},
      buffers = {},
      callbacks = {},
    }, Session)
    current = session
    -- The comments of the range load with the session, so that the first file
    -- shows its anchors at once.
    local _, store_err = require("codeview.comments").attach(session)
    if store_err then
      vim.notify("codeview: " .. tostring(store_err), vim.log.levels.WARN)
    end
    announce("CodeViewSessionOpened", session)
    return session
  end

  if not cb then
    local ok, err = chain(steps)
    if not ok then
      return nil, err
    end
    return build(), nil
  end

  chain(steps, function(ok, err)
    if not ok then
      cb(nil, err)
      return
    end
    cb(build(), nil)
  end)
  return nil, nil
end

---Close the session that runs.
---@return boolean closed False when no session runs.
function M.close()
  if not current then
    return false
  end
  return current:close()
end

---Read the session that runs.
---@return codeview.Session? session
function M.current()
  return current
end

---Report whether a session runs.
---@return boolean
function M.is_active()
  return current ~= nil and not current.closed
end

---Read a review of the working copy again, if the configuration allows it.
---
--- The user interface calls this before it shows a diff again, so that the
--- diff holds the writes of your editor. The `auto_reload` option switches
--- the call off. See |codeview.Session:reload()|.
---
--- A failed reload is no error of the caller. The session keeps its data, the
--- user gets a message, and the diff opens with the old data.
---@param session? codeview.Session Session to read again. The session that runs by default.
---@return codeview.Session? session The same session.
function M.auto_reload(session)
  session = session or current
  if not session or session.closed or not config.get().auto_reload then
    return session
  end
  local _, err = session:reload()
  if err then
    vim.notify("codeview: the reload failed: " .. tostring(err), vim.log.levels.WARN)
  end
  return session
end

--- Session methods -----------------------------------------------------------

---Text that names the range of the session.
---@return string
function Session:label()
  return self.spec
end

---One line with the range, the file count, and the commit count.
---@return string
function Session:summary()
  local count = self:changed_count()
  return string.format(
    "%s: %d %s, %d %s",
    self:label(),
    count,
    count == 1 and "file" or "files",
    #self.commits,
    #self.commits == 1 and "commit" or "commits"
  )
end

---Number of files that the range changes.
---
--- The commit message document is no change of the range, so it does not
--- count. See |codeview.message|.
---@return integer
function Session:changed_count()
  local count = 0
  for _, file in ipairs(self.files) do
    if not file.virtual then
      count = count + 1
    end
  end
  return count
end

---Files that the range changes.
---@return codeview.vcs.FileChange[]
function Session:changed_files()
  return self.files
end

---Read one changed file by its position in the list.
---@param index integer Position, from 1 upwards.
---@return codeview.vcs.FileChange? file Nil when the position is outside the list.
function Session:file(index)
  return self.files[index]
end

---Position of a path in the file list.
---@param path string Path in the new revision.
---@return integer? index Nil when the range does not change the path.
function Session:index_of(path)
  for index, file in ipairs(self.files) do
    if file.path == path then
      return index
    end
  end
  return nil
end

---Report whether the session still runs.
---@return boolean
function Session:is_active()
  return not self.closed
end

---Read the files and the commits of one range into a session.
---@param session codeview.Session
---@param range codeview.vcs.Range Range to read. It becomes the range of the session.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session
---@return codeview.Error? err
local function reread(session, range, cb)
  local state = {}
  local steps = {
    into(function(step_cb)
      return session.repo:changed_files(range, step_cb)
    end, state, "files"),
    into(function(step_cb)
      return session.repo:log({ range = range }, step_cb)
    end, state, "commits"),
  }

  ---Keep the new data, if the session still runs.
  ---
  --- A close can come in while the backend works. A late answer must not
  --- write into a session that closed already.
  ---@return codeview.Session? session
  ---@return codeview.Error? err
  local function apply()
    if session.closed then
      return nil, errors.new(errors.codes.INVALID_ARG, "the session is closed")
    end
    session.range = range
    session.files = with_message(state.files, state.commits)
    session.commits = state.commits
    announce("CodeViewSessionRefreshed", session)
    return session, nil
  end

  if not cb then
    local ok, err = chain(steps)
    if not ok then
      return nil, err
    end
    return apply()
  end

  chain(steps, function(ok, err)
    if not ok then
      cb(nil, err)
      return
    end
    cb(apply())
  end)
  return nil, nil
end

---Read the changed files and the commits again.
---
--- Use this call after the repository changed, for example after an amend.
--- The range stays as it is. |codeview.Session:reload()| also moves the head
--- of the range to the working copy.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session
---@return codeview.Error? err
function Session:refresh(cb)
  if self.closed then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the session is closed"))
  end
  return reread(self, self.range, cb)
end

---Read the review again after a change of the working copy.
---
--- The call acts only on a review that holds the commit of the working copy:
--- `@` on a jj repository. It then writes the working copy into that commit.
--- The new commit id becomes the head of the range, and the call reads the
--- files and the commits of that range again. Every other review keeps its
--- data, and the working copy of the repository stays as it is.
---
--- git holds the working copy outside the commits, so a change of a file
--- moves no commit there. A git session therefore always keeps its data.
---
--- The comments stay with the session, because the comment file follows the
--- session and not the range.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session The session. Its data is new when the working copy moved the head.
---@return codeview.Error? err
function Session:reload(cb)
  if self.closed then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the session is closed"))
  end

  ---Range of the session with a new commit at its head.
  ---@param head string Commit that the working copy sits on now.
  ---@return codeview.vcs.Range
  local function moved(head)
    return { from = self.range.from, to = head, spec = self.range.spec }
  end

  ---@return codeview.Error
  local function gone()
    return errors.new(errors.codes.INVALID_ARG, "the session is closed")
  end

  if not cb then
    local head, head_err = self.repo:working_rev()
    if not head then
      return nil, head_err
    end
    -- The review holds another commit, so the working copy does not belong to
    -- it. A snapshot then writes the repository for nothing.
    if head ~= self.range.to then
      return self, nil
    end
    local fresh, snapshot_err = self.repo:snapshot()
    if not fresh then
      return nil, snapshot_err
    end
    -- The same commit means that the working copy holds no new state.
    if fresh == head then
      return self, nil
    end
    return reread(self, moved(fresh), nil)
  end

  self.repo:working_rev(function(head, head_err)
    if not head then
      cb(nil, head_err)
      return
    end
    if self.closed then
      cb(nil, gone())
      return
    end
    if head ~= self.range.to then
      cb(self, nil)
      return
    end
    self.repo:snapshot(function(fresh, snapshot_err)
      if not fresh then
        cb(nil, snapshot_err)
        return
      end
      if self.closed then
        cb(nil, gone())
        return
      end
      if fresh == head then
        cb(self, nil)
        return
      end
      reread(self, moved(fresh), cb)
    end)
  end)
  return nil, nil
end

--- Lifecycle -----------------------------------------------------------------

---Let a window close with the session.
---@param win integer Window handle.
---@return integer win The same handle.
function Session:add_window(win)
  if not vim.tbl_contains(self.windows, win) then
    self.windows[#self.windows + 1] = win
  end
  return win
end

---Let a buffer close with the session.
---@param buf integer Buffer handle.
---@return integer buf The same handle.
function Session:add_buffer(buf)
  if not vim.tbl_contains(self.buffers, buf) then
    self.buffers[#self.buffers + 1] = buf
  end
  return buf
end

---Take a window out of the list of the session.
---
--- The caller closes the window itself. A view that opens a window for each
--- file calls this, so that the list holds the windows that live.
---@param win integer Window handle.
---@return boolean removed False when the session does not hold the window.
function Session:remove_window(win)
  for index, handle in ipairs(self.windows) do
    if handle == win then
      table.remove(self.windows, index)
      return true
    end
  end
  return false
end

---Take a buffer out of the list of the session.
---
--- The caller deletes the buffer itself.
---@param buf integer Buffer handle.
---@return boolean removed False when the session does not hold the buffer.
function Session:remove_buffer(buf)
  for index, handle in ipairs(self.buffers) do
    if handle == buf then
      table.remove(self.buffers, index)
      return true
    end
  end
  return false
end

---Autocmd group of the session.
---
--- The group is empty until a caller adds an autocmd to it. |Session:close()|
--- deletes the group with every autocmd in it.
---@return integer group Group id for `nvim_create_autocmd()`.
function Session:augroup()
  if not self.group then
    self.group = api.nvim_create_augroup("codeview.session." .. self.id, { clear = true })
  end
  return self.group
end

---Call a function when the session closes.
---
--- The handlers run before the windows and the buffers close. An error in a
--- handler does not stop the close.
---@param fn fun(session: codeview.Session)
function Session:on_close(fn)
  self.callbacks[#self.callbacks + 1] = fn
end

---Close the session.
---
--- The call runs the close handlers, deletes the autocmd group, closes the
--- windows, and deletes the buffers of the session. A second call does
--- nothing.
---@return boolean closed False when the session was closed already.
function Session:close()
  if self.closed then
    return false
  end
  self.closed = true
  if current == self then
    current = nil
  end

  for index = #self.callbacks, 1, -1 do
    pcall(self.callbacks[index], self)
  end
  self.callbacks = {}

  if self.group then
    pcall(api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end

  for _, win in ipairs(self.windows) do
    if api.nvim_win_is_valid(win) then
      -- The call fails on the last window of the last tab page. Keep that one.
      pcall(api.nvim_win_close, win, true)
    end
  end
  self.windows = {}

  for _, buf in ipairs(self.buffers) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  self.buffers = {}

  announce("CodeViewSessionClosed", self)
  return true
end

return M
