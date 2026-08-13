local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.remote", function()
  local remote

  before_each(function()
    helpers.unload()
    remote = require("codeview.remote")
  end)

  after_each(function()
    helpers.unload()
  end)

  describe("side", function()
    it("maps the sides of GitHub to the sides of the diff", function()
      assert.are.equal("old", remote.side("LEFT"))
      assert.are.equal("new", remote.side("RIGHT"))
      assert.are.equal("new", remote.side(nil))
    end)
  end)

  describe("hunk_line", function()
    ---A hunk that ends on an added line.
    local hunk = table.concat({
      "@@ -70,7 +70,7 @@ GLOBAL MAPPINGS",
      " BUFFER-LOCAL MAPPINGS",
      " ",
      " • <CR> opens the file under the cursor.",
      "-• - opens the parent directory.",
      "+• 1- opens the current working directory.",
    }, "\n")

    it("counts the lines of the new side", function()
      assert.are.equal(73, remote.hunk_line(hunk, "new"))
    end)

    it("counts the lines of the old side", function()
      assert.are.equal(73, remote.hunk_line(hunk, "old"))
    end)

    it("answers nothing without a hunk header", function()
      assert.is_nil(remote.hunk_line("no hunk here", "new"))
      assert.is_nil(remote.hunk_line(nil, "new"))
    end)
  end)

  describe("anchor", function()
    it("takes the lines of the newest version first", function()
      local anchor = assert(remote.anchor({ line = 18, original_line = 17, side = "RIGHT" }))
      assert.are.equal(18, anchor.start_line)
      assert.are.equal(18, anchor.end_line)
      assert.are.equal("new", anchor.side)
      assert.is_false(anchor.outdated)
    end)

    it("reads a comment over more than one line", function()
      local anchor = assert(remote.anchor({ line = 1590, start_line = 1585, side = "RIGHT" }))
      assert.are.equal(1585, anchor.start_line)
      assert.are.equal(1590, anchor.end_line)
    end)

    it("falls back to the lines of the older version", function()
      local anchor = assert(remote.anchor({ line = nil, original_line = 17, side = "RIGHT" }))
      assert.are.equal(17, anchor.start_line)
      assert.is_true(anchor.outdated)
    end)

    it("falls back to the last line of the diff hunk", function()
      local anchor = assert(remote.anchor({
        side = "LEFT",
        diff_hunk = "@@ -10,3 +10,2 @@\n one\n-two\n",
      }))
      assert.are.equal("old", anchor.side)
      assert.are.equal(11, anchor.start_line)
      assert.is_true(anchor.outdated)
    end)

    it("answers nothing without a position", function()
      assert.is_nil(remote.anchor({ side = "RIGHT" }))
      assert.is_nil(remote.anchor("not a table"))
    end)
  end)

  describe("parse", function()
    it("reads a recorded answer of the review comments", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments.json"))
      assert.are.equal(6, #comments)

      local first = comments[1]
      assert.are.equal(3745425897, first.id)
      assert.are.equal("runtime/doc/plugins.txt", first.file)
      assert.are.equal(73, first.start_line)
      assert.are.equal(73, first.end_line)
      assert.are.equal("new", first.side)
      assert.are.equal("justinmk", first.author)
      assert.is_true(first.outdated)
      assert.is_truthy(first.body:find("doc", 1, true))
      assert.are.equal("aae84443b6a6b81de32ced9ec8376371151d7d9a", first.commit)

      local last = comments[#comments]
      assert.are.equal(18, last.start_line)
      assert.is_false(last.outdated)
    end)

    it("drops the carriage returns of the recorded bodies", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments.json"))
      local bodies = 0
      for _, comment in ipairs(comments) do
        assert.is_nil(comment.body:find("\r", 1, true), comment.body)
        if comment.body:find("\n", 1, true) then
          bodies = bodies + 1
        end
      end
      assert.is_true(bodies > 0)
    end)

    it("reads a comment over a line range", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments-multiline.json"))
      assert.are.equal(1, #comments)
      assert.are.equal("src/nvim/undo.c", comments[1].file)
      assert.are.equal(1585, comments[1].start_line)
      assert.are.equal(1590, comments[1].end_line)
    end)

    it("keeps the answer of a reply", function()
      local comments = remote.parse({
        { id = 1, path = "a.lua", line = 3, side = "RIGHT", body = "one", user = { login = "ada" } },
        {
          id = 2,
          path = "a.lua",
          line = 3,
          side = "RIGHT",
          body = "two",
          in_reply_to_id = 1,
          user = { login = "grace" },
        },
      })
      assert.are.equal(2, #comments)
      assert.is_nil(comments[1].reply_to)
      assert.are.equal(1, comments[2].reply_to)
    end)

    it("maps a comment of the old side", function()
      local comments = remote.parse({ { id = 5, path = "a.lua", line = 9, side = "LEFT", body = "gone" } })
      assert.are.equal("old", comments[1].side)
      assert.are.equal(9, comments[1].start_line)
    end)

    it("drops an entry without a file or without a position", function()
      local comments = remote.parse({
        { id = 1, line = 3, side = "RIGHT" },
        { id = 2, path = "a.lua", side = "RIGHT" },
        { id = 3, path = "a.lua", line = 4, side = "RIGHT" },
      })
      assert.are.equal(1, #comments)
      assert.are.equal(3, comments[1].id)
    end)

    it("keeps the review of every comment", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments.json"))
      assert.are.equal("4892676268", comments[1].review_id)
      assert.are.equal("", remote.parse({ { path = "a.lua", line = 4, side = "RIGHT" } })[1].review_id)
    end)

    it("reads no comment out of an empty answer", function()
      assert.are.same({}, remote.parse(nil))
      assert.are.same({}, remote.parse({}))
    end)
  end)

  describe("fetch", function()
    it("needs a repository and a number", function()
      local comments, err = remote.fetch({ repo = "", number = 12 })
      assert.is_nil(comments)
      assert.are.equal("invalid_arg", err.code)
    end)
  end)
end)

describe("codeview.remote in the review", function()
  local fixture = fixtures.git_comments()
  local comments_mod, config, overview, remote, session_mod, view
  ---@type codeview.Session?
  local opened

  ---Text of the range of the fixture.
  ---@return string
  local function spec()
    return fixture.ids.base .. ".." .. fixture.ids.change
  end

  ---Open a review session for the fixture range.
  ---@return codeview.Session
  local function open_session()
    if opened then
      return opened
    end
    local review, err = session_mod.open(spec(), { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Show the diff of one file of the session.
  ---
  --- The inline diff of call.lua is:
  ---
  ---     1  @@ -1,4 +1,4 @@
  ---     2   local a = call(one, two)
  ---     3  -local b = 2
  ---     4  +local b = 22
  ---     5   local c = 3
  ---     6   local d = 4
  ---@param path string
  ---@return codeview.view.State
  local function open_diff(path)
    local review = open_session()
    local state = assert(view.open(review, assert(review:index_of(path))))
    api.nvim_set_current_win(state.win)
    return state
  end

  ---Comments of the pull request, as the mapping gives them.
  ---@param fields? table Fields that replace the defaults.
  ---@return codeview.remote.Comment
  local function remote_comment(fields)
    return vim.tbl_extend("force", {
      id = 501,
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      commit = fixture.ids.change,
      author = "grace",
      body = "this line needs a test",
      url = "https://github.com/ada/demo/pull/12#discussion_r501",
      created_at = 0,
      outdated = false,
    }, fields or {})
  end

  ---Marks of the remote namespace in a buffer.
  ---@param buf integer
  ---@return table[]
  local function marks(buf)
    return remote.marks(buf)
  end

  before_each(function()
    helpers.unload()
    comments_mod = require("codeview.comments")
    config = require("codeview.config")
    overview = require("codeview.overview")
    remote = require("codeview.remote")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    config.reset()
  end)

  after_each(function()
    view.close()
    overview.close()
    if opened then
      opened:close()
      opened = nil
    end
    helpers.unload()
  end)

  it("keeps the comments of one session", function()
    local review = open_session()
    assert.are.same({}, remote.list(review))
    remote.attach(review, { remote_comment() })
    assert.are.equal(1, #remote.list(review))
    assert.are.equal(1, #remote.for_file(review, "call.lua"))
    assert.are.equal(0, #remote.for_file(review, "tail.txt"))
    assert.are.equal(1, #remote.at(review, "call.lua", "new", 2))
    assert.are.equal(0, #remote.at(review, "call.lua", "old", 2))
  end)

  it("drops the comments when the session closes", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    review:close()
    assert.are.same({}, remote.list(review))
    opened = nil
  end)

  it("marks the line of a remote comment in the diff", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local state = open_diff("call.lua")

    local found = marks(state.buf)
    assert.are.equal(1, #found)
    -- Row 4 of the render holds the new line 2.
    assert.are.equal(3, found[1][2])
    local details = found[1][4]
    assert.are.equal(config.get().comments.remote_sign, vim.trim(details.sign_text))
    assert.are.equal("CodeViewRemoteSign", details.sign_hl_group)
    assert.is_truthy(details.virt_lines)
    assert.is_truthy(details.virt_lines[1][1][1]:find("@grace", 1, true))
    assert.is_truthy(details.virt_lines[1][1][1]:find("read-only", 1, true))
  end)

  it("keeps the marks of the local comments", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local store = assert(comments_mod.store(review))
    assert(store:add({ file = "call.lua", start_line = 2, end_line = 2, side = "new", body = "mine" }))

    local state = open_diff("call.lua")
    assert.are.equal(1, #marks(state.buf))
    assert.is_true(#comments_mod.marks(state.buf) > 0)
  end)

  it("drops the copy of a comment that a submit sent", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    local comment = assert(store:add({
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      body = "this line needs a test",
    }))
    assert(store:mark_synced(comment.id, { review_id = "77" }))
    remote.attach(review, { remote_comment({ review_id = "77" }), remote_comment({ id = 502, body = "another one" }) })

    local held = remote.list(review)
    assert.are.equal(1, #held)
    assert.are.equal(502, held[1].id)

    local state = open_diff("call.lua")
    assert.are.equal(1, #marks(state.buf))
  end)

  it("keeps the comment of GitHub while the local comment is not sent", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    assert(store:add({
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      body = "this line needs a test",
    }))
    remote.attach(review, { remote_comment() })
    assert.are.equal(1, #remote.list(review))
  end)

  it("keeps the comment of GitHub after an edit of the local text", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    local comment = assert(store:add({
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      body = "this line needs a test",
    }))
    assert(store:mark_synced(comment.id, { review_id = "77" }))
    assert(store:update(comment.id, { body = "this line needs two tests" }))
    remote.attach(review, { remote_comment({ review_id = "77" }) })
    assert.are.equal(1, #remote.list(review))
  end)

  it("marks a comment of an older push", function()
    local review = open_session()
    remote.attach(review, { remote_comment({ outdated = true }) })
    local state = open_diff("call.lua")

    local details = marks(state.buf)[1][4]
    assert.are.equal("CodeViewRemoteOutdated", details.sign_hl_group)
    assert.is_truthy(details.virt_lines[1][1][1]:find("outdated", 1, true))
  end)

  it("draws the comments that arrive after the file is open", function()
    local review = open_session()
    local state = open_diff("call.lua")
    assert.are.equal(0, #marks(state.buf))

    remote.attach(review, { remote_comment() })
    assert.are.equal(1, #marks(state.buf))
  end)

  it("shows a remote comment in the float", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local state = open_diff("call.lua")
    api.nvim_win_set_cursor(state.win, { 4, 0 })

    local buf = assert(comments_mod.show())
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("@grace", 1, true), text)
    assert.is_truthy(text:find("this line needs a test", 1, true), text)
  end)

  it("says in the diff that a remote comment does not change", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local state = open_diff("call.lua")
    api.nvim_win_set_cursor(state.win, { 4, 0 })

    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    local edited = comments_mod.edit()
    vim.notify = notify

    assert.is_false(edited)
    assert.are.equal(1, #seen)
    assert.is_truthy(seen[1]:find("read-only", 1, true), seen[1])
  end)

  it("lists the remote comments in the overview", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment(), remote_comment({ id = 502, file = "tail.txt", start_line = 40 }) })

    local text = table.concat(bar.panel:lines(), "\n")
    assert.is_truthy(text:find("2 remote comments", 1, true), text)
    assert.is_truthy(text:find("call.lua", 1, true), text)

    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))
    local comment = assert(bar:cursor_remote())
    assert.are.equal(501, comment.id)
    assert.are.equal(2, #bar:remote())
  end)

  it("keeps the remote comments out of the local section", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment() })

    assert.are.equal(0, #bar:comments())
    local text = table.concat(bar.panel:lines(), "\n")
    assert.is_truthy(text:find("no comments", 1, true), text)
  end)

  it("does not edit, delete, or resolve a remote comment", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment() })

    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))

    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    local edited = bar:edit()
    local removed = bar:remove({ confirm = false })
    local state = bar:set_state()
    vim.notify = notify

    assert.is_false(edited)
    assert.is_false(removed)
    assert.is_nil(state)
    assert.are.equal(3, #seen)
    assert.is_truthy(seen[1]:find("read-only", 1, true), seen[1])
  end)

  it("jumps from the overview to the line of a remote comment", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment() })

    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))

    local finished = false
    bar:open_cursor(function()
      finished = true
    end)
    assert.is_true(
      vim.wait(20000, function()
        return finished
      end, 10),
      "the jump did not answer"
    )

    local state = assert(view.current())
    assert.are.equal("call.lua", state.path)
    assert.are.equal(4, api.nvim_win_get_cursor(state.win)[1])
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
