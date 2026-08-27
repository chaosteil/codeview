local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.overview", function()
  local fixture = fixtures.git_comments()
  local comments, config, editor, events, overview, panel, session_mod, store_mod, view
  ---@type string
  local dir
  ---@type codeview.Session?
  local opened

  ---Text of the range of the fixture.
  ---@return string
  local function spec()
    return fixture.ids.base .. ".." .. fixture.ids.change
  end

  ---Short commit id of the new side, as the overview shows it.
  ---@return string
  local function rev()
    return fixture.ids.change:sub(1, 7)
  end

  ---Wait until a check answers true.
  ---@param check fun(): boolean
  ---@param message string
  local function wait_for(check, message)
    assert.is_true(vim.wait(20000, check, 10), message)
  end

  ---Press a key in the window that has the focus.
  ---@param lhs string
  local function press(lhs)
    api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
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

  ---Add one comment to the store of the session.
  ---@param fields table Fields of the comment. `file` and `body` are needed.
  ---@return codeview.store.Comment
  local function add_comment(fields)
    local store = assert(comments.store(open_session()))
    local comment = assert(store:add(vim.tbl_extend("keep", fields, {
      side = "new",
      commit = fixture.ids.change,
      body = "a note",
    })))
    assert.is_true(store:save())
    return comment
  end

  ---Open the comment overview of the session.
  ---@param opts? table
  ---@return codeview.Overview
  local function open_overview(opts)
    open_session()
    local bar, err = overview.open(opts)
    assert.is_nil(err)
    return assert(bar)
  end

  ---Show the diff of one file of the session.
  ---@param path string
  ---@return codeview.view.State
  local function open_diff(path)
    local review = open_session()
    local state = assert(view.open(review, assert(review:index_of(path))))
    api.nvim_set_current_win(state.win)
    return state
  end

  ---Write a body into the comment editor and save it.
  ---@param body string
  local function write_comment(body)
    local state = assert(editor.current())
    api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
    assert.is_true(editor.submit())
  end

  ---Line of one comment in the overview.
  ---@param bar codeview.Overview
  ---@param id string
  ---@return integer lnum
  local function line_of(bar, id)
    local lnum = bar.panel:find(function(item)
      return item.kind == "comment" and item.comment.id == id
    end)
    assert.is_truthy(lnum, "no line for the comment " .. id)
    return lnum
  end

  ---Line of one file node in the overview.
  ---@param bar codeview.Overview
  ---@param path string
  ---@return integer lnum
  local function file_line(bar, path)
    local lnum = bar.panel:find(function(item)
      return item.kind ~= "comment" and item.path == path
    end)
    assert.is_truthy(lnum, "no line for " .. path)
    return lnum
  end

  ---Extmark details of one line of the panel.
  ---@param bar codeview.Overview
  ---@param lnum integer
  ---@return table[]
  local function marks_of(bar, lnum)
    local buf = assert(bar.panel:buffer())
    return api.nvim_buf_get_extmarks(buf, panel.ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
  end

  ---Highlight group at one column of one line.
  ---@param bar codeview.Overview
  ---@param lnum integer
  ---@param col integer Column, in bytes, from 0.
  ---@return string? group
  local function hl_at(bar, lnum, col)
    for _, mark in ipairs(marks_of(bar, lnum)) do
      local details = mark[4]
      if details.hl_group and mark[3] <= col and (details.end_col or 0) > col then
        return details.hl_group
      end
    end
    return nil
  end

  ---Highlight group of a part of a line.
  ---@param bar codeview.Overview
  ---@param lnum integer
  ---@param needle string Text inside the line.
  ---@return string? group
  local function hl_of(bar, lnum, needle)
    local from = bar.panel:lines()[lnum]:find(needle, 1, true)
    assert.is_truthy(from, needle .. " is not in line " .. lnum)
    return hl_at(bar, lnum, from - 1)
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = fixtures.tempdir("codeview-overview")
    assert(config.setup({ comments = { dir = dir } }))
    comments = require("codeview.comments")
    editor = require("codeview.editor")
    events = require("codeview.events")
    overview = require("codeview.overview")
    panel = require("codeview.panel")
    session_mod = require("codeview.session")
    store_mod = require("codeview.store")
    view = require("codeview.view")
  end)

  after_each(function()
    editor.cancel()
    overview.close()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    events.clear()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  describe("open", function()
    it("needs a session", function()
      local bar, err = overview.open()
      assert.is_nil(bar)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("opens a second panel window for the session that runs", function()
      local review = open_session()
      local bar = assert(overview.open())
      assert.are.equal(review, bar.session)
      assert.is_true(bar:is_open())
      assert.is_true(panel.is_panel_win(assert(bar.panel:window())))
      assert.are.equal("codeview-comments", vim.bo[assert(bar.panel:buffer())].filetype)
      assert.are.equal(bar, overview.get())
      assert.is_true(overview.is_open())
    end)

    it("takes the width and the side from the configuration", function()
      assert(config.setup({ comments = { dir = dir }, overview = { width = 30, position = "left" } }))
      local bar = open_overview()
      local win = assert(bar.panel:window())
      assert.are.equal(30, api.nvim_win_get_width(win))
      assert.are.equal(0, api.nvim_win_get_position(win)[2])
    end)

    it("stands next to the changed-files sidebar", function()
      local sidebar = require("codeview.sidebar")
      open_session()
      local files = assert(sidebar.open())
      local bar = open_overview()
      local win = assert(files.panel:window())
      assert.are_not.equal(win, bar.panel:window())
      assert.is_true(api.nvim_win_is_valid(win))
      sidebar.close()
    end)

    it("returns the same overview for the same session", function()
      local bar = open_overview()
      assert.are.equal(bar, assert(overview.open()))
    end)

    it("lets the session own the window and the buffer", function()
      local bar = open_overview()
      local win = assert(bar.panel:window())
      local buf = assert(bar.panel:buffer())

      assert(opened):close()
      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_false(api.nvim_buf_is_valid(buf))
      assert.is_nil(overview.get())
    end)
  end)

  describe("the render", function()
    it("reports an empty session", function()
      local bar = open_overview()
      local lines = bar.panel:lines()
      assert.are.equal(assert(opened):label(), lines[1])
      assert.are.equal("no comments", lines[2])
      assert.are.equal("", lines[3])
      assert.are.equal("  no comments", lines[4])
      assert.are.equal(4, #lines)
    end)

    it("groups the comments under the file tree", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "the first note" })
      add_comment({ file = "call.lua", start_line = 2, end_line = 3, side = "old", body = "two lines" })
      add_comment({ file = "lua/deep/util.lua", start_line = 5, end_line = 5, state = "resolved", body = "done" })

      local bar = open_overview()
      assert.are.same({
        assert(opened):label(),
        "3 comments, 1 resolved",
        "",
        "  ▾ lua/deep 1",
        "  │ ▾ util.lua 1",
        "  │ │ ✓ L5 new " .. rev() .. " done",
        "  ▾ call.lua 2",
        "  │ ▌ L1 new " .. rev() .. " the first note",
        "  │ ▌ L2-3 old " .. rev() .. " two lines",
      }, bar.panel:lines())
    end)

    it("counts one comment in the singular", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()
      assert.are.equal("1 comment", bar.panel:lines()[2])
    end)

    it("keeps the item of the line in the line data", function()
      local comment = add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()

      local file = bar.panel:data(file_line(bar, "call.lua"))
      assert.are.equal("file", file.kind)
      assert.are.equal(1, file.count)

      local item = bar.panel:data(line_of(bar, comment.id))
      assert.are.equal("comment", item.kind)
      assert.are.equal(comment.id, item.comment.id)
      assert.is_nil(bar.panel:data(1))
    end)

    it("highlights the state, the range, and the tree", function()
      local open = add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local done = add_comment({ file = "call.lua", start_line = 4, end_line = 4, state = "resolved" })
      local bar = open_overview()

      local first = line_of(bar, open.id)
      assert.are.equal("CodeViewCommentSign", hl_of(bar, first, "▌"))
      assert.are.equal("CodeViewCommentHeader", hl_of(bar, first, "L1"))
      assert.are.equal("CodeViewIndent", hl_of(bar, first, "│"))
      assert.is_nil(marks_of(bar, first)[1][4].line_hl_group)

      local second = line_of(bar, done.id)
      assert.are.equal("CodeViewCommentResolved", hl_of(bar, second, "✓"))
      assert.are.equal("CodeViewComment", marks_of(bar, second)[1][4].line_hl_group)

      local file = file_line(bar, "call.lua")
      assert.are.equal("CodeViewCount", hl_of(bar, file, "2"))
    end)

    it("cuts a long body preview to the width of the panel", function()
      assert(config.setup({ comments = { dir = dir }, overview = { width = 40 } }))
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = string.rep("word ", 30) })
      local bar = open_overview()

      local text = bar.panel:lines()[line_of(bar, assert(comments.list())[1].id)]
      assert.is_true(vim.fn.strdisplaywidth(text) <= 40, "the line is not wider than the panel: " .. text)
      assert.are.equal("…", text:sub(-3))
    end)

    it("shows the first line of a body with more lines", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "\nthe head\nthe tail" })
      local bar = open_overview()
      assert.are.equal("  │ ▌ L1 new " .. rev() .. " the head", bar.panel:lines()[5])
    end)

    it("marks the file that the diff view shows", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()
      assert.are.equal("  ▾ call.lua 1", bar.panel:lines()[file_line(bar, "call.lua")])

      open_diff("call.lua")
      local lnum = file_line(bar, "call.lua")
      assert.are.equal("▸ ▾ call.lua 1", bar.panel:lines()[lnum])
      assert.are.equal("CodeViewCurrent", marks_of(bar, lnum)[1][4].line_hl_group)
    end)

    it("renders again after a refresh of the session", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()
      local review = assert(opened)
      api.nvim_exec_autocmds("User", { pattern = "CodeViewSessionRefreshed", data = { id = review.id } })
      assert.are.equal("1 comment", bar.panel:lines()[2])
    end)
  end)

  describe("expand and collapse", function()
    it("hides the comments of a file", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      add_comment({ file = "call.lua", start_line = 2, end_line = 2 })
      local bar = open_overview()
      assert.are.equal(6, #bar.panel:lines())

      bar.panel:set_cursor(file_line(bar, "call.lua"))
      assert.is_true(bar:toggle_node())
      assert.are.equal("  ▸ call.lua 2", bar.panel:lines()[4])
      assert.are.equal(4, #bar.panel:lines())
      assert.is_false(bar.expanded["call.lua"])
    end)

    it("acts on the file of a comment line", function()
      local comment = add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()
      bar.panel:set_cursor(line_of(bar, comment.id))
      assert.is_true(bar:toggle_node())
      assert.are.equal("  ▸ call.lua 1", bar.panel:lines()[4])
      local win = assert(bar.panel:window())
      assert.are.equal(file_line(bar, "call.lua"), api.nvim_win_get_cursor(win)[1])
    end)

    it("collapses and expands every node with zM and zR", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      add_comment({ file = "lua/deep/util.lua", start_line = 5, end_line = 5 })
      local bar = open_overview({ focus = true })

      press("zM")
      assert.are.same({ "  ▸ lua/deep 1", "  ▸ call.lua 1" }, vim.list_slice(bar.panel:lines(), 4))

      press("zR")
      assert.are.equal(8, #bar.panel:lines())
      assert.are.same({}, bar.expanded)
    end)

    it("toggles a directory with <CR>", function()
      add_comment({ file = "lua/deep/util.lua", start_line = 5, end_line = 5 })
      local bar = open_overview({ focus = true })
      bar.panel:set_cursor(file_line(bar, "lua/deep"))
      press("<CR>")
      assert.are.equal("  ▸ lua/deep 1", bar.panel:lines()[4])
      assert.is_nil(view.current())
    end)
  end)

  describe("jump to the comment", function()
    it("opens the file diff and moves the cursor to the anchor", function()
      local comment = add_comment({ file = "call.lua", start_line = 2, end_line = 2, side = "old" })
      local bar = open_overview({ focus = true })
      bar.panel:set_cursor(line_of(bar, comment.id))
      press("<CR>")

      wait_for(function()
        return view.current() ~= nil
      end, "the diff did not open")
      local state = assert(view.current())
      assert.are.equal("call.lua", state.path)

      -- Row 3 of the inline diff is `-local b = 2`, line 2 of the old side.
      assert.are.equal(state.win, api.nvim_get_current_win())
      local row = api.nvim_win_get_cursor(state.win)[1]
      assert.are.equal(3, row)
      assert.are.equal(2, state.map:file_line(row, "old"))
    end)

    it("moves the cursor in the file that is open already", function()
      local first = add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local last = add_comment({ file = "call.lua", start_line = 4, end_line = 4 })
      local state = open_diff("call.lua")
      local bar = open_overview()

      assert.is_true(bar:jump(last))
      assert.are.equal(4, state.map:file_line(api.nvim_win_get_cursor(state.win)[1], "new"))
      assert.is_true(bar:jump(first))
      assert.are.equal(1, state.map:file_line(api.nvim_win_get_cursor(state.win)[1], "new"))
    end)

    it("opens the diff again after the user closes the window", function()
      local comment = add_comment({ file = "call.lua", start_line = 4, end_line = 4 })
      local state = open_diff("call.lua")
      local bar = open_overview()

      api.nvim_win_close(state.win, true)
      assert.is_nil(view.current())

      assert.is_true(bar:jump(comment))
      wait_for(function()
        return view.current() ~= nil
      end, "the diff did not open again")
      state = assert(view.current())
      assert.are.equal("call.lua", state.path)
      assert.are.equal(4, state.map:file_line(api.nvim_win_get_cursor(state.win)[1], "new"))
    end)

    it("shows the lines of a collapsed section", function()
      -- The render of tail.txt hides the lines 1 to 33 behind one filler row.
      local comment = add_comment({ file = "tail.txt", start_line = 2, end_line = 2 })
      local state = open_diff("tail.txt")
      assert.are.equal("filler", state.map:kind(1))
      assert.is_nil(state.map:buf_row(2, "new"))

      local bar = open_overview()
      assert.is_true(bar:jump(comment))

      state = assert(view.current())
      local row = api.nvim_win_get_cursor(state.win)[1]
      assert.are.equal(2, state.map:file_line(row, "new"))
    end)

    it("opens the first comment of a file line", function()
      add_comment({ file = "call.lua", start_line = 4, end_line = 4 })
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview({ focus = true })
      bar.panel:set_cursor(file_line(bar, "call.lua"))
      press("<CR>")

      wait_for(function()
        return view.current() ~= nil
      end, "the diff did not open")
      local state = assert(view.current())
      assert.are.equal(1, state.map:file_line(api.nvim_win_get_cursor(state.win)[1], "new"))
    end)

    it("reports a file that the range does not change", function()
      local comment = add_comment({ file = "gone.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()
      local err
      assert.is_false(bar:jump(comment, function(_, jump_err)
        err = jump_err
      end))
      assert.are.equal("not_found", err.code)
      assert.is_nil(view.current())

      -- The dim name reports that the jump key cannot open the file.
      local lnum = file_line(bar, "gone.lua")
      assert.is_true(bar.panel:data(lnum).missing)
      assert.are.equal("CodeViewHint", hl_of(bar, lnum, "gone.lua"))
    end)
  end)

  describe("manage the comments", function()
    it("edits the comment under the cursor", function()
      local comment = add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "the first text" })
      local bar = open_overview({ focus = true })
      bar.panel:set_cursor(line_of(bar, comment.id))

      press("<leader>ce")
      assert.is_true(editor.is_open())
      assert.are.same({ "the first text" }, api.nvim_buf_get_lines(assert(editor.current()).buf, 0, -1, false))
      write_comment("the second text")

      local store = assert(comments.store(opened))
      assert.are.equal("the second text", store.comments[1].body)
      assert.are.equal(
        "the second text",
        assert(store_mod.load({ repo = fixture.root, range = store.range })).comments[1].body
      )
      assert.are.equal("  │ ▌ L1 new " .. rev() .. " the second text", bar.panel:lines()[line_of(bar, comment.id)])
    end)

    it("deletes the comment under the cursor", function()
      local comment = add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview({ focus = true })
      bar.panel:set_cursor(line_of(bar, comment.id))

      local calls = 0
      local confirm = vim.fn.confirm
      vim.fn.confirm = function()
        calls = calls + 1
        return 1
      end
      press("<leader>cd")
      vim.fn.confirm = confirm

      assert.are.equal(1, calls)
      local store = assert(comments.store(opened))
      assert.are.equal(0, store:count())
      assert.are.equal(0, assert(store_mod.load({ repo = fixture.root, range = store.range })):count())
      assert.are.equal("  no comments", bar.panel:lines()[4])
    end)

    it("keeps the comment when the question gets no yes", function()
      local comment = add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()
      bar.panel:set_cursor(line_of(bar, comment.id))

      local confirm = vim.fn.confirm
      vim.fn.confirm = function()
        return 2
      end
      local removed = bar:remove()
      vim.fn.confirm = confirm

      assert.is_false(removed)
      assert.are.equal(1, assert(comments.store(opened)):count())
    end)

    it("resolves and reopens the comment under the cursor", function()
      local comment = add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "please rename" })
      local bar = open_overview({ focus = true })
      bar.panel:set_cursor(line_of(bar, comment.id))

      press("<leader>cr")
      local store = assert(comments.store(opened))
      assert.are.equal("resolved", store.comments[1].state)
      assert.are.equal("1 comment, 1 resolved", bar.panel:lines()[2])
      assert.are.equal("  │ ✓ L1 new " .. rev() .. " please rename", bar.panel:lines()[line_of(bar, comment.id)])
      assert.are.equal(
        "resolved",
        assert(store_mod.load({ repo = fixture.root, range = store.range })).comments[1].state
      )

      press("<leader>cr")
      assert.are.equal("open", assert(comments.store(opened)).comments[1].state)
      assert.are.equal("1 comment", bar.panel:lines()[2])
    end)

    it("reports a line without a comment", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local bar = open_overview()
      bar.panel:set_cursor(1)
      assert.is_false(bar:edit())
      assert.is_false(bar:remove({ confirm = false }))
      assert.is_nil(bar:set_state())
      assert.is_false(bar:open_cursor())
    end)
  end)

  describe("the export keys", function()
    ---Set the register of the export to a register that needs no clipboard.
    local function with_register()
      assert(config.setup({ comments = { dir = dir }, export = { register = "z" } }))
      vim.fn.setreg("z", "")
    end

    it("shows the markdown of the comments in a scratch buffer", function()
      with_register()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "please rename" })
      local bar = open_overview({ focus = true })

      press("<leader>cx")
      local buf = api.nvim_get_current_buf()
      assert.are.equal("markdown", vim.bo[buf].filetype)
      assert.is_false(vim.bo[buf].modifiable)
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:find("## call.lua", 1, true), text)
      assert.is_truthy(text:find("please rename", 1, true), text)
      -- The buffer takes the focus, and the register holds the same text.
      assert.are_not.equal(bar.panel:window(), api.nvim_get_current_win())
      assert.is_truthy(vim.fn.getreg("z"):find("please rename", 1, true))
    end)

    it("writes the markdown into the register without a buffer", function()
      with_register()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "please rename" })
      local bar = open_overview({ focus = true })

      press("<leader>cy")
      assert.is_truthy(vim.fn.getreg("z"):find("please rename", 1, true))
      assert.are.equal(bar.panel:window(), api.nvim_get_current_win())
      for _, buf in ipairs(api.nvim_list_bufs()) do
        assert.is_nil(api.nvim_buf_get_name(buf):find("export.md", 1, true))
      end
    end)

    it("needs no comment", function()
      with_register()
      local bar = open_overview()

      local result = assert(bar:copy())
      assert.are.equal(0, result.count)
      assert.are.equal("z", result.register)
      assert.is_truthy(vim.fn.getreg("z"):find("No comments.", 1, true))
    end)
  end)

  describe("the refresh events", function()
    it("shows a comment that the diff view adds", function()
      local bar = open_overview()
      local state = open_diff("call.lua")
      assert.are.equal("  no comments", bar.panel:lines()[4])

      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.is_true(comments.add())
      write_comment("from the diff view")

      assert.are.equal("1 comment", bar.panel:lines()[2])
      assert.are.equal(1, #bar:comments())
      assert.are.equal("from the diff view", bar:comments()[1].body)
    end)

    it("clears the extmarks of the diff on a delete in the overview", function()
      local comment = add_comment({ file = "call.lua", start_line = 2, end_line = 2 })
      local state = open_diff("call.lua")
      assert.are.equal(1, #comments.marks(state.buf))

      local bar = open_overview()
      bar.panel:set_cursor(line_of(bar, comment.id))
      assert.is_true(bar:remove({ confirm = false }))

      assert.are.equal(0, #comments.marks(state.buf))
      assert.are.equal("  no comments", bar.panel:lines()[4])
      assert.is_false(vim.bo[state.buf].modifiable)
      assert.are.equal(6, api.nvim_buf_line_count(state.buf))
    end)

    it("changes the sign of the diff on a resolve in the overview", function()
      local comment = add_comment({ file = "call.lua", start_line = 2, end_line = 2 })
      local state = open_diff("call.lua")
      assert.are.equal("▌", comments.marks(state.buf)[1][4].sign_text:sub(1, 3))

      local bar = open_overview()
      bar.panel:set_cursor(line_of(bar, comment.id))
      assert.is_truthy(bar:set_state("resolved"))

      local mark = comments.marks(state.buf)[1][4]
      assert.are.equal("✓", mark.sign_text:sub(1, 3))
      assert.are.equal("CodeViewCommentResolved", mark.sign_hl_group)
    end)

    it("sends one event per change", function()
      local seen = {}
      events.on(events.comment, function(data, name)
        seen[#seen + 1] = { name = name, id = data.id, file = data.file, session = data.session }
      end)

      local comment = add_comment({ file = "call.lua", start_line = 2, end_line = 2 })
      local bar = open_overview()
      bar.panel:set_cursor(line_of(bar, comment.id))
      assert.is_truthy(bar:set_state("resolved"))
      assert.is_true(bar:remove({ confirm = false }))

      assert.are.same(
        { "comment_changed", "comment_deleted" },
        vim.tbl_map(function(entry)
          return entry.name
        end, seen)
      )
      assert.are.equal(comment.id, seen[1].id)
      assert.are.equal("call.lua", seen[1].file)
      assert.are.equal(assert(opened).id, seen[1].session)
    end)

    it("leaves no event handler behind after a close", function()
      local bar = open_overview()
      local before = 0
      events.on(events.comment, function()
        before = before + 1
      end)

      bar:close()
      events.emit("comment_added", { session = assert(opened).id })
      assert.are.equal(1, before)
      assert.are.same({}, bar.subscriptions)
    end)
  end)

  describe("close", function()
    it("closes the window but keeps the session", function()
      local bar = open_overview()
      local win = assert(bar.panel:window())
      assert.is_true(overview.close())

      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_nil(overview.get())
      assert.is_false(assert(opened).closed)
      assert.is_false(overview.close())
    end)

    it("toggles the overview", function()
      open_session()
      assert.is_true(overview.toggle())
      assert.is_true(overview.is_open())
      assert.is_false(overview.toggle())
      assert.is_false(overview.is_open())
    end)

    it("closes the overview with q", function()
      local bar = open_overview({ focus = true })
      press("q")
      assert.is_false(overview.is_open())
      assert.is_false(assert(opened).closed)
      assert.is_nil(bar.panel:window())
    end)

    it("opens an overview for a new session", function()
      local first = open_overview()
      local win = assert(first.panel:window())

      assert(opened):close()
      opened = nil
      open_session()
      local second = assert(overview.open())
      assert.are_not.equal(first, second)
      assert.is_false(api.nvim_win_is_valid(win))
    end)
  end)

  describe("the command", function()
    it("knows :Codeview comments", function()
      local command = require("codeview.command")
      assert.is_truthy(api.nvim_get_commands({}).Codeview)
      assert.are.equal(command.overview, command.subcommands.comments.run)
    end)

    it("opens and closes the overview", function()
      open_session()
      local command = require("codeview.command")
      command.overview()
      assert.is_true(overview.is_open())
      assert.are.equal(assert(overview.get()).panel:window(), api.nvim_get_current_win())
      command.overview()
      assert.is_false(overview.is_open())
    end)

    it("opens the overview with the session when auto_open is on", function()
      assert(config.setup({ comments = { dir = dir }, overview = { auto_open = true } }))
      local command = require("codeview.command")
      command.run({ args = spec(), dir = fixture.dir })
      wait_for(function()
        return session_mod.current() ~= nil
      end, "the session did not open")
      opened = session_mod.current()

      wait_for(function()
        return overview.is_open()
      end, "the overview did not open")
      require("codeview.sidebar").close()
    end)
  end)

  it("leaves no windows behind", function()
    assert.are.equal(1, #api.nvim_tabpage_list_wins(0))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
