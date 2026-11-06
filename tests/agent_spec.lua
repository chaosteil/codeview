local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.agent", function()
  local agent, config

  before_each(function()
    helpers.unload()
    agent = require("codeview.agent")
    config = require("codeview.config")
    config.reset()
  end)

  after_each(function()
    helpers.unload()
  end)

  describe("root", function()
    local held

    before_each(function()
      held = { root = vim.env.CHAOSHUB_AGENT_ROOT, state = vim.env.XDG_STATE_HOME }
    end)

    after_each(function()
      vim.env.CHAOSHUB_AGENT_ROOT = held.root
      vim.env.XDG_STATE_HOME = held.state
    end)

    it("takes the option first, then the env of chaoshub, then the state directory", function()
      vim.env.CHAOSHUB_AGENT_ROOT = "/from/chaoshub"
      vim.env.XDG_STATE_HOME = "/state"
      assert(config.setup({ github = { agent_dir = "/from/option" } }))
      assert.are.equal("/from/option", agent.root())

      config.reset()
      assert.are.equal("/from/chaoshub", agent.root())

      vim.env.CHAOSHUB_AGENT_ROOT = nil
      assert.are.equal("/state/chaoshub/agent", agent.root())

      vim.env.XDG_STATE_HOME = nil
      assert.are.equal(vim.fs.normalize("~/.local/state/chaoshub/agent"), agent.root())
    end)

    it("puts the files of a pull request under the owner, the repository, and the number", function()
      assert(config.setup({ github = { agent_dir = "/root" } }))
      assert.are.equal("/root/ada/demo/12", agent.dir({ repo = "ada/demo", number = 12 }))
    end)
  end)

  describe("read", function()
    local dir

    before_each(function()
      dir = fixtures.tempdir("codeview-agent")
      assert(config.setup({ github = { agent_dir = dir } }))
    end)

    after_each(function()
      vim.fn.delete(dir, "rf")
    end)

    ---Write one result file of the pull request ada/demo#12.
    ---@param tool string
    ---@param record table
    local function write(tool, record)
      local path = vim.fs.joinpath(dir, "ada", "demo", "12", tool .. ".json")
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ vim.json.encode(record) }, path)
    end

    it("reads the files of the four tools", function()
      write("review", { version = 1, tool = "review", pr = 12, head_sha = "abc", data = { review = {} } })
      write("ask", { version = 1, tool = "ask", pr = 12, head_sha = "abc", data = {} })
      local results = agent.read({ repo = "ada/demo", number = 12 })
      assert.are.equal("review", results.review.tool)
      assert.are.equal("abc", results.review.head_sha)
      assert.are.equal("ask", results.ask.tool)
      assert.is_nil(results.improve)
      assert.is_nil(results.describe)
      assert.are.same({}, results.errors)
    end)

    it("refuses a file of another version", function()
      write("improve", { version = 2, tool = "improve" })
      local results = agent.read({ repo = "ada/demo", number = 12 })
      assert.is_nil(results.improve)
      assert.are.equal("version 2 is not 1", results.errors.improve)
    end)

    it("refuses a file without a JSON object", function()
      local path = vim.fs.joinpath(dir, "ada", "demo", "12", "describe.json")
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ "not json" }, path)
      local record, err = agent.read_file(path)
      assert.is_nil(record)
      assert.are.equal("the file holds no JSON object", err)
    end)

    it("reads no file and no error for a missing directory", function()
      local results = agent.read({ repo = "ada/other", number = 1 })
      assert.is_nil(results.review)
      assert.are.same({}, results.errors)
    end)
  end)
end)

describe("codeview.agent in a pull request review", function()
  local fixture = fixtures.git_comments()
  local agent, config, events, session_mod
  local dir
  ---@type codeview.Session?
  local opened

  ---Write one result file of the pull request ada/demo#12.
  ---@param tool string
  ---@param record table
  local function write(tool, record)
    local path = vim.fs.joinpath(dir, "ada", "demo", "12", tool .. ".json")
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ vim.json.encode(record) }, path)
  end

  ---Open a review of the fixture as the pull request ada/demo#12.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, {
      dir = fixture.dir,
      pr = {
        repo = "ada/demo",
        number = 12,
        title = "Demo",
        author = "ada",
        head_ref = "change",
        base_ref = "main",
        state = "OPEN",
        url = "https://github.com/ada/demo/pull/12",
        body = "",
        head_sha = fixture.ids.change,
      },
    })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  before_each(function()
    helpers.unload()
    agent = require("codeview.agent")
    config = require("codeview.config")
    events = require("codeview.events")
    session_mod = require("codeview.session")
    dir = fixtures.tempdir("codeview-agent")
    config.reset()
    assert(config.setup({ github = { agent_dir = dir } }))
  end)

  after_each(function()
    if opened then
      opened:close()
      opened = nil
    end
    vim.fn.delete(dir, "rf")
    helpers.unload()
  end)

  it("reads the results with the session and sends an event", function()
    write("review", { version = 1, tool = "review", pr = 12, head_sha = fixture.ids.change, data = { review = {} } })
    local seen = 0
    events.on(events.agent, function()
      seen = seen + 1
    end)
    local review = open_session()
    local results = assert(agent.attach(review))
    assert.are.equal("review", results.review.tool)
    assert.are.equal(results, agent.get(review.pr))
    assert.are.equal(1, seen)
  end)

  it("reads nothing for a session without a pull request", function()
    local review = assert(session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir }))
    opened = review
    assert.is_nil(agent.attach(review))
  end)

  it("reads the files again after a refresh of the session", function()
    local review = open_session()
    assert.is_nil(assert(agent.attach(review)).improve)
    write("improve", { version = 1, tool = "improve", pr = 12, head_sha = fixture.ids.change, data = {} })
    vim.api.nvim_exec_autocmds("User", { pattern = "CodeViewSessionRefreshed", data = { id = review.id } })
    assert.are.equal("improve", agent.get(review.pr).improve.tool)
  end)

  it("follows a change of the directory", function()
    local review = open_session()
    agent.attach(review)
    write("describe", { version = 1, tool = "describe", pr = 12, head_sha = fixture.ids.change, data = {} })
    assert.is_true(
      vim.wait(5000, function()
        local results = agent.get(review.pr)
        return results ~= nil and results.describe ~= nil
      end, 20),
      "the watcher did not read the new file"
    )
  end)

  it("warns once for a file of another version", function()
    write("ask", { version = 3, tool = "ask" })
    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    local review = open_session()
    agent.attach(review)
    agent.load(review)
    vim.notify = notify
    assert.are.equal(1, #seen)
    assert.is_truthy(seen[1]:find("ask.json", 1, true), seen[1])
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
