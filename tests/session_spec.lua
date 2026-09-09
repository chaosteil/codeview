local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

---Run an async call and wait for its callback.
---@param fn fun(cb: fun(value: any?, err: codeview.Error?))
---@return any? value
---@return codeview.Error? err
local function await(fn)
  local out, finished = {}, false
  fn(function(value, err)
    out.value, out.err, finished = value, err, true
  end)
  assert.is_true(
    vim.wait(20000, function()
      return finished
    end, 10),
    "the async call did not answer"
  )
  return out.value, out.err
end

---@param files codeview.vcs.FileChange[]
---@return table<string, codeview.vcs.FileChange>
local function by_path(files)
  local out = {}
  for _, file in ipairs(files) do
    out[file.path] = file
  end
  return out
end

describe("codeview.session", function()
  local fixture = fixtures.git()
  local session

  ---@param spec any
  ---@return codeview.Session
  local function open(spec)
    local opened, err = session.open(spec, { dir = fixture.dir })
    assert.is_nil(err)
    return assert(opened)
  end

  before_each(function()
    helpers.unload()
    require("codeview.config").setup({ commit_message = false })
    session = require("codeview.session")
  end)

  after_each(function()
    session.close()
    helpers.unload()
  end)

  describe("open", function()
    it("reports the changed files of one commit", function()
      local opened = open(fixture.ids.edit)
      assert.are.equal(fixture.ids.init, opened.range.from)
      assert.are.equal(fixture.ids.edit, opened.range.to)

      local map = by_path(opened:changed_files())
      assert.are.equal(2, #opened.files)
      assert.are.equal("modified", map["a.txt"].status)
      assert.are.equal("added", map["added.txt"].status)
    end)

    it("reports the commits of the range, newest first", function()
      local opened = open(fixture.ids.init .. ".." .. fixture.ids.shuffle)
      assert.are.equal(2, #opened.commits)
      assert.are.equal(fixture.ids.shuffle, opened.commits[1].id)
      assert.are.equal(fixture.ids.edit, opened.commits[2].id)
    end)

    it("reports every file of the first commit as added", function()
      local opened = open(fixture.ids.init)
      assert.is_nil(opened.range.from)
      assert.are.equal(3, #opened.files)
      for _, file in ipairs(opened.files) do
        assert.are.equal("added", file.status)
      end
    end)

    it("accepts a range table with resolved revisions", function()
      local opened = open({ from = fixture.ids.init, to = fixture.ids.shuffle })
      assert.are.equal(fixture.ids.init, opened.range.from)
      assert.are.equal(4, #opened.files)
      assert.are.equal("dir/nested.txt", by_path(opened.files)["dir/renamed.txt"].old_path)
    end)

    it("accepts a parsed spec from the vcs module", function()
      local parsed = assert(require("codeview.vcs").parse_range(fixture.ids.init .. ".." .. fixture.branch))
      local opened = open(parsed)
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
      assert.are.equal(parsed.spec, opened:label())
    end)

    it("keeps the repository handle of the backend", function()
      local opened = open(fixture.ids.edit)
      assert.are.equal("git", opened.repo.backend)
      assert.are.equal(fixture.root, opened.repo.root)
    end)

    it("reuses a repository handle from the caller", function()
      local repo = assert(require("codeview.vcs.git").detect(fixture.dir))
      local opened = assert(session.open(fixture.ids.edit, { repo = repo }))
      assert.are.equal(repo, opened.repo)
    end)

    it("becomes the session that runs", function()
      local opened = open(fixture.ids.edit)
      assert.are.equal(opened, session.current())
      assert.is_true(session.is_active())
      assert.is_true(opened:is_active())
    end)

    it("opens asynchronously", function()
      local opened, err = await(function(cb)
        session.open(fixture.ids.shuffle, { dir = fixture.dir }, cb)
      end)
      assert.is_nil(err)
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
      assert.are.equal(3, #opened.files)
      assert.are.equal(opened, session.current())
    end)

    it("reports an unknown revision", function()
      local opened, err = session.open("no-such-revision", { dir = fixture.dir })
      assert.is_nil(opened)
      assert.are.equal("bad_revision", err.code)
      assert.is_nil(session.current())
    end)

    it("reports a directory outside a repository", function()
      local outside = fixtures.tempdir("codeview-outside")
      local opened, err = session.open("HEAD", { dir = outside })
      vim.fn.delete(outside, "rf")
      assert.is_nil(opened)
      assert.are.equal("not_a_repo", err.code)
    end)

    it("rejects an argument that is not a string or a table", function()
      local opened, err = session.open(42, { dir = fixture.dir })
      assert.is_nil(opened)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("reports an error asynchronously", function()
      local opened, err = await(function(cb)
        session.open("no-such-revision", { dir = fixture.dir }, cb)
      end)
      assert.is_nil(opened)
      assert.are.equal("bad_revision", err.code)
    end)
  end)

  describe("labels", function()
    it("keeps the text of the user", function()
      local spec = fixture.ids.init:sub(1, 8) .. ".." .. fixture.branch
      assert.are.equal(spec, open(spec):label())
    end)

    it("builds a label from a range table", function()
      local opened = open({ from = fixture.ids.init, to = fixture.ids.shuffle })
      assert.are.equal(fixture.ids.init:sub(1, 8) .. ".." .. fixture.ids.shuffle:sub(1, 8), opened:label())
    end)

    it("counts the files and the commits", function()
      local opened = open(fixture.ids.edit)
      assert.are.equal(opened:label() .. ": 2 files, 1 commit", opened:summary())
    end)
  end)

  describe("file list", function()
    it("reads a file by its position", function()
      local opened = open(fixture.ids.init)
      assert.are.equal(opened.files[2], opened:file(2))
      assert.is_nil(opened:file(99))
    end)

    it("finds the position of a path", function()
      local opened = open(fixture.ids.edit)
      local index = assert(opened:index_of("added.txt"))
      assert.are.equal("added.txt", opened.files[index].path)
      assert.is_nil(opened:index_of("no-such-file.txt"))
    end)
  end)

  describe("refresh", function()
    it("reads the changed files again", function()
      local opened = open(fixture.ids.edit)
      opened.files = {}
      local same, err = opened:refresh()
      assert.is_nil(err)
      assert.are.equal(opened, same)
      assert.are.equal(2, #opened.files)
    end)

    it("refreshes asynchronously", function()
      local opened = open(fixture.ids.edit)
      opened.commits = {}
      local same, err = await(function(cb)
        opened:refresh(cb)
      end)
      assert.is_nil(err)
      assert.are.equal(opened, same)
      assert.are.equal(1, #opened.commits)
    end)

    it("rejects a closed session", function()
      local opened = open(fixture.ids.edit)
      opened:close()
      local same, err = opened:refresh()
      assert.is_nil(same)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("drops the answer when the session closes during the refresh", function()
      local opened = open(fixture.ids.edit)
      opened.files = {}

      local seen = false
      local group = vim.api.nvim_create_augroup("codeview.test.refresh", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CodeViewSessionRefreshed",
        callback = function()
          seen = true
        end,
      })

      local same, err = await(function(cb)
        opened:refresh(cb)
        opened:close()
      end)
      vim.api.nvim_del_augroup_by_id(group)

      assert.is_nil(same)
      assert.are.equal("invalid_arg", err.code)
      assert.is_false(seen)
      assert.are.equal(0, #opened.files)
    end)
  end)

  describe("refresh of a repository that moves", function()
    -- Each case writes its own repository, because a new commit breaks the
    -- commit ids of the fixture of the other tests.

    ---@type tests.Fixture?
    local moving

    ---Environment of a git call in the private fixture.
    ---@return table<string, string>
    local function env_of()
      if moving.env then
        return moving.env
      end
      return { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null", HOME = moving.dir }
    end

    ---Run a command in the private fixture.
    ---@param cmd string[]
    local function run(cmd)
      local res = vim.system(cmd, { cwd = moving.dir, env = env_of(), text = true }):wait(30000)
      assert.are.equal(0, res.code, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
    end

    ---Write one file of the private fixture.
    ---@param path string
    ---@param text string
    local function write(path, text)
      local handle = assert(io.open(vim.fs.joinpath(moving.dir, path), "wb"))
      handle:write(text)
      handle:close()
    end

    ---Open a session of the private fixture.
    ---@param spec any
    ---@return codeview.Session
    local function open_moving(spec)
      local opened, err = session.open(spec, { dir = moving.dir })
      assert.is_nil(err)
      return assert(opened)
    end

    before_each(function()
      -- The manual call is the only actor here, so the watcher stays off.
      require("codeview.config").setup({ commit_message = false, auto_refresh = false })
    end)

    after_each(function()
      if moving then
        moving.cleanup()
        moving = nil
      end
    end)

    it("takes a new commit of a git range", function()
      moving = fixtures.git()
      local opened = open_moving("HEAD~1..HEAD")
      local head = opened.range.to

      write("fresh.txt", "fresh\n")
      run({ "git", "add", "--", "fresh.txt" })
      run({ "git", "commit", "--quiet", "-m", "add fresh.txt" })

      local same, err = opened:refresh()
      assert.is_nil(err)
      assert.are.equal(opened, same)
      assert.are_not.equal(head, opened.range.to)
      assert.is_truthy(opened:index_of("fresh.txt"), vim.inspect(opened.files))
    end)

    it("resolves the range again in the async form", function()
      moving = fixtures.git()
      local opened = open_moving("HEAD~1..HEAD")

      write("fresh.txt", "fresh\n")
      run({ "git", "add", "--", "fresh.txt" })
      run({ "git", "commit", "--quiet", "-m", "add fresh.txt" })

      local same, err = await(function(cb)
        opened:refresh(cb)
      end)
      assert.is_nil(err)
      assert.are.equal(opened, same)
      assert.is_truthy(opened:index_of("fresh.txt"), vim.inspect(opened.files))
    end)

    it("reads a pull request range again without a change", function()
      -- A pull request opens a range of two resolved commits. The refresh
      -- reads the same two commits again.
      moving = fixtures.git()
      local opened = open_moving({ from = moving.ids.init, to = moving.ids.shuffle, spec = "pr-7" })
      assert.are.equal("pr-7", opened.spec)

      local same, err = opened:refresh()
      assert.is_nil(err)
      assert.are.equal(opened, same)
      assert.are.equal(moving.ids.init, opened.range.from)
      assert.are.equal(moving.ids.shuffle, opened.range.to)
    end)

    -- The jj cases need jj in $PATH.
    if vim.fn.executable("jj") == 1 then
      it("takes a new commit of a jj revset", function()
        moving = fixtures.jj()
        local opened = open_moving(moving.ids.init .. "..@")
        assert.are.equal(2, #opened.commits)

        run({ "jj", "--no-pager", "new" })
        write("fresh.txt", "fresh\n")
        run({ "jj", "--no-pager", "describe", "-m", "add fresh.txt" })

        local same, err = opened:refresh()
        assert.is_nil(err)
        assert.are.equal(opened, same)
        assert.are.equal(3, #opened.commits)
        assert.is_truthy(opened:index_of("fresh.txt"), vim.inspect(opened.files))
      end)

      it("takes a write of the jj working copy without a jj command", function()
        moving = fixtures.jj()
        local opened = open_moving(moving.ids.edit .. "..@")
        assert.is_nil(opened:index_of("fresh.txt"))

        write("fresh.txt", "fresh\n")

        local same, err = opened:refresh()
        assert.is_nil(err)
        assert.are.equal(opened, same)
        assert.is_truthy(opened:index_of("fresh.txt"), vim.inspect(opened.files))
      end)

      it("moves the head of a range of commit ids to the snapshot", function()
        -- The commit picker opens such a range. The id resolves to the commit
        -- before the snapshot, so the head takes the new commit.
        moving = fixtures.jj()
        local opened = open_moving({ kind = "range", from = moving.ids.edit, to = moving.ids.shuffle, spec = "picked" })
        assert.are.equal(moving.ids.shuffle, opened.range.to)

        write("fresh.txt", "fresh\n")

        local same, err = opened:refresh()
        assert.is_nil(err)
        assert.are.equal(opened, same)
        assert.are_not.equal(moving.ids.shuffle, opened.range.to)
        assert.is_truthy(opened:index_of("fresh.txt"), vim.inspect(opened.files))
      end)

      it("leaves the working copy alone without a snapshot", function()
        moving = fixtures.jj()
        local opened = open_moving(moving.ids.edit .. "..@")
        local head = opened.range.to

        write("fresh.txt", "fresh\n")

        local same, err = opened:refresh({ snapshot = false })
        assert.is_nil(err)
        assert.are.equal(opened, same)
        assert.are.equal(head, opened.range.to)
        assert.is_nil(opened:index_of("fresh.txt"))
      end)
    end
  end)

  describe("reload", function()
    it("keeps a git session, because a file moves no commit there", function()
      -- The head of the range is HEAD, so the reload asks the backend for the
      -- working copy. git holds it outside the commits, so nothing moves.
      local opened = open(fixture.ids.shuffle)
      opened.files = {}
      local same, err = opened:reload()
      assert.is_nil(err)
      assert.are.equal(opened, same)
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
      assert.are.same({}, opened.files)
    end)

    it("keeps a review that does not hold the working copy", function()
      local opened = open(fixture.ids.edit)
      opened.files = {}
      local same, err = opened:reload()
      assert.is_nil(err)
      assert.are.equal(opened, same)
      assert.are.equal(fixture.ids.edit, opened.range.to)
      assert.are.same({}, opened.files)
    end)

    it("reloads asynchronously", function()
      local opened = open(fixture.ids.shuffle)
      local same, err = await(function(cb)
        opened:reload(cb)
      end)
      assert.is_nil(err)
      assert.are.equal(opened, same)
    end)

    it("rejects a closed session", function()
      local opened = open(fixture.ids.shuffle)
      opened:close()
      local same, err = opened:reload()
      assert.is_nil(same)
      assert.are.equal("invalid_arg", err.code)
    end)
  end)

  describe("lifecycle", function()
    it("closes the windows of the session", function()
      local opened = open(fixture.ids.edit)
      vim.cmd("new")
      local win = vim.api.nvim_get_current_win()
      opened:add_window(win)
      assert.is_true(vim.api.nvim_win_is_valid(win))

      opened:close()
      assert.is_false(vim.api.nvim_win_is_valid(win))
    end)

    it("deletes the buffers of the session", function()
      local opened = open(fixture.ids.edit)
      local buf = opened:add_buffer(vim.api.nvim_create_buf(false, true))
      opened:close()
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
    end)

    it("deletes the autocmd group of the session", function()
      local opened = open(fixture.ids.edit)
      local group = opened:augroup()
      vim.api.nvim_create_autocmd("User", { group = group, pattern = "CodeViewTest", callback = function() end })
      assert.are.equal(1, #vim.api.nvim_get_autocmds({ group = group }))

      opened:close()
      assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = group }))
    end)

    it("runs the close handlers", function()
      local opened = open(fixture.ids.edit)
      local seen = {}
      opened:on_close(function(closed)
        seen[#seen + 1] = closed
      end)
      opened:close()
      assert.are.equal(1, #seen)
      assert.are.equal(opened, seen[1])
    end)

    it("survives an error in a close handler", function()
      local opened = open(fixture.ids.edit)
      opened:on_close(function()
        error("boom")
      end)
      assert.is_true(opened:close())
      assert.is_true(opened.closed)
    end)

    it("closes only once", function()
      local opened = open(fixture.ids.edit)
      assert.is_true(opened:close())
      assert.is_false(opened:close())
      assert.is_false(session.is_active())
      assert.is_nil(session.current())
    end)

    it("reports no session for a close without a session", function()
      assert.is_false(session.close())
    end)

    it("closes the previous session on the next open", function()
      local first = open(fixture.ids.edit)
      local second = open(fixture.ids.shuffle)
      assert.is_true(first.closed)
      assert.is_false(second.closed)
      assert.are.equal(second, session.current())
      assert.are.equal(first.id + 1, second.id)
    end)

    it("keeps the session that runs after a failed open", function()
      local opened = open(fixture.ids.edit)
      local next_session, err = session.open("no-such-revision", { dir = fixture.dir })
      assert.is_nil(next_session)
      assert.is_truthy(err)
      assert.are.equal(opened, session.current())
      assert.is_false(opened.closed)
    end)

    it("fires the User events", function()
      local seen = {}
      local group = vim.api.nvim_create_augroup("codeview.test.events", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = { "CodeViewSessionOpened", "CodeViewSessionClosed" },
        callback = function(event)
          seen[#seen + 1] = event.match
        end,
      })

      local opened = open(fixture.ids.edit)
      opened:close()
      vim.api.nvim_del_augroup_by_id(group)

      assert.are.same({ "CodeViewSessionOpened", "CodeViewSessionClosed" }, seen)
    end)

    it("sends plain data with the events", function()
      local payload
      local group = vim.api.nvim_create_augroup("codeview.test.payload", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CodeViewSessionOpened",
        callback = function(event)
          payload = event.data
        end,
      })

      local opened = open(fixture.ids.edit)
      vim.api.nvim_del_augroup_by_id(group)

      assert.are.equal(opened.id, payload.id)
      assert.are.equal(opened.spec, payload.spec)
      assert.are.equal(#opened.files, payload.files)
      assert.are.equal(#opened.commits, payload.commits)
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
