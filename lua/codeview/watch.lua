---@brief The repository watcher of a review.
---
--- A review holds the resolved commit ids of its range. A commit, an amend, a
--- rebase, or a `jj new` in another terminal moves those ids, and the sidebar
--- then shows old data. This module watches the state directories of the
--- repository, and it reads the review again when the range moves.
---
--- One |uv.new_fs_event()| watches each directory of `repo:state_dirs()`. The
--- events of one operation come in a burst, so a timer of 200 ms collects them
--- and runs one check after the last event. A file system that gives no event
--- still gets a check on `FocusGained`.
---
--- The watcher never writes the repository. It resolves the range with a
--- read-only command, and it reads the review again without a snapshot of the
--- working copy. The refresh key of |codeview-keymaps| is the one that takes
--- the working copy with it.
---
--- Set `auto_refresh` to false to switch the watcher off.

local config = require("codeview.config")
local errors = require("codeview.error")
local util = require("codeview.util")

local api = vim.api
local uv = vim.uv

local done = util.done

local M = {}

---Milliseconds between the last event and the check.
---@type integer
local DEBOUNCE = 200

---@class codeview.watch.State
---@field session codeview.Session Session that the watcher follows.
---@field handles uv.uv_fs_event_t[] One watcher per state directory.
---@field timer uv.uv_timer_t? Timer that collects a burst of events.
---@field group integer? Autocmd group of the fallback trigger.
---@field running boolean True while a check runs.
---@field pending boolean True when an event came in while a check ran.
---@field quiet boolean True after a failed check. It stops a second message.

---Watcher that runs now.
---@type codeview.watch.State?
local state = nil

---Close one libuv handle, without an error on a handle that closes already.
---@param handle uv.uv_handle_t?
local function shut(handle)
  if not handle then
    return
  end
  pcall(function()
    handle:stop()
  end)
  pcall(function()
    if not handle:is_closing() then
      handle:close()
    end
  end)
end

---Report whether a watcher runs.
---@return boolean
function M.is_active()
  return state ~= nil
end

---Stop the watcher.
---
--- The call closes the file system handles and the timer, and it deletes the
--- autocmd group. A second call does nothing.
---@return boolean stopped False when no watcher runs.
function M.stop()
  if not state then
    return false
  end
  local held = state
  state = nil
  for _, handle in ipairs(held.handles) do
    shut(handle)
  end
  held.handles = {}
  shut(held.timer)
  held.timer = nil
  if held.group then
    pcall(api.nvim_del_augroup_by_id, held.group)
    held.group = nil
  end
  return true
end

---Read the range of the session again and compare it with the review.
---
--- The call resolves the argument of the open call with a read-only command.
--- On jj that command runs with `--ignore-working-copy`, so the check writes
--- nothing. The same commit ids mean that the review is current, and the call
--- does nothing. Other ids read the review again with
--- |codeview.view.refresh()|, without a snapshot of the working copy.
---
--- A failed check keeps the data of the review. The user gets one message,
--- and the next failed checks stay quiet until a check succeeds.
---@param session? codeview.Session Session to check. The session of the watcher by default.
---@param cb? fun(changed: boolean?, err: codeview.Error?) Callback for the async form.
---@return boolean? changed True when the call read the review again. Nil with a callback.
---@return codeview.Error? err
function M.check(session, cb)
  if type(session) == "function" then
    cb, session = session, nil
  end
  local held = state
  session = session or (held and held.session) or nil
  if not session or session.closed then
    return done(cb, false, nil)
  end

  -- The watcher owns the session only when it watches that session. A call of
  -- a test on another session takes no state of the watcher.
  local mine = held ~= nil and held.session == session
  if mine and held.running then
    -- A check runs already. The repository can move again while it runs, so
    -- one more check follows this one.
    held.pending = true
    return done(cb, false, nil)
  end
  if mine then
    held.running = true
  end

  ---Report the answer, and run the check that came in while this one ran.
  ---@param changed boolean?
  ---@param err codeview.Error?
  ---@return boolean?, codeview.Error?
  local function finish(changed, err)
    if mine and state == held then
      held.running = false
      if held.pending then
        held.pending = false
        vim.schedule(function()
          if state == held then
            M.check(held.session, function() end)
          end
        end)
      end
    end
    return done(cb, changed, err)
  end

  ---Compare the answer of the backend with the range of the review.
  ---@param range codeview.vcs.Range?
  ---@param err codeview.Error?
  ---@return boolean?, codeview.Error?
  local function handle(range, err)
    if not range then
      err = err or errors.new(errors.codes.COMMAND_FAILED, "the range call gave no answer")
      if mine and state == held and not held.quiet then
        held.quiet = true
        vim.notify("codeview: the watcher cannot read the range: " .. tostring(err), vim.log.levels.WARN)
      end
      return finish(nil, err)
    end
    if mine and state == held then
      held.quiet = false
    end
    if session.closed then
      return finish(false, nil)
    end
    if range.from == session.range.from and range.to == session.range.to then
      return finish(false, nil)
    end
    -- The refresh takes no snapshot. The trigger is an operation of the
    -- repository, and the working copy belongs to the user.
    require("codeview.view").refresh({ snapshot = false })
    return finish(true, nil)
  end

  if not cb then
    return handle(session.repo:resolve_range(session.input))
  end
  session.repo:resolve_range(session.input, function(range, err)
    handle(range, err)
  end)
  return nil, nil
end

---Watch the repository of a session.
---
--- The call does nothing when the `auto_refresh` option is false. A second
--- call stops the watcher of the session before, because the plugin watches
--- one session. The watcher stops with the session.
---@param session codeview.Session Session to follow.
---@return boolean started False when the option is off, or when no watcher attached.
function M.start(session)
  M.stop()
  if type(session) ~= "table" or session.closed or not config.get().auto_refresh then
    return false
  end

  -- The call reads the git directory once. A failed call leaves the review
  -- without a watcher, and the refresh key still works.
  local dirs = session.repo:state_dirs()
  if not dirs or #dirs == 0 then
    return false
  end

  ---@type codeview.watch.State
  local watcher = {
    session = session,
    handles = {},
    timer = nil,
    group = nil,
    running = false,
    pending = false,
    quiet = false,
  }

  local timer = uv.new_timer()
  watcher.timer = timer

  ---Run one check after the last event of a burst.
  local function trigger()
    if state ~= watcher or not timer then
      return
    end
    timer:stop()
    timer:start(DEBOUNCE, 0, function()
      -- The timer runs in the loop of libuv. Every call of the editor needs
      -- the main loop.
      vim.schedule(function()
        if state == watcher and not watcher.session.closed then
          M.check(watcher.session, function() end)
        end
      end)
    end)
  end

  for _, dir in ipairs(dirs) do
    local handle = uv.new_fs_event()
    if handle then
      local ok = pcall(function()
        return handle:start(dir, {}, function(fs_err)
          if not fs_err then
            trigger()
          end
        end)
      end)
      if ok then
        watcher.handles[#watcher.handles + 1] = handle
      else
        shut(handle)
      end
    end
  end

  if #watcher.handles == 0 then
    shut(timer)
    return false
  end

  state = watcher
  -- A network file system gives no event. The check on a return to the editor
  -- is the fallback for it.
  watcher.group = api.nvim_create_augroup("codeview.watch", { clear = true })
  api.nvim_create_autocmd("FocusGained", {
    group = watcher.group,
    desc = "Read the codeview review again after a change of the repository",
    callback = function()
      if state == watcher then
        M.check(watcher.session, function() end)
      end
    end,
  })
  session:on_close(function()
    if state == watcher then
      M.stop()
    end
  end)
  return true
end

return M
