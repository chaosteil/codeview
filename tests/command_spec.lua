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
    -- The specs run in a `-c` command of Neovim, which looks like a start
    -- from the command line. A quit there ends the test run.
    require("codeview.config").setup({ commit_message = false, quit = "never" })
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

    it("reads a subcommand and its argument", function()
      local parsed = assert(command.parse("export z"))
      assert.are.equal("subcommand", parsed.action)
      assert.are.equal("export", parsed.name)
      assert.are.equal("z", parsed.text)
      assert.are.equal("", assert(command.parse("close")).text)
    end)

    it("reads the refresh subcommand", function()
      local parsed = assert(command.parse("refresh"))
      assert.are.equal("subcommand", parsed.action)
      assert.are.equal("refresh", parsed.name)
      assert.is_function(command.subcommands.refresh.run)
    end)

    it("reads the quit flags anywhere in the argument", function()
      local parsed = assert(command.parse("++quit pr 12"))
      assert.are.equal("pr", parsed.action)
      assert.are.equal(12, parsed.number)
      assert.is_true(parsed.quit)
      parsed = assert(command.parse("HEAD~1..HEAD ++noquit"))
      assert.are.equal("HEAD~1..HEAD", parsed.text)
      assert.is_false(parsed.quit)
      assert.are.equal("pick", assert(command.parse("++quit")).action)
      assert.is_nil(assert(command.parse("HEAD")).quit)
    end)

    it("rejects an unknown flag and a flag on a subcommand", function()
      local parsed, err = command.parse("HEAD ++stay")
      assert.is_nil(parsed)
      assert.are.equal("invalid_arg", err.code)
      parsed, err = command.parse("close ++quit")
      assert.is_nil(parsed)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("takes a subcommand before a revision of the same name", function()
      assert.are.equal("subcommand", assert(command.parse("close")).action)
      -- A range form reviews the revision that the subcommand names.
      local parsed = assert(command.parse("close^..close"))
      assert.are.equal("review", parsed.action)
      assert.are.equal("close^", parsed.range.from)
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

    it("runs the subcommand of the argument", function()
      local opened = assert(session.open(fixture.ids.edit, { dir = fixture.dir }))
      command.run({ args = "close" })
      assert.is_true(opened.closed)
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

  describe("codeview.review", function()
    it("opens the sidebar like :Codeview", function()
      local sidebar = require("codeview.sidebar")
      require("codeview").review(fixture.ids.edit, { dir = fixture.dir })
      wait_for(function()
        return session.current() ~= nil
      end)
      wait_for(function()
        return sidebar.is_open()
      end)

      local opened = assert(session.current())
      assert.are.equal(fixture.ids.edit, opened.range.to)
      assert.are.equal(opened, assert(sidebar.get()).session)
    end)
  end)

  describe("the open message", function()
    ---Hand a session to `command.opened()` and keep the echo messages.
    ---@param opened codeview.Session
    ---@return string[] messages
    local function echoes(opened)
      local seen = {}
      local echo = vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks) ---@diagnostic disable-line: duplicate-set-field
        local text = {}
        for _, chunk in ipairs(chunks) do
          text[#text + 1] = chunk[1]
        end
        seen[#seen + 1] = table.concat(text)
      end
      local ok, err = pcall(command.opened, opened, nil)
      vim.api.nvim_echo = echo
      assert.is_true(ok, tostring(err))
      return seen
    end

    ---Make a session look like the review of a pull request with a title.
    ---@param opened codeview.Session
    ---@param title string
    local function as_pr(opened, title)
      opened.pr = { number = 128, title = title }
      opened.spec = "PR #128 " .. title
    end

    it("prints nothing when the sidebar opens", function()
      local opened = assert(session.open(fixture.ids.edit, { dir = fixture.dir }))
      as_pr(opened, string.rep("a long title ", 10))
      assert.are.same({}, echoes(opened))
    end)

    it("cuts the message without the sidebar to fit v:echospace", function()
      assert(require("codeview.config").setup({
        commit_message = false,
        quit = "never",
        sidebar = { auto_open = false },
      }))
      local opened = assert(session.open(fixture.ids.edit, { dir = fixture.dir }))
      for _, title in ipairs({ string.rep("a long title ", 10), string.rep("長いタイトル", 10) }) do
        as_pr(opened, title)
        local seen = echoes(opened)
        assert.are.equal(1, #seen)
        local line = seen[1]
        assert.is_true(vim.fn.strdisplaywidth(line) <= vim.v.echospace, line)
        assert.is_truthy(vim.startswith(line, "codeview: PR #128 "), line)
        assert.is_truthy(vim.endswith(line, "…: " .. opened:counts()), line)
      end
    end)

    it("keeps a short message as it is", function()
      local opened = assert(session.open(fixture.ids.edit, { dir = fixture.dir }))
      as_pr(opened, "Fix it")
      assert.are.equal("codeview: PR #128 Fix it: " .. opened:counts(), command.summary_line(opened, 80))
      assert.are.equal(
        "codeview: PR #128 F…: " .. opened:counts(),
        command.summary_line(opened, 22 + #opened:counts())
      )
    end)
  end)

  describe("quit", function()
    local quits

    before_each(function()
      quits = 0
      command.quit_nvim = function()
        quits = quits + 1
      end
    end)

    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_name, command.quit_group)
    end)

    ---Run the command and wait for its answer.
    ---@param args string
    ---@return codeview.Session? session
    local function run(args)
      local out, finished = {}, false
      command.run({
        args = args,
        dir = fixture.dir,
        on_open = function(opened)
          out.session, finished = opened, true
        end,
      })
      wait_for(function()
        return finished
      end)
      return out.session
    end

    ---Let the scheduled callbacks run.
    local function settle()
      vim.wait(50)
    end

    it("quits Neovim after the session of ++quit closes", function()
      assert(run(fixture.ids.edit .. " ++quit"))
      settle()
      assert.are.equal(0, quits, "the review runs")
      session.close()
      settle()
      assert.are.equal(1, quits)
    end)

    it("stays when a second review replaces the first", function()
      assert(run(fixture.ids.edit .. " ++quit"))
      assert(run(fixture.ids.init .. ".." .. fixture.branch))
      settle()
      assert.are.equal(0, quits)
      session.close()
      settle()
      assert.are.equal(1, quits, "the last review ends")
    end)

    it("stops the quit of a review that runs after ++noquit", function()
      assert(run(fixture.ids.edit .. " ++quit"))
      assert(run(fixture.ids.edit .. " ++noquit"))
      session.close()
      settle()
      assert.are.equal(0, quits)
    end)

    it("quits after a closed picker", function()
      local ui_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice) ---@diagnostic disable-line: duplicate-set-field
        on_choice(nil, nil)
      end
      assert.is_nil(run("++quit"))
      vim.ui.select = ui_select
      settle()
      assert.are.equal(1, quits)
    end)

    it("stays after an error, so that the message shows", function()
      capture_notify(function()
        command.run({ args = "no-such-revision ++quit", dir = fixture.dir })
      end, 1)
      settle()
      assert.are.equal(0, quits)
    end)

    it("quits after a review from the command line of Neovim, with the startup option", function()
      require("codeview.config").setup({ commit_message = false, quit = "startup" })
      command.at_startup = function()
        return true
      end
      assert(run(fixture.ids.edit))
      session.close()
      settle()
      assert.are.equal(1, quits)
    end)

    it("stays after a review from inside Neovim, or after ++noquit", function()
      require("codeview.config").setup({ commit_message = false, quit = "startup" })
      command.at_startup = function()
        return false
      end
      assert(run(fixture.ids.edit))
      session.close()
      command.at_startup = function()
        return true
      end
      assert(run(fixture.ids.edit .. " ++noquit"))
      session.close()
      settle()
      assert.are.equal(0, quits)
    end)

    it("quits Neovim after a codeview.review with quit closes", function()
      require("codeview").review(fixture.ids.edit, { dir = fixture.dir, quit = true })
      wait_for(function()
        return session.current() ~= nil
      end)
      settle()
      assert.are.equal(0, quits, "the review runs")
      session.close()
      settle()
      assert.are.equal(1, quits)
    end)

    it("stays when a second review replaces a codeview.review with quit", function()
      require("codeview").review(fixture.ids.edit, { dir = fixture.dir, quit = true })
      wait_for(function()
        return session.current() ~= nil
      end)
      local first = session.current()
      assert(run(fixture.ids.init .. ".." .. fixture.branch))
      wait_for(function()
        return session.current() ~= nil and session.current() ~= first
      end)
      settle()
      assert.are.equal(0, quits)
      session.close()
      settle()
      assert.are.equal(1, quits, "the last review ends")
    end)

    it("stays after a codeview.review without quit", function()
      require("codeview.config").setup({ commit_message = false, quit = "startup" })
      command.at_startup = function()
        return true
      end
      require("codeview").review(fixture.ids.edit, { dir = fixture.dir })
      wait_for(function()
        return session.current() ~= nil
      end)
      session.close()
      settle()
      assert.are.equal(0, quits)
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

  describe("the registered command", function()
    it("knows :Codeview and no other command", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_truthy(commands.Codeview)
      assert.is_truthy(commands.Codeview.bang)
      assert.are.equal("*", commands.Codeview.nargs)
      assert.is_nil(commands.CodeviewClose)
      assert.is_nil(commands.CodeviewFiles)
    end)

    it("completes the subcommands of the first word", function()
      local res = helpers.clean_nvim('print(vim.inspect(vim.fn.getcompletion("Codeview ", "cmdline")))')
      assert.are.equal(0, res.code)
      for _, name in ipairs({ "back", "close", "comments", "export", "files", "pr", "refresh", "submit" }) do
        assert.is_truthy(res.output:find('"' .. name .. '"', 1, true), res.output)
      end
    end)

    it("completes the first word with the lead", function()
      local res = helpers.clean_nvim('print(vim.inspect(vim.fn.getcompletion("Codeview cl", "cmdline")))')
      assert.are.equal(0, res.code)
      assert.is_truthy(res.output:find('{ "close" }', 1, true), res.output)
    end)

    it("shows the newest commit in the main window when the review opens", function()
      require("codeview.config").setup({ quit = "never" })
      local view = require("codeview.view")
      local message = require("codeview.message")
      local cwd = assert(vim.uv.cwd())
      vim.fn.chdir(fixture.root)
      vim.cmd(string.format("Codeview %s..%s", fixture.ids.init, fixture.branch))
      wait_for(function()
        return view.current() ~= nil
      end)
      vim.fn.chdir(cwd)
      local opened = assert(session.current())
      assert.is_true(#opened.commits > 1, "the range holds more than one commit")
      assert.are.equal(message.path_of(opened.commits[1].id), view.current().path)
      assert.are.equal(view.current().win, vim.api.nvim_get_current_win())
    end)

    it("shows the first file when the review holds no commit entry", function()
      local view = require("codeview.view")
      local tree = require("codeview.tree")
      local cwd = assert(vim.uv.cwd())
      vim.fn.chdir(fixture.root)
      vim.cmd("Codeview " .. fixture.ids.edit)
      wait_for(function()
        return view.current() ~= nil
      end)
      vim.fn.chdir(cwd)
      local opened = assert(session.current())
      assert.are.equal(tree.order(opened:changed_files())[1], view.current().index)
    end)

    it("opens a session from the command line", function()
      local cwd = assert(vim.uv.cwd())
      vim.fn.chdir(fixture.root)
      vim.cmd("Codeview " .. fixture.ids.edit)
      wait_for(function()
        return session.current() ~= nil
      end)
      vim.fn.chdir(cwd)

      local opened = assert(session.current())
      assert.are.equal(fixture.ids.edit, opened.range.to)

      vim.cmd("Codeview close")
      assert.is_nil(session.current())
    end)
  end)

  describe(":Codeview file", function()
    ---@type string
    local dir

    ---Write a file below the test directory.
    ---@param path string
    ---@param content string
    local function write(path, content)
      local full = vim.fs.joinpath(dir, path)
      vim.fn.mkdir(vim.fs.dirname(full), "p")
      local handle = assert(io.open(full, "wb"))
      handle:write(content)
      handle:close()
    end

    ---Run the command and wait for its answer.
    ---@param args string
    ---@return codeview.Session? session
    ---@return codeview.Error? err
    local function run(args)
      local out, finished = {}, false
      command.run({
        args = args,
        dir = dir,
        on_open = function(opened, err)
          out.session, out.err, finished = opened, err, true
        end,
      })
      wait_for(function()
        return finished
      end)
      return out.session, out.err
    end

    before_each(function()
      dir = vim.fs.normalize(fixtures.tempdir("command-files"))
      require("codeview.config").setup({
        commit_message = false,
        quit = "never",
        comments = { dir = dir .. "-store" },
      })
    end)

    after_each(function()
      vim.cmd("silent! %bwipeout!")
      vim.fn.delete(dir, "rf")
      vim.fn.delete(dir .. "-store", "rf")
    end)

    it("reads the paths after the word file", function()
      local parsed = assert(command.parse("file a.md docs/ ++quit"))
      assert.are.equal("files", parsed.action)
      assert.are.same({ "a.md", "docs/" }, parsed.paths)
      assert.is_true(parsed.quit)
      parsed = assert(command.parse("FILE"))
      assert.are.equal("files", parsed.action)
      assert.are.same({}, parsed.paths)
    end)

    it("keeps a space after a backslash", function()
      assert.are.same({ "my notes.md", "b" }, command.split_paths([[my\ notes.md  b]]))
      assert.are.same({ [[a\b]] }, command.split_paths([[a\\b]]))
      assert.are.same({}, command.split_paths("   "))
    end)

    it("opens a review of the files", function()
      write("plan.md", "# Plan\n")
      write("docs/a.md", "a\n")
      local opened, err = run("file plan.md docs")
      assert.is_nil(err)
      opened = assert(opened)
      assert.is_true(opened:is_files())
      assert.are.equal(dir, opened.repo.root)
      assert.are.same(
        { "docs/a.md", "plan.md" },
        vim.tbl_map(function(file)
          return file.path
        end, opened.files)
      )
    end)

    it("expands a wildcard", function()
      write("one.md", "1\n")
      write("two.md", "2\n")
      write("skip.txt", "x\n")
      local opened = assert(run("file " .. dir .. "/*.md"))
      assert.are.equal(2, opened:changed_count())
    end)

    it("reports a wildcard without a match", function()
      local opened, err = run("file " .. dir .. "/*.nothing")
      assert.is_nil(opened)
      assert.matches("no file matches", err.message)
    end)

    it("takes the file of the current buffer without a path", function()
      write("current.txt", "here\n")
      vim.cmd.edit(vim.fn.fnameescape(dir .. "/current.txt"))
      local opened = assert(run("file"))
      -- The buffer name can follow a link of the directory, for example
      -- /var to /private/var on macOS. Compare the real paths.
      assert.are.same({ vim.uv.fs_realpath(dir .. "/current.txt") }, vim.tbl_map(vim.uv.fs_realpath, opened.paths))
    end)

    it("reports a current buffer without a file", function()
      vim.cmd.enew()
      local opened, err = run("file")
      assert.is_nil(opened)
      assert.matches("the current buffer holds no file", err.message)
    end)

    it("opens a review of files from the Lua call", function()
      write("plan.md", "# Plan\n")
      local out, finished = {}, false
      command.review_files({ "plan.md" }, { dir = dir }, function(opened, err)
        out.session, out.err, finished = opened, err, true
      end)
      wait_for(function()
        return finished
      end)
      assert.is_nil(out.err)
      assert.is_true(assert(out.session):is_files())
    end)

    it("completes the word file, and then the paths", function()
      local res = helpers.clean_nvim('print(vim.inspect(vim.fn.getcompletion("Codeview fi", "cmdline")))')
      assert.are.equal(0, res.code)
      assert.is_truthy(res.output:find('"file"', 1, true), res.output)
      write("plan.md", "x\n")
      res = helpers.clean_nvim(
        string.format('print(vim.inspect(vim.fn.getcompletion("Codeview file %s/pl", "cmdline")))', dir)
      )
      assert.are.equal(0, res.code)
      assert.is_truthy(res.output:find("plan.md", 1, true), res.output)
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
