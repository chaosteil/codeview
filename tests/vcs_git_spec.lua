local fixtures = require("tests.fixtures")
local suite = require("tests.vcs_backend_suite")

suite({
  name = "git",
  backend = require("codeview.vcs.git"),
  fixture = fixtures.git,
  head_rev = "HEAD",
  detects_renames = true,
})

describe("codeview.vcs.git", function()
  local git = require("codeview.vcs.git")
  local fixture = fixtures.git()
  local repo = assert(git.detect(fixture.dir))

  it("reports that git is available", function()
    assert.is_true(git.available())
  end)

  it("resolves a branch name", function()
    local id, err = repo:resolve_rev(fixture.branch)
    assert.is_nil(err)
    assert.are.equal(fixture.ids.shuffle, id)
  end)

  it("resolves a relative revision", function()
    local id = assert(repo:resolve_rev("HEAD~1"))
    assert.are.equal(fixture.ids.edit, id)
  end)

  it("resolves a three dot range through the merge base", function()
    local range = assert(repo:resolve_range(fixture.ids.init .. "..." .. fixture.ids.shuffle))
    assert.are.equal(fixture.ids.init, range.from)
    assert.are.equal(fixture.ids.shuffle, range.to)
  end)

  it("reports the rename score", function()
    local range = assert(repo:resolve_range(fixture.ids.shuffle))
    for _, file in ipairs(assert(repo:changed_files(range))) do
      if file.status == "renamed" then
        assert.are.equal(100, file.score)
      end
    end
  end)

  it("keeps the bytes of a file with CRLF line endings", function()
    local path = vim.fs.joinpath(fixture.dir, "crlf.txt")
    local handle = assert(io.open(path, "wb"))
    handle:write("one\r\ntwo\r\n")
    handle:close()
    local env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null", HOME = fixture.dir }
    vim.system({ "git", "add", "crlf.txt" }, { cwd = fixture.dir, env = env }):wait()
    vim.system({ "git", "commit", "--quiet", "-m", "add crlf" }, { cwd = fixture.dir, env = env }):wait()

    local content = assert(repo:file_content("HEAD", "crlf.txt"))
    assert.are.equal("one\r\ntwo\r\n", content)
  end)

  describe("a branch name that is also a path", function()
    before_each(function()
      vim.system({ "git", "branch", "--force", "dir", fixture.ids.shuffle }, { cwd = fixture.dir }):wait()
    end)

    it("resolves the range", function()
      local range, err = repo:resolve_range("dir")
      assert.is_nil(err)
      assert.are.equal(fixture.ids.shuffle, range.to)
      assert.are.equal(fixture.ids.edit, range.from)
    end)

    it("reads the log", function()
      local commits, err = repo:log({ revs = { "dir" }, limit = 1 })
      assert.is_nil(err)
      assert.are.equal(fixture.ids.shuffle, commits[1].id)
    end)

    it("lists the changed files", function()
      local files, err = repo:changed_files({ from = fixture.ids.edit, to = "dir" })
      assert.is_nil(err)
      assert.is_truthy(#files > 0)
    end)
  end)

  describe("a foreign message locale", function()
    ---True when git has a German translation on this machine.
    ---@return boolean
    local function translated()
      local res = vim
        .system({ "git", "show", "HEAD:no-such-file" }, {
          cwd = fixture.dir,
          text = true,
          env = { LC_ALL = "de_DE.UTF-8", LANGUAGE = "de" },
        })
        :wait()
      return (res.stderr or ""):find("fatal:", 1, true) == nil
    end

    it("keeps the empty side of an added file", function()
      if not translated() then
        return
      end
      local lc_all, language = vim.env.LC_ALL, vim.env.LANGUAGE
      vim.env.LC_ALL, vim.env.LANGUAGE = "de_DE.UTF-8", "de"
      local content, content_err = repo:file_content(fixture.ids.init, "added.txt")
      local files, files_err = repo:changed_files({ from = "no-such-revision", to = fixture.ids.shuffle })
      vim.env.LC_ALL, vim.env.LANGUAGE = lc_all, language

      assert.is_nil(content_err)
      assert.are.equal("", content)
      assert.is_nil(files)
      assert.are.equal("bad_revision", files_err.code)
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview.vcs.git configuration", function()
  local git = require("codeview.vcs.git")

  it("ignores log.showSignature of the user", function()
    if vim.fn.executable("ssh-keygen") ~= 1 then
      return
    end
    local fixture = fixtures.git()
    local key = vim.fs.joinpath(fixture.dir, "sign-key")
    local env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null", HOME = fixture.dir }

    ---@param cmd string[]
    local function run(cmd)
      local res = vim.system(cmd, { cwd = fixture.dir, text = true, env = env }):wait()
      assert.are.equal(0, res.code, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
    end

    run({ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "ada@example.com", "-f", key })
    run({ "git", "config", "gpg.format", "ssh" })
    run({ "git", "config", "user.signingkey", key })
    run({ "git", "config", "commit.gpgsign", "true" })
    run({ "git", "config", "log.showSignature", "true" })
    run({ "git", "commit", "--quiet", "--allow-empty", "-m", "signed: a commit with a signature" })

    local repo = assert(git.detect(fixture.dir))
    local commits, err = repo:log({ limit = 1 })
    assert.is_nil(err)
    assert.are.equal("signed: a commit with a signature", commits[1].subject)
    assert.are.equal(40, #commits[1].id)
    assert.is_truthy(commits[1].id:match("^%x+$"), commits[1].id)

    fixture.cleanup()
  end)
end)

describe("codeview.vcs.git on a changed working copy", function()
  local git = require("codeview.vcs.git")
  local fixture = fixtures.git()
  local repo = assert(git.detect(fixture.dir))

  it("keeps the commit of the working copy after a change of a file", function()
    local before = assert(repo:working_rev())
    assert.are.equal(fixture.ids.shuffle, before)

    local handle = assert(io.open(vim.fs.joinpath(fixture.dir, "a.txt"), "ab"))
    handle:write("six\n")
    handle:close()

    -- git holds the working copy outside the commits, so a change of a file
    -- moves no commit. Both calls therefore report HEAD.
    assert.are.equal(before, assert(repo:working_rev()))
    assert.are.equal(before, assert(repo:snapshot()))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview.vcs.git with a configured binary", function()
  local config = require("codeview.config")
  local exec = require("codeview.exec")
  local git = require("codeview.vcs.git")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  ---Record every command line, and answer it without a call to git.
  ---@param stdout string Output of every call.
  ---@return string[][] calls
  local function record(stdout)
    local calls = {}
    exec.capture = function(cmd, _opts, cb) ---@diagnostic disable-line: duplicate-set-field
      calls[#calls + 1] = cmd
      local result = { command = cmd, code = 0, signal = 0, stdout = stdout, stderr = "" }
      if cb then
        vim.schedule(function()
          cb(result, nil)
        end)
        return nil, nil
      end
      return result, nil
    end
    return calls
  end

  it("puts the configured name in front of every command", function()
    local real = exec.capture
    local calls = record(dir .. "\n")
    config.setup({ git = { binary = "my-git" } })

    local repo = git.detect(dir)
    if repo then
      repo:log({ limit = 1 })
    end

    exec.capture = real
    config.reset()

    assert.is_truthy(repo)
    assert.are.equal("my-git", calls[1][1])
    assert.are.equal("my-git", calls[2][1])
  end)

  it("looks for the configured name in $PATH", function()
    config.setup({ git = { binary = "codeview-no-such-git" } })
    local found = git.available()
    config.reset()

    assert.is_false(found)
    assert.is_true(git.available())
  end)

  it("removes the directory", function()
    vim.fn.delete(dir, "rf")
    assert.are.equal(0, vim.fn.isdirectory(dir))
  end)
end)
