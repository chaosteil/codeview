-- The selected comment box: `]c` and the cursor select one box, and the box
-- shows in the group of the selection.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.select", function()
  local fixture = fixtures.git_comments()
  local comments, config, remote, select, session_mod, view
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

  ---Add one local comment on the new side of call.lua.
  ---@param line integer
  ---@param fields? table
  ---@return codeview.store.Comment
  local function add_comment(line, fields)
    return assert(comments.create(
      open_session(),
      vim.tbl_extend("force", {
        file = "call.lua",
        start_line = line,
        end_line = line,
        side = "new",
        commit = fixture.ids.change,
        body = "a note on line " .. line,
      }, fields or {})
    ))
  end

  ---Comment of GitHub on the new line 2 of call.lua.
  ---@param fields? table
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
      reactions = {},
    }, fields or {})
  end

  ---Open the diff of call.lua, with the cursor on one new line.
  ---@param line integer
  ---@return codeview.view.State
  local function open_diff(line)
    local review = open_session()
    local state = assert(view.open(review, assert(review:index_of("call.lua"))))
    api.nvim_set_current_win(state.win)
    api.nvim_win_set_cursor(state.win, { assert(state.map:buf_row(line, "new")), 0 })
    return state
  end

  ---Run one jump and wait for its answer.
  ---@param fn fun(session: codeview.Session, cb: fun(view: codeview.view.State?, err: codeview.Error?))
  ---@return codeview.Error? err
  local function jump(fn)
    local finished, out = false, nil
    fn(open_session(), function(_, err)
      finished, out = true, err
    end)
    assert.is_true(vim.wait(20000, function()
      return finished
    end, 10))
    return out
  end

  ---Virtual lines of the boxes of a buffer, with the group of each chunk.
  ---@param buf integer
  ---@return { text: string, groups: string[] }[] lines
  local function box_lines(buf)
    local out = {}
    for _, mark in ipairs(require("codeview.stack").marks(buf)) do
      for _, line in ipairs(mark[4].virt_lines or {}) do
        local text, groups = "", {}
        for _, chunk in ipairs(line) do
          text = text .. chunk[1]
          local hl = chunk[2]
          groups[#groups + 1] = type(hl) == "table" and hl[1] or hl
        end
        out[#out + 1] = { text = text, groups = groups }
      end
    end
    return out
  end

  ---Lines of the boxes that show in the group of the selection.
  ---@param buf integer
  ---@return string[] texts
  local function selected_lines(buf)
    local out = {}
    for _, line in ipairs(box_lines(buf)) do
      if vim.tbl_contains(line.groups, select.hl) then
        out[#out + 1] = line.text
      end
    end
    return out
  end

  before_each(function()
    helpers.unload()
    dir = fixtures.tempdir("codeview-select")
    config = require("codeview.config")
    assert(config.setup({ commit_message = false, quit = "never", comments = { dir = dir } }))
    comments = require("codeview.comments")
    remote = require("codeview.remote")
    select = require("codeview.select")
    session_mod = require("codeview.session")
    view = require("codeview.view")
  end)

  after_each(function()
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

  it("defines the group of the selection", function()
    require("codeview.highlight").setup()
    local found = api.nvim_get_hl(0, { name = "CodeViewCommentSelected" })
    assert.are.equal("DiagnosticWarn", found.link)
  end)

  it("selects the box that ]c stops at, and draws it in the group of the selection", function()
    local first = add_comment(1, { body = "first note" })
    add_comment(2, { body = "second note" })
    assert.is_nil(jump(view.next_comment))
    local selection = assert(select.get(open_session()))
    assert.are.same({ kind = "local", id = first.id, file = "call.lua" }, selection)

    local state = assert(view.current())
    local lines = selected_lines(state.buf)
    -- The top border with the header and the bottom border take the group.
    assert.are.equal(3, #lines)
    assert.is_truthy(lines[1]:find("comment L1", 1, true))
    for _, line in ipairs(box_lines(state.buf)) do
      if line.text:find("second note", 1, true) then
        assert.is_false(vim.tbl_contains(line.groups, select.hl))
      end
    end
  end)

  it("follows the cursor", function()
    local first = add_comment(1)
    local second = add_comment(2)
    local state = open_diff(2)
    assert.are.equal(second.id, assert(select.follow(state)).id)

    api.nvim_win_set_cursor(state.win, { assert(state.map:buf_row(1, "new")), 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
    assert.are.equal(first.id, assert(select.get(open_session())).id)

    -- A row without a box clears the selection, and no box shows the group.
    api.nvim_win_set_cursor(state.win, { assert(state.map:buf_row(4, "new")), 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
    assert.is_nil(select.get(open_session()))
    assert.are.same({}, selected_lines(state.buf))
  end)

  it("keeps the selected box of a row with two boxes", function()
    add_comment(2)
    local second = add_comment(2)
    local state = open_diff(2)
    assert.is_true(select.set(open_session(), { kind = "local", id = second.id, file = "call.lua" }))
    api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
    assert.are.equal(second.id, assert(select.get(open_session())).id)
  end)

  it("selects a thread of GitHub at its first comment", function()
    remote.attach(open_session(), {
      remote_comment(),
      remote_comment({ id = 502, reply_to = 501, created_at = 1, author = "ada", body = "a reply" }),
    })
    assert.is_nil(jump(view.next_comment))
    local selection = assert(select.get(open_session()))
    assert.are.equal("thread", selection.kind)
    assert.are.equal("501", selection.id)
    assert.are.equal("remote:501", selection.sub)

    -- The frame and the header of the first comment take the group. The
    -- header of the reply does not.
    local state = assert(view.current())
    local headers = {}
    for _, line in ipairs(box_lines(state.buf)) do
      if line.text:find("@grace", 1, true) or line.text:find("@ada", 1, true) then
        -- The chunks of a header line: the left border, the header, the rest.
        headers[#headers + 1] = line.groups[2]
      end
    end
    assert.are.same({ select.hl, "CodeViewRemoteHeader" }, headers)
  end)

  it("makes a local reply a part of the box of its thread", function()
    remote.attach(open_session(), { remote_comment() })
    add_comment(2, { reply_to = "501", body = "a draft reply" })
    local stops = select.stops(open_session())["call.lua"]
    assert.are.equal(1, #stops)
    assert.are.equal("thread", stops[1].kind)
  end)

  it("stops at an item of pr-agent", function()
    local agent = require("codeview.agent")
    agent.items = function() ---@diagnostic disable-line: duplicate-set-field
      return {
        {
          id = "improve:1",
          kind = "suggestion",
          file = "call.lua",
          start_line = 2,
          end_line = 2,
          side = "new",
          author = "",
          label = "possible issue",
          body = "Use the next number.",
          outdated = false,
          anchored = true,
        },
      }
    end
    assert.is_nil(jump(view.next_comment))
    local selection = assert(select.get(open_session()))
    assert.are.same({ kind = "agent", id = "improve:1", file = "call.lua" }, selection)
    local state = assert(view.current())
    assert.is_truthy(selected_lines(state.buf)[1]:find("pr-agent", 1, true))
  end)

  describe("in a thread", function()
    ---Thread of three comments of GitHub and one draft reply on line 2.
    ---@param fields? table Fields of the first comment.
    ---@return codeview.store.Comment draft
    local function thread_of_three(fields)
      remote.attach(open_session(), {
        remote_comment(fields),
        remote_comment({ id = 502, reply_to = 501, created_at = 1, author = "ada", body = "a reply" }),
        remote_comment({ id = 503, reply_to = 501, created_at = 2, author = "grace", body = "an answer" }),
      })
      return add_comment(2, { reply_to = "501", body = "a draft reply" })
    end

    it("moves the selection from comment to comment", function()
      local draft = thread_of_three()
      local state = open_diff(2)
      select.follow(state)
      local subs = { assert(select.get(open_session())).sub }
      for _ = 1, 3 do
        assert.is_truthy((select.step_in_thread(state, 1)))
        subs[#subs + 1] = assert(select.get(open_session())).sub
      end
      -- The draft reply is the newest comment, so it comes last.
      assert.are.same({ "remote:501", "remote:502", "remote:503", "local:" .. draft.id }, subs)

      local sub, message = select.step_in_thread(state, 1)
      assert.is_nil(sub)
      assert.are.equal("no comment after this one in the thread", message)
      assert.are.equal("remote:503", select.step_in_thread(state, -1))
    end)

    it("draws the header of the selected comment in the group of the selection", function()
      thread_of_three()
      local state = open_diff(2)
      select.follow(state)
      select.step_in_thread(state, 1)
      local headers = {}
      for _, line in ipairs(box_lines(state.buf)) do
        if line.groups[2] == select.hl then
          headers[#headers + 1] = line.text
        end
      end
      assert.are.equal(1, #headers)
      assert.is_truthy(headers[1]:find("@ada", 1, true))
    end)

    it("shows the comments of a resolved thread", function()
      thread_of_three({
        thread = {
          id = "PRRT_1",
          resolved = true,
          resolved_by = "ada",
          can_resolve = false,
          can_unresolve = true,
          can_reply = true,
        },
      })
      local state = open_diff(2)
      select.follow(state)
      -- A resolved thread shows its header line only, so no comment is
      -- selected yet.
      assert.is_nil(assert(select.get(open_session())).sub)
      assert.are.equal("remote:501", select.step_in_thread(state, 1))
      local thread = assert(remote.thread_by_key(open_session(), "501"))
      assert.is_true(remote.is_expanded(open_session(), thread))
    end)

    it("reports a selection without a thread", function()
      add_comment(1)
      local state = open_diff(1)
      select.follow(state)
      local sub, message = select.step_in_thread(state, 1)
      assert.is_nil(sub)
      assert.are.equal("no thread of GitHub is selected", message)
    end)

    it("moves with the keys of the diff view", function()
      thread_of_three()
      local state = open_diff(2)
      select.follow(state)
      api.nvim_feedkeys("]t", "x", false)
      assert.are.equal("remote:502", assert(select.get(open_session())).sub)
      api.nvim_feedkeys("[t", "x", false)
      assert.are.equal("remote:501", assert(select.get(open_session())).sub)
    end)
  end)

  it("drops the selection when the session closes", function()
    local comment = add_comment(1)
    local review = open_session()
    select.set(review, { kind = "local", id = comment.id, file = "call.lua" })
    review:close()
    assert.is_nil(select.get(review))
  end)
end)
