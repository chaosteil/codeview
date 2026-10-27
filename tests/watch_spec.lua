-- Tests of the repository watcher.
--
-- The deterministic cases call `watch.check()` themselves. One case waits for
-- an event of the file system, because that path needs the loop of libuv.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.watch", function()
  local config, session_mod, watch
  ---@type tests.Fixture?
  local fixture
  ---@type codeview.Session?
  local opened
  ---@type string[]
  local messages
  ---@type fun(msg: string, level?: integer, opts?: table)
  local notify

  ---Run a command in the fixture.
  ---@param cmd string[]
  local function run(cmd)
    local env = fixture.env or { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null", HOME = fixture.dir }
    local res = vim.system(cmd, { cwd = fixture.dir, env = env, text = true }):wait(30000)
    assert.are.equal(0, res.code, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
  end

  ---Write one file of the fixture and commit it with git.
  ---@param path string
  local function commit(path)
    local handle = assert(io.open(vim.fs.joinpath(fixture.dir, path), "wb"))
    handle:write("fresh\n")
    handle:close()
    run({ "git", "add", "--", path })
    run({ "git", "commit", "--quiet", "-m", "add " .. path })
  end

  ---Open a session of a new git fixture.
  ---@param spec? string
  ---@return codeview.Session
  local function open_session(spec)
    fixture = fixture or fixtures.git()
    local review, err = session_mod.open(spec or "HEAD~1..HEAD", { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Count the CodeViewSessionRefreshed events of one session.
  ---@param review codeview.Session
  ---@return fun(): integer count
  ---@return fun() stop
  local function count_refreshed(review)
    local seen = 0
    local group = vim.api.nvim_create_augroup("codeview.test.watch", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "CodeViewSessionRefreshed",
      callback = function(event)
        if event.data and event.data.id == review.id then
          seen = seen + 1
        end
      end,
    })
    return function()
      return seen
    end, function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    config.setup({ commit_message = false })
    session_mod = require("codeview.session")
    watch = require("codeview.watch")
    messages = {}
    notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(text)
      messages[#messages + 1] = text
    end
  end)

  after_each(function()
    vim.notify = notify
    watch.stop()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    if fixture then
      fixture.cleanup()
      fixture = nil
    end
    helpers.unload()
  end)

  describe("start and stop", function()
    it("watches the repository of a new session", function()
      open_session()
      assert.is_true(watch.is_active())
    end)

    it("stops with the session", function()
      local review = open_session()
      assert.is_true(watch.is_active())
      review:close()
      assert.is_false(watch.is_active())
    end)

    it("stays off when auto_refresh is false", function()
      config.setup({ commit_message = false, auto_refresh = false })
      open_session()
      assert.is_false(watch.is_active())
    end)

    it("does nothing on a second stop", function()
      open_session()
      assert.is_true(watch.stop())
      assert.is_false(watch.stop())
    end)
  end)

  describe("check", function()
    it("reads the review again after a new commit", function()
      local review = open_session()
      local seen, stop = count_refreshed(review)
      local head = review.range.to

      commit("fresh.txt")
      local changed, err = watch.check(review)
      stop()

      assert.is_nil(err)
      assert.is_true(changed)
      assert.are_not.equal(head, review.range.to)
      assert.is_truthy(review:index_of("fresh.txt"), vim.inspect(review.files))
      assert.are.equal(1, seen())
    end)

    it("does nothing while the ids stay the same", function()
      local review = open_session()
      local seen, stop = count_refreshed(review)

      local changed, err = watch.check(review)
      stop()

      assert.is_nil(err)
      assert.is_false(changed)
      assert.are.equal(0, seen())
    end)

    it("reads the review again in the async form", function()
      local review = open_session()
      commit("fresh.txt")

      local answered = false
      watch.check(review, function()
        answered = true
      end)
      assert.is_true(
        vim.wait(20000, function()
          return answered
        end, 10),
        "the check did not answer"
      )
      assert.is_truthy(review:index_of("fresh.txt"), vim.inspect(review.files))
    end)

    it("keeps the data after a failed read of the range", function()
      local review = open_session()
      local files = #review.files
      local errors = require("codeview.error")
      ---@diagnostic disable-next-line: duplicate-set-field
      review.repo.resolve_range = function(_, _, cb)
        local err = errors.new(errors.codes.BAD_REVISION, "no such revision")
        if cb then
          cb(nil, err)
          return nil, nil
        end
        return nil, err
      end

      local changed, err = watch.check(review)
      assert.is_nil(changed)
      assert.are.equal("bad_revision", err.code)
      assert.are.equal(files, #review.files)
    end)

    it("does nothing for a closed session", function()
      local review = open_session()
      review:close()
      local changed, err = watch.check(review)
      assert.is_nil(err)
      assert.is_false(changed)
    end)
  end)

  -- The jj cases need jj in $PATH. They cover the operation log as the state
  -- of the repository.
  if vim.fn.executable("jj") == 1 then
    describe("on a jj repository", function()
      ---Open a session of a new jj fixture.
      ---@return codeview.Session
      local function open_jj()
        fixture = fixture or fixtures.jj()
        local review, err = session_mod.open(fixture.ids.init .. "..@", { dir = fixture.dir })
        assert.is_nil(err)
        opened = assert(review)
        return opened
      end

      it("reads the review again after a new commit", function()
        local review = open_jj()
        assert.are.equal(2, #review.commits)
        local seen, stop = count_refreshed(review)

        run({ "jj", "--no-pager", "new" })
        run({ "jj", "--no-pager", "describe", "-m", "one more" })

        local changed, err = watch.check(review)
        stop()

        assert.is_nil(err)
        assert.is_true(changed)
        assert.are.equal(3, #review.commits)
        assert.are.equal(1, seen())
      end)

      it("reads the review again after an operation of another process", function()
        local review = open_jj()
        if not watch.is_active() then
          print("no file system watcher, the case does not run")
          return
        end
        local seen, stop = count_refreshed(review)

        run({ "jj", "--no-pager", "new" })
        run({ "jj", "--no-pager", "describe", "-m", "one more" })

        local ok = vim.wait(10000, function()
          return seen() > 0
        end, 50)
        stop()

        assert.is_true(ok, "the watcher sent no event")
        assert.are.equal(3, #review.commits)
      end)
    end)

    describe("on a colocated jj repository", function()
      ---Open a session on a bookmark that git moves later.
      ---@return codeview.Session
      local function open_colocated()
        fixture = fixtures.jj({ colocate = true })
        run({ "jj", "--no-pager", "bookmark", "create", "side", "-r", "@-" })
        local review, err = session_mod.open("side", { dir = fixture.dir })
        assert.is_nil(err)
        opened = assert(review)
        return opened
      end

      ---Commit with git on the bookmark `side`.
      local function git_commit()
        local identity = { "-c", "user.name=Ada Lovelace", "-c", "user.email=ada@example.com" }
        run(vim.list_extend({ "git" }, vim.list_extend(vim.deepcopy(identity), { "checkout", "--quiet", "side" })))
        run(
          vim.list_extend(
            { "git" },
            vim.list_extend(vim.deepcopy(identity), { "commit", "--quiet", "--allow-empty", "-m", "git: one more" })
          )
        )
      end

      it("reads the review again after a commit of git", function()
        local review = open_colocated()
        local head = review.range.to
        local seen, stop = count_refreshed(review)

        git_commit()
        local changed, err = watch.check(review)
        stop()

        assert.is_nil(err)
        assert.is_true(changed)
        assert.are_not.equal(head, review.range.to)
        assert.are.equal(1, seen())
      end)

      it("watches the git directory", function()
        local review = open_colocated()
        if not watch.is_active() then
          print("no file system watcher, the case does not run")
          return
        end
        local head = review.range.to
        local seen, stop = count_refreshed(review)

        git_commit()
        local ok = vim.wait(10000, function()
          return seen() > 0
        end, 50)
        stop()

        assert.is_true(ok, "the watcher sent no event")
        assert.are_not.equal(head, review.range.to)
      end)
    end)
  end

  describe("the events of the file system", function()
    it("reads the review again after a commit of another process", function()
      local review = open_session()
      if not watch.is_active() then
        -- A file system without events leaves the review to the refresh key.
        print("no file system watcher, the case does not run")
        return
      end
      local seen, stop = count_refreshed(review)

      commit("fresh.txt")
      local ok = vim.wait(10000, function()
        return seen() > 0
      end, 50)
      stop()

      assert.is_true(ok, "the watcher sent no event")
      assert.is_truthy(review:index_of("fresh.txt"), vim.inspect(review.files))
    end)
  end)
  describe("the user interface", function()
    it("runs no backend command in the sync form for a watcher event and a sidebar <CR>", function()
      local review = open_session()
      local view = require("codeview.view")
      local bar = assert(require("codeview.sidebar").open({ session = review }))
      assert(view.open(review, 1))
      local seen, stop = count_refreshed(review)
      commit("fresh.txt")

      -- A sync call blocks the editor. The stub fails each one and keeps the
      -- command, and the async form runs as before.
      local exec = require("codeview.exec")
      local errors = require("codeview.error")
      local capture = exec.capture
      ---@type string[]
      local blocked = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      exec.capture = function(cmd, opts, cb)
        if not cb then
          blocked[#blocked + 1] = table.concat(cmd, " ")
          return nil, errors.new(errors.codes.COMMAND_FAILED, "a sync call of the user interface")
        end
        return capture(cmd, opts, cb)
      end

      -- The watcher checks the repository on FocusGained. Without a watcher of
      -- the file system, the check runs in the form that the watcher uses.
      if watch.is_active() then
        vim.api.nvim_exec_autocmds("FocusGained", {})
      else
        watch.check(review, function() end)
      end
      local refreshed = vim.wait(20000, function()
        return seen() > 0 and review:index_of("fresh.txt") ~= nil
      end, 10)
      stop()

      local lnum = bar.panel:find(function(node)
        return node.kind == "file" and node.path == "fresh.txt"
      end)
      local opened_file = false
      if lnum then
        local win = assert(bar.panel:window())
        vim.api.nvim_set_current_win(win)
        bar.panel:set_cursor(lnum)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
        opened_file = vim.wait(20000, function()
          local state = view.current()
          return state ~= nil and state.path == "fresh.txt"
        end, 10)
      end
      exec.capture = capture

      assert.is_true(refreshed, "the watcher did not read the review again")
      assert.is_truthy(lnum, "the sidebar shows no fresh.txt")
      assert.is_true(opened_file, "the <CR> of the sidebar opened no file")
      assert.are.same({}, blocked)
    end)
  end)
end)
