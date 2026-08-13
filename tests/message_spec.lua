local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.message", function()
  local fixture = fixtures.git_comments()
  local comments, config, editor, message, session_mod, view
  ---@type string
  local dir
  ---@type codeview.Session?
  local opened

  ---Text of the range of the fixture.
  ---@return string
  local function spec()
    return fixture.ids.base .. ".." .. fixture.ids.change
  end

  ---Open a session on the fixture range.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(spec(), { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return review
  end

  ---Open the document of the newest commit of a session.
  ---@param session codeview.Session
  ---@return codeview.view.State
  local function open_commit(session)
    local path = message.path_of(session.commits[1].id)
    local index = assert(session:index_of(path), "no commit entry for " .. path)
    local state = assert(view.open(session, index))
    api.nvim_set_current_win(state.win)
    return state
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = fixtures.tempdir("codeview-message")
    assert(config.setup({ comments = { dir = dir } }))
    comments = require("codeview.comments")
    editor = require("codeview.editor")
    message = require("codeview.message")
    session_mod = require("codeview.session")
    view = require("codeview.view")
  end)

  after_each(function()
    editor.cancel()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  describe("the file list", function()
    it("holds one entry per commit, before the files", function()
      local session = open_session()
      local count = #session.commits
      for index = 1, count do
        local entry = session.files[index]
        assert.is_true(entry.virtual)
        assert.is_true(message.is(entry.path))
      end
      assert.is_not_true(session.files[count + 1].virtual)
    end)

    it("reads the commits from the oldest to the newest", function()
      local session = open_session()
      -- The session holds the commits newest first, so the first entry is the
      -- oldest commit.
      local oldest = session.commits[#session.commits]
      assert.are.equal(message.path_of(oldest.id), session.files[1].path)
    end)

    it("names an entry with the short id and the subject", function()
      local session = open_session()
      local commit = session.commits[#session.commits]
      assert.are.equal(commit.short_id .. " " .. commit.subject, session.files[1].label)
    end)

    it("keeps the commits out of the file count", function()
      local session = open_session()
      assert.are.equal(#session.files - #session.commits, session:changed_count())
      assert.is_truthy(session:summary():find(session:changed_count() .. " file", 1, true))
    end)

    it("leaves the commits out when the option says so", function()
      assert(config.setup({ comments = { dir = dir }, commit_message = false }))
      local session = open_session()
      for _, file in ipairs(session.files) do
        assert.is_false(message.is(file.path))
      end
    end)
  end)

  describe("the sidebar", function()
    it("groups the commits under one node", function()
      local session = open_session()
      local sidebar = require("codeview.sidebar")
      sidebar.open({ session = session })
      local lines = assert(sidebar.get()).panel:lines()

      -- The range, the counts, a blank line, the Comments line, and a blank
      -- line come first. The group node of the commits follows them.
      local head = 5
      assert.is_truthy(lines[head + 1]:find(message.group_label(#session.commits), 1, true), lines[head + 1])
      local oldest = session.commits[#session.commits]
      assert.is_truthy(lines[head + 2]:find(oldest.subject, 1, true), lines[head + 2])
    end)
  end)

  describe("the document", function()
    it("holds the header and the message of the commit", function()
      local session = open_session()
      local state = open_commit(session)
      local commit = session.commits[1]
      local text = table.concat(api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")

      assert.is_truthy(text:find(commit.id, 1, true))
      assert.is_truthy(text:find(commit.author, 1, true))
      assert.is_truthy(text:find(commit.subject, 1, true))
    end)

    it("lists the files that the commit changes", function()
      local session = open_session()
      local state = open_commit(session)
      local text = table.concat(api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")

      assert.is_truthy(text:find("changed file", 1, true), text)
      assert.is_true(#state.diff.files > 0)
      for _, file in ipairs(state.diff.files) do
        assert.is_truthy(text:find(file.path, 1, true), "no line for " .. file.path)
      end
    end)

    it("renders without a diff and stays read-only", function()
      local session = open_session()
      local state = open_commit(session)
      assert.is_true(state.diff.message)
      assert.is_false(vim.bo[state.buf].modifiable)
    end)

    it("maps every row to a line of the document", function()
      local session = open_session()
      local state = open_commit(session)
      for row = 1, api.nvim_buf_line_count(state.buf) do
        assert.are.equal(row, state.map:file_line(row, "new"))
      end
    end)

    it("keeps the inline style", function()
      assert(config.setup({ comments = { dir = dir }, diff = { style = "split" } }))
      local session = open_session()
      local state = open_commit(session)
      assert.are.equal("inline", state.style)
      assert.is_nil(state.old_win)
    end)
  end)

  describe("comments", function()
    it("anchors a comment to the commit of the document", function()
      local session = open_session()
      local state = open_commit(session)

      api.nvim_win_set_cursor(state.win, { 1, 0 })
      assert.is_true(comments.add({ view = state }))
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "a note on the message" })
      assert.is_true(editor.submit())

      local comment = comments.list(session)[1]
      assert.are.equal(message.path_of(session.commits[1].id), comment.file)
      assert.are.equal(session.commits[1].id, comment.commit)
      assert.are.equal(1, comment.start_line)
      assert.are.equal("new", comment.side)
    end)

    it("keeps the document read-only through the flow", function()
      local session = open_session()
      local state = open_commit(session)
      local rows = api.nvim_buf_line_count(state.buf)
      local text = api.nvim_buf_get_lines(state.buf, 0, -1, false)

      api.nvim_win_set_cursor(state.win, { 1, 0 })
      comments.add({ view = state })
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "a note" })
      editor.submit()

      assert.are.equal(rows, api.nvim_buf_line_count(state.buf))
      assert.are.same(text, api.nvim_buf_get_lines(state.buf, 0, -1, false))
      assert.is_false(vim.bo[state.buf].modifiable)
    end)

    it("finds the comment again after a reopen", function()
      local session = open_session()
      local state = open_commit(session)
      api.nvim_win_set_cursor(state.win, { 1, 0 })
      comments.add({ view = state })
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "a note" })
      editor.submit()

      view.close()
      session:close()
      opened = nil
      session_mod.close()

      local again = open_session()
      local held = comments.list(again)
      assert.are.equal(1, #held)
      assert.is_true(message.is(held[1].file))
    end)
  end)

  describe("the export", function()
    it("names the commit instead of its path", function()
      local session = open_session()
      local state = open_commit(session)
      api.nvim_win_set_cursor(state.win, { 1, 0 })
      comments.add({ view = state })
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "a note" })
      editor.submit()

      local text = assert(require("codeview.export").render({ session = session }))
      assert.is_truthy(text:find("## " .. session.commits[1].short_id, 1, true), text)
      assert.is_nil(text:find(message.prefix, 1, true))
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
