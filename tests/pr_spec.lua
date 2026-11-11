local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.pr", function()
  local fixture = fixtures.git_pr()
  local errors, exec, gh, pr, remote, session, store
  ---@type string[][]
  local gh_calls
  ---@type fun(cmd: string[]): table
  local answer

  ---Run a git command in the review repository.
  ---@param args string[]
  ---@return string stdout
  local function git(args)
    local cmd = vim.list_extend({ "git", "-C", fixture.root }, args)
    local res = vim.system(cmd, { text = true, env = fixture.env }):wait(20000)
    assert.are.equal(0, res.code, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
    return vim.trim(res.stdout or "")
  end

  ---Answer of `gh pr view --json`, built from the fixture.
  ---@return string json
  local function pr_view()
    return vim.json.encode({
      number = 12,
      title = "Add the feature",
      state = "OPEN",
      isDraft = false,
      url = "https://github.com/ada/demo/pull/12",
      author = { login = "ada" },
      headRefName = "pr",
      baseRefName = "main",
      headRefOid = fixture.ids.pr_two,
      baseRefOid = fixture.ids.main_two,
      headRepository = { name = "demo", nameWithOwner = "ada/demo" },
      headRepositoryOwner = { login = "ada" },
      isCrossRepository = false,
      body = "the body of the pull request",
      commits = {
        {
          oid = fixture.ids.pr_one,
          messageHeadline = "pr: add feature.txt",
          messageBody = "",
          committedDate = "2024-05-02T10:00:00Z",
          authors = { { name = "Ada Lovelace", email = "ada@example.com", login = "ada" } },
        },
        {
          oid = fixture.ids.pr_two,
          messageHeadline = "pr: change a.txt",
          messageBody = "",
          committedDate = "2024-05-03T10:00:00Z",
          authors = { { name = "Ada Lovelace", email = "ada@example.com", login = "ada" } },
        },
      },
    })
  end

  ---Answer of the review comment endpoint.
  ---@return string json
  local function pr_comments()
    return vim.json.encode({
      {
        id = 501,
        path = "a.txt",
        line = 2,
        start_line = vim.NIL,
        original_line = 2,
        side = "RIGHT",
        commit_id = fixture.ids.pr_two,
        original_commit_id = fixture.ids.pr_two,
        body = "this line needs a test",
        created_at = "2024-05-04T10:00:00Z",
        html_url = "https://github.com/ada/demo/pull/12#discussion_r501",
        user = { login = "grace" },
        diff_hunk = "@@ -1,3 +1,3 @@\n one\n-two\n+two changed\n three",
      },
    })
  end

  ---Answer every gh call. Every other command runs for real.
  ---@param cmd string[]
  ---@return table
  local function default_answer(cmd)
    if cmd[2] == "pr" and cmd[3] == "view" then
      return { stdout = pr_view() }
    end
    if cmd[2] == "api" then
      -- The paging stops at the first short page.
      return { stdout = cmd[3]:find("page=1", 1, true) and pr_comments() or "[]" }
    end
    return { code = 1, stderr = "unexpected gh call: " .. table.concat(cmd, " ") }
  end

  ---Wait until a check answers true.
  ---@param check fun(): boolean
  ---@param message string
  local function wait_for(check, message)
    assert.is_true(vim.wait(20000, check, 10), message)
  end

  ---Open a pull request session and wait for the answer.
  ---@param number integer?
  ---@param opts? table
  ---@return codeview.Session? opened
  ---@return codeview.Error? err
  local function open(number, opts)
    local out, finished = {}, false
    pr.open(number, vim.tbl_extend("force", { dir = fixture.dir }, opts or {}), function(opened, err)
      out.session, out.err, finished = opened, err, true
    end)
    wait_for(function()
      return finished
    end, "the pull request did not open")
    return out.session, out.err
  end

  before_each(function()
    helpers.unload()
    -- The specs run in a `-c` command of Neovim, which looks like a start
    -- from the command line. A quit there ends the test run.
    require("codeview.config").setup({ commit_message = false, quit = "never" })
    errors = require("codeview.error")
    exec = require("codeview.exec")
    gh = require("codeview.gh")
    pr = require("codeview.pr")
    remote = require("codeview.remote")
    session = require("codeview.session")
    store = require("codeview.store")

    gh_calls = {}
    answer = default_answer
    local real = exec.capture
    exec.capture = function(cmd, opts, cb) ---@diagnostic disable-line: duplicate-set-field
      if cmd[1] ~= gh.binary() then
        return real(cmd, opts, cb)
      end
      gh_calls[#gh_calls + 1] = cmd
      local scripted = answer(cmd)
      local result = {
        command = cmd,
        code = scripted.code or 0,
        signal = 0,
        stdout = scripted.stdout or "",
        stderr = scripted.stderr or "",
      }
      if cb then
        vim.schedule(function()
          cb(result, nil)
        end)
        return nil, nil
      end
      return result, nil
    end
    gh.available = function() ---@diagnostic disable-line: duplicate-set-field
      return true
    end
  end)

  after_each(function()
    session.close()
    helpers.unload()
  end)

  describe("parse", function()
    it("reads a recorded answer of gh pr view", function()
      local info = assert(pr.parse(fixtures.gh_json("pr-view.json")))
      assert.are.equal(41254, info.number)
      assert.are.equal("refactor(defaults): edit global cwd on `1-`", info.title)
      assert.are.equal("MERGED", info.state)
      assert.are.equal("neovim/neovim", info.repo)
      assert.are.equal("nathanzeng/neovim", info.head_repo)
      assert.is_true(info.cross)
      assert.are.equal("master", info.base_ref)
      assert.are.equal("a456d242e154ed8ab4fe5a88a2113a6f7ff3ca3d", info.head_sha)
    end)

    it("reads the repository of a GitHub Enterprise address", function()
      local info = assert(pr.parse({
        number = 7,
        headRefOid = "abc123",
        url = "https://github.acme.com/team/app/pull/7",
      }))
      assert.are.equal("team/app", info.repo)
    end)

    it("rejects an answer without a pull request", function()
      local info, err = pr.parse({})
      assert.is_nil(info)
      assert.are.equal(errors.codes.NOT_FOUND, err.code)
    end)
  end)

  describe("names", function()
    it("keeps the refs of the plugin out of the branches", function()
      local refs = pr.refs(12)
      assert.are.equal("refs/codeview/pr/12/head", refs.head)
      assert.are.equal("refs/codeview/pr/12/base", refs.base)
    end)

    it("keys the store by the number and the head commit", function()
      assert.are.equal("pr-12-abc123", pr.store_key({ number = 12, head_sha = "abc123" }))
    end)

    it("names the session after the title", function()
      assert.are.equal("PR #12 Add the feature", pr.label({ number = 12, title = "Add the feature" }))
      assert.are.equal("PR #12", pr.label({ number = 12, title = "" }))
    end)
  end)

  describe("view", function()
    it("asks gh for the fields of the pull request", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      assert.are.equal(12, info.number)
      assert.are.equal("ada/demo", info.repo)
      assert.are.equal(fixture.ids.pr_two, info.head_sha)
      assert.are.same({ "gh", "pr", "view", "12", "--json", table.concat(pr.fields, ",") }, gh_calls[1])
      -- The commits come from the repository. The field makes gh slower.
      assert.is_false(vim.tbl_contains(pr.fields, "commits"))
    end)

    it("asks for the pull request of the branch without a number", function()
      assert(pr.view(nil, { dir = fixture.dir }))
      assert.are.equal("--json", gh_calls[1][4])
    end)

    it("takes a repository argument", function()
      assert(pr.view(12, { dir = fixture.dir, repo = "ada/demo" }))
      assert.is_truthy(vim.tbl_contains(gh_calls[1], "--repo"))
    end)

    it("rejects a number that is not a number", function()
      local info, err = pr.view("12" --[[@as integer]], { dir = fixture.dir })
      assert.is_nil(info)
      assert.are.equal(errors.codes.INVALID_ARG, err.code)
    end)
  end)

  describe("fetch", function()
    it("writes the two refs without a change of the working copy", function()
      local head_before = git({ "rev-parse", "HEAD" })
      local info = assert(pr.view(12, { dir = fixture.dir }))
      local refs = assert(pr.fetch(fixture.root, info))

      assert.are.equal("origin", refs.remote)
      assert.are.equal(fixture.ids.pr_two, git({ "rev-parse", refs.head }))
      assert.are.equal(fixture.ids.main_two, git({ "rev-parse", refs.base }))

      assert.are.equal("refs/heads/main", git({ "symbolic-ref", "HEAD" }))
      assert.are.equal(head_before, git({ "rev-parse", "HEAD" }))
      assert.are.equal("", git({ "status", "--porcelain" }))
      assert.are.equal(0, vim.fn.filereadable(vim.fs.joinpath(fixture.root, "feature.txt")))
    end)

    it("keeps the head when the remote no longer holds the base branch", function()
      -- An earlier test brought the commits in. Only the fetch sees the base
      -- branch that is gone.
      assert(require("codeview.config").setup({ commit_message = false, github = { fetch = "always" } }))
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.base_ref = "gone"
      local refs = assert(pr.fetch(fixture.root, info))

      assert.are.equal(fixture.ids.pr_two, git({ "rev-parse", refs.head }))
      assert.are.equal(fixture.ids.main_two, git({ "rev-parse", refs.base }))
      assert.is_truthy(refs.warning)
      assert.is_truthy(refs.warning:find("gone", 1, true), refs.warning)
    end)

    ---Run a fetch and keep the git commands that it runs.
    ---@param info codeview.pr.Info
    ---@return codeview.pr.Refs? refs
    ---@return string[] subcommands The first argument after the options of each git call.
    local function fetch_and_record(info)
      local subcommands = {}
      local outer = exec.capture
      exec.capture = function(cmd, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        if cmd[1] ~= gh.binary() then
          subcommands[#subcommands + 1] = cmd[5]
        end
        return outer(cmd, opts, cb)
      end
      local refs = pr.fetch(fixture.root, info)
      exec.capture = outer
      return refs, subcommands
    end

    it("skips the fetch when the repository holds both commits", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      assert(pr.fetch(fixture.root, info))
      git({ "update-ref", "-d", pr.refs(12).head })
      git({ "update-ref", "-d", pr.refs(12).base })

      local refs, subcommands = fetch_and_record(info)
      assert(refs)
      assert.is_false(vim.tbl_contains(subcommands, "fetch"), table.concat(subcommands, " "))
      assert.are.equal("origin", refs.remote)
      assert.are.equal(fixture.ids.pr_two, git({ "rev-parse", refs.head }))
      assert.are.equal(fixture.ids.main_two, git({ "rev-parse", refs.base }))
    end)

    it("fetches when the repository lacks the head commit", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.head_sha = string.rep("b", 40)
      local refs, subcommands = fetch_and_record(info)
      -- The fetch gives the real head, so the head check stops the open.
      assert.is_nil(refs)
      assert.is_true(vim.tbl_contains(subcommands, "fetch"), table.concat(subcommands, " "))
    end)

    it("fetches every time with the always value", function()
      assert(require("codeview.config").setup({ commit_message = false, github = { fetch = "always" } }))
      local info = assert(pr.view(12, { dir = fixture.dir }))
      local refs, subcommands = fetch_and_record(info)
      assert(refs)
      assert.is_true(vim.tbl_contains(subcommands, "fetch"), table.concat(subcommands, " "))
    end)

    ---Run a fetch and keep the fetch calls of git.
    ---@param info codeview.pr.Info
    ---@return codeview.pr.Refs? refs
    ---@return string[][] fetches The remote and the refspecs of each fetch call.
    local function record_fetches(info)
      local fetches = {}
      local outer = exec.capture
      exec.capture = function(cmd, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        if cmd[1] ~= gh.binary() and cmd[5] == "fetch" then
          fetches[#fetches + 1] = vim.list_slice(cmd, 9)
        end
        return outer(cmd, opts, cb)
      end
      local refs = pr.fetch(fixture.root, info)
      exec.capture = outer
      return refs, fetches
    end

    local head_refspec = "refs/pull/12/head:refs/codeview/pr/12/head"
    local base_refspec = "refs/heads/main:refs/codeview/pr/12/base"

    it("fetches the head and the base branch in one call", function()
      assert(require("codeview.config").setup({ commit_message = false, github = { fetch = "always" } }))
      local info = assert(pr.view(12, { dir = fixture.dir }))
      local refs, fetches = record_fetches(info)
      assert(refs)
      assert.are.same({ { "origin", head_refspec, base_refspec } }, fetches)
      assert.are.equal(fixture.ids.pr_two, git({ "rev-parse", refs.head }))
      assert.are.equal(fixture.ids.main_two, git({ "rev-parse", refs.base }))
    end)

    it("fetches only the base branch when the repository holds the head", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.base_sha = string.rep("c", 40)
      local refs, fetches = record_fetches(info)
      assert(refs)
      assert.are.same({ { "origin", base_refspec } }, fetches)
      assert.are.equal(fixture.ids.pr_two, git({ "rev-parse", refs.head }))
      assert.are.equal(fixture.ids.main_two, git({ "rev-parse", refs.base }))
    end)

    it("fetches only the head when the repository holds the base", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.head_sha = string.rep("b", 40)
      local refs, fetches = record_fetches(info)
      -- The fetch gives the real head, so the head check stops the open.
      assert.is_nil(refs)
      assert.are.same({ { "origin", head_refspec } }, fetches)
    end)

    it("fetches the head alone after a fetch that fails on the base branch", function()
      assert(require("codeview.config").setup({ commit_message = false, github = { fetch = "always" } }))
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.base_ref = "gone"
      local refs, fetches = record_fetches(info)
      assert(refs)
      assert.are.same(
        { { "origin", head_refspec, "refs/heads/gone:refs/codeview/pr/12/base" }, { "origin", head_refspec } },
        fetches
      )
      assert.are.equal(fixture.ids.main_two, git({ "rev-parse", refs.base }))
    end)

    it("reports a base branch that neither the remote nor the repository holds", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.base_ref = "gone"
      info.base_sha = string.rep("a", 40)
      local refs, err = pr.fetch(fixture.root, info)
      assert.is_nil(refs)
      assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
      assert.is_truthy(err.message:find("base branch gone", 1, true), err.message)
    end)

    it("reports a remote that the repository does not have", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      local refs, err = pr.fetch(fixture.root, info, { remote = "upstream" })
      assert.is_nil(refs)
      assert.are.equal(errors.codes.NOT_FOUND, err.code)
    end)

    it("stops when the fetched head is not the head of GitHub", function()
      -- The repository holds the commit, so only the fetch runs the head check.
      assert(require("codeview.config").setup({ commit_message = false, github = { fetch = "always" } }))
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.head_sha = fixture.ids.main_two
      local refs, err = pr.fetch(fixture.root, info)
      assert.is_nil(refs)
      assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
      assert.is_truthy(err.message:find("changed during the open", 1, true), err.message)
    end)

    it("opens no session when the fetched head is not the head of GitHub", function()
      -- The repository holds the commit, so only the fetch runs the head check.
      assert(require("codeview.config").setup({ commit_message = false, github = { fetch = "always" } }))
      answer = function(cmd)
        if cmd[2] == "pr" then
          local data = vim.json.decode(pr_view())
          data.headRefOid = fixture.ids.pr_one
          return { stdout = vim.json.encode(data) }
        end
        return default_answer(cmd)
      end
      local opened, err = open(12)
      assert.is_nil(opened)
      assert.is_truthy(err.message:find("changed during the open", 1, true), err.message)
      assert.is_nil(session.current())
    end)

    it("runs the configured git binary", function()
      local info = assert(pr.view(12, { dir = fixture.dir }))
      assert(require("codeview.config").setup({
        commit_message = false,
        git = { binary = "codeview-no-such-git" },
      }))

      ---@type string[][]
      local calls = {}
      local outer = exec.capture
      exec.capture = function(cmd, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        calls[#calls + 1] = cmd
        return outer(cmd, opts, cb)
      end

      local refs, err = pr.fetch(fixture.root, info)
      exec.capture = outer

      -- The name is in no $PATH, so the fetch fails. The command line still
      -- shows which executable the module tried to run.
      assert.is_nil(refs)
      assert.are.equal(errors.codes.SPAWN_FAILED, err.code)
      assert.is_true(#calls > 0)
      for _, cmd in ipairs(calls) do
        assert.are.equal("codeview-no-such-git", cmd[1])
      end
    end)
  end)

  describe("remotes", function()
    ---Clone the bare repository of the fixture into a new directory.
    ---@return string root
    local function clone()
      local origin = vim.fs.joinpath(vim.fs.dirname(fixture.dir), "origin.git")
      local dir = fixtures.tempdir("codeview-pr-clone")
      local res = vim.system({ "git", "clone", "--quiet", origin, dir }, { text = true, env = fixture.env }):wait(20000)
      assert.are.equal(0, res.code, res.stderr)
      return vim.fs.normalize(dir)
    end

    ---Run a git command in a clone.
    ---@param root string
    ---@param args string[]
    local function git_in(root, args)
      local res =
        vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true, env = fixture.env }):wait(20000)
      assert.are.equal(0, res.code, res.stderr)
    end

    it("reads every form of a remote address", function()
      local cases = {
        { "https://github.com/ada/demo.git", "github.com", "ada/demo" },
        { "https://github.com/ada/demo", "github.com", "ada/demo" },
        { "https://github.com/ada/demo/", "github.com", "ada/demo" },
        { "https://token@GitHub.com/ada/demo.git", "github.com", "ada/demo" },
        { "git@github.com:ada/demo.git", "github.com", "ada/demo" },
        { "git@github.com:ada/demo", "github.com", "ada/demo" },
        { "ssh://git@github.com/ada/demo.git", "github.com", "ada/demo" },
        { "ssh://git@github.acme.com:2222/team/app.git", "github.acme.com", "team/app" },
        { "git://github.com/ada/demo.git", "github.com", "ada/demo" },
      }
      for _, case in ipairs(cases) do
        local host, repo = pr.parse_remote_url(case[1])
        assert.are.equal(case[2], host, case[1])
        assert.are.equal(case[3], repo, case[1])
      end
      assert.is_nil(pr.parse_remote_url("/tmp/origin.git"))
      assert.is_nil(pr.parse_remote_url(""))
    end)

    it("picks the remote of the repository of the pull request", function()
      local info = { repo = "ada/demo", url = "https://github.com/ada/demo/pull/12" }
      local fork = {
        { name = "origin", url = "git@github.com:grace/demo.git" },
        { name = "base", url = "https://github.com/ada/demo.git" },
      }
      assert.are.equal("base", pr.pick_remote(fork, info))
      assert.is_nil(pr.pick_remote({ { name = "origin", url = "git@github.com:grace/demo.git" } }, info))
    end)

    it("prefers the host of the pull request and then the order of gh", function()
      local info = { repo = "team/app", url = "https://github.acme.com/team/app/pull/7" }
      local remotes = {
        { name = "mirror", url = "https://github.com/team/app.git" },
        { name = "origin", url = "git@github.acme.com:team/app.git" },
        { name = "upstream", url = "ssh://git@github.acme.com/team/app" },
      }
      assert.are.equal("upstream", pr.pick_remote(remotes, info))
      assert.are.equal("mirror", pr.pick_remote({ remotes[1] }, info))
    end)

    it("fetches from the remote whose address names the repository", function()
      local root = clone()
      local origin = vim.fs.joinpath(vim.fs.dirname(fixture.dir), "origin.git")
      -- The two addresses lead to a local path, so that the test needs no
      -- network. The fork path does not exist, so a fetch from it fails.
      git_in(root, { "config", "url." .. origin .. ".insteadOf", "https://github.com/ada/demo.git" })
      git_in(root, { "config", "url./codeview-no-such-fork.insteadOf", "https://github.com/grace/demo.git" })
      git_in(root, { "remote", "set-url", "origin", "https://github.com/grace/demo.git" })
      git_in(root, { "remote", "add", "base", "https://github.com/ada/demo.git" })

      local info = assert(pr.view(12, { dir = fixture.dir }))
      local refs, err = pr.fetch(root, info)
      vim.fn.delete(root, "rf")
      assert.is_nil(err)
      assert.are.equal("base", refs.remote)
    end)

    it("fetches a named repository that no remote holds from its address", function()
      local root = clone()
      local origin = vim.fs.joinpath(vim.fs.dirname(fixture.dir), "origin.git")
      git_in(root, { "config", "url." .. origin .. ".insteadOf", "https://github.com/other/x.git" })
      git_in(root, { "remote", "set-url", "origin", "/codeview-no-such-origin" })

      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.repo = "other/x"
      info.url = "https://github.com/other/x/pull/12"
      local refs, err = pr.fetch(root, info, { repo = "other/x" })
      vim.fn.delete(root, "rf")
      assert.is_nil(err)
      assert.are.equal("https://github.com/other/x.git", refs.remote)
    end)
  end)

  describe("range", function()
    it("starts at the merge base of the base branch and the head", function()
      local repo = assert(require("codeview.vcs").detect(fixture.dir, { backend = "git" }))
      local info = assert(pr.view(12, { dir = fixture.dir }))
      assert(pr.fetch(fixture.root, info))

      local range = assert(pr.range(repo, info))
      assert.are.equal(fixture.ids.base, range.from)
      assert.are.equal(fixture.ids.pr_two, range.to)
    end)
  end)

  describe("open", function()
    it("opens a session for the pull request", function()
      local opened, err = open(12)
      assert.is_nil(err)
      assert.are.equal("PR #12 Add the feature", opened:label())
      assert.are.equal(12, opened.pr.number)
      assert.are.equal(fixture.ids.base, opened.range.from)
      assert.are.equal(fixture.ids.pr_two, opened.range.to)
      assert.are.equal(opened, session.current())

      local paths = {}
      for _, file in ipairs(opened:changed_files()) do
        if not file.virtual then
          paths[#paths + 1] = file.path
        end
      end
      table.sort(paths)
      assert.are.same({ "a.txt", "feature.txt" }, paths)
    end)

    it("opens a session in the sync form", function()
      local opened, err = pr.open(12, { dir = fixture.dir, comments = false })
      assert.is_nil(err)
      assert.is_truthy(opened)
      assert.are.equal(12, opened.pr.number)
      assert.are.equal(fixture.ids.pr_two, opened.range.to)
      assert.are.equal(opened, session.current())
    end)

    it("keys the comment store by the pull request and the head commit", function()
      local opened = assert(open(12))
      local session_store = assert(store.for_session(opened))
      assert.are.equal(store.path(fixture.root, "pr-12-" .. fixture.ids.pr_two), session_store.path)
      assert.are_not.equal(store.path(fixture.root, opened.range.from .. ".." .. opened.range.to), session_store.path)
    end)

    it("reads the review comments of the pull request", function()
      local opened = assert(open(12))
      wait_for(function()
        return #remote.list(opened) > 0
      end, "the review comments did not arrive")

      local comments = remote.list(opened)
      assert.are.equal(1, #comments)
      assert.are.equal("a.txt", comments[1].file)
      assert.are.equal(2, comments[1].start_line)
      assert.are.equal("new", comments[1].side)
      assert.are.equal("grace", comments[1].author)
      assert.is_false(comments[1].outdated)
    end)

    it("reads the review comments from the host of the pull request", function()
      local opened = assert(open(12))
      wait_for(function()
        return #remote.list(opened) > 0
      end, "the review comments did not arrive")

      local api_call
      for _, cmd in ipairs(gh_calls) do
        if cmd[2] == "api" then
          api_call = cmd
        end
      end
      local at = assert(vim.iter(ipairs(assert(api_call))):find(function(_, arg)
        return arg == "--hostname"
      end))
      assert.are.equal("github.com", api_call[at + 1])
    end)

    it("leaves the review comments out on request", function()
      local opened = assert(open(12, { comments = false }))
      assert.are.equal(0, #remote.list(opened))
      for _, cmd in ipairs(gh_calls) do
        assert.are_not.equal("api", cmd[2])
      end
    end)

    it("reports the start of each step and the title to a progress handle", function()
      local seen, titles = {}, {}
      local progress = {
        start = function(_, key)
          seen[#seen + 1] = key
        end,
        set_title = function(_, text)
          titles[#titles + 1] = text
        end,
      }
      assert(open(12, { progress = progress }))
      local keys = {}
      for _, step in ipairs(pr.steps) do
        keys[#keys + 1] = step.key
      end
      assert.are.same(keys, seen)
      assert.are.same({ "PR #12 Add the feature" }, titles)
    end)

    it("shows the loading view from the command, and closes it before the review", function()
      local command = require("codeview.command")
      local loading = require("codeview.loading")
      local float_wins = function()
        local out = {}
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == loading.filetype then
            out[#out + 1] = win
          end
        end
        return out
      end
      local finished = false
      command.run({
        args = "pr 12",
        dir = fixture.dir,
        on_open = function()
          finished = true
        end,
      })
      assert.are.equal(1, #float_wins(), "the view shows at once")
      wait_for(function()
        return finished
      end, "the pull request did not open")
      assert.are.same({}, float_wins())
    end)

    it("shows the pull request document in the main window when the review opens", function()
      local command = require("codeview.command")
      local view = require("codeview.view")
      local message = require("codeview.message")
      command.run({ args = "pr 12", dir = fixture.dir })
      wait_for(function()
        return view.current() ~= nil
      end, "the review did not show an entry")
      assert.are.equal(message.pr_path(12), view.current().path)
    end)

    it("keeps the loading view open with the error after a failure", function()
      answer = function()
        return { code = 1, stderr = "dial tcp: lookup api.github.com: no such host" }
      end
      local command = require("codeview.command")
      local loading = require("codeview.loading")
      local notified = {}
      local real_notify = vim.notify
      vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
        notified[#notified + 1] = msg
      end
      local finished = false
      command.run({
        args = "pr 12",
        dir = fixture.dir,
        on_open = function()
          finished = true
        end,
      })
      wait_for(function()
        return finished
      end, "the call did not answer")
      vim.notify = real_notify
      assert.are.same({}, notified, "the view is the report")
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_win_get_buf(win)
      assert.are.equal(loading.filetype, vim.bo[buf].filetype)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:find("✗ read the pull request", 1, true), text)
      vim.api.nvim_win_close(win, true)
    end)

    it("quits Neovim when q closes the error of ++quit", function()
      answer = function()
        return { code = 1, stderr = "dial tcp: lookup api.github.com: no such host" }
      end
      local command = require("codeview.command")
      local quits = 0
      command.quit_nvim = function()
        quits = quits + 1
      end
      local finished = false
      command.run({
        args = "pr 12 ++quit",
        dir = fixture.dir,
        on_open = function()
          finished = true
        end,
      })
      wait_for(function()
        return finished
      end, "the call did not answer")
      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal("  q quits Neovim", lines[#lines])
      assert.are.equal(0, quits)
      vim.api.nvim_feedkeys("q", "x", false)
      assert.are.equal(1, quits)
    end)

    it("reports a missing login and opens no session", function()
      answer = function()
        return { code = 4, stderr = "To get started with GitHub CLI, please run:  gh auth login" }
      end
      local opened, err = open(12)
      assert.is_nil(opened)
      assert.are.equal(errors.codes.NOT_AUTHENTICATED, err.code)
      assert.is_nil(session.current())
    end)

    it("reports a host that it cannot reach", function()
      answer = function()
        return { code = 1, stderr = "dial tcp: lookup api.github.com: no such host" }
      end
      local _, err = open(12)
      assert.are.equal(errors.codes.OFFLINE, err.code)
    end)

    it("reports a missing gh executable", function()
      gh.available = function() ---@diagnostic disable-line: duplicate-set-field
        return false
      end
      local opened, err = open(12)
      assert.is_nil(opened)
      assert.are.equal(errors.codes.UNSUPPORTED, err.code)
    end)

    it("reports a directory outside a git repository", function()
      local outside = fixtures.tempdir("codeview-no-repo")
      local out, finished = {}, false
      pr.open(12, { dir = outside }, function(opened, err)
        out.session, out.err, finished = opened, err, true
      end)
      wait_for(function()
        return finished
      end, "the call did not answer")
      vim.fn.delete(outside, "rf")

      assert.is_nil(out.session)
      assert.are.equal(errors.codes.NOT_A_REPO, out.err.code)
    end)
  end)

  describe("the pull request document", function()
    it("lists the pull request before the commits", function()
      assert(require("codeview.config").setup({ commit_message = true }))
      local message = require("codeview.message")
      local opened = assert(open(12))

      assert.is_true(opened.files[1].virtual)
      assert.is_true(message.is_pr(opened.files[1].path))
      assert.are.equal("#12 Add the feature", opened.files[1].label)
      assert.are.equal(1, opened.files[1].order)

      assert.is_true(message.is(opened.files[2].path))
      assert.is_false(message.is_pr(opened.files[2].path))
      assert.are.equal(3, opened.files[2].order)

      assert.are.equal(2, opened:changed_count())
    end)

    it("keeps the document when the commit messages are off", function()
      assert(require("codeview.config").setup({ commit_message = false }))
      local message = require("codeview.message")
      local opened = assert(open(12))

      assert.is_true(message.is_pr(opened.files[1].path))
      assert.is_not_true(opened.files[2].virtual)
    end)

    it("shows the summary, the link, and the description", function()
      local message = require("codeview.message")
      local view = require("codeview.view")
      local opened = assert(open(12))
      local state = assert(view.open(opened, 1))
      local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
      view.close()

      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("Pull request #12: Add the feature", 1, true), text)
      assert.is_truthy(text:find("wants to merge", 1, true), text)
      assert.is_truthy(vim.tbl_contains(lines, "State: open"), text)
      assert.is_truthy(text:find("https://github.com/ada/demo/pull/12", 1, true), text)
      -- The description is markdown, so it keeps no indent.
      assert.is_truthy(text:find("\nthe body of the pull request", 1, true), text)

      local head
      for index, line in ipairs(lines) do
        if line == "2 commits:" then
          head = index
        end
      end
      assert.is_truthy(head, text)
      local commits = opened.commits
      assert.are.equal("    " .. message.label(commits[1]), lines[head + 2])
      assert.are.equal("    " .. message.label(commits[#commits]), lines[head + 3])
    end)

    it("puts the pull request group first in the sidebar", function()
      assert(require("codeview.config").setup({ commit_message = true }))
      local sidebar = require("codeview.sidebar")
      local opened = assert(open(12))
      sidebar.open({ session = opened })
      local lines = assert(sidebar.get()).panel:lines()
      sidebar.close()

      local pr_row, commits_row
      for index, line in ipairs(lines) do
        if not pr_row and line:find("Pull request", 1, true) then
          pr_row = index
        end
        if not commits_row and line:find("Commits", 1, true) then
          commits_row = index
        end
      end
      assert.is_truthy(pr_row, table.concat(lines, "\n"))
      assert.is_truthy(commits_row, table.concat(lines, "\n"))
      assert.is_true(pr_row < commits_row)
    end)

    it("names the document in the display", function()
      local message = require("codeview.message")
      local opened = assert(open(12))
      assert.are.equal(pr.label(opened.pr), message.display(message.pr_path(12), opened))
      assert.are.equal("PR 12", message.display(message.pr_path(12), nil))
    end)
  end)

  describe(":Codeview pr", function()
    it("reads the number", function()
      local command = require("codeview.command")
      local parsed = assert(command.parse("pr 12"))
      assert.are.equal("pr", parsed.action)
      assert.are.equal(12, parsed.number)
      assert.are.equal(12, assert(command.parse("pr #12")).number)
    end)

    it("takes no number for the pull request of the branch", function()
      local parsed = assert(require("codeview.command").parse("pr"))
      assert.are.equal("pr", parsed.action)
      assert.is_nil(parsed.number)
    end)

    it("rejects an argument that is not a number", function()
      local parsed, err = require("codeview.command").parse("pr feature")
      assert.is_nil(parsed)
      assert.are.equal(errors.codes.INVALID_ARG, err.code)
    end)

    it("opens the session from the command", function()
      local command = require("codeview.command")
      local out, finished = {}, false
      command.run({
        args = "pr 12",
        dir = fixture.dir,
        on_open = function(opened, err)
          out.session, out.err, finished = opened, err, true
        end,
      })
      wait_for(function()
        return finished
      end, "the command did not answer")
      assert.is_nil(out.err)
      assert.are.equal(12, out.session.pr.number)
    end)
  end)

  describe("the pull request data of the caller", function()
    ---Metadata as a caller gives it: the answer of gh with other fields.
    ---@param fields? table Fields of `gh pr view --json` to change.
    ---@return codeview.pr.Info
    local function given(fields)
      return assert(pr.parse(vim.tbl_extend("force", vim.json.decode(pr_view()), fields or {})))
    end

    ---Start to wait for the end of the next check.
    ---@return fun(): table data Waits, then returns the data of the event.
    local function on_check()
      local seen
      local id = vim.api.nvim_create_autocmd("User", {
        pattern = "CodeViewPrChecked",
        once = true,
        callback = function(event)
          seen = event.data
        end,
      })
      return function()
        wait_for(function()
          return seen ~= nil
        end, "the check did not end")
        pcall(vim.api.nvim_del_autocmd, id)
        return seen
      end
    end

    ---Count the closes of a session.
    ---@return fun(): integer count
    local function count_closes()
      local count = 0
      local id = vim.api.nvim_create_autocmd("User", {
        pattern = "CodeViewSessionClosed",
        callback = function()
          count = count + 1
        end,
      })
      return function()
        pcall(vim.api.nvim_del_autocmd, id)
        return count
      end
    end

    before_each(function()
      -- The repository must hold the commits of the pull request.
      assert(pr.fetch(fixture.root, assert(pr.view(12, { dir = fixture.dir }))))
      gh_calls = {}
    end)

    after_each(function()
      vim.env[pr.env_var] = nil
    end)

    it("reads the variable once, and only for the same pull request", function()
      vim.env[pr.env_var] = pr_view()
      local info = assert(pr.from_env(12))
      assert.are.equal(fixture.ids.pr_two, info.head_sha)
      assert.are.equal("the body of the pull request", info.body)
      assert.is_nil(vim.env[pr.env_var])
      assert.is_nil(pr.from_env(12))

      vim.env[pr.env_var] = pr_view()
      assert.is_nil(pr.from_env(13))
      assert.is_nil(vim.env[pr.env_var])

      vim.env[pr.env_var] = "{not json"
      assert.is_nil(pr.from_env(12))
      assert.is_nil(pr.from_env(nil))
    end)

    it("opens the review before it asks GitHub, and checks it after", function()
      local open_before_view = nil
      answer = function(cmd)
        if cmd[2] == "pr" and cmd[3] == "view" then
          open_before_view = session.current() ~= nil
        end
        return default_answer(cmd)
      end
      local wait = on_check()
      local opened = assert(open(12, { info = given(), comments = false }))
      assert.are.equal(fixture.ids.pr_two, opened.range.to)
      local data = wait()
      assert.is_true(open_before_view)
      assert.are.same({ id = opened.id, ok = true, changed = false }, data)
      assert.are.equal(opened, session.current())
    end)

    it("reads the review again in the same session when GitHub reports a new head", function()
      local closes = count_closes()
      local wait = on_check()
      local opened = assert(open(12, { info = given({ headRefOid = fixture.ids.pr_one }), comments = false }))
      assert.are.equal(fixture.ids.pr_one, opened.range.to)
      assert.are.equal("pr-12-" .. fixture.ids.pr_one, opened.store_key)

      local data = wait()
      assert.is_true(data.ok)
      assert.is_true(data.changed)
      assert.are.equal(0, closes())
      assert.are.equal(opened, session.current())
      assert.are.equal(fixture.ids.pr_two, opened.pr.head_sha)
      assert.are.equal(fixture.ids.pr_two, opened.range.to)
      assert.are.equal(fixture.ids.pr_two, opened.input.to)
      assert.are.equal("pr-12-" .. fixture.ids.pr_two, opened.store_key)
      local session_store = assert(require("codeview.comments").store(opened))
      assert.are.equal(store.path(fixture.root, "pr-12-" .. fixture.ids.pr_two), session_store.path)
      local paths = {}
      for _, file in ipairs(opened:changed_files()) do
        if not file.virtual then
          paths[#paths + 1] = file.path
        end
      end
      table.sort(paths)
      assert.are.same({ "a.txt", "feature.txt" }, paths)
    end)

    it("takes a new title without a fetch", function()
      local first_label
      vim.api.nvim_create_autocmd("User", {
        pattern = "CodeViewSessionOpened",
        once = true,
        callback = function()
          first_label = session.current():label()
        end,
      })
      local wait = on_check()
      local opened = assert(open(12, { info = given({ title = "An old title" }), comments = false }))
      local data = wait()
      assert.are.equal("PR #12 An old title", first_label)
      assert.is_true(data.changed)
      assert.are.equal("PR #12 Add the feature", opened:label())
      assert.are.equal("Add the feature", opened.pr.title)
    end)

    it("opens with the data of GitHub when the data of the caller does not open", function()
      local opened, err = open(12, { info = given({ headRefOid = string.rep("b", 40) }), comments = false })
      assert.is_nil(err)
      assert.are.equal(fixture.ids.pr_two, opened.pr.head_sha)
      assert.are.equal(fixture.ids.pr_two, opened.range.to)
    end)

    it("ignores the data of another pull request", function()
      local opened = assert(open(12, { info = given({ number = 13 }), comments = false }))
      assert.are.equal(12, opened.pr.number)
      assert.are.equal("pr", gh_calls[1][2])
    end)

    it("takes the variable from the command", function()
      local command = require("codeview.command")
      vim.env[pr.env_var] = pr_view()
      local open_before_view = nil
      answer = function(cmd)
        if cmd[2] == "pr" and cmd[3] == "view" then
          open_before_view = session.current() ~= nil
        end
        return default_answer(cmd)
      end
      local wait = on_check()
      local out, finished = {}, false
      command.run({
        args = "pr 12",
        dir = fixture.dir,
        on_open = function(opened, err)
          out.session, out.err, finished = opened, err, true
        end,
      })
      wait_for(function()
        return finished
      end, "the command did not answer")
      wait()
      assert.is_nil(out.err)
      assert.is_nil(vim.env[pr.env_var])
      assert.are.equal(fixture.ids.pr_two, out.session.pr.head_sha)
      assert.is_true(open_before_view)
    end)

    it("shows the messages of the check in a popup, not on the command line", function()
      local messages, popups = {}, {}
      local notify = require("codeview.notify")
      notify.notify = function(message) ---@diagnostic disable-line: duplicate-set-field
        messages[#messages + 1] = message
      end
      notify.background = function(message) ---@diagnostic disable-line: duplicate-set-field
        popups[#popups + 1] = message
      end
      local wait = on_check()
      assert(open(12, { info = given({ headRefOid = fixture.ids.pr_one }), comments = false }))
      assert.is_true(wait().changed)
      assert.are.same({}, messages)
      assert.are.same(
        { "PR #12 changed on GitHub: the review reloads with head " .. fixture.ids.pr_two:sub(1, 8) },
        popups
      )

      answer = function(cmd)
        if cmd[2] == "pr" and cmd[3] == "view" then
          return { code = 1, stderr = "HTTP 502" }
        end
        return default_answer(cmd)
      end
      popups = {}
      wait = on_check()
      assert(open(12, { info = given(), comments = false }))
      assert.is_false(wait().ok)
      assert.are.same({}, messages)
      assert.are.equal(1, #popups)
      assert.is_truthy(popups[1]:find("the check of PR #12 failed", 1, true), popups[1])
    end)

    describe("with a base commit that the repository lacks", function()
      local side = vim.fn.tempname()

      ---Run git in the side clone.
      ---@param args string[]
      ---@return string stdout
      local function side_git(args)
        local cmd = vim.list_extend({ "git", "-C", side }, args)
        local res = vim.system(cmd, { text = true, env = fixture.env }):wait(20000)
        assert.are.equal(0, res.code, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
        return vim.trim(res.stdout or "")
      end

      ---Push a new tip of main to the remote: a merge of the first commit of
      ---the pull request. The merge base with the head then moves, and the
      ---review lists only a.txt.
      ---@return string id
      local function push_base()
        local origin = git({ "remote", "get-url", "origin" })
        local res = vim
          .system({ "git", "clone", "--quiet", origin, side }, { text = true, env = fixture.env })
          :wait(20000)
        assert.are.equal(0, res.code, res.stderr)
        side_git({ "fetch", "--quiet", "origin", "refs/pull/12/head" })
        side_git({ "merge", "--quiet", "--no-edit", fixture.ids.pr_one })
        side_git({ "push", "--quiet", "origin", "HEAD:refs/heads/main" })
        return side_git({ "rev-parse", "HEAD" })
      end

      ---Paths of the changed files of a session.
      ---@param opened codeview.Session
      ---@return string[]
      local function paths_of(opened)
        local paths = {}
        for _, file in ipairs(opened:changed_files()) do
          if not file.virtual then
            paths[#paths + 1] = file.path
          end
        end
        table.sort(paths)
        return paths
      end

      after_each(function()
        if vim.fn.isdirectory(side) == 1 then
          side_git({ "push", "--quiet", "--force", "origin", fixture.ids.main_two .. ":refs/heads/main" })
          vim.fn.delete(side, "rf")
        end
        git({ "update-ref", "refs/remotes/origin/main", fixture.ids.main_two })
      end)

      it("opens against the last known base, then fetches the new base and says so in a popup", function()
        local new_base = push_base()
        answer = function(cmd)
          if cmd[2] == "pr" and cmd[3] == "view" then
            local data = vim.json.decode(pr_view())
            data.baseRefOid = new_base
            return { stdout = vim.json.encode(data) }
          end
          return default_answer(cmd)
        end
        local messages, popups = {}, {}
        local notify = require("codeview.notify")
        notify.notify = function(message) ---@diagnostic disable-line: duplicate-set-field
          messages[#messages + 1] = message
        end
        notify.background = function(message) ---@diagnostic disable-line: duplicate-set-field
          popups[#popups + 1] = message
        end
        local updated
        local real_update = pr.update_base
        pr.update_base = function(opened, cb) ---@diagnostic disable-line: duplicate-set-field
          real_update(opened, function(ok, err)
            updated = { ok = ok, err = err }
            if cb then
              cb(ok, err)
            end
          end)
        end

        local opened = assert(open(12, { info = given({ baseRefOid = new_base }), comments = false }))
        assert.are.same({ "a.txt", "feature.txt" }, paths_of(opened))
        assert.are.equal(fixture.ids.pr_two, opened.range.to)

        wait_for(function()
          return updated ~= nil
        end, "the base did not update")
        assert.is_true(updated.ok, tostring(updated.err))
        assert.are.equal(new_base, git({ "rev-parse", pr.refs(12).base }))
        assert.are.equal(opened, session.current())
        assert.are.same({ "a.txt" }, paths_of(opened))
        assert.are.same({}, messages)
        assert.are.same({ "PR #12: updated to the new base" }, popups)

        -- A second update finds the same range: nothing reads again, and no
        -- message shows.
        updated = nil
        pr.update_base(opened)
        wait_for(function()
          return updated ~= nil
        end, "the second update did not end")
        assert.is_true(updated.ok)
        assert.are.same({ "PR #12: updated to the new base" }, popups)
      end)

      it("fetches before the open without a base commit of the caller", function()
        local new_base = push_base()
        local deferred = false
        pr.update_base = function() ---@diagnostic disable-line: duplicate-set-field
          deferred = true
        end
        local opened = assert(open(12, { info = given({ baseRefOid = "" }), comments = false }))
        assert.is_false(deferred)
        assert.are.equal(new_base, git({ "rev-parse", pr.refs(12).base }))
        assert.are.same({ "a.txt" }, paths_of(opened))
      end)
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.root))
  end)
end)
