---@brief One runner for every external command.
---
--- All backend calls go through this module. It collects stdout and stderr and
--- returns a result value or a |codeview.Error|. It never throws.
---
--- Each function takes an optional callback as its last argument. Without a
--- callback the call blocks and returns `result, err`. With a callback the
--- call returns at once and the callback gets `result, err` on the main loop.

local errors = require("codeview.error")

local M = {}

---Time limit of a command, in milliseconds.
---@type integer
M.default_timeout = 30000

---Exit code that |vim.system()| reports after a timeout.
local TIMEOUT_CODE = 124

---@class codeview.ExecOpts
---@field cwd string? Working directory of the command.
---@field env table<string, string>? Extra environment variables.
---@field stdin string? Text for standard input.
---@field text boolean? Replace CRLF with LF in the output. True by default.
---@field timeout integer? Milliseconds before the plugin kills the command.

---@class codeview.ExecResult
---@field command string[] Command that ran.
---@field code integer Exit code.
---@field signal integer Signal that stopped the command, or 0.
---@field stdout string Standard output.
---@field stderr string Standard error output.

---@param cmd string[]
---@param res vim.SystemCompleted
---@return codeview.ExecResult? result
---@return codeview.Error? err
local function to_result(cmd, res)
  local signal = res.signal or 0
  if res.code == TIMEOUT_CODE and signal ~= 0 then
    return nil,
      errors.new(errors.codes.TIMEOUT, "command timed out: " .. table.concat(cmd, " "), {
        command = cmd,
        stderr = res.stderr,
      })
  end
  -- A signal stops the command before it can set an exit code. libuv reports
  -- code 0 for that case, which looks like success with empty output.
  if signal ~= 0 and res.code == 0 then
    return nil,
      errors.new(errors.codes.COMMAND_FAILED, string.format("signal %d killed %s", signal, cmd[1]), {
        command = cmd,
        stderr = res.stderr,
      })
  end
  return {
    command = cmd,
    code = res.code,
    signal = res.signal or 0,
    stdout = res.stdout or "",
    stderr = res.stderr or "",
  },
    nil
end

---@param cmd string[]
---@param reason any
---@return codeview.Error
local function spawn_error(cmd, reason)
  return errors.new(errors.codes.SPAWN_FAILED, "cannot run " .. cmd[1], {
    command = cmd,
    stderr = vim.trim(tostring(reason)),
  })
end

---@param cb fun(result: codeview.ExecResult?, err: codeview.Error?)
---@param result codeview.ExecResult?
---@param err codeview.Error?
local function later(cb, result, err)
  vim.schedule(function()
    cb(result, err)
  end)
end

---Run a command and collect its output, whatever the exit code is.
---
--- Use this function when a non-zero exit code carries information, for
--- example an unknown revision. Use |codeview.exec.run()| otherwise.
---@param cmd string[] Command and arguments.
---@param opts? codeview.ExecOpts
---@param cb? fun(result: codeview.ExecResult?, err: codeview.Error?) Callback for the async form.
---@return codeview.ExecResult? result Nil after a spawn error, a timeout, or a signal.
---@return codeview.Error? err
function M.capture(cmd, opts, cb)
  opts = opts or {}
  local sys = {
    text = opts.text ~= false,
    cwd = opts.cwd,
    env = opts.env,
    stdin = opts.stdin,
    timeout = opts.timeout or M.default_timeout,
  }

  if cb then
    local ok, reason = pcall(vim.system, cmd, sys, function(res)
      later(cb, to_result(cmd, res))
    end)
    if not ok then
      later(cb, nil, spawn_error(cmd, reason))
    end
    return nil, nil
  end

  local ok, res = pcall(function()
    return vim.system(cmd, sys):wait()
  end)
  if not ok then
    return nil, spawn_error(cmd, res)
  end
  return to_result(cmd, res --[[@as vim.SystemCompleted]])
end

---@param result codeview.ExecResult
---@return codeview.Error? err
local function exit_error(result)
  if result.code == 0 then
    return nil
  end
  return errors.new(
    errors.codes.COMMAND_FAILED,
    string.format("%s exited with code %d", result.command[1], result.code),
    { command = result.command, stderr = result.stderr }
  )
end

---Run a command and accept only exit code 0.
---@param cmd string[] Command and arguments.
---@param opts? codeview.ExecOpts
---@param cb? fun(result: codeview.ExecResult?, err: codeview.Error?) Callback for the async form.
---@return codeview.ExecResult? result Nil after any failure.
---@return codeview.Error? err
function M.run(cmd, opts, cb)
  if cb then
    M.capture(cmd, opts, function(result, err)
      if not result then
        cb(nil, err)
        return
      end
      local failed = exit_error(result)
      if failed then
        cb(nil, failed)
      else
        cb(result, nil)
      end
    end)
    return nil, nil
  end

  local result, err = M.capture(cmd, opts)
  if not result then
    return nil, err
  end
  local failed = exit_error(result)
  if failed then
    return nil, failed
  end
  return result, nil
end

---Split command output into lines and drop the trailing empty line.
---@param text string?
---@return string[]
function M.lines(text)
  if not text or text == "" then
    return {}
  end
  local out = vim.split(text, "\n", { plain = true })
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

return M
