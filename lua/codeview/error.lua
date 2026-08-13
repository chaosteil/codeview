---@brief One error shape for every command and file call in codeview.
---
--- Backend code never throws. It returns `nil, codeview.Error`. The caller
--- reads `err.code` to react, and `tostring(err)` to show one line to the
--- user.

local M = {}

---@alias codeview.ErrorCode
---| "not_a_repo" # The directory is outside a repository of this backend.
---| "bad_revision" # The revision does not name a commit.
---| "not_found" # A path or an object is missing.
---| "command_failed" # The command ran and reported a non-zero exit code.
---| "spawn_failed" # The command did not start. The executable is missing.
---| "timeout" # The command took longer than the time limit.
---| "invalid_arg" # A caller passed an argument of the wrong shape.
---| "unsupported" # The backend does not support the operation.

---Error codes. Compare `err.code` against these values.
---@type table<string, codeview.ErrorCode>
M.codes = {
  NOT_A_REPO = "not_a_repo",
  BAD_REVISION = "bad_revision",
  NOT_FOUND = "not_found",
  COMMAND_FAILED = "command_failed",
  SPAWN_FAILED = "spawn_failed",
  TIMEOUT = "timeout",
  INVALID_ARG = "invalid_arg",
  UNSUPPORTED = "unsupported",
}

---@class codeview.Error
---@field code codeview.ErrorCode Machine-readable reason.
---@field message string One line that describes the problem.
---@field command string[]? Command that produced the error.
---@field stderr string? Standard error output of the command.

---@class codeview.Error.Opts
---@field command string[]? Command that produced the error.
---@field stderr string? Standard error output of the command.

local mt = {}

---@param e codeview.Error
---@return string
function mt.__tostring(e)
  return M.format(e)
end

---Build an error value.
---@param code codeview.ErrorCode Value from `M.codes`.
---@param message string One line that describes the problem.
---@param opts? codeview.Error.Opts Command context.
---@return codeview.Error
function M.new(code, message, opts)
  opts = opts or {}
  return setmetatable({
    code = code,
    message = message,
    command = opts.command,
    stderr = opts.stderr,
  }, mt)
end

---Report whether a value is an error of this module.
---@param value any
---@return boolean
function M.is(value)
  return type(value) == "table" and getmetatable(value) == mt
end

---Render an error as one line.
---@param e codeview.Error
---@return string
function M.format(e)
  local text = e.message
  local stderr = vim.trim(e.stderr or "")
  if stderr ~= "" and not text:find(stderr, 1, true) then
    text = text .. ": " .. vim.split(stderr, "\n", { plain = true })[1]
  end
  return text
end

return M
