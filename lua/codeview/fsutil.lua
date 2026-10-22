---@brief File helpers that more than one module needs.
---
--- The comment store and the export both write files with
--- |codeview.fsutil.write_atomic()|.

local errors = require("codeview.error")

local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local M = {}

---Write a text to a file, without a partial result.
---
--- The call writes a temporary file in the directory of the target and renames
--- it. A rename inside one directory is atomic, so a reader sees the old file
--- or the new file, never a half file.
---@param path string
---@param text string
---@return boolean ok
---@return codeview.Error? err
function M.write_atomic(path, text)
  local dir = fs.dirname(path)
  if fn.isdirectory(dir) == 0 then
    local made = pcall(fn.mkdir, dir, "p")
    if not made or fn.isdirectory(dir) == 0 then
      return false, errors.new(errors.codes.COMMAND_FAILED, "cannot make the directory " .. dir)
    end
  end

  local tmp = string.format("%s.%d.tmp", path, uv.os_getpid())
  local handle, open_err = io.open(tmp, "wb")
  if not handle then
    return false, errors.new(errors.codes.COMMAND_FAILED, "cannot write " .. tmp .. ": " .. tostring(open_err))
  end
  local written, write_err = handle:write(text)
  handle:close()
  if not written then
    os.remove(tmp)
    return false, errors.new(errors.codes.COMMAND_FAILED, "cannot write " .. tmp .. ": " .. tostring(write_err))
  end

  local ok, rename_err = uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, errors.new(errors.codes.COMMAND_FAILED, "cannot replace " .. path .. ": " .. tostring(rename_err))
  end
  return true, nil
end

return M
