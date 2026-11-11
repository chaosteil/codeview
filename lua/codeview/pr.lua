---@brief Review of a GitHub pull request.
---
--- `:Codeview pr <number>` reads the pull request with |codeview.gh|, brings
--- its commits into the repository, and opens a normal review session on them.
--- Every feature of a local review then works on the pull request: the
--- changed-files sidebar, both diff styles, the comments, and the export.
---
--- The working copy never changes. The call fetches the head of the pull
--- request and the tip of its base branch into two refs of the plugin:
---
--- >
---     refs/codeview/pr/<number>/head
---     refs/codeview/pr/<number>/base
--- <
---
--- The call checks out no branch, and it touches no file of the working copy.
--- The review range is `base...head`, so it starts at the merge base of the
--- two refs. That is the range that GitHub shows in the "Files changed" tab.
---
--- The fetch takes the git remote whose address names the repository of the
--- pull request. SSH, HTTPS, and scp addresses all match, with or without
--- `.git`, on github.com and on a GitHub Enterprise host. See
--- |codeview.pr.pick_remote()|. The fetched head must be the head commit that
--- GitHub reports, or the open stops.
---
--- The session key of the comment store is `pr-<number>-<head commit>`. A new
--- push to the pull request gives a new head commit, so it opens its own
--- comment file and the comments of the older push stay where they are.
---
--- A pull request needs a git repository. A colocated jj repository has one,
--- so it works too.
---
--- The open call runs the steps of |codeview.pr.steps| in order. A caller can
--- give a progress handle, for example a |codeview.loading| view, and the
--- call reports the start of each step to it.

local config = require("codeview.config")
local errors = require("codeview.error")
local exec = require("codeview.exec")
local gh = require("codeview.gh")
local notify = require("codeview.notify")
local git_backend = require("codeview.vcs.git")
local session_mod = require("codeview.session")
local util = require("codeview.util")
local vcs = require("codeview.vcs")

local chain = util.chain
local done = util.done

local M = {}

---Steps of |codeview.pr.open()|, in the order of the run.
---@type codeview.loading.Step[]
M.steps = {
  { key = "repo", text = "find the repository" },
  { key = "info", text = "read the pull request" },
  { key = "refs", text = "fetch the commits" },
  { key = "range", text = "find the diff range" },
  { key = "open", text = "open the review" },
}

---Receiver of the progress of |codeview.pr.open()|.
---@class codeview.pr.Progress
---@field start fun(self: codeview.pr.Progress, key: string) A step starts.
---@field set_title fun(self: codeview.pr.Progress, text: string) The pull request is known.

---Prefix of the refs that hold a pull request.
---@type string
M.ref_prefix = "refs/codeview/pr"

---Fields of `gh pr view --json`.
---
--- The list holds no `commits`: the review reads the commits from the
--- repository, and the field makes the answer of GitHub slower.
---@type string[]
M.fields = {
  "number",
  "title",
  "state",
  "isDraft",
  "url",
  "author",
  "headRefName",
  "baseRefName",
  "headRefOid",
  "baseRefOid",
  "headRepository",
  "headRepositoryOwner",
  "isCrossRepository",
  "body",
}

---@class codeview.pr.Info
---@field number integer Number of the pull request.
---@field title string Title of the pull request.
---@field state string State that GitHub reports: OPEN, CLOSED, or MERGED.
---@field draft boolean True while the pull request is a draft.
---@field url string Address of the pull request.
---@field author string Login of the author.
---@field head_ref string Name of the branch that holds the changes.
---@field base_ref string Name of the branch that receives the changes.
---@field head_sha string Commit at the top of the head branch.
---@field base_sha string Commit at the tip of the base branch.
---@field repo string Repository of the pull request, as `owner/name`.
---@field head_repo string Repository of the head branch, as `owner/name`.
---@field cross boolean True when the head branch lives in a fork.
---@field body string Description of the pull request.

---@class codeview.pr.Refs
---@field head string Local ref that holds the head of the pull request.
---@field base string Local ref that holds the tip of the base branch.
---@field remote string Git remote that the refs come from. An address when no remote names the repository.
---@field warning string? Line about a step that did not run as planned.

---@class codeview.pr.Remote
---@field name string Name of the git remote.
---@field url string Address of the remote, as the git configuration holds it.

---Names of the remotes that gh prefers, in the order of gh.
---@type string[]
M.remote_order = { "upstream", "github", "origin" }

---Environment of every git call of this module.
---
--- The fetch is the only call of the plugin that reaches the network. Without
--- the two prompt variables git can ask for a password on the terminal that
--- Neovim holds. It then waits until the timeout kills it. With them a
--- missing credential fails at once, with a readable line on stderr.
---@type table<string, string>
local GIT_ENV = {
  LC_ALL = "C",
  LANGUAGE = "",
  GIT_TERMINAL_PROMPT = "0",
  GIT_ASKPASS = "",
}

---Time limit of the fetch, in milliseconds.
---
--- The first fetch of a large pull request reads many objects, so it needs
--- more time than a local git call.
---@type integer
M.fetch_timeout = 120000

---Run one git command in a repository.
---@param root string Absolute path of the repository root.
---@param args string[] Arguments after `git`.
---@param handle fun(result: codeview.ExecResult): any?, codeview.Error? Maps the result to a value or an error.
---@param cb? fun(value: any?, err: codeview.Error?)
---@param timeout? integer Milliseconds before the plugin kills the command.
---@return any?, codeview.Error?
local function git(root, args, handle, cb, timeout, stdin)
  local cmd = vim.list_extend({ git_backend.binary(), "-C", root, "--no-pager" }, args)
  local opts = { cwd = root, env = GIT_ENV, timeout = timeout, stdin = stdin }

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

---@alias codeview.pr.Step codeview.util.Step

--- Metadata --------------------------------------------------------------------

---Read the `owner/name` of a repository from the address of a pull request.
---
--- The host is free, because a GitHub Enterprise server holds the pull request
--- under its own name.
---@param url string?
---@return string repo Empty when the address has another form.
local function repo_of_url(url)
  local owner, name = tostring(url or ""):match("^https?://[^/]+/([^/]+)/([^/]+)/pull/")
  if not owner then
    return ""
  end
  return owner .. "/" .. name
end

---Read the answer of `gh pr view --json`.
---@param data table Decoded JSON answer.
---@return codeview.pr.Info? info
---@return codeview.Error? err
function M.parse(data)
  if type(data) ~= "table" or type(data.number) ~= "number" then
    return nil, errors.new(errors.codes.NOT_FOUND, "gh reported no pull request")
  end
  local head_sha = tostring(data.headRefOid or "")
  if head_sha == "" then
    return nil, errors.new(errors.codes.NOT_FOUND, "the pull request has no head commit")
  end

  ---@type codeview.pr.Info
  return {
    number = math.floor(data.number),
    title = data.title or "",
    state = data.state or "",
    draft = data.isDraft == true,
    url = data.url or "",
    author = (data.author or {}).login or "",
    head_ref = data.headRefName or "",
    base_ref = data.baseRefName or "",
    head_sha = head_sha,
    base_sha = tostring(data.baseRefOid or ""),
    repo = repo_of_url(data.url),
    head_repo = (data.headRepository or {}).nameWithOwner or "",
    cross = data.isCrossRepository == true,
    body = data.body or "",
  },
    nil
end

---Read the metadata of one pull request.
---
--- Without a number the call takes the pull request of the current branch.
---@param number integer? Number of the pull request.
---@param opts? { dir?: string, repo?: string, timeout?: integer } `repo` is `owner/name`.
---@param cb? fun(info: codeview.pr.Info?, err: codeview.Error?) Callback for the async form.
---@return codeview.pr.Info? info
---@return codeview.Error? err
function M.view(number, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
  if number ~= nil and (type(number) ~= "number" or number < 1) then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the pull request number must be a positive number"))
  end

  local args = { "pr", "view" }
  if number then
    args[#args + 1] = tostring(math.floor(number))
  end
  if opts.repo and opts.repo ~= "" then
    vim.list_extend(args, { "--repo", opts.repo })
  end
  vim.list_extend(args, { "--json", table.concat(M.fields, ",") })

  local gh_opts = { cwd = opts.dir, timeout = opts.timeout }
  if not cb then
    local data, err = gh.json(args, gh_opts)
    if not data then
      return nil, err
    end
    return M.parse(data)
  end

  gh.json(args, gh_opts, function(data, err)
    if not data then
      cb(nil, err)
      return
    end
    cb(M.parse(data))
  end)
  return nil, nil
end

---Name of the environment variable that holds the metadata of a pull request.
---@type string
M.env_var = "CODEVIEW_PR"

---Read the metadata of a pull request that the caller of Neovim gives.
---
--- A tool that starts Neovim for a review can hold the metadata already, for
--- example chaoshub. The tool puts the JSON object of `gh pr view --json` into
--- the variable of |codeview.pr.env_var|, with the fields of
--- |codeview.pr.fields|. The call reads the variable once and clears it, so
--- that a process of Neovim does not get it.
---@param number integer? Number of the pull request of the command.
---@return codeview.pr.Info? info Nil without the variable, for another number, or for a value that is not valid.
function M.from_env(number)
  local text = vim.env[M.env_var]
  if text == nil or text == "" then
    return nil
  end
  vim.env[M.env_var] = nil
  if type(number) ~= "number" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    return nil
  end
  local info = M.parse(data)
  if not info or info.number ~= number then
    return nil
  end
  return info
end

--- Refs -------------------------------------------------------------------------

---Names of the two refs of one pull request.
---@param number integer Number of the pull request.
---@return codeview.pr.Refs refs The `remote` field is empty until the fetch runs.
function M.refs(number)
  local base = string.format("%s/%d", M.ref_prefix, math.floor(number))
  return { head = base .. "/head", base = base .. "/base", remote = "", warning = nil }
end

---Key of the comment store of one pull request.
---
--- The key holds the head commit, so a new push opens its own comment file.
---@param info codeview.pr.Info
---@return string key
function M.store_key(info)
  return string.format("pr-%d-%s", info.number, info.head_sha)
end

---Text that names the session of one pull request.
---@param info codeview.pr.Info
---@return string label
function M.label(info)
  local title = vim.trim(info.title or "")
  if title == "" then
    return string.format("PR #%d", info.number)
  end
  return string.format("PR #%d %s", info.number, title)
end

---Read the host and the repository of the address of a git remote.
---
--- The call reads the HTTPS form, the SSH form, the git form, and the scp form
--- `[user@]host:owner/name`. A trailing `.git` and a trailing slash drop out.
---@param url string? Address of a git remote.
---@return string? host Lowercase host. Nil when the address has another form, for example a local path.
---@return string? repo Repository as `owner/name`. Nil with the host.
function M.parse_remote_url(url)
  url = vim.trim(tostring(url or ""))
  local host, path
  local rest = url:match("^%a[%w+.-]*://(.+)$")
  if rest then
    host, path = rest:match("^([^/]+)/(.+)$")
  else
    host, path = url:match("^([^/:]+):(.+)$")
  end
  if not host or not path then
    return nil, nil
  end
  host = host:gsub("^.*@", ""):gsub(":%d*$", ""):lower()
  path = path:gsub("/+$", ""):gsub("%.git$", "")
  local owner, name = path:match("([^/]+)/([^/]+)$")
  if host == "" or not owner then
    return nil, nil
  end
  return host, owner .. "/" .. name
end

---First remote of a list, in the order of gh.
---@param list codeview.pr.Remote[]
---@return codeview.pr.Remote? remote Nil for an empty list.
local function preferred(list)
  for _, name in ipairs(M.remote_order) do
    for _, remote in ipairs(list) do
      if remote.name == name then
        return remote
      end
    end
  end
  return list[1]
end

---Pick the remote whose address names the repository of a pull request.
---
--- A remote on the host of the pull request comes first. A remote with the
--- same `owner/name` on another host comes next, for example an SSH host
--- alias. Between two such remotes the order of gh decides: upstream, github,
--- origin, then the first one.
---@param remotes codeview.pr.Remote[] Remotes of the repository.
---@param info codeview.pr.Info Metadata of the pull request.
---@return string? name Nil when no address names the repository.
function M.pick_remote(remotes, info)
  local repo = (info.repo or ""):lower()
  if repo == "" then
    return nil
  end
  local host = gh.host(info.url)
  local same_host, same_repo = {}, {}
  for _, remote in ipairs(remotes or {}) do
    local remote_host, remote_repo = M.parse_remote_url(remote.url)
    if remote_repo and remote_repo:lower() == repo then
      if remote_host == host then
        same_host[#same_host + 1] = remote
      end
      same_repo[#same_repo + 1] = remote
    end
  end
  local found = preferred(same_host) or preferred(same_repo)
  return found and found.name or nil
end

---List the git remotes of a repository with their addresses.
---@param root string Absolute path of the repository root.
---@param cb? fun(remotes: codeview.pr.Remote[]?, err: codeview.Error?)
---@return codeview.pr.Remote[]? remotes In the order of the git configuration.
---@return codeview.Error? err
function M.remotes(root, cb)
  ---@param result codeview.ExecResult
  ---@return codeview.pr.Remote[]?, codeview.Error?
  local function handle(result)
    -- Exit code 1 with no output means that no key matches: no remote.
    if result.code ~= 0 and not (result.code == 1 and vim.trim(result.stdout or "") == "") then
      return nil,
        errors.new(errors.codes.COMMAND_FAILED, "cannot list the git remotes", {
          command = result.command,
          stderr = result.stderr,
        })
    end
    local out, seen = {}, {}
    for _, line in ipairs(exec.lines(result.stdout)) do
      local key, url = line:match("^(%S+)%s+(.*)$")
      local name = key and key:match("^remote%.(.+)%.url$")
      if name and not seen[name] then
        seen[name] = true
        out[#out + 1] = { name = name, url = vim.trim(url) }
      end
    end
    return out, nil
  end

  return git(root, { "config", "--get-regexp", "^remote\\..*\\.url$" }, handle, cb)
end

---Pick the git remote that holds the pull request, by name.
---
--- An empty name takes the remote that gh prefers: upstream, github, origin,
--- then the first remote.
---@param root string Absolute path of the repository root.
---@param wanted string? Name from the configuration. An empty text picks one.
---@param cb? fun(name: string?, err: codeview.Error?)
---@return string? name
---@return codeview.Error? err
function M.remote(root, wanted, cb)
  wanted = vim.trim(wanted or "")

  ---@param remotes codeview.pr.Remote[]?
  ---@param err codeview.Error?
  ---@return string?, codeview.Error?
  local function handle(remotes, err)
    if not remotes then
      return nil, err
    end
    if #remotes == 0 then
      return nil, errors.new(errors.codes.NOT_FOUND, "the repository has no git remote")
    end
    if wanted ~= "" then
      for _, remote in ipairs(remotes) do
        if remote.name == wanted then
          return wanted, nil
        end
      end
      return nil, errors.new(errors.codes.NOT_FOUND, "the repository has no remote named " .. wanted)
    end
    return preferred(remotes).name, nil
  end

  if not cb then
    return handle(M.remotes(root))
  end
  M.remotes(root, function(remotes, err)
    cb(handle(remotes, err))
  end)
  return nil, nil
end

---Pick the source of the fetch of one pull request.
---
--- A name from the configuration wins. Without it the call takes the remote
--- whose address names the repository of the pull request. When no address
--- names it and the user named the repository, the fetch reads the HTTPS
--- address of the repository. Else the call picks a remote by name, like
--- |codeview.pr.remote()|.
---@param root string Absolute path of the repository root.
---@param info codeview.pr.Info Metadata of the pull request.
---@param wanted string Name of the git remote. Empty picks one.
---@param repo string Repository that the user named, as `owner/name`. Empty when the user named none.
---@param cb? fun(source: string?, err: codeview.Error?)
---@return string? source Name of a remote, or an address.
---@return codeview.Error? err
local function source_of(root, info, wanted, repo, cb)
  if wanted ~= "" then
    return M.remote(root, wanted, cb)
  end

  ---@param remotes codeview.pr.Remote[]?
  ---@param err codeview.Error?
  ---@return string?, codeview.Error?
  local function handle(remotes, err)
    if not remotes then
      return nil, err
    end
    local name = M.pick_remote(remotes, info)
    if name then
      return name, nil
    end
    if repo ~= "" and info.repo ~= "" then
      return string.format("https://%s/%s.git", gh.host(info.url), info.repo), nil
    end
    if #remotes == 0 then
      return nil, errors.new(errors.codes.NOT_FOUND, "the repository has no git remote")
    end
    return preferred(remotes).name, nil
  end

  if not cb then
    return handle(M.remotes(root))
  end
  M.remotes(root, function(remotes, err)
    cb(handle(remotes, err))
  end)
  return nil, nil
end

---Bring the commits of one pull request into the repository.
---
--- The call writes two refs of the plugin and nothing else. It does not check
--- out a branch, and it does not touch a file of the working copy.
---
--- When `github.fetch` is "auto" and the repository holds the head commit and
--- the base commit that GitHub reports, the call writes the two refs from them
--- and runs no fetch. git writes no ref to a commit that it does not hold, so
--- one `update-ref` transaction answers both questions.
---
--- The head and the base come in two calls, because one call writes no ref
--- when one refspec fails. A base branch that the remote no longer holds is
--- normal for a merged pull request. In that case the call writes the base
--- commit that GitHub reports into the base ref, and it reports the missing
--- branch in `warning`.
---@param root string Absolute path of the repository root.
---@param info codeview.pr.Info Metadata of the pull request.
---@param opts? { remote?: string, repo?: string } `remote` is the name of the git remote, the configuration value by default. `repo` is the `owner/name` that the user named.
---@param cb? fun(refs: codeview.pr.Refs?, err: codeview.Error?) Callback for the async form.
---@return codeview.pr.Refs? refs
---@return codeview.Error? err
function M.fetch(root, info, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
  if type(root) ~= "string" or root == "" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the call needs a repository root"))
  end
  if type(info) ~= "table" or type(info.number) ~= "number" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the call needs the metadata of a pull request"))
  end

  local refs = M.refs(info.number)
  local wanted = vim.trim(opts.remote or config.get().github.remote or "")
  local repo = vim.trim(opts.repo or "")

  ---Arguments of one fetch.
  ---@param name string Name of the git remote.
  ---@param refspec string
  ---@return string[]
  local function fetch_args(name, refspec)
    return { "fetch", "--no-tags", "--force", "--quiet", name, refspec }
  end

  ---Error of a fetch that failed.
  ---@param _name string Name of the git remote. The message of the caller holds it.
  ---@param message string
  ---@param result codeview.ExecResult
  ---@return codeview.Error
  local function fetch_error(_name, message, result)
    local text = (result.stderr or ""):lower()
    local code = errors.codes.COMMAND_FAILED
    if text:find("could not read from remote", 1, true) or text:find("could not resolve host", 1, true) then
      code = errors.codes.OFFLINE
    end
    return errors.new(code, message, { command = result.command, stderr = result.stderr })
  end

  ---Steps that write the two refs of one remote.
  ---@param name string Name of the git remote.
  ---@return codeview.pr.Step[]
  local function steps_for(name)
    ---@type codeview.ExecResult?
    local failed

    ---Fetch the head of the pull request. A failure stops the chain.
    ---@type codeview.pr.Step
    local function head_step(step_cb)
      local refspec = string.format("refs/pull/%d/head:%s", info.number, refs.head)
      return git(root, fetch_args(name, refspec), function(result)
        if result.code ~= 0 then
          return nil,
            fetch_error(name, string.format("cannot fetch pull request %d from %s", info.number, name), result)
        end
        refs.remote = name
        return true, nil
      end, step_cb, M.fetch_timeout)
    end

    ---Check that the fetched head is the head commit that GitHub reports.
    ---
    --- A push between the read of the metadata and the fetch gives another
    --- commit. The review then shows lines that the comments of GitHub do not
    --- know, so the open stops.
    ---@type codeview.pr.Step
    local function check_step(step_cb)
      return git(root, { "rev-parse", "--verify", "--quiet", refs.head .. "^{commit}" }, function(result)
        local fetched = vim.trim(result.stdout or ""):lower()
        if result.code ~= 0 or fetched ~= info.head_sha:lower() then
          return nil,
            errors.new(
              errors.codes.COMMAND_FAILED,
              string.format(
                "pull request %d changed during the open: GitHub reports head %s, the fetch gave %s. Open it again",
                info.number,
                info.head_sha:sub(1, 8),
                fetched ~= "" and fetched:sub(1, 8) or "no commit"
              ),
              { command = result.command, stderr = result.stderr }
            )
        end
        return true, nil
      end, step_cb)
    end

    ---Fetch the tip of the base branch. A failure waits for the fallback.
    ---@type codeview.pr.Step
    local function base_step(step_cb)
      if info.base_ref == "" then
        return done(step_cb, true, nil)
      end
      local refspec = string.format("refs/heads/%s:%s", info.base_ref, refs.base)
      return git(root, fetch_args(name, refspec), function(result)
        if result.code ~= 0 then
          failed = result
        end
        return true, nil
      end, step_cb, M.fetch_timeout)
    end

    ---Write the base commit of GitHub into the base ref.
    ---
    --- The step only runs after the base branch is gone from the remote. The
    --- commit is in the repository when the head of the pull request holds it,
    --- which is the normal case for a merged pull request.
    ---@type codeview.pr.Step
    local function fallback_step(step_cb)
      if not failed then
        return done(step_cb, true, nil)
      end
      local message = string.format("cannot fetch the base branch %s of pull request %d", info.base_ref, info.number)
      if info.base_sha == "" then
        return done(step_cb, nil, fetch_error(name, message, failed))
      end
      return git(root, { "update-ref", refs.base, info.base_sha .. "^{commit}" }, function(result)
        if result.code ~= 0 then
          return nil, fetch_error(name, message, failed)
        end
        refs.warning = string.format(
          "%s no longer holds the branch %s. The review starts at %s",
          name,
          info.base_ref,
          info.base_sha:sub(1, 8)
        )
        return true, nil
      end, step_cb)
    end

    return { head_step, check_step, base_step, fallback_step }
  end

  ---Write the two refs from the commits of the repository. The answer is
  ---true when both refs point at the commits of GitHub, and false when the
  ---fetch must run.
  ---@param name string Name of the git remote.
  ---@param local_cb? fun(written: boolean)
  ---@return boolean? written
  local function from_local(name, local_cb)
    if config.get().github.fetch ~= "auto" or info.head_sha == "" or info.base_sha == "" then
      if local_cb then
        local_cb(false)
        return nil
      end
      return false
    end
    local stdin = string.format("update %s %s\nupdate %s %s\n", refs.head, info.head_sha, refs.base, info.base_sha)
    local function handle(result)
      if result.code ~= 0 then
        return false, nil
      end
      refs.remote = name
      return true, nil
    end
    if not local_cb then
      return git(root, { "update-ref", "--stdin" }, handle, nil, nil, stdin) == true
    end
    git(root, { "update-ref", "--stdin" }, handle, function(written)
      local_cb(written == true)
    end, nil, stdin)
    return nil
  end

  if not cb then
    local name, err = source_of(root, info, wanted, repo)
    if not name then
      return nil, err
    end
    if from_local(name) then
      return refs, nil
    end
    local ok, chain_err = chain(steps_for(name))
    if not ok then
      return nil, chain_err
    end
    return refs, nil
  end

  source_of(root, info, wanted, repo, function(name, err)
    if not name then
      cb(nil, err)
      return
    end
    from_local(name, function(written)
      if written then
        cb(refs, nil)
        return
      end
      chain(steps_for(name), function(ok, chain_err)
        if not ok then
          cb(nil, chain_err)
          return
        end
        cb(refs, nil)
      end)
    end)
  end)
  return nil, nil
end

---Build the review range of one pull request.
---
--- The range starts at the merge base of the base branch and the head, like
--- the "Files changed" tab of GitHub.
---@param repo codeview.vcs.Repo Repository handle of the git backend.
---@param info codeview.pr.Info
---@param cb? fun(range: codeview.vcs.Range?, err: codeview.Error?) Callback for the async form.
---@return codeview.vcs.Range? range
---@return codeview.Error? err
function M.range(repo, info, cb)
  local refs = M.refs(info.number)
  ---@type codeview.vcs.RangeSpec
  local spec = {
    kind = "triple",
    from = refs.base,
    to = refs.head,
    spec = string.format("pr-%d", info.number),
  }
  return repo:resolve_range(spec, cb)
end

--- Session ----------------------------------------------------------------------

---Repository handle for a pull request review.
---
--- The refs of a pull request are git refs, so the review always runs on the
--- git backend. A colocated jj repository holds a git repository, so it works
--- too.
---@param dir string? Directory for the detection.
---@param cb? fun(repo: codeview.vcs.Repo?, err: codeview.Error?)
---@return codeview.vcs.Repo? repo
---@return codeview.Error? err
local function detect(dir, cb)
  ---@param repo codeview.vcs.Repo?
  ---@param err codeview.Error?
  ---@return codeview.vcs.Repo?, codeview.Error?
  local function handle(repo, err)
    if repo then
      return repo, nil
    end
    return nil,
      errors.new(errors.codes.NOT_A_REPO, "pull request review needs a git repository", {
        stderr = err and err.message or nil,
      })
  end

  if not cb then
    return handle(vcs.detect(dir, { backend = "git" }))
  end
  vcs.detect(dir, { backend = "git" }, function(repo, err)
    cb(handle(repo, err))
  end)
  return nil, nil
end

---Open a review session for one pull request.
---
--- Without a number the call takes the pull request of the current branch.
--- The session shows the title of the pull request in the sidebar header, and
--- it stores its comments under the key of |codeview.pr.store_key()|.
---
--- With `opts.info` the call takes the metadata of the caller, and it does not
--- wait for GitHub before the review shows. |codeview.pr.check()| then reads
--- the pull request in the background. When the open with that metadata
--- fails, for example because it is old, the call opens again with the
--- metadata of GitHub.
---@param number integer? Number of the pull request.
---@param opts? { dir?: string, repo?: string, remote?: string, comments?: boolean, progress?: codeview.pr.Progress, info?: codeview.pr.Info } `repo` is `owner/name`.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session
---@return codeview.Error? err
function M.open(number, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
  if not gh.available() then
    return done(cb, nil, errors.new(errors.codes.UNSUPPORTED, "pull request review needs the gh CLI in $PATH"))
  end

  -- Metadata of the caller, for the same pull request only.
  local given = opts.info
  if type(given) ~= "table" or type(given.number) ~= "number" or given.number ~= number then
    given = nil
  end

  local state = {}
  local steps = {}

  ---Add one call to the chain and keep its answer in `state`.
  ---@param fn fun(cb?: fun(value: any?, err: codeview.Error?)): any?, codeview.Error? Call in both forms.
  ---@param key string Field of `state` that receives the answer.
  local function step(fn, key)
    ---@param value any?
    ---@param err codeview.Error?
    ---@return any?, codeview.Error?
    local function keep(value, err)
      if value == nil then
        return nil, err or errors.new(errors.codes.COMMAND_FAILED, "the " .. key .. " call gave no answer")
      end
      state[key] = value
      return value, nil
    end

    steps[#steps + 1] = function(step_cb)
      if opts.progress then
        opts.progress:start(key)
      end
      if not step_cb then
        return keep(fn())
      end
      fn(function(value, err)
        step_cb(keep(value, err))
      end)
      return nil, nil
    end
  end

  step(function(step_cb)
    return detect(opts.dir, step_cb)
  end, "repo")
  step(function(step_cb)
    if given then
      return done(step_cb, given, nil)
    end
    return M.view(number, { dir = opts.dir, repo = opts.repo }, step_cb)
  end, "info")
  step(function(step_cb)
    if opts.progress then
      opts.progress:set_title(M.label(state.info))
    end
    return M.fetch(state.repo.root, state.info, { remote = opts.remote, repo = opts.repo }, step_cb)
  end, "refs")
  step(function(step_cb)
    return M.range(state.repo, state.info, step_cb)
  end, "range")

  ---Open the session, after every call gave its answer.
  ---
  --- The review comments of the pull request load after the session, so that
  --- the sidebar and the diff open without a wait for the network.
  ---@param build_cb? fun(session: codeview.Session?, err: codeview.Error?)
  ---@return codeview.Session?
  ---@return codeview.Error?
  local function build(build_cb)
    local info = state.info --[[@as codeview.pr.Info]]
    local refs = state.refs --[[@as codeview.pr.Refs]]
    if opts.progress then
      opts.progress:start("open")
    end
    if refs.warning then
      notify.warn(refs.warning)
    end
    local open_opts = {
      repo = state.repo,
      label = M.label(info),
      store_key = M.store_key(info),
      pr = info,
      pr_opts = { dir = opts.dir, repo = opts.repo, remote = opts.remote },
    }

    ---@param session codeview.Session?
    ---@param err codeview.Error?
    ---@return codeview.Session?, codeview.Error?
    local function after(session, err)
      if session and opts.comments ~= false and config.get().github.comments then
        require("codeview.remote").load(session, {
          repo = info.repo,
          number = info.number,
          dir = opts.dir or state.repo.root,
          host = gh.host(info.url),
        })
      end
      -- The results of pr-agent are files on the disk, so they read at once.
      if session then
        require("codeview.agent").attach(session)
      end
      if session and given then
        M.check(session)
      end
      return session, err
    end

    if not build_cb then
      return after(session_mod.open(state.range, open_opts))
    end
    session_mod.open(state.range, open_opts, function(session, err)
      build_cb(after(session, err))
    end)
    return nil, nil
  end

  ---Options of the second open, with the metadata of GitHub.
  ---@return table
  local function without_info()
    return vim.tbl_extend("force", opts, { info = false })
  end

  if not cb then
    local ok, err = chain(steps)
    if not ok then
      if given then
        return M.open(number, without_info())
      end
      return nil, err
    end
    return build()
  end

  chain(steps, function(ok, err)
    if not ok then
      if given then
        M.open(number, without_info(), cb)
        return
      end
      cb(nil, err)
      return
    end
    build(cb)
  end)
  return nil, nil
end

--- Check -----------------------------------------------------------------------

---Fields of |codeview.pr.Info| that the review shows.
---@type string[]
local shown_fields = {
  "title",
  "state",
  "draft",
  "url",
  "author",
  "head_ref",
  "base_ref",
  "head_sha",
  "base_sha",
  "repo",
  "head_repo",
  "cross",
  "body",
}

---Report whether the review must fetch new commits for the metadata of GitHub.
---
--- A new head commit needs new commits. A new base commit needs them only when
--- the session knew a base commit: without one, the fetch read the tip of the
--- base branch, and GitHub can report an older base commit.
---@param held codeview.pr.Info Metadata of the session.
---@param fresh codeview.pr.Info Metadata of GitHub.
---@return boolean moved
local function moved(held, fresh)
  if held.head_sha:lower() ~= fresh.head_sha:lower() then
    return true
  end
  return held.base_sha ~= "" and held.base_sha:lower() ~= fresh.base_sha:lower()
end

---Send the User event of the end of a check.
---@param session codeview.Session
---@param fields { ok: boolean, changed: boolean }
local function announce_check(session, fields)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "CodeViewPrChecked",
    data = { id = session.id, ok = fields.ok, changed = fields.changed },
  })
end

---Give a session the metadata of GitHub, and read the review again.
---
--- The session stays open, so a handler of CodeViewSessionClosed does not
--- run. For a new head or a new base, the call writes the refs and the range
--- first. A new head commit gives a new key of the comment store, so the
--- session loads the comment file of that key.
---@param session codeview.Session
---@param fresh codeview.pr.Info Metadata of GitHub.
---@param cb fun(ok: boolean, err: codeview.Error?)
local function reload(session, fresh, cb)
  local pr_opts = session.pr_opts or {}

  ---@param range codeview.vcs.Range? New range. Nil keeps the range.
  local function apply(range)
    if session.closed then
      cb(false, errors.new(errors.codes.INVALID_ARG, "the session is closed"))
      return
    end
    session.pr = fresh
    session.spec = M.label(fresh)
    local key = M.store_key(fresh)
    if key ~= session.store_key then
      local comments = require("codeview.comments")
      comments.detach(session)
      session.store_key = key
      local _, store_err = comments.attach(session)
      if store_err then
        notify.warn(tostring(store_err))
      end
    end
    if range then
      session.input = range
    end
    local refresh = { snapshot = false, range = range or session.range }
    if session_mod.current() == session then
      require("codeview.view").refresh(refresh, function(ok)
        cb(ok, nil)
      end)
      return
    end
    session:refresh(refresh, function(_, err)
      cb(err == nil, err)
    end)
  end

  if not moved(session.pr, fresh) then
    apply(nil)
    return
  end
  M.fetch(session.repo.root, fresh, { remote = pr_opts.remote, repo = pr_opts.repo }, function(refs, err)
    if not refs then
      cb(false, err)
      return
    end
    if refs.warning then
      notify.warn(refs.warning)
    end
    M.range(session.repo, fresh, function(range, range_err)
      if not range then
        cb(false, range_err)
        return
      end
      apply(range)
    end)
  end)
end

---Check the metadata of a session against GitHub.
---
--- A review that opens with the metadata of the caller shows it at once,
--- without a wait for GitHub. This call then reads the pull request with gh.
--- When GitHub reports other values, the session takes them and reads the
--- review again, with a short message. A new head commit or a new base commit
--- also fetches the commits. The session stays open the whole time.
---
--- The call sends `User CodeViewPrChecked` at the end. The `data` field holds
--- `id`, the number of the session, `ok`, false after a failure, and
--- `changed`, true when the session took new values.
---@param session codeview.Session Session of a pull request.
---@param cb? fun(changed: boolean, err: codeview.Error?)
function M.check(session, cb)
  local held = M.current(session)
  if not held then
    if cb then
      cb(false, errors.new(errors.codes.INVALID_ARG, "the session does not review a pull request"))
    end
    return
  end
  local pr_opts = session.pr_opts or {}

  ---@param ok boolean
  ---@param changed boolean
  ---@param err codeview.Error?
  local function finish(ok, changed, err)
    if not ok and err then
      notify.warn("the check of the pull request failed: " .. tostring(err))
    end
    announce_check(session, { ok = ok, changed = changed })
    if cb then
      cb(changed, err)
    end
  end

  M.view(held.number, { dir = pr_opts.dir or session.repo.root, repo = pr_opts.repo }, function(fresh, err)
    if session.closed then
      if cb then
        cb(false, nil)
      end
      return
    end
    if not fresh then
      finish(false, false, err)
      return
    end
    local same = true
    for _, field in ipairs(shown_fields) do
      if fresh[field] ~= held[field] then
        same = false
        break
      end
    end
    if same then
      finish(true, false, nil)
      return
    end
    if moved(held, fresh) then
      notify.info(
        string.format(
          "PR #%d changed on GitHub: the review reloads with head %s",
          fresh.number,
          fresh.head_sha:sub(1, 8)
        )
      )
    end
    reload(session, fresh, function(ok, reload_err)
      finish(ok, ok, reload_err)
    end)
  end)
end

---Metadata of the pull request that the session shows.
---@param session? codeview.Session Session to read. The active session by default.
---@return codeview.pr.Info? info Nil for a session that reviews a local range.
function M.current(session)
  session = session or session_mod.current()
  local info = session and session.pr or nil
  if type(info) == "table" and type(info.number) == "number" then
    return info
  end
  return nil
end

return M
