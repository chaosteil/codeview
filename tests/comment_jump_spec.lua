-- The comment keys: `]c` and `[c` jump from comment to comment, also from
-- file to file.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview comment jumps", function()
  local fixture = fixtures.git_comments()
  local comments, config, remote, session_mod, sidebar, view
  ---@type string
  local dir
  ---@type codeview.Session?
  local opened

  ---Open a review session for the fixture range.
  ---@return codeview.Session
  local function open_session()
    if opened then
      return opened
    end
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Add one local comment to the store of the session.
  ---@param path string
  ---@param line integer
  ---@param side? codeview.linemap.Side
  ---@return codeview.store.Comment
  local function add_comment(path, line, side)
    return assert(comments.create(open_session(), {
      file = path,
      start_line = line,
      end_line = line,
      side = side or "new",
      commit = side == "old" and fixture.ids.base or fixture.ids.change,
      body = "a note on " .. path .. ":" .. line,
    }))
  end

  ---Comment of GitHub for `remote.attach()`.
  ---@param fields table
  ---@return codeview.remote.Comment
  local function remote_comment(fields)
    return vim.tbl_extend("force", {
      id = 501,
      file = "call.lua",
      start_line = 3,
      end_line = 3,
      side = "new",
      commit = fixture.ids.change,
      author = "grace",
      body = "this line needs a test",
      url = "https://github.com/ada/demo/pull/12#discussion_r501",
      created_at = 0,
      outdated = false,
    }, fields)
  end

  ---Run one jump and wait for its answer.
  ---@param fn fun(session: codeview.Session, cb: fun(view: codeview.view.State?, err: codeview.Error?))
  ---@return codeview.Error? err
  local function jump(fn)
    local finished, out = false, nil
    fn(open_session(), function(_, err)
      finished, out = true, err
    end)
    assert.is_true(
      vim.wait(20000, function()
        return finished
      end, 10),
      "the jump did not answer"
    )
    return out
  end

  ---File, line, and side under the cursor of the diff view.
  ---@return string place For example "call.lua:2:new".
  local function where()
    local state = assert(view.current())
    local win = api.nvim_get_current_win()
    local map = (win == state.old_win and state.old_map) or state.map
    local line, side = map:file_line(api.nvim_win_get_cursor(win)[1])
    return string.format("%s:%s:%s", state.path, tostring(line), tostring(side))
  end

  ---Press a key in the window that has the focus.
  ---@param lhs string
  local function press(lhs)
    api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
  end

  before_each(function()
    helpers.unload()
    dir = fixtures.tempdir("codeview-jump")
    config = require("codeview.config")
    assert(config.setup({ commit_message = false, quit = "never", comments = { dir = dir } }))
    comments = require("codeview.comments")
    remote = require("codeview.remote")
    session_mod = require("codeview.session")
    sidebar = require("codeview.sidebar")
    view = require("codeview.view")
  end)

  after_each(function()
    sidebar.close()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    require("codeview.events").clear()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  describe("next", function()
    it("walks the comments of the review in the order of the tree", function()
      -- Line 5 of tail.txt sits in a collapsed section. The order of the
      -- comments of a file is the order of the diff, not of the store.
      add_comment("tail.txt", 40)
      add_comment("tail.txt", 5)
      add_comment("call.lua", 2)
      add_comment("call.lua", 1)

      local visited = {}
      for _ = 1, 4 do
        assert.is_nil(jump(view.next_comment))
        visited[#visited + 1] = where()
      end
      assert.are.same({ "call.lua:1:new", "call.lua:2:new", "tail.txt:5:new", "tail.txt:40:new" }, visited)

      local err = jump(view.next_comment)
      assert.are.equal("not_found", err and err.code)
      assert.are.equal("no comment after this one", err and err.message)
      assert.are.equal("tail.txt:40:new", where())
    end)

    it("starts at the cursor", function()
      add_comment("tail.txt", 38)
      add_comment("tail.txt", 40)
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("tail.txt"))))
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { assert(state.map:buf_row(39, "new")), 0 })
      assert.is_nil(jump(view.next_comment))
      assert.are.equal("tail.txt:40:new", where())
    end)

    it("stops once on a line with two comments", function()
      add_comment("call.lua", 2)
      add_comment("call.lua", 2)
      add_comment("tail.txt", 40)
      assert.is_nil(jump(view.next_comment))
      assert.are.equal("call.lua:2:new", where())
      assert.is_nil(jump(view.next_comment))
      assert.are.equal("tail.txt:40:new", where())
    end)

    it("stops at a thread of GitHub, and not at an outdated one", function()
      add_comment("call.lua", 1)
      remote.attach(open_session(), {
        remote_comment({}),
        remote_comment({ id = 502, reply_to = 501, created_at = 1 }),
        -- No line of the current file holds the outdated comment.
        remote_comment({ id = 503, file = "tail.txt", start_line = 7, end_line = 7, outdated = true, anchored = false }),
      })
      local visited = {}
      for _ = 1, 2 do
        assert.is_nil(jump(view.next_comment))
        visited[#visited + 1] = where()
      end
      assert.are.same({ "call.lua:1:new", "call.lua:3:new" }, visited)
      assert.are.equal("not_found", jump(view.next_comment).code)
    end)

    it("goes to the side of the comment in the side-by-side style", function()
      assert(
        config.setup({ commit_message = false, quit = "never", comments = { dir = dir }, diff = { style = "split" } })
      )
      add_comment("call.lua", 2, "old")
      add_comment("call.lua", 2, "new")
      assert.is_nil(jump(view.next_comment))
      local state = assert(view.current())
      assert.are.equal(state.old_win, api.nvim_get_current_win())
      assert.are.equal("call.lua:2:old", where())
      -- Both sides hold the change on one row, so the next stop is the next
      -- row with a comment.
      local err = jump(view.next_comment)
      assert.are.equal("no comment after this one", err and err.message)
    end)

    it("reports a review without comments", function()
      local err = jump(view.next_comment)
      assert.are.equal("not_found", err and err.code)
      assert.are.equal("the review has no comments", err and err.message)
      assert.is_nil(view.current())
    end)

    it("skips a file that the range does not change", function()
      add_comment("gone.txt", 1)
      add_comment("tail.txt", 40)
      assert.is_nil(jump(view.next_comment))
      assert.are.equal("tail.txt:40:new", where())
    end)
  end)

  describe("prev", function()
    it("walks the comments of the review backwards", function()
      add_comment("call.lua", 1)
      add_comment("call.lua", 2)
      add_comment("tail.txt", 5)
      add_comment("tail.txt", 40)

      local visited = {}
      for _ = 1, 4 do
        assert.is_nil(jump(view.prev_comment))
        visited[#visited + 1] = where()
      end
      assert.are.same({ "tail.txt:40:new", "tail.txt:5:new", "call.lua:2:new", "call.lua:1:new" }, visited)

      local err = jump(view.prev_comment)
      assert.are.equal("no comment before this one", err and err.message)
      assert.are.equal("call.lua:1:new", where())
    end)
  end)

  describe("the keys", function()
    it("jump in the diff view", function()
      add_comment("call.lua", 1)
      add_comment("tail.txt", 40)
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("call.lua"))))
      api.nvim_set_current_win(state.win)
      press("]c")
      assert.is_true(vim.wait(20000, function()
        return where() == "call.lua:1:new"
      end, 10))
      press("]c")
      assert.is_true(vim.wait(20000, function()
        return where() == "tail.txt:40:new"
      end, 10))
      press("[c")
      assert.is_true(vim.wait(20000, function()
        return where() == "call.lua:1:new"
      end, 10))
    end)

    it("jump from the sidebar into the diff view", function()
      add_comment("tail.txt", 40)
      open_session()
      local bar = assert(sidebar.open({ focus = true }))
      assert.are.equal(bar.panel:window(), api.nvim_get_current_win())
      press("]c")
      assert.is_true(vim.wait(20000, function()
        return view.current() ~= nil and where() == "tail.txt:40:new"
      end, 10))
    end)

    it("name the key in the hint row", function()
      local hints = require("codeview.hints")
      local found = false
      for _, entry in ipairs(hints.actions.view) do
        found = found or entry.action == "next_comment"
      end
      assert.is_true(found)
    end)
  end)

  describe("the comment overview", function()
    it("still jumps to the comment under the cursor", function()
      local comment = add_comment("tail.txt", 5)
      local bar = assert(require("codeview.overview").open({ session = open_session() }))
      local finished, failure = false, nil
      assert.is_true(bar:jump(comment, function(_, err)
        finished, failure = true, err
      end))
      assert.is_true(vim.wait(20000, function()
        return finished
      end, 10))
      assert.is_nil(failure)
      assert.are.equal("tail.txt:5:new", where())
      require("codeview.overview").close()
    end)
  end)
end)
