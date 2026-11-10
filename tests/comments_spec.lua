local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.comments", function()
  local fixture = fixtures.git_comments()
  local comments, config, editor, session_mod, store_mod, view
  ---@type string
  local dir
  ---@type codeview.Session?
  local opened

  ---Text of the range of the fixture.
  ---@return string
  local function spec()
    return fixture.ids.base .. ".." .. fixture.ids.change
  end

  ---Open a session and show the diff of call.lua.
  ---
  --- The inline diff of the file is:
  ---
  ---     1  @@ -1,4 +1,4 @@
  ---     2   local a = call(one, two)
  ---     3  -local b = 2
  ---     4  +local b = 22
  ---     5   local c = 3
  ---     6   local d = 4
  ---@return codeview.view.State
  local function open_diff()
    local review, err = session_mod.open(spec(), { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    local state = assert(view.open(review, 1))
    api.nvim_set_current_win(state.win)
    return state
  end

  ---Open a session and show the diff of tail.txt.
  ---
  --- Only the last line of the file changes, so the render hides the head of
  --- the file behind the filler row of the first section:
  ---
  ---     1  ⋯ 33 unchanged lines
  ---     2  @@ -37,4 +37,4 @@
  ---     3   line 37
  ---     4   line 38
  ---     5   line 39
  ---     6  -line 40
  ---     7  +line 40 changed
  ---@return codeview.view.State
  local function open_tail()
    local review, err = session_mod.open(spec(), { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    local state = assert(view.open(review, assert(review:index_of("tail.txt"))))
    api.nvim_set_current_win(state.win)
    return state
  end

  ---Press keys in the window that has the focus.
  ---@param lhs string
  local function press(lhs)
    api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
  end

  ---Write a body into the editor and save it.
  ---@param body string
  local function write_comment(body)
    local state = assert(editor.current())
    api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
    assert.is_true(editor.submit())
  end

  ---Comment on one row of the diff, through the whole flow.
  ---@param row integer Buffer row of the cursor.
  ---@param body string
  ---@param opts? table Options of |codeview.comments.add()|.
  ---@return codeview.store.Comment
  local function comment_on(row, body, opts)
    local state = assert(view.current())
    api.nvim_set_current_win(state.win)
    api.nvim_win_set_cursor(state.win, { row, 0 })
    assert.is_true(comments.add(opts))
    write_comment(body)
    local store = assert(comments.store())
    return store.comments[#store.comments]
  end

  ---Extmarks of the comments of a buffer.
  ---@param buf integer
  ---@return table[]
  local function marks_of(buf)
    return comments.marks(buf)
  end

  ---Extmarks of the boxes of a buffer.
  ---@param buf integer
  ---@return table[]
  local function box_marks_of(buf)
    return require("codeview.stack").marks(buf)
  end

  ---Rows that hold a comment sign, from 1.
  ---@param buf integer
  ---@return integer[]
  local function sign_rows(buf)
    local rows = {}
    for _, mark in ipairs(marks_of(buf)) do
      if mark[4].sign_text then
        rows[#rows + 1] = mark[2] + 1
      end
    end
    table.sort(rows)
    return rows
  end

  ---Full text of the virtual lines of every mark of a buffer, with the frame.
  ---@param buf integer
  ---@return string[] lines
  local function box_lines(buf)
    local out = {}
    for _, mark in ipairs(box_marks_of(buf)) do
      for _, line in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(line) do
          text = text .. chunk[1]
        end
        out[#out + 1] = text
      end
    end
    return out
  end

  ---Text of a box line without the frame and without the padding.
  ---@param text string
  ---@return string
  local function content(text)
    for _, char in ipairs({ "╭", "│", "╰", "├" }) do
      if vim.startswith(text, char) then
        text = text:sub(#char + 1)
      end
    end
    for _, char in ipairs({ "╮", "│", "╯", "┤" }) do
      if vim.endswith(text, char) then
        text = text:sub(1, -#char - 1)
      end
    end
    while vim.startswith(text, "─") do
      text = text:sub(#"─" + 1)
    end
    while vim.endswith(text, "─") do
      text = text:sub(1, -#"─" - 1)
    end
    return vim.trim(text)
  end

  ---Text of the virtual lines of every mark of a buffer, without the frame.
  ---
  --- A line without text does not count: the bottom border, and the blank
  --- lines that the other side of a side-by-side view takes, so that both
  --- windows grow by the same height.
  ---@param buf integer
  ---@return string[] lines
  local function virt_lines(buf)
    local out = {}
    for _, line in ipairs(box_lines(buf)) do
      local text = content(line)
      if text ~= "" then
        out[#out + 1] = text
      end
    end
    return out
  end

  ---Number of virtual lines of a buffer, with the blank ones.
  ---@param buf integer
  ---@return integer count
  local function virt_line_count(buf)
    local count = 0
    for _, mark in ipairs(box_marks_of(buf)) do
      count = count + #(mark[4].virt_lines or {})
    end
    return count
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = fixtures.tempdir("codeview-comments")
    assert(config.setup({ commit_message = false, comments = { dir = dir } }))
    comments = require("codeview.comments")
    editor = require("codeview.editor")
    session_mod = require("codeview.session")
    store_mod = require("codeview.store")
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

  describe("anchors", function()
    it("anchors a comment on the new side of a context row", function()
      local state = open_diff()
      local comment = comment_on(2, "a note on the first line")
      assert.are.equal("call.lua", comment.file)
      assert.are.equal("new", comment.side)
      assert.are.equal(1, comment.start_line)
      assert.are.equal(1, comment.end_line)
      assert.are.equal(fixture.ids.change, comment.commit)
      assert.are.equal("a note on the first line", comment.body)
      assert.are.same({ 2 }, sign_rows(state.buf))
    end)

    it("anchors a comment on the old side of a removed row", function()
      local state = open_diff()
      local comment = comment_on(3, "this line goes away")
      assert.are.equal("old", comment.side)
      assert.are.equal(2, comment.start_line)
      assert.are.equal(fixture.ids.base, comment.commit)
      assert.are.same({ 3 }, sign_rows(state.buf))
    end)

    it("anchors a comment on the new side of an added row", function()
      local state = open_diff()
      local comment = comment_on(4, "this line is new")
      assert.are.equal("new", comment.side)
      assert.are.equal(2, comment.start_line)
      assert.are.same({ 4 }, sign_rows(state.buf))
    end)

    it("anchors a comment over a range of lines", function()
      local state = open_diff()
      local comment = comment_on(5, "these two lines", { first = 5, last = 6 })
      assert.are.equal("new", comment.side)
      assert.are.equal(3, comment.start_line)
      assert.are.equal(4, comment.end_line)
      assert.are.same({ 5, 6 }, sign_rows(state.buf))
    end)

    it("shows the body in virtual lines below the range", function()
      local state = open_diff()
      comment_on(5, "first line\nsecond line", { first = 5, last = 6 })
      assert.are.same({
        "comment L3-4 (new)",
        "first line",
        "second line",
      }, virt_lines(state.buf))

      -- The body sits below the last row of the range, and only there.
      local last = nil
      for _, mark in ipairs(box_marks_of(state.buf)) do
        if mark[4].virt_lines then
          last = mark[2] + 1
        end
      end
      assert.are.equal(6, last)
    end)

    it("reports a row without a line of the file", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 1, 0 })
      assert.is_false(comments.add())
      assert.is_false(editor.is_open())
      assert.are.equal(0, #marks_of(state.buf))
    end)

    it("puts the marks of both sides in the side-by-side style", function()
      open_diff()
      comment_on(3, "the old side")
      comment_on(4, "the new side")

      assert.are.equal("split", view.set_style("split"))
      local state = assert(view.current())
      assert.are.same({ 3 }, sign_rows(state.old_buf))
      assert.are.same({ 3 }, sign_rows(state.buf))
      assert.are.same({ "comment L2 (old)", "the old side" }, virt_lines(state.old_buf))
      assert.are.same({ "comment L2 (new)", "the new side" }, virt_lines(state.buf))
    end)

    it("keeps the two windows of the split aligned", function()
      open_diff()
      assert.are.equal("split", view.set_style("split"))
      local state = assert(view.current())
      local old_win = assert(state.old_win)

      ---@return integer old
      ---@return integer new
      local function heights()
        return api.nvim_win_text_height(old_win, {}).all, api.nvim_win_text_height(state.win, {}).all
      end

      local before_old, before_new = heights()
      assert.are.equal(before_old, before_new)

      comment_on(3, "one\ntwo\nthree")
      state = assert(view.current())

      -- The comment adds five virtual lines to the new side: the top border,
      -- three body lines, and the bottom border. The old side takes five blank
      -- ones, so both windows keep the same height.
      assert.are.equal(5, virt_line_count(state.buf))
      assert.are.equal(5, virt_line_count(assert(state.old_buf)))
      local after_old, after_new = heights()
      assert.are.equal(after_old, after_new)
      assert.is_true(after_new > before_new)

      -- The sign column has a fixed width, so the text of the two sides starts
      -- in the same column.
      assert.are.equal("yes:1", vim.wo[old_win][0].signcolumn)
      assert.are.equal("yes:1", vim.wo[state.win][0].signcolumn)
      assert.are.equal(vim.fn.getwininfo(old_win)[1].textoff, vim.fn.getwininfo(state.win)[1].textoff)
    end)

    it("takes the side of the window in the side-by-side style", function()
      open_diff()
      view.set_style("split")
      local state = assert(view.current())

      api.nvim_set_current_win(state.old_win --[[@as integer]])
      api.nvim_win_set_cursor(state.old_win --[[@as integer]], { 3, 0 })
      assert.is_true(comments.add())
      write_comment("from the left window")

      local store = assert(comments.store())
      assert.are.equal("old", store.comments[1].side)
      assert.are.equal(2, store.comments[1].start_line)
      assert.are.same({ 3 }, sign_rows(state.old_buf))
      assert.are.same({}, sign_rows(state.buf))
    end)

    it("keeps the anchor after a change of the style", function()
      local state = open_diff()
      comment_on(4, "the added line")
      assert.are.same({ 4 }, sign_rows(state.buf))

      view.set_style("split")
      state = assert(view.current())
      assert.are.same({ 3 }, sign_rows(state.buf))
      assert.are.equal(2, state.map:file_line(3, "new"))

      view.set_style("inline")
      state = assert(view.current())
      assert.are.same({ 4 }, sign_rows(state.buf))
      assert.are.equal(2, state.map:file_line(4, "new"))
    end)

    it("keeps the line map correct while a comment shows", function()
      local state = open_diff()
      local before = state.map:len()
      local rows = {}
      for lnum = 1, before do
        rows[lnum] = { state.map:file_line(lnum, "old") or 0, state.map:file_line(lnum, "new") or 0 }
      end

      comment_on(4, "a comment with\nthree\nlines")

      state = assert(view.current())
      assert.are.equal(before, state.map:len())
      assert.are.equal(before, api.nvim_buf_line_count(state.buf))
      for lnum = 1, before do
        assert.are.same(rows[lnum], {
          state.map:file_line(lnum, "old") or 0,
          state.map:file_line(lnum, "new") or 0,
        })
      end
    end)
  end)

  describe("the editor", function()
    it("uses a modifiable scratch buffer of its own", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()

      local ed = assert(editor.current())
      assert.are_not.equal(state.buf, ed.buf)
      assert.is_true(vim.bo[ed.buf].modifiable)
      assert.are.equal("markdown", vim.bo[ed.buf].filetype)
      assert.are.equal("acwrite", vim.bo[ed.buf].buftype)
      assert.is_false(vim.bo[state.buf].modifiable)
      editor.cancel()
    end)

    it("opens under the line of the diff", function()
      local state = open_diff()
      local rows = api.nvim_buf_line_count(state.buf)
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()

      local ed = assert(editor.current())
      local win_config = api.nvim_win_get_config(ed.win)
      assert.are.equal("inline", ed.style)
      assert.are.equal("win", win_config.relative)
      assert.are.equal(state.win, win_config.win)
      -- The window sits on the virtual lines that the spacer holds, one screen
      -- row under the commented row.
      assert.are.same({ 1, 0 }, win_config.bufpos)
      assert.are.equal(1, win_config.row)

      -- The space comes from an extmark, so the diff keeps its rows. It holds
      -- the rows of the frame too.
      assert.are.equal(1, #box_marks_of(state.buf))
      assert.are.equal(win_config.height + 2, virt_line_count(state.buf))
      assert.are.equal(rows, api.nvim_buf_line_count(state.buf))
      assert.is_false(vim.bo[state.buf].modifiable)
      editor.cancel()
    end)

    it("takes the space back after a discard", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      assert.is_true(virt_line_count(state.buf) > 0)

      editor.cancel()
      assert.are.equal(0, virt_line_count(state.buf))
    end)

    it("takes the space back after a save", function()
      local state = open_diff()
      local rows = api.nvim_buf_line_count(state.buf)
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "saved" })
      assert.is_true(editor.submit())

      -- The box of the comment is all that stays: the frame and one line.
      assert.are.equal(3, virt_line_count(state.buf))
      assert.are.equal(rows, api.nvim_buf_line_count(state.buf))
    end)

    it("starts in insert mode", function()
      -- The test reads the request, not the mode. A headless Neovim runs no
      -- input loop, so `startinsert` reaches no mode change until the loop
      -- runs, and `vim.api.nvim_get_mode()` answers "n" through the test.
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      assert.is_true(assert(editor.current()).insert)
      editor.cancel()
    end)

    it("keeps normal mode when the option says so", function()
      assert(config.setup({ commit_message = false, comments = { dir = dir, start_insert = false } }))
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      assert.is_false(assert(editor.current()).insert)
      editor.cancel()
    end)

    it("opens a float when the option asks for one", function()
      assert(config.setup({ commit_message = false, comments = { dir = dir, editor = "float" } }))
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()

      local ed = assert(editor.current())
      assert.are.equal("float", ed.style)
      assert.are.equal("editor", api.nvim_win_get_config(ed.win).relative)
      editor.cancel()
    end)

    it("falls back to a float without a row to sit under", function()
      open_diff()
      -- An editor that opens without an anchor has no diff row, which is the
      -- case of the comment overview.
      editor.open({ on_save = function() end })

      local ed = assert(editor.current())
      assert.are.equal("float", ed.style)
      assert.are.equal("editor", api.nvim_win_get_config(ed.win).relative)
      editor.cancel()
    end)

    it("saves the comment on a write", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "written with :w" })
      vim.cmd.write()

      assert.is_false(editor.is_open())
      local store = assert(comments.store())
      assert.are.equal(1, store:count())
      assert.are.equal("written with :w", store.comments[1].body)
    end)

    -- A quit command after a write closes the window that has the focus. The
    -- write must not close the editor, or the quit closes a window of the
    -- review.
    for _, case in ipairs({
      {
        name = ":wq",
        run = function()
          vim.cmd.wq()
        end,
      },
      {
        name = ":x",
        run = function()
          vim.cmd.x()
        end,
      },
      {
        name = "ZZ",
        run = function()
          press("ZZ")
        end,
      },
    }) do
      it("saves the comment on " .. case.name .. " and closes only the editor", function()
        local state = open_diff()
        api.nvim_win_set_cursor(state.win, { 2, 0 })
        local before = api.nvim_tabpage_list_wins(0)
        comments.add()
        local ed = assert(editor.current())
        api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "written with " .. case.name })
        case.run()

        assert.is_false(editor.is_open())
        assert.is_false(api.nvim_win_is_valid(ed.win))
        assert.are.same(before, api.nvim_tabpage_list_wins(0))
        local store = assert(comments.store())
        assert.are.equal(1, store:count())
        assert.are.equal("written with " .. case.name, store.comments[1].body)
      end)
    end

    it("closes the editor on the next tick after :w", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      local before = api.nvim_tabpage_list_wins(0)
      comments.add()
      local ed = assert(editor.current())
      api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "written with :w" })
      vim.cmd.write()

      assert.is_true(vim.wait(1000, function()
        return not api.nvim_win_is_valid(ed.win)
      end))
      assert.are.same(before, api.nvim_tabpage_list_wins(0))
      assert.is_false(api.nvim_buf_is_valid(ed.buf))
    end)

    it("discards an empty body on :wq and closes only the editor", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      local before = api.nvim_tabpage_list_wins(0)
      comments.add()
      vim.cmd.wq()

      assert.is_false(editor.is_open())
      assert.are.same(before, api.nvim_tabpage_list_wins(0))
      assert.are.equal(0, assert(comments.store()):count())
    end)

    it("keeps an unchanged comment on ZZ", function()
      local state = open_diff()
      local comment = comment_on(2, "first text")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      local before = api.nvim_tabpage_list_wins(0)
      assert.is_true(comments.edit_or_add({ view = state }))
      assert.is_true(editor.is_open())
      press("ZZ")

      assert.is_false(editor.is_open())
      assert.are.same(before, api.nvim_tabpage_list_wins(0))
      local store = assert(comments.store())
      assert.are.equal(1, store:count())
      assert.are.equal("first text", store.comments[1].body)
      assert.are.equal(comment.id, store.comments[1].id)
    end)

    it("discards the comment on q", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "never saved" })
      press("q")

      assert.is_false(editor.is_open())
      assert.are.equal(0, assert(comments.store()):count())
      assert.are.equal(0, #marks_of(state.buf))
    end)

    it("discards the comment on a double escape", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      press("<Esc><Esc>")
      assert.is_false(editor.is_open())
      assert.are.equal(0, assert(comments.store()):count())
    end)

    it("discards an empty body", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      assert.is_false(editor.submit())
      assert.is_false(editor.is_open())
      assert.are.equal(0, assert(comments.store()):count())
    end)

    it("closes the window on a discard", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      local ed = assert(editor.current())
      editor.cancel()
      assert.is_false(api.nvim_win_is_valid(ed.win))
      assert.is_false(api.nvim_buf_is_valid(ed.buf))
    end)

    it("leaves no autocmd behind after a save with :w", function()
      ---Autocmds of the editor that are set now.
      ---@return integer count
      local function autocmds()
        local count = 0
        for _, cmd in ipairs(api.nvim_get_autocmds({ event = { "BufWriteCmd", "WinClosed" } })) do
          if type(cmd.group_name) == "string" and cmd.group_name:find("codeview.editor", 1, true) then
            count = count + 1
          end
        end
        return count
      end

      local state = open_diff()
      assert.are.equal(0, autocmds())
      for index = 1, 3 do
        api.nvim_set_current_win(state.win)
        api.nvim_win_set_cursor(state.win, { 2, 0 })
        assert.is_true(comments.add())
        api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "note " .. index })
        vim.cmd.write()
        assert.is_false(editor.is_open())
        assert.are.equal(0, autocmds())
      end
      assert.are.equal(3, assert(comments.store()):count())
      -- The window of the last :w closes on the next tick.
      assert.is_true(vim.wait(1000, function()
        return #api.nvim_tabpage_list_wins(0) == 1
      end))
    end)

    it("closes the editor when the session closes", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      assert.is_true(comments.add())
      assert.is_true(editor.is_open())

      local review = assert(opened)
      opened = nil
      review:close()

      assert.is_false(editor.is_open())
      assert.are.equal(1, #api.nvim_tabpage_list_wins(0))
    end)
  end)

  describe("the keymaps", function()
    it("opens the editor with i, a, o, and O", function()
      local state = open_diff()
      for _, key in ipairs({ "i", "a", "o", "O" }) do
        api.nvim_set_current_win(state.win)
        api.nvim_win_set_cursor(state.win, { 2, 0 })
        press(key)
        assert.is_true(editor.is_open(), "the key " .. key .. " opens the editor")
        assert.are.equal("n", api.nvim_get_mode().mode, "the key " .. key .. " starts no insert mode")
        assert.is_false(vim.bo[state.buf].modifiable)
        editor.cancel()
      end
    end)

    it("opens the editor with the explicit key", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      press("<leader>cc")
      assert.is_true(editor.is_open())
      editor.cancel()
    end)

    it("comments on the selected lines with I, A, and c", function()
      local state = open_diff()
      for _, key in ipairs({ "I", "A", "c" }) do
        api.nvim_set_current_win(state.win)
        api.nvim_win_set_cursor(state.win, { 5, 0 })
        press("Vj" .. key)
        assert.is_true(editor.is_open(), "the key " .. key .. " opens the editor")
        assert.are.equal("n", api.nvim_get_mode().mode)
        write_comment("about " .. key)

        local store = assert(comments.store())
        local comment = store.comments[#store.comments]
        assert.are.equal(3, comment.start_line, "the key " .. key .. " takes the first line")
        assert.are.equal(4, comment.end_line, "the key " .. key .. " takes the last line")
        assert.are.equal("new", comment.side)
      end
      assert.are.same({ 5, 5, 5, 6, 6, 6 }, sign_rows(state.buf))
    end)

    it("comments on the selected lines with the explicit key", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 5, 0 })
      press("Vj<leader>cc")
      assert.is_true(editor.is_open())
      write_comment("from the visual mode")
      local comment = assert(comments.store()).comments[1]
      assert.are.equal(3, comment.start_line)
      assert.are.equal(4, comment.end_line)
    end)

    it("keeps the text objects of the visual mode", function()
      local state = open_diff()
      api.nvim_set_current_win(state.win)
      -- Row 2 is ` local a = call(one, two)`. Column 16 is inside the brackets.
      api.nvim_win_set_cursor(state.win, { 2, 16 })
      vim.fn.setreg('"', "")
      press("vi(y")

      assert.are.equal("one, two", vim.fn.getreg('"'))
      assert.is_false(editor.is_open())
      assert.are.equal("n", api.nvim_get_mode().mode)
    end)

    it("maps the keys in the diff buffer only", function()
      local state = open_diff()
      ---@param buf integer
      ---@param mode string
      ---@return table<string, boolean>
      local function mapped(buf, mode)
        local out = {}
        for _, map in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
          out[map.lhs] = true
        end
        return out
      end

      local diff_normal = mapped(state.buf, "n")
      for _, key in ipairs({ "i", "a", "o", "O", "K" }) do
        assert.is_true(diff_normal[key], "the diff buffer maps " .. key)
      end
      local diff_visual = mapped(state.buf, "x")
      for _, key in ipairs({ "I", "A", "c" }) do
        assert.is_true(diff_visual[key], "the diff buffer maps " .. key .. " in the visual mode")
      end
      assert.is_nil(diff_visual["i"], "the visual mode keeps i free for the text objects")

      vim.cmd.edit(vim.fs.joinpath(fixture.dir, "call.lua"))
      local file_buf = api.nvim_get_current_buf()
      assert.are_not.equal(state.buf, file_buf)
      for _, key in ipairs({ "i", "a", "o", "O", "K" }) do
        assert.is_nil(mapped(file_buf, "n")[key], "a file buffer keeps " .. key)
      end
      for _, key in ipairs({ "I", "A", "c" }) do
        assert.is_nil(mapped(file_buf, "x")[key], "a file buffer keeps " .. key)
      end
      assert.is_true(vim.bo[file_buf].modifiable)
      api.nvim_buf_delete(file_buf, { force = true })
    end)

    it("edits the comment of the line with the insert key", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      write_comment("the first note")

      api.nvim_win_set_cursor(state.win, { 2, 0 })
      assert.is_true(comments.edit_or_add({ view = state }))
      local ed = assert(editor.current())
      assert.are.same({ "the first note" }, api.nvim_buf_get_lines(ed.buf, 0, -1, false))
      editor.cancel()

      -- The line keeps one comment: the key edited, it did not add.
      assert.are.equal(1, #comments.list(assert(opened)))
    end)

    it("writes a new comment with the insert key on a free line", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      assert.is_true(comments.edit_or_add({ view = state }))
      local ed = assert(editor.current())
      assert.are.same({ "" }, api.nvim_buf_get_lines(ed.buf, 0, -1, false))
      editor.cancel()
    end)

    it("writes another comment with the add key", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      write_comment("the first note")

      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      write_comment("the second note")

      assert.are.equal(2, #comments.list(assert(opened)))
    end)

    it("hides the body of the comment that the editor holds", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      write_comment("the first note")

      ---Number of extmarks that draw virtual lines.
      ---@return integer
      local function bodies()
        local count = 0
        for _, mark in ipairs(box_marks_of(state.buf)) do
          if mark[4] and mark[4].virt_lines then
            count = count + 1
          end
        end
        return count
      end
      assert.are.equal(1, bodies())

      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.edit_or_add({ view = state })
      -- The editor sits under the row with the same text, so the diff drops
      -- the box while the editor is open. The row keeps only the blank space
      -- of the editor.
      assert.are.equal(1, bodies())
      assert.are.same({}, virt_lines(state.buf))
      assert.are.equal(1, #api.nvim_buf_get_extmarks(state.buf, comments.ns, 0, -1, {}))

      editor.cancel()
      assert.are.equal(1, bodies())
      assert.is_nil(require("codeview.marks").editing())
    end)

    it("shows the body again after a refresh and a discard", function()
      local state = open_diff()
      comment_on(2, "the first note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      assert.is_true(comments.edit_or_add({ view = state }))
      assert.is_true(editor.is_open())

      -- The refresh replaces the view, while the editor stays open.
      api.nvim_set_current_win(state.win)
      assert.is_true(view.refresh())
      local fresh = assert(view.current())
      assert.are_not.equal(state, fresh)

      editor.cancel()
      assert.is_nil(require("codeview.marks").editing())
      assert.are.same({ "comment L1 (new)", "the first note" }, virt_lines(fresh.buf))
    end)

    it("shows the body again after a close of the editor window", function()
      local state = open_diff()
      comment_on(2, "the first note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      assert.is_true(comments.edit({ view = state }))
      assert.are.same({}, virt_lines(state.buf))

      -- `:q!` and a close from another plugin come here.
      api.nvim_win_close(assert(editor.current()).win, true)
      assert.is_true(vim.wait(1000, function()
        return #virt_lines(state.buf) > 0
      end))
      assert.are.same({ "comment L1 (new)", "the first note" }, virt_lines(state.buf))
    end)

    it("keeps the body in the diff while the float editor edits it", function()
      config.setup({ commit_message = false, comments = { dir = dir, editor = "float" } })
      local state = open_diff()
      comment_on(2, "the first note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      assert.is_true(comments.edit({ view = state }))
      assert.are.equal("float", assert(editor.current()).style)

      -- The float sits in the middle of the screen, not under the row.
      assert.is_nil(require("codeview.marks").editing())
      assert.are.same({ "comment L1 (new)", "the first note" }, virt_lines(state.buf))
      editor.cancel()
    end)

    it("takes the keys from the configuration", function()
      config.setup({
        commit_message = false,
        comments = { dir = dir },
        keymaps = { comment_insert = { "gc" }, comment_visual = false },
      })
      local state = open_diff()

      local out = {}
      for _, map in ipairs(api.nvim_buf_get_keymap(state.buf, "n")) do
        out[map.lhs] = true
      end
      assert.is_true(out["gc"])
      assert.is_nil(out["i"])
      for _, map in ipairs(api.nvim_buf_get_keymap(state.buf, "x")) do
        assert.are_not.equal("I", map.lhs)
      end
    end)
  end)

  describe("the read-only guarantee", function()
    it("never makes the diff buffer modifiable", function()
      local state = open_diff()
      local text = api.nvim_buf_get_lines(state.buf, 0, -1, false)
      assert.is_false(vim.bo[state.buf].modifiable)

      api.nvim_win_set_cursor(state.win, { 4, 0 })
      press("i")
      assert.is_false(vim.bo[state.buf].modifiable)
      assert.are.same(text, api.nvim_buf_get_lines(state.buf, 0, -1, false))

      write_comment("a comment")
      assert.is_false(vim.bo[state.buf].modifiable)
      assert.are.same(text, api.nvim_buf_get_lines(state.buf, 0, -1, false))
      assert.are.equal(6, api.nvim_buf_line_count(state.buf))

      local comment = assert(comments.store()).comments[1]
      comments.edit()
      write_comment("a longer comment\nwith two lines")
      assert.is_false(vim.bo[state.buf].modifiable)
      assert.are.same(text, api.nvim_buf_get_lines(state.buf, 0, -1, false))

      assert.is_true(comments.remove({ id = comment.id, confirm = false }))
      assert.is_false(vim.bo[state.buf].modifiable)
      assert.are.same(text, api.nvim_buf_get_lines(state.buf, 0, -1, false))
      assert.are.equal(6, api.nvim_buf_line_count(state.buf))
    end)

    it("changes the extmarks only", function()
      local state = open_diff()
      assert.are.equal(0, #marks_of(state.buf))

      local comment = comment_on(4, "one")
      assert.are.equal(1, #marks_of(state.buf))
      assert.are.same({ "comment L2 (new)", "one" }, virt_lines(state.buf))

      comments.edit({ id = comment.id })
      write_comment("two")
      assert.are.equal(1, #marks_of(state.buf))
      assert.are.same({ "comment L2 (new)", "two" }, virt_lines(state.buf))

      comments.remove({ id = comment.id, confirm = false })
      assert.are.equal(0, #marks_of(state.buf))
    end)

    it("does not change the file in the working copy", function()
      local path = vim.fs.joinpath(fixture.dir, "call.lua")
      local before = vim.fn.readfile(path)
      local stat_before = assert(vim.uv.fs_stat(path))

      open_diff()
      local comment = comment_on(4, "a note")
      comments.edit({ id = comment.id })
      write_comment("another note")
      comments.remove({ id = comment.id, confirm = false })

      assert.are.same(before, vim.fn.readfile(path))
      local stat_after = assert(vim.uv.fs_stat(path))
      assert.are.equal(stat_before.size, stat_after.size)
      assert.are.equal(stat_before.mtime.sec, stat_after.mtime.sec)
    end)

    it("writes the comment file only", function()
      open_diff()
      comment_on(4, "a note")

      local store = assert(comments.store())
      assert.are.equal(1, vim.fn.filereadable(store.path))
      assert.is_truthy(store.path:find(dir, 1, true))

      -- The repository holds the commit of the fixture and no new file.
      local status = vim.system({ "git", "status", "--porcelain" }, { cwd = fixture.dir, text = true }):wait()
      assert.are.equal("", vim.trim(status.stdout or ""))
    end)
  end)

  describe("edit and delete", function()
    it("reopens the editor with the body of the comment", function()
      local state = open_diff()
      comment_on(4, "the first text")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      assert.is_true(comments.edit())
      local ed = assert(editor.current())
      assert.are.same({ "the first text" }, api.nvim_buf_get_lines(ed.buf, 0, -1, false))
      write_comment("the second text")

      local store = assert(comments.store())
      assert.are.equal(1, store:count())
      assert.are.equal("the second text", store.comments[1].body)
      assert.are.equal(
        "the second text",
        assert(store_mod.load({ repo = fixture.root, range = store.range })).comments[1].body
      )
    end)

    it("deletes the comment when the edit is saved empty", function()
      local state = open_diff()
      comment_on(4, "the first text")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      assert.is_true(comments.edit())
      local ed = assert(editor.current())
      api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "", "  " })
      vim.cmd.write()

      local store = assert(comments.store())
      assert.are.equal(0, store:count())
      assert.are.equal(0, #assert(store_mod.load({ repo = fixture.root, range = store.range })).comments)
      assert.is_false(editor.is_open())
      assert.is_nil(require("codeview.marks").editing())
    end)

    it("deletes the comment when the edit is submitted empty", function()
      local state = open_diff()
      comment_on(4, "the first text")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      assert.is_true(comments.edit())
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, {})
      assert.is_false(editor.submit())

      assert.are.equal(0, assert(comments.store()):count())
      assert.is_false(editor.is_open())
    end)

    it("keeps the comment when an emptied edit is discarded", function()
      local state = open_diff()
      comment_on(4, "the first text")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      assert.is_true(comments.edit())
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, {})
      editor.cancel()

      local store = assert(comments.store())
      assert.are.equal(1, store:count())
      assert.are.equal("the first text", store.comments[1].body)
    end)

    it("opens the float for a comment of another file", function()
      open_tail()
      local comment = comment_on(7, "a tail note")
      local review = assert(opened)
      local state = assert(view.open(review, assert(review:index_of("call.lua"))))
      api.nvim_set_current_win(state.win)
      local rows = api.nvim_buf_line_count(state.buf)

      -- The comment overview edits by id, while the diff shows another file.
      assert.is_true(comments.edit({ id = comment.id, session = review }))
      local ed = assert(editor.current())
      assert.are.equal("float", ed.style)
      assert.are.equal("editor", api.nvim_win_get_config(ed.win).relative)
      assert.is_nil(require("codeview.marks").editing())
      assert.are.equal(0, virt_line_count(state.buf))
      assert.are.equal(rows, api.nvim_buf_line_count(state.buf))

      write_comment("a changed tail note")
      assert.are.equal("a changed tail note", assert(comments.store()).comments[1].body)
    end)

    it("asks which comment to edit when the line holds more than one", function()
      local state = open_diff()
      comment_on(4, "the first note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      comments.add()
      write_comment("the second note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      local select = vim.ui.select
      local offered, prompt
      vim.ui.select = function(items, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        prompt = opts.prompt
        offered = vim.tbl_map(opts.format_item, items)
        cb(items[2])
      end
      local started = comments.edit_or_add({ view = state })
      vim.ui.select = select

      assert.is_true(started)
      assert.are.equal("codeview: edit which comment?", prompt)
      assert.are.same({ "L2 (new): the first note", "L2 (new): the second note" }, offered)
      local ed = assert(editor.current())
      assert.are.same({ "the second note" }, api.nvim_buf_get_lines(ed.buf, 0, -1, false))
      write_comment("the second note, changed")
      local bodies = vim.tbl_map(function(comment)
        return comment.body
      end, assert(comments.store()).comments)
      assert.are.same({ "the first note", "the second note, changed" }, bodies)
    end)

    it("opens no editor when the question gets no answer", function()
      local state = open_diff()
      comment_on(4, "the first note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      comments.add()
      write_comment("the second note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      local select = vim.ui.select
      vim.ui.select = function(_, _, cb) ---@diagnostic disable-line: duplicate-set-field
        cb(nil)
      end
      comments.edit()
      vim.ui.select = select
      assert.is_false(editor.is_open())
    end)

    it("edits the one comment of a line without a question", function()
      local state = open_diff()
      comment_on(4, "the only note")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      local select = vim.ui.select
      local asked = false
      vim.ui.select = function() ---@diagnostic disable-line: duplicate-set-field
        asked = true
      end
      assert.is_true(comments.edit())
      vim.ui.select = select
      assert.is_false(asked)
      assert.is_true(editor.is_open())
    end)

    it("reports no comment under the cursor", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 5, 0 })
      assert.is_false(comments.edit())
      assert.is_false(comments.remove({ confirm = false }))
      assert.is_false(editor.is_open())
    end)

    it("deletes the comment under the cursor", function()
      local state = open_diff()
      comment_on(4, "goes away")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      assert.is_true(comments.remove({ confirm = false }))
      local store = assert(comments.store())
      assert.are.equal(0, store:count())
      assert.are.equal(0, #marks_of(state.buf))
      assert.are.equal(0, #assert(store_mod.load({ repo = fixture.root, range = store.range })).comments)
    end)

    it("closes the editor of a comment that goes away", function()
      local state = open_diff()
      local comment = comment_on(4, "goes away")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.is_true(comments.edit())
      local ed = assert(editor.current())
      api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "typed during the delete" })

      local said = {}
      local notify = vim.notify
      vim.notify = function(text)
        said[#said + 1] = text
      end
      local removed = comments.remove({ id = comment.id, confirm = false })
      vim.notify = notify

      assert.is_true(removed)
      assert.is_false(editor.is_open())
      assert.is_false(api.nvim_win_is_valid(ed.win))
      assert.are.equal(0, assert(comments.store()):count())
      assert.are.same({ "codeview: the open editor of this comment closed" }, said)
    end)

    it("keeps the comment when the question gets no yes", function()
      local state = open_diff()
      comment_on(4, "stays")
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      local calls = 0
      local confirm = vim.fn.confirm
      vim.fn.confirm = function()
        calls = calls + 1
        return 2
      end
      local removed = comments.remove()
      vim.fn.confirm = confirm

      assert.are.equal(1, calls)
      assert.is_false(removed)
      assert.are.equal(1, assert(comments.store()):count())
    end)

    it("resolves and reopens the comment under the cursor", function()
      local state = open_diff()
      local comment = comment_on(4, "please rename this")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.are.equal("open", comment.state)

      press("<leader>cr")
      local store = assert(comments.store())
      assert.are.equal("resolved", store.comments[1].state)
      assert.are.equal("✓", marks_of(state.buf)[1][4].sign_text:sub(1, 3))
      assert.are.same({ "comment L2 (new) · resolved", "please rename this" }, virt_lines(state.buf))
      assert.are.equal(
        "resolved",
        assert(store_mod.load({ repo = fixture.root, range = store.range })).comments[1].state
      )

      press("<leader>cr")
      assert.are.equal("open", assert(comments.store()).comments[1].state)
      assert.are.equal("▌", marks_of(state.buf)[1][4].sign_text:sub(1, 3))
    end)

    it("sets one state without a question", function()
      open_diff()
      local comment = comment_on(4, "a note")
      assert.are.equal("resolved", assert(comments.set_state({ id = comment.id, state = "resolved" })).state)
      assert.are.equal("resolved", assert(comments.set_state({ id = comment.id, state = "resolved" })).state)
      assert.is_nil(comments.set_state({ id = "no-such-comment" }))
    end)

    it("reads the comments under the cursor", function()
      local state = open_diff()
      comment_on(5, "the range", { first = 5, last = 6 })
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 6, 0 })
      assert.are.equal(1, #comments.at_cursor())

      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.are.equal(0, #comments.at_cursor())
    end)
  end)

  describe("the box", function()
    ---Width that a box takes in a window.
    ---@param win integer
    ---@return integer
    local function box_width(win)
      return api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 1
    end

    ---Chunks of the virtual lines of the first mark with virtual lines.
    ---@param buf integer
    ---@return table[][]
    local function chunks_of(buf)
      for _, mark in ipairs(box_marks_of(buf)) do
        if mark[4].virt_lines then
          return mark[4].virt_lines
        end
      end
      return {}
    end

    it("frames the comment with the rounded border", function()
      local state = open_diff()
      comment_on(4, "one\n\ntwo")
      local width = box_width(state.win)
      local lines = box_lines(state.buf)
      assert.are.equal(5, #lines)

      assert.is_true(vim.startswith(lines[1], "╭─ comment L2 (new) ─"))
      assert.is_true(vim.endswith(lines[1], "─╮"))
      assert.are.equal("│ one" .. string.rep(" ", width - 7) .. " │", lines[2])
      -- An empty body line stays in the box as a line of spaces.
      assert.are.equal("│" .. string.rep(" ", width - 2) .. "│", lines[3])
      assert.are.equal("│ two" .. string.rep(" ", width - 7) .. " │", lines[4])
      assert.are.equal("╰" .. string.rep("─", width - 2) .. "╯", lines[5])
    end)

    it("fills the space right of the line numbers, minus one column", function()
      local state = open_diff()
      comment_on(4, "a short note")
      local width = box_width(state.win)
      assert.is_true(width > 20)
      for _, line in ipairs(box_lines(state.buf)) do
        assert.are.equal(width, vim.fn.strdisplaywidth(line))
      end
    end)

    it("wraps a long body line inside the box", function()
      local state = open_diff()
      local width = box_width(state.win)
      local words = {}
      for index = 1, 40 do
        words[index] = "word" .. index
      end
      local long = string.rep("x", width)
      comment_on(4, table.concat(words, " ") .. " " .. long)

      local lines = box_lines(state.buf)
      assert.is_true(#lines > 4)
      for _, line in ipairs(lines) do
        assert.are.equal(width, vim.fn.strdisplaywidth(line))
      end
      -- The words break at the spaces only, and a word that is wider than the
      -- box breaks at the width.
      local body = {}
      for index = 2, #lines - 1 do
        body[#body + 1] = content(lines[index])
      end
      local text = table.concat(body, " ")
      assert.are.equal(table.concat(words, " "), text:sub(1, #table.concat(words, " ")))
      assert.are.equal(long, text:sub(#table.concat(words, " ") + 2):gsub(" ", ""))
      for index = 2, #lines - 1 do
        local line = content(lines[index])
        if not line:find("x", 1, true) then
          assert.is_truthy(line:match("^word%d+"), line)
        end
      end
    end)

    it("cuts a header that does not fit", function()
      local lines = require("codeview.box").lines({
        header = "comment L120-140 (new) · resolved",
        header_hl = "CodeViewCommentHeader",
        body = "note",
        body_hl = "CodeViewComment",
        box_hl = "CodeViewCommentBox",
        border_hl = "CodeViewCommentBorder",
        border = "rounded",
        width = 20,
      })
      local top = ""
      for _, chunk in ipairs(lines[1]) do
        top = top .. chunk[1]
      end
      assert.are.equal("╭─ comment L120-… ─╮", top)
      assert.are.equal(20, vim.fn.strdisplaywidth(top))
    end)

    it("draws no frame with the border none", function()
      config.setup({ commit_message = false, comments = { dir = dir, border = "none" } })
      local state = open_diff()
      comment_on(4, "one\ntwo")
      local width = box_width(state.win)
      assert.are.same({
        " comment L2 (new)" .. string.rep(" ", width - 18) .. " ",
        " one" .. string.rep(" ", width - 5) .. " ",
        " two" .. string.rep(" ", width - 5) .. " ",
      }, box_lines(state.buf))
    end)

    it("takes the characters of the border option", function()
      config.setup({ commit_message = false, comments = { dir = dir, border = "double" } })
      local state = open_diff()
      comment_on(4, "one")
      local lines = box_lines(state.buf)
      assert.is_true(vim.startswith(lines[1], "╔═ comment L2 (new) ═"))
      assert.is_true(vim.startswith(lines[2], "║ one"))
      assert.is_true(vim.startswith(lines[3], "╚═"))
    end)

    it("puts the box groups on the chunks", function()
      local state = open_diff()
      comment_on(4, "one")
      local lines = chunks_of(state.buf)
      assert.are.same({
        { "╭─ ", "CodeViewCommentBorder" },
        { "comment L2 (new)", { "CodeViewCommentHeader", "CodeViewCommentBox" } },
      }, { lines[1][1], lines[1][2] })
      assert.are.equal("CodeViewCommentBorder", lines[1][3][2])
      assert.are.same({ "│", "CodeViewCommentBorder" }, lines[2][1])
      assert.are.same({ "CodeViewComment", "CodeViewCommentBox" }, lines[2][2][2])
      assert.are.same({ "│", "CodeViewCommentBorder" }, lines[2][3])
      assert.are.equal("CodeViewCommentBorder", lines[3][1][2])

      -- The box group carries a background and no foreground, so the text
      -- keeps the color of its own group.
      local box = api.nvim_get_hl(0, { name = "CodeViewCommentBox" })
      assert.is_number(box.bg)
      assert.is_nil(box.fg)
      local border = api.nvim_get_hl(0, { name = "CodeViewCommentBorder" })
      assert.are.equal(box.bg, border.bg)
      assert.is_number(border.fg)
    end)

    it("gives a resolved comment the header group of the state", function()
      local state = open_diff()
      local comment = comment_on(4, "one")
      assert(assert(comments.store()):update(comment.id, { state = "resolved" }))
      comments.refresh()
      local lines = chunks_of(state.buf)
      assert.are.same(
        { "comment L2 (new) · resolved", { "CodeViewCommentResolved", "CodeViewCommentBox" } },
        lines[1][2]
      )
    end)

    it("keeps the frame and its colors after a new comment and after an edit", function()
      local state = open_diff()

      ---Colors of the box and its frame.
      ---@return table
      local function colors()
        return {
          box = api.nvim_get_hl(0, { name = "CodeViewCommentBox" }),
          border = api.nvim_get_hl(0, { name = "CodeViewCommentBorder" }),
        }
      end

      ---Write a body in the editor that is open and save it with `:w`.
      ---
      --- The redraw shows the editor once, as a real screen does. The write
      --- then runs in the editor window, the same as a `:w` of the reviewer.
      ---@param body string
      local function save_with_write(body)
        local ed = assert(editor.current())
        api.nvim_buf_set_lines(ed.buf, 0, -1, false, { body })
        vim.cmd.redraw()
        vim.cmd.write()
        assert.is_true(vim.wait(1000, function()
          return not api.nvim_win_is_valid(ed.win)
        end))
      end

      ---Report whether the box holds the frame and the body.
      ---@param body string
      local function assert_framed(body)
        local lines = box_lines(state.buf)
        assert.are.equal(3, #lines)
        assert.is_true(vim.startswith(lines[1], "╭─ comment L2 (new) ─"))
        assert.is_true(vim.startswith(lines[2], "│ " .. body))
        assert.is_true(vim.endswith(lines[2], "│"))
        assert.is_true(vim.startswith(lines[3], "╰─"))
      end

      require("codeview.highlight").apply_comment_boxes()
      local expected = colors()

      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.is_true(comments.add())
      save_with_write("the first text")
      assert_framed("the first text")
      assert.are.same(expected, colors())

      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.is_true(comments.edit())
      save_with_write("the second text")
      assert_framed("the second text")
      assert.are.same(expected, colors())

      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.is_true(comments.edit())
      save_with_write("the third text")
      assert_framed("the third text")
      assert.are.same(expected, colors())
    end)

    it("fits the box to the window again after a resize", function()
      local state = open_diff()
      comment_on(4, "a short note")
      local before = box_width(state.win)
      assert.are.equal(before, vim.fn.strdisplaywidth(box_lines(state.buf)[1]))

      -- A second window takes room from the diff window, as a sidebar does.
      local other = api.nvim_open_win(api.nvim_create_buf(false, true), false, { split = "left", win = state.win })
      api.nvim_win_set_width(state.win, 50)
      local after = box_width(state.win)
      assert.is_true(after < before)

      -- A headless Neovim sends no WinResized event, so the test sends it.
      api.nvim_exec_autocmds("WinResized", { group = assert(opened):augroup() })
      for _, line in ipairs(box_lines(state.buf)) do
        assert.are.equal(after, vim.fn.strdisplaywidth(line))
      end

      api.nvim_win_close(other, true)
      api.nvim_exec_autocmds("WinResized", { group = assert(opened):augroup() })
      assert.are.equal(box_width(state.win), vim.fn.strdisplaywidth(box_lines(state.buf)[1]))
      assert.are.equal(before, box_width(state.win))
    end)

    it("fits the box again after the redraw that shows the sign column", function()
      local state = open_diff()
      comment_on(4, "a short note")
      local before = vim.fn.strdisplaywidth(box_lines(state.buf)[1])

      -- Neovim measures the sign column and the line numbers on a redraw. The
      -- first sign of the buffer then makes the text column move right.
      vim.cmd("redraw")
      local width = box_width(state.win)
      assert.is_true(width < before)
      assert.is_true(vim.wait(1000, function()
        return vim.fn.strdisplaywidth(box_lines(state.buf)[1]) == width
      end))
    end)

    it("gives the other side of the split as many blank lines as the open editor", function()
      open_diff()
      assert.are.equal("split", view.set_style("split"))
      comment_on(3, "a note")
      local state = assert(view.current())
      local old_buf = assert(state.old_buf)

      -- A new comment on a free row.
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.is_true(comments.add())
      local height = api.nvim_win_get_config(assert(editor.current()).win).height + 2
      assert.are.equal(3 + height, virt_line_count(state.buf))
      assert.are.equal(virt_line_count(state.buf), virt_line_count(old_buf))
      editor.cancel()
      assert.are.equal(3, virt_line_count(old_buf))

      -- An edit of the comment: the editor takes the place of the box.
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 3, 0 })
      assert.is_true(comments.edit())
      assert.are.equal(height, virt_line_count(state.buf))
      assert.are.equal(height, virt_line_count(old_buf))
      editor.cancel()
      assert.are.equal(3, virt_line_count(old_buf))
    end)

    it("gives the other side of the split as many blank lines as the box", function()
      open_diff()
      assert.are.equal("split", view.set_style("split"))
      local state = assert(view.current())
      local width = box_width(state.win)
      comment_on(3, string.rep("long words ", width))
      state = assert(view.current())

      local count = virt_line_count(state.buf)
      assert.is_true(count > 3)
      assert.are.equal(count, virt_line_count(assert(state.old_buf)))
      assert.are.same({}, virt_lines(assert(state.old_buf)))
      for _, line in ipairs(box_lines(state.buf)) do
        assert.are.equal(width, vim.fn.strdisplaywidth(line))
      end
    end)
  end)

  describe("the display", function()
    it("shows the comment in a float on the hover key", function()
      local state = open_diff()
      comment_on(4, "a note in a float")
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      local buf, win = comments.show()
      buf = assert(buf)
      win = assert(win)
      assert.is_true(api.nvim_win_is_valid(win))
      assert.are_not.equal("", api.nvim_win_get_config(win).relative)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal("### comment L2 (new)", lines[1])
      assert.are.equal("a note in a float", lines[#lines])
      assert.is_false(vim.bo[buf].modifiable)
      api.nvim_win_close(win, true)
    end)

    it("draws no virtual lines with the float display", function()
      config.setup({ commit_message = false, comments = { dir = dir, display = "float" } })
      local state = open_diff()
      comment_on(4, "only a sign")
      assert.are.same({ 4 }, sign_rows(state.buf))
      assert.are.same({}, virt_lines(state.buf))
    end)

    it("reports no comment under the cursor", function()
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      local buf, win = comments.show()
      assert.is_nil(buf)
      assert.is_nil(win)
    end)
  end)

  describe("load on reopen", function()
    it("computes the key of the session from the resolved range", function()
      open_diff()
      local review = assert(opened)
      local store = assert(comments.store(review))
      assert.are.equal(store_mod.key(fixture.root, review.range), store.key)
      assert.are.equal(store_mod.path(fixture.root, review.range), store.path)
      assert.are.equal(review.spec, store.spec)
    end)

    it("finds the comments of the same range again", function()
      open_diff()
      comment_on(4, "written in the first session")
      local path = assert(comments.store()).path

      view.close()
      assert(opened):close()
      opened = nil

      local state = open_diff()
      local store = assert(comments.store())
      assert.are.equal(path, store.path)
      assert.are.equal(1, store:count())
      assert.are.equal("written in the first session", store.comments[1].body)
      assert.are.same({ 4 }, sign_rows(state.buf))
      assert.are.same({ "comment L2 (new)", "written in the first session" }, virt_lines(state.buf))
    end)

    it("keeps the comments of another range apart", function()
      open_diff()
      comment_on(4, "about the change")
      view.close()
      assert(opened):close()

      local review = assert(session_mod.open(fixture.ids.base, { dir = fixture.dir }))
      opened = review
      local store = assert(comments.store(review))
      assert.are.equal(0, store:count())
      assert.are_not.equal(store_mod.key(fixture.root, spec()), store.key)
    end)

    it("shows the comment again after a restart of Neovim", function()
      open_diff()
      local comment = comment_on(4, "this note survives a restart")
      local path = assert(comments.store()).path
      view.close()
      assert(opened):close()
      opened = nil

      local script = string.format(
        [[
          require('codeview').setup({ commit_message = false, comments = { dir = %q } })
          local review, err = require('codeview.session').open(%q, { dir = %q })
          if not review then print('ERROR ' .. tostring(err)) return end
          local state = require('codeview.view').open(review, 1)
          local store = require('codeview.comments').store(review)
          local marks = require('codeview.comments').marks(state.buf)
          print(string.format('COUNT %%d ROW %%d BODY %%s', store:count(), marks[1][2] + 1, store.comments[1].body))
        ]],
        dir,
        spec(),
        fixture.dir
      )
      local res = helpers.clean_nvim(script)

      assert.are.equal(1, vim.fn.filereadable(path))
      assert.is_truthy(
        res.output:find("COUNT 1 ROW 4 BODY this note survives a restart", 1, true),
        "the new Neovim shows the comment: " .. res.output
      )
      assert.are.equal("this note survives a restart", comment.body)
    end)

    it("forgets the store after the session closes", function()
      open_diff()
      local review = assert(opened)
      assert.is_truthy(comments.store(review))
      review:close()
      opened = nil

      local store, err = comments.store()
      assert.is_nil(store)
      assert.are.equal("invalid_arg", err.code)
      assert.are.same({}, comments.list())
    end)
  end)

  describe("replies to a GitHub thread", function()
    ---Thread state that lets the user reply.
    ---@type codeview.remote.ThreadState
    local open_thread = {
      id = "PRRT_1",
      resolved = false,
      resolved_by = "",
      can_resolve = true,
      can_unresolve = false,
      can_reply = true,
    }

    ---One comment of GitHub on the new line 2 of call.lua.
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
        created_at = 10,
        outdated = false,
        reactions = {},
        thread = open_thread,
      }, fields or {})
    end

    ---Title of the open editor.
    ---@return string
    local function editor_title()
      local title = api.nvim_win_get_config(assert(editor.current()).win).title
      local text = ""
      for _, chunk in ipairs(type(title) == "table" and title or { { title } }) do
        text = text .. chunk[1]
      end
      return vim.trim(text)
    end

    ---Catch the warnings of a call.
    ---@param fn fun(): any
    ---@return string[] messages
    ---@return any value
    local function warnings(fn)
      local seen = {}
      local notify = vim.notify
      vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
        seen[#seen + 1] = msg
      end
      local ok, value = pcall(fn)
      vim.notify = notify
      assert(ok, value)
      return seen, value
    end

    it("writes a draft reply under the thread of the line", function()
      local state = open_diff()
      require("codeview.remote").attach(assert(opened), { remote_comment() })
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      assert.is_true(comments.reply())
      assert.are.equal("Reply to @grace", editor_title())
      write_comment("a reply of mine")

      local store = assert(comments.store())
      assert.are.equal(1, #store.comments)
      local reply = store.comments[1]
      assert.are.equal("501", reply.reply_to)
      assert.are.equal("call.lua", reply.file)
      assert.are.equal(2, reply.start_line)
      assert.are.equal("new", reply.side)
      assert.are.equal(fixture.ids.change, reply.commit)

      -- The reply is a section of the box of the thread, not a box of its own.
      assert.are.equal(1, #require("codeview.stack").marks(state.buf))
      assert.are.same({
        "@grace L2 (new)",
        "this line needs a test",
        "comment L2 (new) · draft",
        "a reply of mine",
      }, virt_lines(state.buf))
    end)

    it("edits and deletes a draft reply with the keys of a local comment", function()
      local state = open_diff()
      require("codeview.remote").attach(assert(opened), { remote_comment() })
      local store = assert(comments.store())
      local reply = assert(store:add({
        file = "call.lua",
        start_line = 2,
        end_line = 2,
        side = "new",
        reply_to = "501",
        body = "a draft",
      }))
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      assert.is_true(comments.edit_or_add({ view = state }))
      assert.are.same({ "a draft" }, api.nvim_buf_get_lines(assert(editor.current()).buf, 0, -1, false))
      write_comment("a better draft")
      assert.are.equal("a better draft", assert(store:get(reply.id)).body)

      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.is_true(comments.remove({ view = state, confirm = false }))
      assert.are.equal(0, #store.comments)
    end)

    it("asks which thread takes the reply when more than one covers the line", function()
      local state = open_diff()
      require("codeview.remote").attach(assert(opened), {
        remote_comment(),
        remote_comment({ id = 600, author = "ada", created_at = 20 }),
      })
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      local select = vim.ui.select
      local offered
      vim.ui.select = function(items, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        offered = vim.tbl_map(opts.format_item, items)
        cb(items[2])
      end
      local started = comments.reply()
      vim.ui.select = select

      assert.is_true(started)
      assert.are.same({ "@grace L2 (new)", "@ada L2 (new)" }, offered)
      assert.are.equal("Reply to @ada", editor_title())
      write_comment("to ada")
      assert.are.equal("600", assert(comments.store()).comments[1].reply_to)
    end)

    it("does not open the editor for a thread without a reply right", function()
      local state = open_diff()
      require("codeview.remote").attach(
        assert(opened),
        { remote_comment({ thread = vim.tbl_extend("force", open_thread, { can_reply = false }) }) }
      )
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      local seen, started = warnings(function()
        return comments.reply()
      end)
      assert.is_false(started)
      assert.is_false(editor.is_open())
      assert.is_truthy(seen[1]:find("reply", 1, true), seen[1])
    end)

    it("says that the thread state is missing", function()
      local state = open_diff()
      local stateless = remote_comment()
      stateless.thread = nil
      require("codeview.remote").attach(assert(opened), { stateless })
      api.nvim_win_set_cursor(state.win, { 4, 0 })

      local seen, started = warnings(function()
        return comments.reply()
      end)
      assert.is_false(started)
      assert.is_truthy(seen[1]:find("thread state of GitHub is not available", 1, true), seen[1])
    end)

    it("draws a reply to a thread that the session does not hold as its own box", function()
      local state = open_diff()
      local store = assert(comments.store())
      assert(store:add({
        file = "call.lua",
        start_line = 2,
        end_line = 2,
        side = "new",
        reply_to = "999",
        body = "a lost reply",
      }))
      comments.decorate(state)
      assert.are.same({ "comment L2 (new) · reply", "a lost reply" }, virt_lines(state.buf))
    end)
  end)

  describe("a collapsed section", function()
    local diff_fixture = fixtures.git_diff()

    ---Open the diff of long.txt, the file with two hunks and two sections.
    ---@return codeview.view.State
    local function open_long()
      local review, err = session_mod.open(diff_fixture.ids.base .. ".." .. diff_fixture.ids.change, {
        dir = diff_fixture.dir,
      })
      assert.is_nil(err)
      opened = assert(review)
      local state = assert(view.open(review, assert(review:index_of("long.txt"))))
      api.nvim_set_current_win(state.win)
      return state
    end

    it("moves the sign of a hidden line to the row above the section", function()
      local state = open_long()
      -- Row 9 is the filler row of the section that hides the lines 7 to 26.
      assert.are.equal("filler", state.map:kind(9))

      local store = assert(comments.store())
      assert(store:add({
        file = "long.txt",
        start_line = 15,
        end_line = 15,
        side = "new",
        commit = diff_fixture.ids.change,
        body = "about a hidden line",
      }))
      assert.is_true(store:save())
      assert.are.equal(1, comments.refresh())

      -- Row 8 holds line 06, the last line above the section.
      assert.are.same({ 8 }, sign_rows(state.buf))

      view.expand_all()
      state = assert(view.current())
      local row = assert(state.map:buf_row(15, "new"))
      assert.are.same({ row }, sign_rows(state.buf))

      view.collapse_all()
      state = assert(view.current())
      assert.are.same({ 8 }, sign_rows(state.buf))
    end)

    it("keeps the comment of a section at the start of the file", function()
      local state = open_tail()
      -- Row 1 is the filler row of the section that hides the lines 1 to 36.
      -- No row of the new side is at or above line 2.
      assert.are.equal("filler", state.map:kind(1))
      assert.is_nil(state.map:nearest_row(2, "new"))

      local store = assert(comments.store())
      assert(store:add({
        file = "tail.txt",
        start_line = 2,
        end_line = 2,
        side = "new",
        commit = fixture.ids.change,
        body = "please rename this",
      }))
      assert.is_true(store:save())

      local count, hidden = comments.refresh()
      assert.are.equal(1, count)
      assert.are.equal(0, hidden)
      assert.are.same({ 1 }, sign_rows(state.buf))
      assert.are.same({ "comment L2 (new)", "please rename this" }, virt_lines(state.buf))

      -- The row of the section reaches the comment, so edit and delete work.
      api.nvim_win_set_cursor(state.win, { 1, 0 })
      local found = comments.at_cursor()
      assert.are.equal(1, #found)
      assert.are.equal("please rename this", found[1].body)

      view.expand_all()
      state = assert(view.current())
      assert.are.same({ assert(state.map:buf_row(2, "new")) }, sign_rows(state.buf))

      view.collapse_all()
      state = assert(view.current())
      assert.are.same({ 1 }, sign_rows(state.buf))
    end)

    it("removes the fixture", function()
      diff_fixture.cleanup()
      assert.are.equal(0, vim.fn.isdirectory(diff_fixture.dir))
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
