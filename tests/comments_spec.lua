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

  ---Text of the virtual lines of every mark of a buffer.
  ---
  --- A line without text does not count. The other side of a side-by-side view
  --- takes such lines, so that both windows grow by the same height.
  ---@param buf integer
  ---@return string[] lines
  local function virt_lines(buf)
    local out = {}
    for _, mark in ipairs(marks_of(buf)) do
      for _, line in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(line) do
          text = text .. chunk[1]
        end
        if text ~= "" then
          out[#out + 1] = text
        end
      end
    end
    return out
  end

  ---Number of virtual lines of a buffer, with the blank ones.
  ---@param buf integer
  ---@return integer count
  local function virt_line_count(buf)
    local count = 0
    for _, mark in ipairs(marks_of(buf)) do
      count = count + #(mark[4].virt_lines or {})
    end
    return count
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = fixtures.tempdir("codeview-comments")
    assert(config.setup({ comments = { dir = dir } }))
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
        "▌ comment L3-4 (new)",
        "▌ first line",
        "▌ second line",
      }, virt_lines(state.buf))

      -- The body sits below the last row of the range, and only there.
      local last = nil
      for _, mark in ipairs(marks_of(state.buf)) do
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
      assert.are.same({ "▌ comment L2 (old)", "▌ the old side" }, virt_lines(state.old_buf))
      assert.are.same({ "▌ comment L2 (new)", "▌ the new side" }, virt_lines(state.buf))
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

      -- The comment adds four virtual lines to the new side. The old side takes
      -- four blank ones, so both windows keep the same height.
      assert.are.equal(4, virt_line_count(state.buf))
      assert.are.equal(4, virt_line_count(assert(state.old_buf)))
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

      -- The space comes from an extmark, so the diff keeps its rows.
      local ns = api.nvim_create_namespace("codeview.editor")
      assert.are.equal(1, #api.nvim_buf_get_extmarks(state.buf, ns, 0, -1, {}))
      assert.are.equal(rows, api.nvim_buf_line_count(state.buf))
      assert.is_false(vim.bo[state.buf].modifiable)
      editor.cancel()
    end)

    it("takes the space back after a discard", function()
      local state = open_diff()
      local ns = api.nvim_create_namespace("codeview.editor")
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      assert.are.equal(1, #api.nvim_buf_get_extmarks(state.buf, ns, 0, -1, {}))

      editor.cancel()
      assert.are.equal(0, #api.nvim_buf_get_extmarks(state.buf, ns, 0, -1, {}))
    end)

    it("takes the space back after a save", function()
      local state = open_diff()
      local ns = api.nvim_create_namespace("codeview.editor")
      local rows = api.nvim_buf_line_count(state.buf)
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "saved" })
      assert.is_true(editor.submit())

      assert.are.equal(0, #api.nvim_buf_get_extmarks(state.buf, ns, 0, -1, {}))
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
      assert(config.setup({ comments = { dir = dir, start_insert = false } }))
      local state = open_diff()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      comments.add()
      assert.is_false(assert(editor.current()).insert)
      editor.cancel()
    end)

    it("opens a float when the option asks for one", function()
      assert(config.setup({ comments = { dir = dir, editor = "float" } }))
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
      assert.are.equal(1, #api.nvim_tabpage_list_wins(0))
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

    it("takes the keys from the configuration", function()
      config.setup({ comments = { dir = dir }, keymaps = { comment_insert = { "gc" }, comment_visual = false } })
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
      assert.are.same({ "▌ comment L2 (new)", "▌ one" }, virt_lines(state.buf))

      comments.edit({ id = comment.id })
      write_comment("two")
      assert.are.equal(1, #marks_of(state.buf))
      assert.are.same({ "▌ comment L2 (new)", "▌ two" }, virt_lines(state.buf))

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
      assert.are.equal(0, assert(store_mod.load({ repo = fixture.root, range = store.range })):count())
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
      assert.are.same({ "✓ comment L2 (new) · resolved", "✓ please rename this" }, virt_lines(state.buf))
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
      config.setup({ comments = { dir = dir, display = "float" } })
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
      assert.are.same({ "▌ comment L2 (new)", "▌ written in the first session" }, virt_lines(state.buf))
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
          require('codeview').setup({ comments = { dir = %q } })
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
      assert.are.same({ "▌ comment L2 (new)", "▌ please rename this" }, virt_lines(state.buf))

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
