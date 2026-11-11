---@brief The file backend: files on the disk, with no repository.
---
--- The backend reviews files that no repository tracks, for example a plan
--- that an agent wrote outside a repository. It implements the interface of
--- |codeview.vcs|, so the session, the sidebar, the comments, and the export
--- work as they do for a range. The automatic detection never picks it. Only
--- |codeview.session.open_files()| makes a handle.
---
--- The handle never runs git or jj to read a file. It reads the files from
--- the disk. A file inside a repository also reads from the disk, with no
--- diff.
---
--- The paths of the handle are files and directories. A directory gives every
--- file below it, with these rules:
---
--- - The walk skips hidden entries: a file or a directory with a name that
---   starts with `.`. This skips `.git` and `.jj` too.
--- - Inside a git work tree, the walk also skips the files that `.gitignore`
---   ignores. git lists the files, so the rules of git apply.
--- - The walk skips binary files, and files above the `files.max_bytes`
---   option. The handle counts them in `skipped`.
--- - More than `files.max_files` files give an error.
---
--- A file that the caller names is always part of the review, also a hidden
--- file, a binary file, or a large file. The diff view then shows the note of
--- a binary file, or the load key of a large file.
---
--- The root of the handle is the deepest directory that holds every path. The
--- paths of the review are relative to it.
---
--- The range of the handle has no base. Its head is a digest of the paths and
--- the contents of the files. A change of a file gives a new digest, and so a
--- new comment store, the way a new commit does for a range.

local config = require("codeview.config")
local errors = require("codeview.error")
local exec = require("codeview.exec")
local util = require("codeview.util")

local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local done = util.done

local M = {}

---Name of the backend.
---@type string
M.name = "file"

---Status of every file of the review.
---@type codeview.vcs.Status
M.status = "file"

---Id of the working copy. The disk has no commit, so the id never changes.
---@type string
M.working = "disk"

---Number of bytes that the binary check reads from the start of a file.
---@type integer
M.probe_bytes = 8000

---@class codeview.vcs.file.Skipped
---@field binary integer Number of binary files that a directory walk skipped.
---@field large integer Number of files above `files.max_bytes` that a directory walk skipped.

---@class codeview.vcs.file.Collected
---@field root string Deepest directory that holds every path.
---@field paths string[] Paths of the files, relative to the root, in order.
---@field skipped codeview.vcs.file.Skipped Files that a directory walk skipped.

---@class codeview.vcs.FileRepo: codeview.vcs.Repo
---@field inputs string[] Absolute paths of the files and directories of the review.
---@field files string[] Paths of the files after the last resolve, relative to the root.
---@field skipped codeview.vcs.file.Skipped Files that the last resolve skipped.
local Repo = {}
Repo.__index = Repo

--- Paths -----------------------------------------------------------------------

---Absolute form of a path, without `.` and `..` parts.
---@param path string
---@param base string Directory for a relative path.
---@return string
function M.absolute(path, base)
  local expanded = fs.normalize(path)
  if expanded:sub(1, 1) ~= "/" then
    expanded = fs.joinpath(base, expanded)
  end
  -- `fnamemodify()` drops the `..` parts. It needs no file on the disk.
  return fs.normalize(fn.fnamemodify(expanded, ":p"))
end

---Parts of an absolute path.
---@param path string
---@return string[]
local function parts(path)
  return vim.split(path, "/", { plain = true, trimempty = true })
end

---Deepest directory that holds every directory of a list.
---@param dirs string[] Absolute paths of directories.
---@return string root
function M.common_root(dirs)
  local common = parts(dirs[1] or "/")
  for index = 2, #dirs do
    local other = parts(dirs[index])
    local count = 0
    while count < #common and count < #other and common[count + 1] == other[count + 1] do
      count = count + 1
    end
    for drop = #common, count + 1, -1 do
      common[drop] = nil
    end
  end
  return "/" .. table.concat(common, "/")
end

---Path of a file relative to a directory that holds it.
---@param path string Absolute path of the file.
---@param root string Absolute path of the directory.
---@return string
local function relative(path, root)
  if root == "/" then
    return path:sub(2)
  end
  return path:sub(#root + 2)
end

---Report whether a relative path holds a hidden part.
---@param path string
---@return boolean
local function hidden(path)
  for _, part in ipairs(parts(path)) do
    if part:sub(1, 1) == "." then
      return true
    end
  end
  return false
end

--- Files -----------------------------------------------------------------------

---Read a file from the disk.
---@param path string Absolute path.
---@param limit integer? Number of bytes to read. Nil reads the whole file.
---@return string? content
---@return string? err
local function read(path, limit)
  local handle, err = io.open(path, "rb")
  if not handle then
    return nil, tostring(err)
  end
  local content = handle:read(limit or "*a") or ""
  handle:close()
  return content, nil
end

---Report whether a file holds binary data.
---@param path string Absolute path.
---@return boolean
local function is_binary(path)
  local head = read(path, M.probe_bytes)
  return head ~= nil and head:find("\0", 1, true) ~= nil
end

---Files of a directory that git lists, without the ignored files.
---
--- git lists the tracked files and the untracked files that `.gitignore` does
--- not ignore. A directory outside a git work tree, or a missing git, gives
--- nil.
---@param dir string Absolute path of the directory.
---@return string[]? paths Paths relative to the directory.
local function git_files(dir)
  local binary = config.get().git.binary
  if fn.executable(binary) ~= 1 then
    return nil
  end
  local result = exec.capture(
    { binary, "-C", dir, "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
    { cwd = dir, env = { LC_ALL = "C" } }
  )
  if not result or result.code ~= 0 then
    return nil
  end
  return vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })
end

---Files below a directory, without the walk of git.
---@param dir string Absolute path of the directory.
---@return string[] paths Paths relative to the directory.
local function walk_files(dir)
  local out = {}
  for name, kind in
    fs.dir(dir, {
      depth = math.huge,
      skip = function(name)
        return fs.basename(name):sub(1, 1) ~= "."
      end,
    })
  do
    if kind ~= "directory" then
      out[#out + 1] = name
    end
  end
  return out
end

---Error of a review with too many files.
---@param max integer
---@return codeview.Error
local function too_many(max)
  return errors.new(
    errors.codes.INVALID_ARG,
    string.format("the review holds more than %d files: name fewer files, or raise files.max_files", max)
  )
end

---Collect the files of a list of paths.
---
--- The call reads the disk only. See |codeview.vcs.file| for the rules of a
--- directory.
---@param paths string[] Files and directories. A relative path starts at `opts.dir`.
---@param opts? { dir?: string } `dir` is the directory of a relative path. The current directory by default.
---@return codeview.vcs.file.Collected? collected
---@return codeview.Error? err
function M.collect(paths, opts)
  opts = opts or {}
  if type(paths) ~= "table" or #paths == 0 then
    return nil, errors.new(errors.codes.INVALID_ARG, "the review needs at least one path")
  end
  local base = opts.dir and M.absolute(opts.dir, uv.cwd() or "/") or uv.cwd() or "/"
  local cfg = config.get().files

  ---@type string[]
  local found = {}
  ---@type table<string, boolean>
  local seen = {}
  ---@type codeview.vcs.file.Skipped
  local skipped = { binary = 0, large = 0 }
  ---@type string[]
  local dirs = {}

  ---@param path string Absolute path of a file.
  ---@return boolean ok False when the review holds too many files.
  local function add(path)
    if seen[path] then
      return true
    end
    seen[path] = true
    found[#found + 1] = path
    return #found <= cfg.max_files
  end

  for _, input in ipairs(paths) do
    if type(input) ~= "string" or vim.trim(input) == "" then
      return nil, errors.new(errors.codes.INVALID_ARG, "a path must be a non-empty string")
    end
    local path = M.absolute(input, base)
    local stat = uv.fs_stat(path)
    if not stat then
      return nil, errors.new(errors.codes.NOT_FOUND, "no such file: " .. input)
    end
    if stat.type == "directory" then
      dirs[#dirs + 1] = path
      local names = git_files(path) or walk_files(path)
      table.sort(names)
      for _, name in ipairs(names) do
        local full = path == "/" and "/" .. name or path .. "/" .. name
        local entry = not hidden(name) and uv.fs_stat(full) or nil
        if entry and entry.type == "file" and not seen[full] then
          if cfg.max_bytes > 0 and entry.size > cfg.max_bytes then
            skipped.large = skipped.large + 1
          elseif is_binary(full) then
            skipped.binary = skipped.binary + 1
          elseif not add(full) then
            return nil, too_many(cfg.max_files)
          end
        end
      end
    else
      dirs[#dirs + 1] = fs.dirname(path)
      if not add(path) then
        return nil, too_many(cfg.max_files)
      end
    end
  end

  if #found == 0 then
    return nil,
      errors.new(
        errors.codes.NOT_FOUND,
        "no file to review in "
          .. table.concat(paths, ", ")
          .. ": the walk skips hidden, ignored, binary, and large files"
      )
  end

  local root = M.common_root(dirs)
  local out = {}
  for _, path in ipairs(found) do
    out[#out + 1] = relative(path, root)
  end
  table.sort(out)
  return { root = root, paths = out, skipped = skipped }, nil
end

---Digest of the paths and the contents of the files.
---@param root string
---@param paths string[] Paths relative to the root, in order.
---@return string? id
---@return codeview.Error? err
function M.digest(root, paths)
  local lines = {}
  for _, path in ipairs(paths) do
    local content, err = read(fs.joinpath(root, path))
    if not content then
      return nil, errors.new(errors.codes.NOT_FOUND, string.format("cannot read %s: %s", path, err))
    end
    -- `sha256()` of Neovim 0.11 fails on a text with a zero byte. The escape
    -- keeps two different contents apart: a backslash doubles, and a zero
    -- byte becomes `\0`.
    local text = content:gsub("\\", "\\\\"):gsub("%z", "\\0")
    -- The length in front keeps a path apart from the digest after it.
    lines[#lines + 1] = #path .. ":" .. path .. " " .. fn.sha256(text)
  end
  return fn.sha256(table.concat(lines, "\n")), nil
end

--- Handle ----------------------------------------------------------------------

---True: the backend needs no executable.
---@return boolean
function M.available()
  return true
end

---Name of the executable of the backend. The backend runs none.
---@return string
function M.binary()
  return ""
end

---The automatic detection never picks this backend.
---@param dir? string
---@param cb? fun(repo: codeview.vcs.Repo?, err: codeview.Error?)
---@return codeview.vcs.Repo? repo Always nil.
---@return codeview.Error? err
function M.detect(dir, cb)
  return done(cb, nil, errors.new(errors.codes.NOT_A_REPO, "the file backend has no repository: " .. tostring(dir)))
end

---Make a handle for a list of files and directories.
---
--- The call reads no file. |Repo:resolve_range()| collects the files.
---@param paths string[] Files and directories. A relative path starts at `opts.dir`.
---@param opts? { dir?: string } `dir` is the directory of a relative path. The current directory by default.
---@return codeview.vcs.FileRepo? repo
---@return codeview.Error? err
function M.new(paths, opts)
  opts = opts or {}
  if type(paths) ~= "table" or #paths == 0 then
    return nil, errors.new(errors.codes.INVALID_ARG, "the review needs at least one path")
  end
  local base = opts.dir and M.absolute(opts.dir, uv.cwd() or "/") or uv.cwd() or "/"
  local inputs = {}
  local dirs = {}
  for _, path in ipairs(paths) do
    if type(path) ~= "string" or vim.trim(path) == "" then
      return nil, errors.new(errors.codes.INVALID_ARG, "a path must be a non-empty string")
    end
    local full = M.absolute(path, base)
    inputs[#inputs + 1] = full
    dirs[#dirs + 1] = fn.isdirectory(full) == 1 and full or fs.dirname(full)
  end
  return setmetatable({
    backend = M.name,
    root = M.common_root(dirs),
    inputs = inputs,
    files = {},
    skipped = { binary = 0, large = 0 },
  }, Repo),
    nil
end

---Collect the files again, and give the digest of their content.
---
--- A directory can hold a new file after a refresh, so every resolve walks
--- the directories again.
---@param self codeview.vcs.FileRepo
---@return string? id
---@return codeview.Error? err
local function resolve(self)
  local collected, err = M.collect(self.inputs)
  if not collected then
    return nil, err
  end
  -- The root comes from the inputs, so it stays the same. The collected root
  -- can only be deeper. The paths take the root of the handle.
  local paths = {}
  for _, path in ipairs(collected.paths) do
    paths[#paths + 1] = relative(fs.joinpath(collected.root, path), self.root)
  end
  table.sort(paths)
  local id, digest_err = M.digest(self.root, paths)
  if not id then
    return nil, digest_err
  end
  self.files = paths
  self.skipped = collected.skipped
  return id, nil
end

---Give the digest of the files. The revision text does not matter.
---@param _rev string
---@param cb? fun(id: string?, err: codeview.Error?)
---@return string? id
---@return codeview.Error? err
function Repo:resolve_rev(_rev, cb)
  return done(cb, resolve(self))
end

---Collect the files, and give a range without a base.
---@param spec string|codeview.vcs.Range|codeview.vcs.RangeSpec Label of the review. The handle reads only its text.
---@param cb? fun(range: codeview.vcs.Range?, err: codeview.Error?)
---@return codeview.vcs.Range? range
---@return codeview.Error? err
function Repo:resolve_range(spec, cb)
  local id, err = resolve(self)
  if not id then
    return done(cb, nil, err)
  end
  local text = type(spec) == "string" and spec or (type(spec) == "table" and spec.spec) or nil
  return done(cb, { from = nil, to = id, spec = text }, nil)
end

---The disk has no commits.
---@param _opts? codeview.vcs.LogOpts
---@param cb? fun(commits: codeview.vcs.Commit[]?, err: codeview.Error?)
---@return codeview.vcs.Commit[]? commits Always empty.
---@return codeview.Error? err
function Repo.log(_self, _opts, cb)
  return done(cb, {}, nil)
end

---Files of the last resolve.
---@param _range codeview.vcs.Range
---@param cb? fun(files: codeview.vcs.FileChange[]?, err: codeview.Error?)
---@return codeview.vcs.FileChange[]? files
---@return codeview.Error? err
function Repo:changed_files(_range, cb)
  local out = {}
  for _, path in ipairs(self.files) do
    out[#out + 1] = { path = path, status = M.status }
  end
  return done(cb, out, nil)
end

---Read one file from the disk.
---
--- A nil revision is the empty state, as in the other backends. Every other
--- revision reads the file as the disk holds it now.
---@param rev string?
---@param path string Path relative to the root.
---@param cb? fun(content: string?, err: codeview.Error?)
---@return string? content
---@return codeview.Error? err
function Repo:file_content(rev, path, cb)
  if type(path) ~= "string" or path == "" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "path must be a non-empty string"))
  end
  if rev == nil then
    return done(cb, "", nil)
  end
  local content, err = read(fs.joinpath(self.root, path))
  if not content then
    return done(cb, nil, errors.new(errors.codes.NOT_FOUND, string.format("cannot read %s: %s", path, err)))
  end
  return done(cb, content, nil)
end

---The disk has no commit, so the id never changes.
---@param cb? fun(id: string?, err: codeview.Error?)
---@return string? id
---@return codeview.Error? err
function Repo.working_rev(_self, cb)
  return done(cb, M.working, nil)
end

---The disk needs no snapshot.
---@param cb? fun(id: string?, err: codeview.Error?)
---@return string? id
---@return codeview.Error? err
function Repo.snapshot(_self, cb)
  return done(cb, M.working, nil)
end

---The disk has no state directory, so the review starts no watcher.
---@param cb? fun(dirs: string[]?, err: codeview.Error?)
---@return string[]? dirs Always empty.
---@return codeview.Error? err
function Repo.state_dirs(_self, cb)
  return done(cb, {}, nil)
end

return M
