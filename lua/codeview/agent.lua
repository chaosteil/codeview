---@brief The pr-agent results of chaoshub.
---
--- chaoshub runs pr-agent on a pull request and writes the results to JSON
--- files, one file per tool: `review.json`, `improve.json`, `describe.json`,
--- and `ask.json`. This module reads them for the pull request of a session.
--- pr-agent wrote nothing to GitHub, so the results are read-only.
---
--- The files live in `<root>/<owner>/<repo>/<number>/`. The root is the
--- first of these:
---
--- 1. The `github.agent_dir` option, when it is not empty.
--- 2. `$CHAOSHUB_AGENT_ROOT`. chaoshub sets it for the review that it opens.
--- 3. `$XDG_STATE_HOME/chaoshub/agent`.
--- 4. `~/.local/state/chaoshub/agent`.
---
--- Each file holds one object with the fields `version`, `tool`, `pr`,
--- `head_sha`, `model`, `started_at`, `finished_at`, `usage`, and `data`.
--- The module refuses a file of a `version` other than 1.
---
--- The results load with the session, again after each refresh of the
--- session, and after each change of the directory. A |uv.new_fs_event()|
--- watches the directory, so a run of chaoshub reaches the open review.
---
--- The review, describe, and ask results are documents of the review, in the
--- group "Agent" of the sidebar. See |codeview.message|.

local config = require("codeview.config")
local events = require("codeview.events")
local notify = require("codeview.notify")

local api = vim.api
local fs = vim.fs
local uv = vim.uv

local M = {}

---Version of the file format that the module reads.
---@type integer
M.version = 1

---Tools of pr-agent, in the order of the files.
---@type string[]
M.tools = { "review", "improve", "describe", "ask" }

---Milliseconds between the last change of the directory and the read.
---@type integer
local DEBOUNCE = 100

---@class codeview.agent.Record
---@field version integer Version of the file format.
---@field tool string Name of the tool, for example "review".
---@field pr integer Number of the pull request.
---@field head_sha string Head commit of the pull request when the run started.
---@field model string Name of the model.
---@field started_at string Start time of the run.
---@field finished_at string End time of the run.
---@field usage table Token counts of the run.
---@field data any JSON of pr-agent. For ask, a list of `{ question, answer, head_sha, at }`, newest first.

---@class codeview.agent.Results
---@field review codeview.agent.Record?
---@field improve codeview.agent.Record?
---@field describe codeview.agent.Record?
---@field ask codeview.agent.Record?
---@field errors table<string, string> Reason per tool for a file that the module refused.

---Results of each pull request, by the key of |codeview.agent.key()|.
---@type table<string, codeview.agent.Results>
local cache = {}

---Watcher of each session, by session id.
---@type table<integer, { handle: uv.uv_fs_event_t?, timer: uv.uv_timer_t?, autocmd: integer? }>
local watchers = {}

--- Paths -----------------------------------------------------------------------

---Root of the result files.
---@return string root
function M.root()
  local option = config.get().github.agent_dir
  if option ~= "" then
    return fs.normalize(option)
  end
  local env = vim.env.CHAOSHUB_AGENT_ROOT
  if env and env ~= "" then
    return fs.normalize(env)
  end
  local state = vim.env.XDG_STATE_HOME
  if state and state ~= "" then
    return fs.joinpath(state, "chaoshub", "agent")
  end
  return fs.joinpath(fs.normalize("~"), ".local", "state", "chaoshub", "agent")
end

---Key of the results of one pull request.
---@param info codeview.pr.Info
---@return string key `owner/repo#number`.
function M.key(info)
  return string.format("%s#%d", info.repo, info.number)
end

---Directory of the result files of one pull request.
---@param info codeview.pr.Info `repo` is `owner/name`.
---@return string dir
function M.dir(info)
  local owner, name = (info.repo or ""):match("^([^/]+)/([^/]+)$")
  return fs.joinpath(M.root(), owner or "", name or "", tostring(info.number))
end

--- Read ------------------------------------------------------------------------

---Read one result file.
---@param path string
---@return codeview.agent.Record? record Nil when the file does not exist or when the module refuses it.
---@return string? err Reason of a refusal. Nil for a missing file.
function M.read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil, nil
  end
  local text = handle:read("*a")
  handle:close()
  local ok, record = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(record) ~= "table" then
    return nil, "the file holds no JSON object"
  end
  if record.version ~= M.version then
    return nil, string.format("version %s is not %d", tostring(record.version), M.version)
  end
  return record, nil
end

---Read the result files of one pull request.
---@param info codeview.pr.Info
---@return codeview.agent.Results results
function M.read(info)
  local dir = M.dir(info)
  ---@type codeview.agent.Results
  local results = { errors = {} }
  for _, tool in ipairs(M.tools) do
    local record, err = M.read_file(fs.joinpath(dir, tool .. ".json"))
    if record then
      results[tool] = record
    elseif err then
      results.errors[tool] = err
    end
  end
  return results
end

---Results of one pull request, from the last read.
---@param info codeview.pr.Info?
---@return codeview.agent.Results? results Nil before the first read.
function M.get(info)
  if type(info) ~= "table" or type(info.number) ~= "number" then
    return nil
  end
  return cache[M.key(info)]
end

---Read the results of the pull request of a session and keep them.
---
--- A file that the module refuses gives one warning. The same reason on the
--- next read stays quiet.
---@param session codeview.Session
---@return codeview.agent.Results? results Nil for a session without a pull request.
function M.load(session)
  local info = require("codeview.pr").current(session)
  if not info or session.closed then
    return nil
  end
  local key = M.key(info)
  local held = cache[key]
  local results = M.read(info)
  for tool, err in pairs(results.errors) do
    if not (held and held.errors[tool] == err) then
      notify.warn(string.format("cannot read %s.json of pr-agent: %s", tool, err))
    end
  end
  cache[key] = results
  M.sync_files(session, results)
  events.emit("agent_loaded", { session = session.id })
  return results
end

---Put the pr-agent documents of the results into the file list of a session.
---
--- The documents follow the pull request document. The open view and the
--- sidebar keep their file, because the positions of the list move. An open
--- pr-agent document shows the new result.
---@param session codeview.Session
---@param results codeview.agent.Results
function M.sync_files(session, results)
  local message = require("codeview.message")
  local view_mod = require("codeview.view")
  local open = view_mod.current()
  if open and open.session ~= session then
    open = nil
  end
  local entries = message.agent_entries(results)
  local out, placed = {}, false
  for _, file in ipairs(session.files) do
    if not message.is_agent(file.path) then
      out[#out + 1] = file
      if not placed and message.is_pr(file.path) then
        vim.list_extend(out, entries)
        placed = true
      end
    end
  end
  if not placed then
    out = vim.list_extend(vim.list_extend({}, entries), out)
  end
  session.files = out

  local index = open and session:index_of(open.path) or nil
  if open and index then
    open.index = index
    if message.is_agent(open.path) then
      view_mod.open(session, index, { win = open.win }, function() end)
    end
  end
  local bar = require("codeview.sidebar").get()
  if bar and bar.session == session then
    bar.current = index or bar.current
    bar:render()
  end
end

--- Watch -----------------------------------------------------------------------

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

---Stop the watcher of a session.
---@param session codeview.Session
local function unwatch(session)
  local held = watchers[session.id]
  if not held then
    return
  end
  watchers[session.id] = nil
  shut(held.handle)
  shut(held.timer)
  if held.autocmd then
    pcall(api.nvim_del_autocmd, held.autocmd)
  end
end

---Watch the directory of the results of a session.
---
--- The directory comes to exist when it does not, because a watcher needs
--- it. The events of one write come in a burst, so a timer collects them.
---@param session codeview.Session
---@param info codeview.pr.Info
local function watch(session, info)
  local held = { timer = uv.new_timer() }
  watchers[session.id] = held
  local dir = M.dir(info)
  if vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local handle = uv.new_fs_event()
  if handle then
    local ok = pcall(function()
      return handle:start(dir, {}, function(err)
        if err or not held.timer then
          return
        end
        held.timer:stop()
        held.timer:start(DEBOUNCE, 0, function()
          vim.schedule(function()
            if watchers[session.id] == held and not session.closed then
              M.load(session)
            end
          end)
        end)
      end)
    end)
    if ok then
      held.handle = handle
    else
      shut(handle)
    end
  end
  held.autocmd = api.nvim_create_autocmd("User", {
    group = session:augroup(),
    pattern = "CodeViewSessionRefreshed",
    desc = "Read the pr-agent results of the codeview session again",
    callback = function(event)
      if type(event.data) == "table" and event.data.id == session.id then
        M.load(session)
      end
    end,
  })
end

---Read the results of a pull request session, and follow them.
---
--- The call reads the files at once. It then reads them again on each
--- refresh of the session and on each change of the directory. The close of
--- the session stops the watcher.
---@param session codeview.Session Session of a pull request.
---@return codeview.agent.Results? results Nil for a session without a pull request.
function M.attach(session)
  local info = require("codeview.pr").current(session)
  if not info or session.closed then
    return nil
  end
  if not watchers[session.id] then
    watch(session, info)
    session:on_close(function(closed)
      unwatch(closed)
    end)
  end
  return M.load(session)
end

---Drop every result that the module holds.
function M.clear()
  cache = {}
end

return M
