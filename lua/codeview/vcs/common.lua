---@brief Helpers that the git backend and the jj backend share.
---
--- The module holds no state. Each backend builds its own command line, and
--- this module runs it. The argument checks give the same error for the same
--- bad input in both backends.

local exec = require("codeview.exec")
local errors = require("codeview.error")
local fs = vim.fs
local uv = vim.uv

local M = {}

---Run a command and map its result.
---
--- Without a callback the call blocks and returns `value, err`. With a
--- callback it returns at once and calls `cb(value, err)` on the main loop.
---@param cmd string[] Full command line.
---@param opts codeview.ExecOpts Options of |codeview.exec.capture()|.
---@param handle fun(result: codeview.ExecResult): any?, codeview.Error? Maps the result to a value or an error.
---@param cb? fun(value: any?, err: codeview.Error?) Callback for the async form.
---@return any? value
---@return codeview.Error? err
function M.call(cmd, opts, handle, cb)
  if cb then
    exec.capture(cmd, opts, function(result, err)
      if not result then
        cb(nil, err)
        return
      end
      cb(handle(result))
    end)
    return nil, nil
  end

  local result, err = exec.capture(cmd, opts)
  if not result then
    return nil, err
  end
  return handle(result)
end

---Directory to start the search for a repository from.
---
--- A file gives its directory. A path that does not exist gives nil.
---@param dir? string Directory or file. The current directory by default.
---@return string? path
function M.start_dir(dir)
  local path = dir and fs.normalize(dir) or uv.cwd()
  if not path then
    return nil
  end
  local stat = uv.fs_stat(path)
  if not stat then
    return nil
  end
  if stat.type == "directory" then
    return path
  end
  return fs.dirname(path)
end

---Resolve a range without a base.
---
--- The base is nil, which means the state before the first commit. Every file
--- of `to` is then an addition.
---@param repo codeview.vcs.Repo
---@param to string Revision of the head side.
---@param text string Text that the user wrote.
---@param cb? fun(range: codeview.vcs.Range?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.Range? range
---@return codeview.Error? err
function M.explicit_range(repo, to, text, cb)
  if not cb then
    local id, err = repo:resolve_rev(to)
    if not id then
      return nil, err
    end
    return { from = nil, to = id, spec = text }, nil
  end
  repo:resolve_rev(to, function(id, err)
    if not id then
      cb(nil, err)
      return
    end
    cb({ from = nil, to = id, spec = text }, nil)
  end)
  return nil, nil
end

--- Argument checks -----------------------------------------------------------

---Check a revision argument.
---@param rev any Value from the caller.
---@return string? rev The revision without white space around it.
---@return codeview.Error? err
function M.check_rev(rev)
  if type(rev) ~= "string" or vim.trim(rev) == "" then
    return nil, errors.new(errors.codes.INVALID_ARG, "revision must be a non-empty string")
  end
  return vim.trim(rev), nil
end

---Check a range with resolved revisions.
---@param range any Value from the caller.
---@return codeview.Error? err Nil for a valid range.
function M.check_range(range)
  if type(range) ~= "table" or type(range.to) ~= "string" then
    return errors.new(errors.codes.INVALID_ARG, "range needs a `to` revision")
  end
  return nil
end

---Check a path argument.
---@param path any Value from the caller.
---@return codeview.Error? err Nil for a valid path.
function M.check_path(path)
  if type(path) ~= "string" or path == "" then
    return errors.new(errors.codes.INVALID_ARG, "path must be a non-empty string")
  end
  return nil
end

---Read a range table or a parsed spec.
---
--- A table with a `kind` is a parsed spec. A table without one is a
--- |codeview.vcs.Range|. Its nil `from` means the state before the first
--- commit, so it becomes the `explicit` form.
---@param spec any Value from the caller.
---@param kinds table<string, boolean> Forms that the backend reads.
---@return codeview.vcs.RangeSpec? parsed
---@return codeview.Error? err
function M.table_spec(spec, kinds)
  if type(spec) ~= "table" or type(spec.to) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "range needs a `to` revision")
  end
  if not spec.kind then
    return { kind = spec.from and "range" or "explicit", from = spec.from, to = spec.to, spec = spec.spec }, nil
  end
  if not kinds[spec.kind] then
    return nil, errors.new(errors.codes.INVALID_ARG, "the backend does not read the range form " .. tostring(spec.kind))
  end
  if (spec.kind == "range" or spec.kind == "triple") and type(spec.from) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the " .. spec.kind .. " form needs a `from` revision")
  end
  ---@cast spec codeview.vcs.RangeSpec
  return spec, nil
end

return M
