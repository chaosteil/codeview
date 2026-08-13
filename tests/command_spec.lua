local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

---Wait until a check answers true.
---@param check fun(): boolean
local function wait_for(check)
  assert.is_true(vim.wait(20000, check, 10), "the command did not answer")
end

---Collect the notifications of one call.
---@param fn fun()
---@param expected? integer Wait until this many notifications arrived.
---@return { msg: string, level: integer }[]
local function capture_notify(fn, expected)
  local seen = {}
  local notify = vim.notify
  vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
    seen[#seen + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(function()
    fn()
    if expected then
      vim.wait(20000, function()
        return #seen >= expected
      end, 10)
    end
  end)
  vim.notify = notify
  assert.is_true(ok, tostring(err))
  return seen
end

describe("codeview.command", function()
  local fixture = fixtures.git()
  local command, session

  before_each(function()
    helpers.unload()
    command = require("codeview.command")
    session = require("codeview.session")
  end)

  after_each(function()
    session.close()
    helpers.unload()
  end)

  describe("parse", function()
    it("reads one revision", function()
      local parsed = assert(command.parse("HEAD"))
      assert.are.equal("review", parsed.action)
      assert.are.equal("single", parsed.range.kind)
      assert.are.equal("HEAD", parsed.range.to)
      assert.are.equal("HEAD", parsed.range.spec)
    end)

    it("reads a two dot range", function()
      local parsed = assert(command.parse("main..feature"))
      assert.are.equal("review", parsed.action)
      assert.are.equal("range", parsed.range.kind)
      assert.are.equal("main", parsed.range.from)
      assert.are.equal("feature", parsed.range.to)
    end)

    it("reads a three dot range", function()
      local parsed = assert(command.parse("main...feature"))
      assert.are.equal("triple", parsed.range.kind)
    end)

    it("trims the argument", function()
      local parsed = assert(command.parse("  HEAD~2  "))
      assert.are.equal("HEAD~2", parsed.range.spec)
    end)

    it("keeps a revision argument that holds a space", function()
      local parsed = assert(command.parse("main@{2 days ago}"))
      assert.are.equal("main@{2 days ago}", parsed.range.to)
    end)

    it("asks for one commit without an argument", function()
      local parsed = assert(command.parse(""))
      assert.are.equal("pick", parsed.action)
      assert.are.equal("single", parsed.mode)
      assert.is_nil(parsed.range)
    end)

    it("asks for a range after a bang", function()
      local parsed = assert(command.parse("", true))
      assert.are.equal("pick", parsed.action)
      assert.are.equal("range", parsed.mode)
    end)

    it("treats a nil argument as no argument", function()
      local parsed = assert(command.parse(nil))
      assert.are.equal("pick", parsed.action)
    end)

    it("treats spaces as no argument", function()
      assert.are.equal("pick", assert(command.parse("   ")).action)
    end)

    it("rejects an argument that is not a string", function()
      local parsed, err = command.parse(42)
      assert.is_nil(parsed)
      assert.are.equal("invalid_arg", err.code)
    end)
  end)

  describe("run", function()
    ---Run the command and wait for the session.
    ---@param opts table
    ---@return codeview.Session? session
    ---@return codeview.Error? err
    local function run(opts)
      local out, finished = {}, false
      opts.dir = opts.dir or fixture.dir
      opts.on_open = function(opened, err)
        out.session, out.err, finished = opened, err, true
      end
      command.run(opts)
      wait_for(function()
        return finished
      end)
      return out.session, out.err
    end

    it("opens a session for one commit", function()
      local opened, err = run({ args = fixture.ids.edit })
      assert.is_nil(err)
      assert.are.equal(fixture.ids.edit, opened.range.to)
      assert.are.equal(2, #opened.files)
      assert.are.equal(opened, session.current())
    end)

    it("opens a session for a range", function()
      local opened = assert(run({ args = fixture.ids.init .. ".." .. fixture.branch }))
      assert.are.equal(fixture.ids.init, opened.range.from)
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
    end)

    it("opens the picker without an argument", function()
      local ui_select = vim.ui.select
      vim.ui.select = function(items, _, on_choice) ---@diagnostic disable-line: duplicate-set-field
        on_choice(items[1], 1)
      end
      local opened = assert(run({ args = "" }))
      vim.ui.select = ui_select
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
    end)

    it("opens the range picker after a bang", function()
      local calls = 0
      local ui_select = vim.ui.select
      vim.ui.select = function(items, _, on_choice) ---@diagnostic disable-line: duplicate-set-field
        calls = calls + 1
        on_choice(items[#items], #items)
      end
      local opened = assert(run({ args = "", bang = true }))
      vim.ui.select = ui_select

      assert.are.equal(2, calls)
      assert.is_nil(opened.range.from)
      assert.are.equal(fixture.ids.init, opened.range.to)
    end)

    it("reports an unknown revision", function()
      -- The default handler notifies, so the call needs no `on_open`.
      local seen = capture_notify(function()
        command.run({ args = "no-such-revision", dir = fixture.dir })
      end, 1)
      assert.are.equal(1, #seen)
      assert.are.equal(vim.log.levels.ERROR, seen[1].level)
      assert.is_truthy(seen[1].msg:find("no-such-revision", 1, true), seen[1].msg)
      assert.is_nil(session.current())
    end)

    it("reports an argument of the wrong type", function()
      local seen = capture_notify(function()
        command.run({ args = 42 })
      end)
      assert.are.equal(1, #seen)
      assert.are.equal(vim.log.levels.ERROR, seen[1].level)
    end)
  end)

  describe("close", function()
    it("closes the session that runs", function()
      local opened = assert(session.open(fixture.ids.edit, { dir = fixture.dir }))
      command.close()
      assert.is_true(opened.closed)
      assert.is_nil(session.current())
    end)

    it("warns without a session", function()
      local seen = capture_notify(function()
        command.close()
      end)
      assert.are.equal(1, #seen)
      assert.are.equal(vim.log.levels.WARN, seen[1].level)
    end)
  end)

  describe("the registered commands", function()
    it("knows :CodeView and :CodeViewClose", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_truthy(commands.CodeView)
      assert.is_truthy(commands.CodeView.bang)
      assert.are.equal("*", commands.CodeView.nargs)
      assert.is_truthy(commands.CodeViewClose)
      assert.is_truthy(commands.CodeViewFiles)
    end)

    it("opens a session from the command line", function()
      local cwd = assert(vim.uv.cwd())
      vim.fn.chdir(fixture.root)
      vim.cmd("CodeView " .. fixture.ids.edit)
      wait_for(function()
        return session.current() ~= nil
      end)
      vim.fn.chdir(cwd)

      local opened = assert(session.current())
      assert.are.equal(fixture.ids.edit, opened.range.to)

      vim.cmd("CodeViewClose")
      assert.is_nil(session.current())
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
