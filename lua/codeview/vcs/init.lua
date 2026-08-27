---@brief The VCS backend interface.
---
--- A backend module has a name, an `available()` check, and a `detect(dir)`
--- function. `detect()` returns a repository handle. Every other call is a
--- method on that handle:
---
--- - `repo:resolve_rev(rev)` — one revision to one commit id.
--- - `repo:resolve_range(spec)` — user text such as `a..b` to a range of commit ids.
--- - `repo:log(opts)` — commit records, newest first.
--- - `repo:changed_files(range)` — the files that the range changes.
--- - `repo:file_content(rev, path)` — the content of one file at one revision.
--- - `repo:working_rev()` — the commit that the working copy sits on.
--- - `repo:snapshot()` — write the working copy into that commit and read it.
---
--- Every method takes an optional callback as its last argument. Without a
--- callback the method blocks and returns `value, err`. With a callback it
--- returns at once and calls `cb(value, err)` on the main loop.
---
--- No method throws. Errors come back as |codeview.Error| values.

local config = require("codeview.config")
local errors = require("codeview.error")

local M = {}

---@class codeview.vcs.Commit
---@field id string Full commit id.
---@field short_id string Abbreviated id for the user interface. The jj backend uses the change id.
---@field change_id string? Change id, for a backend that has one.
---@field subject string First line of the commit message.
---@field body string Rest of the commit message, without the subject.
---@field author string Name of the author.
---@field author_email string Mail address of the author.
---@field date string Author date, in ISO 8601 format.
---@field committer_date string Committer date, in ISO 8601 format.
---@field parents string[] Ids of the parent commits.

---@alias codeview.vcs.Status
---| "added"
---| "modified"
---| "deleted"
---| "renamed"
---| "copied"
---| "typechanged"
---| "unmerged"
---| "unknown"

---@class codeview.vcs.FileChange
---@field path string Path in the new revision. For a deletion it is the old path.
---@field old_path string? Path in the old revision, when it differs from `path`.
---@field status codeview.vcs.Status
---@field score integer? Similarity of a rename or a copy, in percent.
---@field virtual boolean? True for an entry that the repository does not hold, like the commit message.
---@field label string? Name for the user. A virtual entry sets it, because its path is no file name.
---@field group string? Name of the group node that holds a virtual entry.
---@field group_path string? Path key of that group node.
---@field commit codeview.vcs.Commit? Commit of a commit entry.

---@class codeview.vcs.Range
---@field from string? Base revision, exclusive. Nil means the state before the first commit.
---@field to string Head revision, inclusive.
---@field spec string? Text that the user wrote.

---@class codeview.vcs.RangeSpec
---@field kind "single"|"range"|"triple"|"explicit"|"revset" Form of the input: `a`, `a..b`, `a...b`, a range table with no base, or a jj revset.
---@field from string? Left side of the text.
---@field to string Right side of the text.
---@field spec string The text itself.

---@class codeview.vcs.LogOpts
---@field range codeview.vcs.Range? Only the commits of this range.
---@field revs string[]? Revision arguments, when there is no range.
---@field limit integer? Maximum number of commits.
---@field paths string[]? Only the commits that touch these paths.

---@class codeview.vcs.Repo
---@field backend string Name of the backend that made the handle.
---@field root string Absolute path of the repository root.
---@field resolve_rev fun(self: codeview.vcs.Repo, rev: string, cb?: fun(id: string?, err: codeview.Error?)): string?, codeview.Error?
---@field resolve_range fun(self: codeview.vcs.Repo, spec: string|codeview.vcs.Range|codeview.vcs.RangeSpec, cb?: fun(range: codeview.vcs.Range?, err: codeview.Error?)): codeview.vcs.Range?, codeview.Error?
---@field log fun(self: codeview.vcs.Repo, opts?: codeview.vcs.LogOpts, cb?: fun(commits: codeview.vcs.Commit[]?, err: codeview.Error?)): codeview.vcs.Commit[]?, codeview.Error?
---@field changed_files fun(self: codeview.vcs.Repo, range: codeview.vcs.Range, cb?: fun(files: codeview.vcs.FileChange[]?, err: codeview.Error?)): codeview.vcs.FileChange[]?, codeview.Error?
---@field file_content fun(self: codeview.vcs.Repo, rev: string?, path: string, cb?: fun(content: string?, err: codeview.Error?)): string?, codeview.Error?
---@field working_rev fun(self: codeview.vcs.Repo, cb?: fun(id: string?, err: codeview.Error?)): string?, codeview.Error?
---@field snapshot fun(self: codeview.vcs.Repo, cb?: fun(id: string?, err: codeview.Error?)): string?, codeview.Error?

---@class codeview.vcs.Backend
---@field name string Name of the backend.
---@field available fun(): boolean True when the executable is in $PATH.
---@field detect fun(dir?: string, cb?: fun(repo: codeview.vcs.Repo?, err: codeview.Error?)): codeview.vcs.Repo?, codeview.Error?

---Module path of each backend.
---@type table<string, string>
M.backends = {
  git = "codeview.vcs.git",
  jj = "codeview.vcs.jj",
}

---Order in which `backend = "auto"` reads the backends.
---
--- The order decides only between two repositories with the same root. A
--- colocated repository has a `.jj` directory and a `.git` directory, and both
--- backends report the same root. The jj backend wins there, because the user
--- drives such a repository with jj.
---@type string[]
M.order = { "jj", "git" }

---Load a backend module.
---@param name string
---@return codeview.vcs.Backend? backend
---@return codeview.Error? err
function M.get(name)
  local path = M.backends[name]
  if not path then
    return nil, errors.new(errors.codes.INVALID_ARG, "unknown backend: " .. tostring(name))
  end
  local ok, backend = pcall(require, path)
  if not ok then
    return nil, errors.new(errors.codes.UNSUPPORTED, "cannot load backend " .. name, { stderr = tostring(backend) })
  end
  return backend, nil
end

---Names of the backends to try, in order.
---@param name string "auto", or the name of one backend.
---@return string[]
local function candidates(name)
  if name ~= "auto" then
    return { name }
  end
  local out = {}
  for _, candidate in ipairs(M.order) do
    if M.backends[candidate] then
      out[#out + 1] = candidate
    end
  end
  return out
end

---@param dir string?
---@return codeview.Error
local function no_repo(dir)
  return errors.new(errors.codes.NOT_A_REPO, "no repository at " .. (dir or vim.uv.cwd() or "."))
end

---@param name string Name of the backend that the configuration forces.
---@return codeview.Error
local function no_executable(name)
  return errors.new(errors.codes.UNSUPPORTED, "the " .. name .. " backend needs " .. name .. " in $PATH")
end

---Keep the repository that holds the other one.
---
--- Both roots are parents of the same directory, so one path is a prefix of
--- the other. The deeper root is the closer repository: a git repository
--- inside a jj repository wins over the jj repository around it. Two equal
--- roots keep the first candidate, which is the order of |codeview.vcs.order|.
---@param current codeview.vcs.Repo?
---@param candidate codeview.vcs.Repo
---@return codeview.vcs.Repo
local function closer(current, candidate)
  if not current or #candidate.root > #current.root then
    return candidate
  end
  return current
end

---Find the repository that holds a directory.
---
--- With `backend = "auto"` the search reads every backend and takes the
--- repository with the deepest root. |codeview.vcs.order| decides only between
--- two repositories with the same root.
---@param dir? string Directory inside the repository. The current directory by default.
---@param opts? { backend?: "auto"|"git"|"jj" } Backend to use. The configuration value by default.
---@param cb? fun(repo: codeview.vcs.Repo?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.Repo? repo Nil when the directory is outside a repository.
---@return codeview.Error? err
function M.detect(dir, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  local name = (opts or {}).backend or config.get().backend
  local names = candidates(name)
  local forced = name ~= "auto"

  if not cb then
    local best ---@type codeview.vcs.Repo?
    local last ---@type codeview.Error?
    for _, candidate in ipairs(names) do
      local backend, err = M.get(candidate)
      if not backend then
        return nil, err
      end
      if not backend.available() then
        if forced then
          return nil, no_executable(candidate)
        end
      else
        local repo, detect_err = backend.detect(dir)
        if repo then
          best = closer(best, repo)
        elseif detect_err and detect_err.code ~= errors.codes.NOT_A_REPO then
          return nil, detect_err
        else
          last = detect_err
        end
      end
    end
    if best then
      return best, nil
    end
    return nil, last or no_repo(dir)
  end

  local index = 0
  local best ---@type codeview.vcs.Repo?
  local last ---@type codeview.Error?
  local function step()
    index = index + 1
    local candidate = names[index]
    if not candidate then
      if best then
        cb(best, nil)
      else
        cb(nil, last or no_repo(dir))
      end
      return
    end
    local backend, err = M.get(candidate)
    if not backend then
      cb(nil, err)
      return
    end
    if not backend.available() then
      if forced then
        cb(nil, no_executable(candidate))
        return
      end
      step()
      return
    end
    backend.detect(dir, function(repo, detect_err)
      if repo then
        best = closer(best, repo)
        step()
        return
      end
      if detect_err and detect_err.code ~= errors.codes.NOT_A_REPO then
        cb(nil, detect_err)
        return
      end
      last = detect_err
      step()
    end)
  end
  step()
  return nil, nil
end

---Read the form of a revision argument.
---
--- The function does not talk to the backend. It only splits the text.
--- `a` is one commit, and `a..b` is a range. `a...b` is a range from the
--- merge base of `a` and `b`. An empty side means `HEAD`.
---@param spec string Revision text from the user.
---@return codeview.vcs.RangeSpec? parsed
---@return codeview.Error? err
function M.parse_range(spec)
  if type(spec) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "revision must be a string, got " .. type(spec))
  end
  local text = vim.trim(spec)
  if text == "" then
    return nil, errors.new(errors.codes.INVALID_ARG, "revision is empty")
  end

  local from, sep, to = text:match("^(.-)(%.%.%.?)(.*)$")
  if not sep then
    return { kind = "single", to = text, spec = text }, nil
  end

  from = vim.trim(from)
  to = vim.trim(to)
  if from == "" then
    from = "HEAD"
  end
  if to == "" then
    to = "HEAD"
  end
  return { kind = sep == "..." and "triple" or "range", from = from, to = to, spec = text }, nil
end

return M
