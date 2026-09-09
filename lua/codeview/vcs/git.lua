---@brief The git backend.
---
--- It implements the interface of |codeview.vcs|. Every call runs one git
--- command through |codeview.exec|. Errors come back as values.

local exec = require("codeview.exec")
local errors = require("codeview.error")
local config = require("codeview.config")
local util = require("codeview.util")
local fs = vim.fs
local uv = vim.uv

local done = util.done

local M = {}

---Name of the backend.
---@type string
M.name = "git"

---Name or path of the git executable, from the configuration.
---@return string binary
function M.binary()
  return config.get().git.binary
end

---Field separator inside one log record.
local FIELD = "\31"
---Record separator between two log records.
local RECORD = "\30"

---Format string for `git log`. It must match `LOG_FIELDS`.
local LOG_FORMAT = table.concat({
  "%H", -- commit id
  "%h", -- short commit id
  "%an", -- author name
  "%ae", -- author mail
  "%aI", -- author date, ISO 8601
  "%cI", -- committer date, ISO 8601
  "%P", -- parent ids
  "%s", -- subject
  "%b", -- body
}, "%x1f") .. "%x1e"

---Status letter of `git diff --name-status`, mapped to the interface status.
---@type table<string, codeview.vcs.Status>
local STATUS = {
  A = "added",
  M = "modified",
  D = "deleted",
  R = "renamed",
  C = "copied",
  T = "typechanged",
  U = "unmerged",
}

---Environment of every git call.
---
--- git translates its messages. The error classification reads them, so the
--- calls force the C locale. |vim.system()| merges this table with the
--- environment of Neovim.
---@type table<string, string>
local GIT_ENV = {
  LC_ALL = "C",
  LANGUAGE = "",
}

---@class codeview.vcs.GitRepo: codeview.vcs.Repo
---@field git_dir string? Absolute path of the git directory. The handle reads it once.
local Repo = {}
Repo.__index = Repo

---Build a git command line that ignores the configuration of the user.
---
--- `log.showSignature` writes verification text into the log output.
--- `core.quotePath` escapes non-ASCII path bytes. Both break the parsers.
---@param repo codeview.vcs.GitRepo
---@param args string[]
---@return string[]
local function git_cmd(repo, args)
  local cmd = {
    M.binary(),
    "-C",
    repo.root,
    "--no-pager",
    "-c",
    "log.showSignature=false",
    "-c",
    "core.quotePath=false",
  }
  return vim.list_extend(cmd, args)
end

---Add the fixed git environment to the options of one call.
---@param opts? codeview.ExecOpts
---@return codeview.ExecOpts
local function git_opts(opts)
  opts = vim.deepcopy(opts or {})
  opts.env = vim.tbl_extend("force", opts.env or {}, GIT_ENV)
  return opts
end

---Run a git command in the repository and map its result.
---@param repo codeview.vcs.GitRepo
---@param args string[] Arguments after `git`.
---@param handle fun(result: codeview.ExecResult): any?, codeview.Error? Maps the result to a value or an error.
---@param opts? codeview.ExecOpts
---@param cb? fun(value: any?, err: codeview.Error?)
---@return any?, codeview.Error?
local function call(repo, args, handle, opts, cb)
  local cmd = git_cmd(repo, args)
  opts = vim.tbl_extend("keep", git_opts(opts), { cwd = repo.root })

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

---Build the error of a failed git call.
---@param code codeview.ErrorCode
---@param message string
---@param result codeview.ExecResult
---@return codeview.Error
local function failed(code, message, result)
  return errors.new(code, message, { command = result.command, stderr = result.stderr })
end

--- Detection -----------------------------------------------------------------

---Directory to start the search from.
---@param dir? string
---@return string? path
local function start_dir(dir)
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

---True when the git executable is in $PATH.
---@return boolean
function M.available()
  return vim.fn.executable(M.binary()) == 1
end

---Find the git repository that holds a directory.
---@param dir? string Directory inside the repository. The current directory by default.
---@param cb? fun(repo: codeview.vcs.GitRepo?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.GitRepo? repo Nil when the directory is outside a git repository.
---@return codeview.Error? err
function M.detect(dir, cb)
  local path = start_dir(dir)
  if not path then
    return done(cb, nil, errors.new(errors.codes.NOT_FOUND, "no such directory: " .. tostring(dir)))
  end

  local cmd = { M.binary(), "-C", path, "rev-parse", "--show-toplevel" }
  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.NOT_A_REPO, "not a git repository: " .. path, result)
    end
    local root = vim.trim(result.stdout)
    if root == "" then
      return nil, failed(errors.codes.NOT_A_REPO, "not a git work tree: " .. path, result)
    end
    return setmetatable({ backend = M.name, root = fs.normalize(root) }, Repo), nil
  end

  if cb then
    exec.capture(cmd, { cwd = path, env = GIT_ENV }, function(result, err)
      if not result then
        cb(nil, err)
        return
      end
      cb(handle(result))
    end)
    return nil, nil
  end

  local result, err = exec.capture(cmd, { cwd = path, env = GIT_ENV })
  if not result then
    return nil, err
  end
  return handle(result)
end

--- Revisions -----------------------------------------------------------------

---True when git rejected a revision name.
---
--- The text of git is stable, because `GIT_ENV` sets the C locale.
---@param result codeview.ExecResult
---@return boolean
local function looks_like_bad_revision(result)
  local text = (result.stderr or ""):lower()
  return text:find("unknown revision", 1, true) ~= nil
    or text:find("invalid object name", 1, true) ~= nil
    or text:find("bad revision", 1, true) ~= nil
    or text:find("ambiguous argument", 1, true) ~= nil
    or text:find("not a valid object name", 1, true) ~= nil
end

---Resolve one revision to a full commit id.
---@param rev string Revision name: an id, a branch, a tag, or an expression.
---@param cb? fun(id: string?, err: codeview.Error?) Callback for the async form.
---@return string? id Full commit id.
---@return codeview.Error? err
function Repo:resolve_rev(rev, cb)
  if type(rev) ~= "string" or vim.trim(rev) == "" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "revision must be a non-empty string"))
  end
  rev = vim.trim(rev)

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.BAD_REVISION, "unknown revision: " .. rev, result)
    end
    local id = vim.trim(result.stdout)
    if id == "" then
      return nil, failed(errors.codes.BAD_REVISION, "unknown revision: " .. rev, result)
    end
    return id, nil
  end

  return call(self, { "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }, handle, nil, cb)
end

---@param spec string|codeview.vcs.Range|codeview.vcs.RangeSpec
---@return codeview.vcs.RangeSpec? parsed
---@return codeview.Error? err
local function as_spec(spec)
  if type(spec) == "string" then
    return require("codeview.vcs").parse_range(spec)
  end
  if type(spec) ~= "table" or type(spec.to) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "range needs a `to` revision")
  end
  if spec.kind then
    ---@cast spec codeview.vcs.RangeSpec
    return spec, nil
  end
  -- A range table. A nil `from` means the state before the first commit.
  return { kind = spec.from and "range" or "explicit", from = spec.from, to = spec.to, spec = spec.spec }, nil
end

---Resolve a revision argument to a range of commit ids.
---
--- The argument is user text (`a`, `a..b`, `a...b`), a parsed spec, or a range
--- table. For one commit the base is its first parent. For a root commit the
--- base is nil, which means the state before the first commit.
---@param spec string|codeview.vcs.Range|codeview.vcs.RangeSpec
---@param cb? fun(range: codeview.vcs.Range?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.Range? range
---@return codeview.Error? err
function Repo:resolve_range(spec, cb)
  local parsed, err = as_spec(spec)
  if not parsed then
    return done(cb, nil, err)
  end
  local text = parsed.spec or (parsed.from and (parsed.from .. ".." .. parsed.to) or parsed.to)

  if parsed.kind == "single" then
    -- `rev-list --parents` reports the commit and its parents in one call.
    ---@param result codeview.ExecResult
    local function handle(result)
      if result.code ~= 0 then
        return nil, failed(errors.codes.BAD_REVISION, "unknown revision: " .. parsed.to, result)
      end
      local fields = vim.split(vim.trim(result.stdout), "%s+")
      if #fields == 0 or fields[1] == "" then
        return nil, failed(errors.codes.BAD_REVISION, "unknown revision: " .. parsed.to, result)
      end
      return { from = fields[2], to = fields[1], spec = text }, nil
    end
    -- `--` keeps a revision name that is also a path out of the pathspec.
    return call(self, { "rev-list", "--parents", "-n", "1", parsed.to, "--" }, handle, nil, cb)
  end

  if parsed.kind == "explicit" then
    if not cb then
      local id, resolve_err = self:resolve_rev(parsed.to)
      if not id then
        return nil, resolve_err
      end
      return { from = nil, to = id, spec = text }, nil
    end
    self:resolve_rev(parsed.to, function(id, resolve_err)
      if not id then
        cb(nil, resolve_err)
        return
      end
      cb({ from = nil, to = id, spec = text }, nil)
    end)
    return nil, nil
  end

  local from_rev = parsed.from --[[@as string]]

  ---Resolve both sides in one call.
  ---@param result codeview.ExecResult
  local function handle_pair(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.BAD_REVISION, "unknown revision in " .. text, result)
    end
    local ids = exec.lines(result.stdout)
    if #ids < 2 then
      return nil, failed(errors.codes.BAD_REVISION, "unknown revision in " .. text, result)
    end
    return { from = ids[1], to = ids[2], spec = text }, nil
  end
  local pair_args = { "rev-parse", from_rev .. "^{commit}", parsed.to .. "^{commit}" }

  if parsed.kind == "range" then
    return call(self, pair_args, handle_pair, nil, cb)
  end

  -- Triple dot: the base is the merge base of the two sides.
  ---@param range codeview.vcs.Range
  ---@param result codeview.ExecResult
  local function handle_base(range, result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.BAD_REVISION, "no merge base for " .. text, result)
    end
    local base = vim.trim(result.stdout)
    if base == "" then
      return nil, failed(errors.codes.BAD_REVISION, "no merge base for " .. text, result)
    end
    return { from = base, to = range.to, spec = text }, nil
  end

  if not cb then
    local range, range_err = call(self, pair_args, handle_pair)
    if not range then
      return nil, range_err
    end
    return call(self, { "merge-base", range.from, range.to }, function(result)
      return handle_base(range, result)
    end)
  end

  call(self, pair_args, handle_pair, nil, function(range, range_err)
    if not range then
      cb(nil, range_err)
      return
    end
    call(self, { "merge-base", range.from, range.to }, function(result)
      return handle_base(range, result)
    end, nil, cb)
  end)
  return nil, nil
end

--- Working copy --------------------------------------------------------------

---Read the commit that the working copy sits on.
---
--- It is `HEAD`. The call reads the repository only.
---@param cb? fun(id: string?, err: codeview.Error?) Callback for the async form.
---@return string? id Full commit id.
---@return codeview.Error? err
function Repo:working_rev(cb)
  return self:resolve_rev("HEAD", cb)
end

---Write the state of the working copy into the repository, and read its commit.
---
--- git holds the working copy outside the commits, so there is nothing to
--- write. A change of a file does not move `HEAD`. The call therefore gives
--- the same id as |working_rev|, and it changes nothing.
---@param cb? fun(id: string?, err: codeview.Error?) Callback for the async form.
---@return string? id Full commit id.
---@return codeview.Error? err
function Repo:snapshot(cb)
  return self:working_rev(cb)
end

---Directories to watch under one git directory.
---@param git_dir string Absolute path of the git directory.
---@return string[] dirs Directories that exist now.
local function watch_dirs(git_dir)
  local dirs = { git_dir }
  local heads = fs.joinpath(git_dir, "refs", "heads")
  if uv.fs_stat(heads) then
    dirs[#dirs + 1] = heads
  end
  return dirs
end

---Read the directories that every git operation writes.
---
--- The git directory itself holds `HEAD`, `index`, `ORIG_HEAD`,
--- `packed-refs`, and `COMMIT_EDITMSG`. A commit, an amend, a rebase, and a
--- checkout all write one of them. The `refs/heads` subdirectory holds the
--- branches, so a branch that moves shows there too.
---
--- The handle keeps the path of the git directory, because that path does not
--- move while the repository is open.
---@param cb? fun(dirs: string[]?, err: codeview.Error?) Callback for the async form.
---@return string[]? dirs
---@return codeview.Error? err
function Repo:state_dirs(cb)
  if self.git_dir then
    return done(cb, watch_dirs(self.git_dir), nil)
  end

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.COMMAND_FAILED, "cannot read the git directory", result)
    end
    local dir = vim.trim(result.stdout)
    if dir == "" then
      return nil, failed(errors.codes.NOT_FOUND, "the repository has no git directory", result)
    end
    self.git_dir = fs.normalize(dir)
    return watch_dirs(self.git_dir), nil
  end

  return call(self, { "rev-parse", "--absolute-git-dir" }, handle, nil, cb)
end

--- Log -----------------------------------------------------------------------

---@param record string
---@return codeview.vcs.Commit?
local function parse_commit(record)
  local text = record:gsub("^[\r\n]+", "")
  if vim.trim(text) == "" then
    return nil
  end
  local fields = vim.split(text, FIELD, { plain = true })
  if #fields < 9 then
    return nil
  end
  local parents = {}
  for _, id in ipairs(vim.split(vim.trim(fields[7]), " ", { plain = true })) do
    if id ~= "" then
      parents[#parents + 1] = id
    end
  end
  return {
    id = fields[1],
    short_id = fields[2],
    author = fields[3],
    author_email = fields[4],
    date = fields[5],
    committer_date = fields[6],
    parents = parents,
    subject = fields[8],
    body = (fields[9]:gsub("%s+$", "")),
  }
end

---List the commits of a range or of a set of revisions.
---@param opts? codeview.vcs.LogOpts
---@param cb? fun(commits: codeview.vcs.Commit[]?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.Commit[]? commits Newest first.
---@return codeview.Error? err
function Repo:log(opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}

  local args = { "log", "--no-color", "--format=" .. LOG_FORMAT }
  if opts.limit then
    vim.list_extend(args, { "-n", tostring(opts.limit) })
  end

  local range = opts.range
  if range then
    if type(range.to) ~= "string" then
      return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "range needs a `to` revision"))
    end
    args[#args + 1] = range.from and (range.from .. ".." .. range.to) or range.to
  elseif opts.revs and #opts.revs > 0 then
    vim.list_extend(args, opts.revs)
  else
    args[#args + 1] = "HEAD"
  end

  -- `--` keeps a revision name that is also a path out of the pathspec.
  args[#args + 1] = "--"
  if opts.paths and #opts.paths > 0 then
    vim.list_extend(args, opts.paths)
  end

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      local code = looks_like_bad_revision(result) and errors.codes.BAD_REVISION or errors.codes.COMMAND_FAILED
      return nil, failed(code, "cannot read the log", result)
    end
    local commits = {}
    for _, record in ipairs(vim.split(result.stdout, RECORD, { plain = true })) do
      local commit = parse_commit(record)
      if commit then
        commits[#commits + 1] = commit
      end
    end
    return commits, nil
  end

  return call(self, args, handle, nil, cb)
end

--- Changed files -------------------------------------------------------------

---Parse the NUL separated output of `git diff --name-status -z`.
---@param text string
---@return codeview.vcs.FileChange[]
local function parse_name_status(text)
  local parts = vim.split(text, "\0", { plain = true })
  local files = {}
  local i = 1
  while i <= #parts do
    local field = parts[i]
    i = i + 1
    if field ~= "" then
      local letter = field:sub(1, 1)
      local score = tonumber(field:sub(2))
      local status = STATUS[letter] or "unknown"
      local path = parts[i]
      i = i + 1
      if letter == "R" or letter == "C" then
        local new_path = parts[i]
        i = i + 1
        files[#files + 1] = { path = new_path, old_path = path, status = status, score = score }
      elseif path then
        files[#files + 1] = { path = path, status = status }
      end
    end
  end
  return files
end

---Parse the NUL separated output of `git ls-tree --name-only -z`.
---
--- Every file of the tree counts as added, because the range has no base.
---@param text string
---@return codeview.vcs.FileChange[]
local function parse_tree(text)
  local files = {}
  for _, path in ipairs(vim.split(text, "\0", { plain = true })) do
    if path ~= "" then
      files[#files + 1] = { path = path, status = "added" }
    end
  end
  return files
end

---List the files that a range changes.
---
--- A nil `range.from` stands for the state before the first commit. Every file
--- of `range.to` is then an addition.
---@param range codeview.vcs.Range Range with resolved revisions.
---@param cb? fun(files: codeview.vcs.FileChange[]?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.FileChange[]? files
---@return codeview.Error? err
function Repo:changed_files(range, cb)
  if type(range) ~= "table" or type(range.to) ~= "string" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "range needs a `to` revision"))
  end

  local args, parse
  if range.from then
    -- `--` keeps a revision name that is also a path out of the pathspec.
    args = { "diff", "--no-color", "--name-status", "-M", "-z", range.from, range.to, "--" }
    parse = parse_name_status
  else
    -- `diff-tree --root` compares a non-root commit against its parent.
    -- List the whole tree instead, so that the base stays the empty state.
    args = { "ls-tree", "-r", "-z", "--name-only", range.to }
    parse = parse_tree
  end

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      local code = looks_like_bad_revision(result) and errors.codes.BAD_REVISION or errors.codes.COMMAND_FAILED
      return nil, failed(code, "cannot list the changed files", result)
    end
    return parse(result.stdout), nil
  end

  return call(self, args, handle, nil, cb)
end

--- File content --------------------------------------------------------------

---True when the revision does not hold the path.
---
--- The text of git is stable, because `GIT_ENV` sets the C locale.
---@param result codeview.ExecResult
---@return boolean
local function path_missing(result)
  local text = (result.stderr or ""):lower()
  return text:find("does not exist in", 1, true) ~= nil
    or text:find("exists on disk, but not in", 1, true) ~= nil
    or text:find("path not in the working tree", 1, true) ~= nil
end

---Read the content of one file at one revision.
---
--- A nil revision stands for the missing side of an added or a deleted file.
--- The call then returns an empty string. A path that the revision does not
--- hold gives the same result.
---@param rev string? Revision, or nil for the missing side.
---@param path string Path relative to the repository root.
---@param cb? fun(content: string?, err: codeview.Error?) Callback for the async form.
---@return string? content
---@return codeview.Error? err
function Repo:file_content(rev, path, cb)
  if type(path) ~= "string" or path == "" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "path must be a non-empty string"))
  end
  if rev == nil then
    return done(cb, "", nil)
  end
  if type(rev) ~= "string" or vim.trim(rev) == "" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "revision must be a non-empty string"))
  end

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      if path_missing(result) then
        return "", nil
      end
      local code = looks_like_bad_revision(result) and errors.codes.BAD_REVISION or errors.codes.NOT_FOUND
      return nil, failed(code, string.format("cannot read %s at %s", path, rev), result)
    end
    return result.stdout, nil
  end

  -- `text = false` keeps the bytes of the file, with the line endings it has.
  return call(self, { "show", rev .. ":" .. path }, handle, { text = false }, cb)
end

return M
