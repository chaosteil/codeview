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
    require("codeview.config").setup({ commit_message = false })
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
      assert.are.equal(1, #info.commits)
      assert.are.equal("refactor(defaults): edit global cwd on `1-`", info.commits[1].subject)
      assert.are.equal("Nathan Zeng", info.commits[1].author)
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
      local info = assert(pr.view(12, { dir = fixture.dir }))
      info.base_ref = "gone"
      local refs = assert(pr.fetch(fixture.root, info))

      assert.are.equal(fixture.ids.pr_two, git({ "rev-parse", refs.head }))
      assert.are.equal(fixture.ids.main_two, git({ "rev-parse", refs.base }))
      assert.is_truthy(refs.warning)
      assert.is_truthy(refs.warning:find("gone", 1, true), refs.warning)
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

    it("leaves the review comments out on request", function()
      local opened = assert(open(12, { comments = false }))
      assert.are.equal(0, #remote.list(opened))
      for _, cmd in ipairs(gh_calls) do
        assert.are_not.equal("api", cmd[2])
      end
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
      assert.are.equal(2, opened.files[2].order)

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
      assert.is_truthy(text:find("    the body of the pull request", 1, true), text)

      local head
      for index, line in ipairs(lines) do
        if line == "2 commits:" then
          head = index
        end
      end
      assert.is_truthy(head, text)
      local commits = opened.commits
      assert.are.equal("    " .. message.label(commits[#commits]), lines[head + 2])
      assert.are.equal("    " .. message.label(commits[1]), lines[head + 3])
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

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.root))
  end)
end)
