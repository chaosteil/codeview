---@brief The jj backend.
---
--- It implements the interface of |codeview.vcs|. Every call runs one jj
--- command through |codeview.exec|. Errors come back as values.
---
--- A revision argument is a revset. The backend sends the text to jj as it is,
--- so `::@`, `trunk()..@`, and `main..feature` all work. A revset that names a
--- set of commits becomes a range. The head of the set is the new side, and
--- the parent of the roots of the set is the base.
---
--- Every command runs with `--ignore-working-copy`. The backend reads the
--- repository only. It never snapshots the working copy, and it never writes
--- an operation.

local exec = require("codeview.exec")
local errors = require("codeview.error")
local fs = vim.fs
local uv = vim.uv

local M = {}

---Name of the backend.
---@type string
M.name = "jj"

---Field separator inside one record.
local FIELD = "\31"
---Record separator between two records.
local RECORD = "\30"

---The separators as jj template escapes.
local T_FIELD = '"\\x1f"'
local T_RECORD = '"\\x1e"'

---Commit id of the virtual root commit of a jj repository.
---
--- Every jj history starts at this commit. It holds no files and no message.
--- The interface has no value for it, so the backend maps it to nil.
---@type string
local ROOT_ID = string.rep("0", 40)

---Timestamp format of the log template. It gives ISO 8601.
local DATE_FORMAT = '"%Y-%m-%dT%H:%M:%S%:z"'

---Join template parts with the field separator and close the record.
---@param parts string[]
---@return string
local function template(parts)
  return table.concat(parts, " ++ " .. T_FIELD .. " ++ ") .. " ++ " .. T_RECORD
end

---Template of one commit record. It must match `parse_commit()`.
local LOG_TEMPLATE = template({
  "commit_id",
  "change_id",
  "change_id.short(8)",
  "author.name()",
  "author.email()",
  "author.timestamp().format(" .. DATE_FORMAT .. ")",
  "committer.timestamp().format(" .. DATE_FORMAT .. ")",
  'parents.map(|c| c.commit_id()).join(" ")',
  "description",
})

---Template of one changed file. It must match `parse_diff()`.
local DIFF_TEMPLATE = template({ "status", "source.path()", "path" })

---Template that prints one commit id per line.
local ID_TEMPLATE = 'commit_id ++ "\\n"'

---Template of one commit id with the ids of its parents.
local PARENT_TEMPLATE = "commit_id ++ " .. T_FIELD .. ' ++ parents.map(|c| c.commit_id()).join(" ") ++ "\\n"'

---Status word of `jj diff`, mapped to the interface status.
---@type table<string, codeview.vcs.Status>
local STATUS = {
  added = "added",
  modified = "modified",
  removed = "deleted",
  copied = "copied",
  renamed = "renamed",
}

---@class codeview.vcs.JjRepo: codeview.vcs.Repo
---@field colocated boolean True when the repository also has a `.git` directory.
local Repo = {}
Repo.__index = Repo

---Return a value in the sync form, or send it to the callback.
---@generic T
---@param cb? fun(value: T?, err: codeview.Error?)
---@param value any?
---@param err codeview.Error?
---@return any?, codeview.Error?
local function done(cb, value, err)
  if not cb then
    return value, err
  end
  vim.schedule(function()
    cb(value, err)
  end)
  return nil, nil
end

---Build a jj command line for a repository.
---
--- `--ignore-working-copy` keeps the call read-only. `--color=never` and
--- `--no-pager` keep the output plain, whatever the user configured.
---@param repo codeview.vcs.JjRepo
---@param args string[]
---@return string[]
local function jj_cmd(repo, args)
  local cmd = {
    "jj",
    "--repository",
    repo.root,
    "--no-pager",
    "--color=never",
    "--quiet",
    "--ignore-working-copy",
  }
  return vim.list_extend(cmd, args)
end

---Run a jj command in the repository and map its result.
---@param repo codeview.vcs.JjRepo
---@param args string[] Arguments after `jj`.
---@param handle fun(result: codeview.ExecResult): any?, codeview.Error? Maps the result to a value or an error.
---@param opts? codeview.ExecOpts
---@param cb? fun(value: any?, err: codeview.Error?)
---@return any?, codeview.Error?
local function call(repo, args, handle, opts, cb)
  local cmd = jj_cmd(repo, args)
  opts = vim.tbl_extend("keep", vim.deepcopy(opts or {}), { cwd = repo.root })

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

---Build the error of a failed jj call.
---@param code codeview.ErrorCode
---@param message string
---@param result codeview.ExecResult
---@return codeview.Error
local function failed(code, message, result)
  return errors.new(code, message, { command = result.command, stderr = result.stderr })
end

---True when jj rejected a revision or a revset.
---
--- jj prints its messages in English only, so the text is stable.
---@param result codeview.ExecResult
---@return boolean
local function looks_like_bad_revision(result)
  local text = (result.stderr or ""):lower()
  return text:find("doesn't exist", 1, true) ~= nil
    or text:find("is ambiguous", 1, true) ~= nil
    or text:find("failed to parse revset", 1, true) ~= nil
    or text:find("invalid revset", 1, true) ~= nil
    or text:find("no such revision", 1, true) ~= nil
end

---True when the revision does not hold the path.
---@param result codeview.ExecResult
---@return boolean
local function path_missing(result)
  local text = (result.stderr or ""):lower()
  return text:find("no such path", 1, true) ~= nil
end

---True when the path is not a file, for example a symbolic link.
---
--- `jj file show` writes this warning, prints nothing, and exits with 0.
---@param result codeview.ExecResult
---@return boolean
local function not_a_file(result)
  local text = (result.stderr or ""):lower()
  return text:find("exists but is not a file", 1, true) ~= nil
end

---Wrap a revset in parentheses.
---
--- The text of the user can hold any operator. The parentheses keep it as one
--- operand of the expression that the backend builds around it.
---@param expr string
---@return string
local function group(expr)
  return "(" .. vim.trim(expr) .. ")"
end

---Quote a path as a jj string literal.
---@param path string
---@return string
local function quote(path)
  return '"' .. path:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
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

---True when jj is in $PATH.
---@return boolean
function M.available()
  return vim.fn.executable("jj") == 1
end

---Find the jj repository that holds a directory.
---
--- The search walks upwards and takes the first directory that holds a `.jj`
--- directory. A colocated repository holds `.git` next to `.jj`. The handle
--- reports it in `repo.colocated`.
---@param dir? string Directory inside the repository. The current directory by default.
---@param cb? fun(repo: codeview.vcs.JjRepo?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.JjRepo? repo Nil when the directory is outside a jj repository.
---@return codeview.Error? err
function M.detect(dir, cb)
  local path = start_dir(dir)
  if not path then
    return done(cb, nil, errors.new(errors.codes.NOT_FOUND, "no such directory: " .. tostring(dir)))
  end

  local marker = fs.find(".jj", { upward = true, path = path, type = "directory", limit = 1 })[1]
  if not marker then
    return done(cb, nil, errors.new(errors.codes.NOT_A_REPO, "not a jj repository: " .. path))
  end

  -- jj reports the root without symbolic links. Match that, so that the same
  -- repository always gives the same root.
  local root = fs.dirname(marker)
  root = fs.normalize(uv.fs_realpath(root) or root)

  return done(
    cb,
    setmetatable({
      backend = M.name,
      root = root,
      colocated = uv.fs_stat(fs.joinpath(root, ".git")) ~= nil,
    }, Repo),
    nil
  )
end

--- Revisions -----------------------------------------------------------------

---Resolve a revset that must name exactly one commit.
---@param repo codeview.vcs.JjRepo
---@param expr string Revset expression, already grouped.
---@param message string Error message when the revset names no single commit.
---@param opts? { root_message?: string } `root_message` rejects the virtual root commit with that text.
---@param cb? fun(id: string?, err: codeview.Error?)
---@return string? id
---@return codeview.Error? err
local function resolve_one(repo, expr, message, opts, cb)
  local root_message = (opts or {}).root_message

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.BAD_REVISION, message, result)
    end
    local ids = exec.lines(result.stdout)
    if #ids ~= 1 then
      return nil, failed(errors.codes.BAD_REVISION, message, result)
    end
    if root_message and ids[1] == ROOT_ID then
      return nil, failed(errors.codes.BAD_REVISION, root_message, result)
    end
    return ids[1], nil
  end

  return call(repo, { "log", "--no-graph", "-T", ID_TEMPLATE, "-r", expr }, handle, nil, cb)
end

---Resolve one revision to a full commit id.
---@param rev string Revision name: a commit id, a change id, a bookmark, or a revset.
---@param cb? fun(id: string?, err: codeview.Error?) Callback for the async form.
---@return string? id Full commit id.
---@return codeview.Error? err
function Repo:resolve_rev(rev, cb)
  if type(rev) ~= "string" or vim.trim(rev) == "" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "revision must be a non-empty string"))
  end
  rev = vim.trim(rev)
  return resolve_one(
    self,
    group(rev),
    "unknown revision: " .. rev,
    { root_message = "the root commit has no content: " .. rev },
    cb
  )
end

---@param spec string|codeview.vcs.Range|codeview.vcs.RangeSpec
---@return codeview.vcs.RangeSpec? parsed
---@return codeview.Error? err
local function as_spec(spec)
  if type(spec) == "string" then
    local text = vim.trim(spec)
    if text == "" then
      return nil, errors.new(errors.codes.INVALID_ARG, "revision is empty")
    end
    -- The text is a revset. jj reads `a..b` itself, so the backend does not
    -- split the text.
    return { kind = "revset", to = text, spec = text }, nil
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

---Read the base of a revset from the parents of its roots.
---@param result codeview.ExecResult
---@return string? base Nil when the roots start at the virtual root commit.
local function base_of_roots(result)
  for _, line in ipairs(exec.lines(result.stdout)) do
    local fields = vim.split(line, FIELD, { plain = true })
    for _, parent in ipairs(vim.split(vim.trim(fields[2] or ""), " ", { plain = true })) do
      -- The first parent of the newest root, like the first-parent rule of git.
      if parent ~= "" and parent ~= ROOT_ID then
        return parent
      end
    end
  end
  return nil
end

---Turn a revset into a range.
---
--- The head of the set is the new side. The base is the parent of the roots of
--- the set, so that the set itself is the content of the range.
---@param repo codeview.vcs.JjRepo
---@param expr string Revset expression, already grouped.
---@param text string Text that the user wrote.
---@param cb? fun(range: codeview.vcs.Range?, err: codeview.Error?)
---@return codeview.vcs.Range? range
---@return codeview.Error? err
local function revset_range(repo, expr, text, cb)
  local head_args = { "log", "--no-graph", "-T", ID_TEMPLATE, "-r", "heads(" .. expr .. ")" }
  local root_args = { "log", "--no-graph", "-T", PARENT_TEMPLATE, "-r", "roots(" .. expr .. ")" }

  ---@param result codeview.ExecResult
  local function handle_head(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.BAD_REVISION, "unknown revision: " .. text, result)
    end
    local ids = exec.lines(result.stdout)
    -- jj exits with 0 for a revset that names no commit. The revset is then
    -- correct and empty, which is not the same as an unknown revision.
    if #ids == 0 then
      return nil, failed(errors.codes.NOT_FOUND, "the revset holds no commits: " .. text, result)
    end
    if #ids > 1 then
      return nil, failed(errors.codes.BAD_REVISION, "more than one head in " .. text, result)
    end
    if ids[1] == ROOT_ID then
      return nil, failed(errors.codes.BAD_REVISION, "the root commit has no content: " .. text, result)
    end
    return ids[1], nil
  end

  ---@param result codeview.ExecResult
  local function handle_roots(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.BAD_REVISION, "unknown revision: " .. text, result)
    end
    -- A nil base is a valid answer, so the value is a table.
    return { from = base_of_roots(result) }, nil
  end

  if not cb then
    local head, head_err = call(repo, head_args, handle_head)
    if not head then
      return nil, head_err
    end
    local base, base_err = call(repo, root_args, handle_roots)
    if not base then
      return nil, base_err
    end
    return { from = base.from, to = head, spec = text }, nil
  end

  call(repo, head_args, handle_head, nil, function(head, head_err)
    if not head then
      cb(nil, head_err)
      return
    end
    call(repo, root_args, handle_roots, nil, function(base, base_err)
      if not base then
        cb(nil, base_err)
        return
      end
      cb({ from = base.from, to = head, spec = text }, nil)
    end)
  end)
  return nil, nil
end

---Resolve two sides of a range, one after the other.
---@param repo codeview.vcs.JjRepo
---@param from_expr string Revset of the base, already grouped.
---@param from_message string Error message of the base.
---@param to_rev string Revision of the head side.
---@param text string Text that the user wrote.
---@param cb? fun(range: codeview.vcs.Range?, err: codeview.Error?)
---@return codeview.vcs.Range? range
---@return codeview.Error? err
local function resolve_pair(repo, from_expr, from_message, to_rev, text, cb)
  if not cb then
    local from, from_err = resolve_one(repo, from_expr, from_message, nil)
    if not from then
      return nil, from_err
    end
    local to, to_err = repo:resolve_rev(to_rev)
    if not to then
      return nil, to_err
    end
    return { from = from, to = to, spec = text }, nil
  end

  resolve_one(repo, from_expr, from_message, nil, function(from, from_err)
    if not from then
      cb(nil, from_err)
      return
    end
    repo:resolve_rev(to_rev, function(to, to_err)
      if not to then
        cb(nil, to_err)
        return
      end
      cb({ from = from, to = to, spec = text }, nil)
    end)
  end)
  return nil, nil
end

---Resolve a revision argument to a range of commit ids.
---
--- The argument is a revset, a parsed spec, or a range table. A revset becomes
--- the range that holds its commits. For one commit the base is its first
--- parent. For the first commit of the history the base is nil, which means
--- the state before the first commit.
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

  if parsed.kind == "revset" or parsed.kind == "single" then
    return revset_range(self, group(parsed.to), text, cb)
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

  if parsed.kind == "range" then
    return resolve_pair(self, group(from_rev), "unknown revision: " .. from_rev, parsed.to, text, cb)
  end

  -- Triple dot: the base is the closest common ancestor of the two sides.
  local base = "heads(::" .. group(from_rev) .. " & ::" .. group(parsed.to) .. ")"
  return resolve_pair(self, base, "no merge base for " .. text, parsed.to, text, cb)
end

--- Log -----------------------------------------------------------------------

---@param record string
---@return codeview.vcs.Commit?
local function parse_commit(record)
  if vim.trim(record) == "" then
    return nil
  end
  local fields = vim.split(record, FIELD, { plain = true })
  if #fields < 9 then
    return nil
  end
  local parents = {}
  for _, id in ipairs(vim.split(vim.trim(fields[8]), " ", { plain = true })) do
    -- The virtual root commit is not a commit of the interface.
    if id ~= "" and id ~= ROOT_ID then
      parents[#parents + 1] = id
    end
  end
  -- jj keeps the whole message in one field. The first line is the subject.
  -- The blank line between the subject and the body is not part of the body.
  local description = fields[9]
  local subject = vim.split(description, "\n", { plain = true })[1]
  local body = description:sub(#subject + 2):gsub("^\n+", "")
  return {
    id = fields[1],
    change_id = fields[2],
    short_id = fields[3],
    author = fields[4],
    author_email = fields[5],
    date = fields[6],
    committer_date = fields[7],
    parents = parents,
    subject = subject,
    body = (body:gsub("%s+$", "")),
  }
end

---Revset of a log call.
---
--- The virtual root commit is never part of the answer. It has no message and
--- no files, and no other backend has such a commit.
---@param opts codeview.vcs.LogOpts
---@return string? expr
---@return codeview.Error? err
local function log_revset(opts)
  local range = opts.range
  if range then
    if type(range.to) ~= "string" then
      return nil, errors.new(errors.codes.INVALID_ARG, "range needs a `to` revision")
    end
    local expr = range.from and (group(range.from) .. ".." .. group(range.to)) or ("::" .. group(range.to))
    return group(expr) .. " ~ root()", nil
  end

  if opts.revs and #opts.revs > 0 then
    local parts = vim.tbl_map(group, opts.revs)
    return group(table.concat(parts, " | ")) .. " ~ root()", nil
  end

  -- `@` is the working-copy commit. Its ancestors are the history of the
  -- current workspace, like `HEAD` in git.
  return "(::@) ~ root()", nil
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

  local revset, revset_err = log_revset(opts)
  if not revset then
    return done(cb, nil, revset_err)
  end

  local args = { "log", "--no-graph", "-T", LOG_TEMPLATE, "-r", revset }
  if opts.limit then
    vim.list_extend(args, { "-n", tostring(opts.limit) })
  end
  if opts.paths and #opts.paths > 0 then
    args[#args + 1] = "--"
    for _, path in ipairs(opts.paths) do
      args[#args + 1] = "root:" .. quote(path)
    end
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

---Parse the records of `jj diff -T`.
---@param text string
---@return codeview.vcs.FileChange[]
local function parse_diff(text)
  local files = {}
  for _, record in ipairs(vim.split(text, RECORD, { plain = true })) do
    if vim.trim(record) ~= "" then
      local fields = vim.split(record, FIELD, { plain = true })
      local status = STATUS[fields[1]] or "unknown"
      local source, path = fields[2], fields[3]
      if path and path ~= "" then
        local change = { path = path, status = status } ---@type codeview.vcs.FileChange
        -- jj reports the source path of every entry. Only a rename or a copy
        -- has a source that differs from the target.
        if (status == "renamed" or status == "copied") and source and source ~= path then
          change.old_path = source
        end
        files[#files + 1] = change
      end
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

  local from = range.from and group(range.from) or "root()"
  local args = { "diff", "--from", from, "--to", group(range.to), "-T", DIFF_TEMPLATE }

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      local code = looks_like_bad_revision(result) and errors.codes.BAD_REVISION or errors.codes.COMMAND_FAILED
      return nil, failed(code, "cannot list the changed files", result)
    end
    return parse_diff(result.stdout), nil
  end

  return call(self, args, handle, nil, cb)
end

--- File content --------------------------------------------------------------

---Marker for a path that `jj file show` refuses, because it is not a file.
---@type table
local NOT_A_FILE = {}

---Read the added lines of a git-format diff.
---@param text string Output of `jj diff --git`.
---@return string content
local function added_content(text)
  local lines, seen_hunk, final_newline = {}, false, true
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line:sub(1, 2) == "@@" then
      seen_hunk = true
    elseif line:sub(1, 1) == "\\" then
      final_newline = false
    elseif seen_hunk and line:sub(1, 1) == "+" then
      lines[#lines + 1] = line:sub(2)
    end
  end
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. (final_newline and "\n" or "")
end

---Read the target of a symbolic link at one revision.
---
--- `jj file show` refuses a path that is not a file. The git-format diff from
--- the root commit holds the link target as the content of an added file. The
--- git backend returns the same text for a link.
---@param repo codeview.vcs.JjRepo
---@param rev string
---@param path string
---@param cb? fun(content: string?, err: codeview.Error?)
---@return string? content
---@return codeview.Error? err
local function link_target(repo, rev, path, cb)
  local args = { "diff", "--git", "--from", "root()", "--to", group(rev), "--", "root-file:" .. quote(path) }

  ---@param result codeview.ExecResult
  local function handle(result)
    if result.code ~= 0 then
      return nil, failed(errors.codes.NOT_FOUND, string.format("cannot read %s at %s", path, rev), result)
    end
    return added_content(result.stdout), nil
  end

  return call(repo, args, handle, nil, cb)
end

---Read the content of one file at one revision.
---
--- A nil revision stands for the missing side of an added or a deleted file.
--- The call then returns an empty string. A path that the revision does not
--- hold gives the same result. For a symbolic link the call returns the target
--- of the link.
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
    -- A path that is not a file gives an exit code of 0 and no output.
    if result.stdout == "" and not_a_file(result) then
      return NOT_A_FILE, nil
    end
    return result.stdout, nil
  end

  -- `root-file:` matches the exact path from the repository root, whatever the
  -- working directory is and whatever characters the path holds.
  local args = { "file", "show", "-r", group(rev), "--", "root-file:" .. quote(path) }

  if not cb then
    -- `text = false` keeps the bytes of the file, with the line endings it has.
    local content, err = call(self, args, handle, { text = false })
    if content == NOT_A_FILE then
      return link_target(self, rev, path)
    end
    return content, err
  end

  call(self, args, handle, { text = false }, function(content, err)
    if content == NOT_A_FILE then
      link_target(self, rev, path, cb)
      return
    end
    cb(content, err)
  end)
  return nil, nil
end

return M
