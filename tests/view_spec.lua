local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.view", function()
  local fixture = fixtures.git()
  local view, session_mod, panel
  ---@type codeview.Session?
  local opened

  ---Open a session for the whole fixture history.
  ---@param spec? string
  ---@return codeview.Session
  local function open_session(spec)
    local review, err = session_mod.open(spec or (fixture.ids.init .. ".." .. fixture.ids.shuffle), {
      dir = fixture.dir,
    })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Lines of a buffer.
  ---@param buf integer
  ---@return string[]
  local function lines_of(buf)
    return api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  ---Press keys in the window that has the focus.
  ---@param lhs string
  local function press(lhs)
    api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
  end

  ---Answer the reads of the session after a delay.
  ---@param review codeview.Session
  ---@param delay fun(path: string): integer Delay of one path, in milliseconds.
  local function slow_reads(review, delay)
    review.repo.file_content = function(_, _, path, cb)
      vim.defer_fn(function()
        cb("content of " .. path, nil)
      end, delay(path))
    end
  end

  before_each(function()
    helpers.unload()
    require("codeview.config").setup({ commit_message = false })
    panel = require("codeview.panel")
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
    helpers.unload()
  end)

  describe("open", function()
    it("shows the diff of the file", function()
      local review = open_session()
      local state, err = view.open(review, 1)
      assert.is_nil(err)
      state = assert(state)

      assert.are.equal("a.txt", state.path)
      assert.are.equal(1, state.index)
      assert.are.equal(review.range.to, state.rev)
      assert.are.equal(review.range.from, state.old_rev)
      assert.are.equal(review.range.to, state.new_rev)
      assert.are.same({
        "@@ -1,3 +1,5 @@",
        " one",
        "-two",
        "+two changed",
        " three",
        "+four",
        "+five",
      }, lines_of(state.buf))
      assert.are.equal(state.buf, api.nvim_win_get_buf(state.win))
    end)

    it("keeps a line map of the diff", function()
      local review = open_session()
      local state = assert(view.open(review, 1))
      assert.are.equal(7, state.map:len())
      assert.are.equal("header", state.map:kind(1))
      assert.are.equal(1, state.map:file_line(2, "old"))
      assert.are.equal(2, state.map:file_line(3, "old"))
      assert.are.equal(4, state.map:buf_row(2, "new"))
      assert.are.same({ 1, 6 }, state.map:hunk_starts())
      assert.are.equal(state.map, view.map())
      assert.are.equal("a.txt", assert(view.diff()).path)
    end)

    it("shows a deleted file as removed lines", function()
      local review = open_session()
      local state = assert(view.open(review, 4))
      assert.are.equal("keep.txt", state.path)
      assert.are.equal("deleted", state.status)
      assert.are.equal(review.range.from, state.rev)
      assert.is_nil(state.new_rev)
      assert.are.same({ "@@ -1 +0,0 @@", "-keep me" }, lines_of(state.buf))
      assert.are.equal("delete", state.map:kind(2))
    end)

    it("shows a renamed file with no content change", function()
      local review = open_session()
      local state = assert(view.open(review, 3))
      assert.are.equal("dir/renamed.txt", state.path)
      assert.are.equal("dir/nested.txt", state.diff.old_path)
      assert.are.same({ "The file has no changes." }, lines_of(state.buf))
      assert.are.equal("message", state.map:kind(1))
    end)

    it("sets the buffer options and the filetype", function()
      local review = open_session()
      local state = assert(view.open(review, 3))
      assert.are.equal("nofile", vim.bo[state.buf].buftype)
      assert.is_false(vim.bo[state.buf].modifiable)
      assert.is_false(vim.bo[state.buf].buflisted)
      assert.is_truthy(api.nvim_buf_get_name(state.buf):find("dir/renamed.txt", 1, true))
      assert.are.equal("codeview-diff", vim.bo[state.buf].filetype)
      assert.are.equal("text", vim.b[state.buf].codeview_filetype)
    end)

    it("keeps one view buffer", function()
      local review = open_session()
      local first = assert(view.open(review, 1)).buf
      local second = assert(view.open(review, 2)).buf
      assert.are_not.equal(first, second)
      assert.is_false(api.nvim_buf_is_valid(first))
      assert.is_true(api.nvim_buf_is_valid(second))
    end)

    it("opens asynchronously", function()
      local review = open_session()
      local out, finished = {}, false
      view.open(review, 2, function(state, err)
        out.state, out.err, finished = state, err, true
      end)
      assert.is_true(vim.wait(20000, function()
        return finished
      end, 10))
      assert.is_nil(out.err)
      assert.are.same({ "@@ -0,0 +1 @@", "+added" }, lines_of(out.state.buf))
    end)

    it("sends a User event", function()
      local review = open_session()
      local payload
      local group = api.nvim_create_augroup("codeview.test.view", { clear = true })
      api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CodeViewFileOpened",
        callback = function(event)
          payload = event.data
        end,
      })
      view.open(review, 2)
      api.nvim_del_augroup_by_id(group)

      assert.are.equal(review.id, payload.session)
      assert.are.equal(2, payload.index)
      assert.are.equal("added.txt", payload.path)
      assert.are.equal("added", payload.status)
    end)

    it("does not use a panel window", function()
      local review = open_session()
      local side = panel.new({
        title = "demo",
        render = function()
          return { { text = "one" } }
        end,
      })
      side:open({ focus = true })

      local state = assert(view.open(review, 1))
      assert.is_false(panel.is_panel_win(state.win))
      assert.are.equal(1, #lines_of(assert(side:buffer())))
      side:close()
    end)

    it("reports a position outside the file list", function()
      local review = open_session()
      local state, err = view.open(review, 99)
      assert.is_nil(state)
      assert.are.equal("not_found", err.code)
    end)

    it("reports a closed session", function()
      local review = open_session()
      review:close()
      local state, err = view.open(review, 1)
      assert.is_nil(state)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("reports an argument that is not a session", function()
      local state, err = view.open({}, 1)
      assert.is_nil(state)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("names the buffer of a second open of the same file", function()
      local review = open_session()
      local first = assert(view.open(review, 1))
      local second = assert(view.open(review, 1))
      assert.are_not.equal(first.buf, second.buf)
      local name = string.format("codeview://%d/a.txt", review.id)
      assert.is_truthy(api.nvim_buf_get_name(second.buf):find(name, 1, true))
    end)
  end)

  describe("a request that runs", function()
    it("drops the answer after the session closes", function()
      local review = open_session()
      slow_reads(review, function()
        return 50
      end)
      local win = api.nvim_get_current_win()
      local buf = api.nvim_win_get_buf(win)

      local out, finished = {}, false
      view.open(review, 1, function(state, err)
        out.state, out.err, finished = state, err, true
      end)
      review:close()

      assert.is_true(vim.wait(20000, function()
        return finished
      end, 10))
      assert.is_nil(out.state)
      assert.are.equal("invalid_arg", out.err.code)
      assert.is_nil(view.current())
      assert.are.equal(buf, api.nvim_win_get_buf(win))
    end)

    it("keeps the file of the newest request", function()
      local review = open_session()
      slow_reads(review, function(path)
        return path == "a.txt" and 400 or 20
      end)

      local answered = {}
      view.open(review, 1, function(state)
        answered[#answered + 1] = state and state.index or 0
      end)
      view.open(review, 2, function(state)
        answered[#answered + 1] = state and state.index or 0
      end)

      assert.is_true(vim.wait(20000, function()
        return #answered > 0
      end, 10))
      vim.wait(600, function()
        return #answered > 1
      end, 10)

      assert.are.same({ 2 }, answered)
      assert.are.equal("added.txt", assert(view.current()).path)
      assert.is_true(api.nvim_buf_is_valid(assert(view.current()).buf))
    end)

    it("counts the steps from the request that runs", function()
      local review = open_session()
      slow_reads(review, function()
        return 50
      end)

      view.next(review, function() end)
      assert.are.equal(1, view.step(review, 1))
      view.next(review, function() end)
      assert.are.equal(2, view.step(review, 1))
    end)
  end)

  describe("walk", function()
    -- The tree order of the fixture is dir/renamed.txt, a.txt, added.txt,
    -- keep.txt. The backend order starts with a.txt.
    it("counts the steps from the file that is open", function()
      local review = open_session()
      assert.are.equal(3, view.step(review, 1))
      assert.are.equal(4, view.step(review, -1))

      view.open(review, 2)
      assert.are.equal(4, view.step(review, 1))
      assert.are.equal(1, view.step(review, -1))
    end)

    it("stops at the ends of the list", function()
      local review = open_session()
      view.open(review, 4)
      assert.is_nil(view.step(review, 1))
      local state, err = view.next(review)
      assert.is_nil(state)
      assert.are.equal("not_found", err.code)

      view.open(review, 3)
      assert.is_nil(view.step(review, -1))
      assert.is_nil(view.prev(review))
    end)

    it("opens the next and the previous file", function()
      local review = open_session()
      assert.are.equal("dir/renamed.txt", assert(view.next(review)).path)
      assert.are.equal("a.txt", assert(view.next(review)).path)
      assert.are.equal("dir/renamed.txt", assert(view.prev(review)).path)
    end)

    it("reports an empty file list", function()
      local review = open_session()
      review.files = {}
      assert.is_nil(view.step(review, 1))
    end)
  end)

  describe("state", function()
    it("forgets the file after the session closes", function()
      local review = open_session()
      local buf = assert(view.open(review, 1)).buf
      assert.is_truthy(view.current())

      review:close()
      assert.is_nil(view.current())
      assert.is_false(api.nvim_buf_is_valid(buf))
    end)

    it("deletes the buffer on close", function()
      local review = open_session()
      local buf = assert(view.open(review, 1)).buf
      assert.is_true(view.close())
      assert.is_false(api.nvim_buf_is_valid(buf))
      assert.is_nil(view.current())
      assert.is_false(view.close())
    end)
  end)

  describe("hunks and collapsed sections", function()
    local diff_fixture = fixtures.git_diff()

    ---Open the diff of long.txt, the file with two hunks.
    ---@return codeview.view.State
    local function open_long()
      local review, err = session_mod.open(diff_fixture.ids.base .. ".." .. diff_fixture.ids.change, {
        dir = diff_fixture.dir,
      })
      assert.is_nil(err)
      opened = assert(review)
      local index = assert(review:index_of("long.txt"))
      return assert(view.open(review, index))
    end

    ---Row of the cursor of the view.
    ---@param state codeview.view.State
    ---@return integer
    local function cursor(state)
      return api.nvim_win_get_cursor(state.win)[1]
    end

    it("renders the hunks with a collapsed section between them", function()
      local state = open_long()
      assert.are.same({
        "@@ -1,6 +1,6 @@",
        " line 01",
        " line 02",
        "-line 03",
        "+line 03 changed",
        " line 04",
        " line 05",
        " line 06",
        "⋯ 20 unchanged lines",
        "@@ -27,7 +27,7 @@",
        " line 27",
        " line 28",
        " line 29",
        "-line 30",
        "+line 30 changed",
        " line 31",
        " line 32",
        " line 33",
        "⋯ 7 unchanged lines",
      }, lines_of(state.buf))
      assert.are.equal(2, state.map:hunk_count())
      assert.are.same({ 1, 10 }, state.map:hunk_starts())
    end)

    it("jumps to the next hunk and to the previous hunk", function()
      local state = open_long()
      api.nvim_win_set_cursor(state.win, { 1, 0 })
      assert.are.equal(10, view.next_hunk())
      assert.are.equal(10, cursor(state))
      assert.is_nil(view.next_hunk())
      assert.are.equal(1, view.prev_hunk())
      assert.is_nil(view.prev_hunk())
    end)

    it("wraps the hunk jump on request", function()
      local state = open_long()
      api.nvim_win_set_cursor(state.win, { 10, 0 })
      assert.are.equal(1, view.next_hunk({ wrap = true }))
      assert.are.equal(10, view.prev_hunk({ wrap = true }))
    end)

    it("shows the lines of a collapsed section", function()
      local state = open_long()
      api.nvim_win_set_cursor(state.win, { 9, 0 })
      assert.is_true(view.toggle_context())

      local lines = lines_of(state.buf)
      assert.are.equal(19 + 20 - 1, #lines)
      assert.are.equal(" line 07", lines[9])
      assert.are.equal(" line 26", lines[28])
      assert.are.equal(7, state.map:file_line(9, "new"))
      assert.are.equal("context", state.map:kind(9))
      -- The header of the second hunk keeps the line numbers of the file.
      assert.are.equal("@@ -27,7 +27,7 @@", lines[29])
    end)

    it("hides the lines of a section again", function()
      local state = open_long()
      api.nvim_win_set_cursor(state.win, { 9, 0 })
      view.toggle_context()
      api.nvim_win_set_cursor(state.win, { 9, 0 })
      assert.is_true(view.toggle_context())
      assert.are.equal(19, #lines_of(state.buf))
      assert.are.equal("filler", state.map:kind(9))
    end)

    it("keeps the file line of the cursor after an expand", function()
      local state = open_long()
      api.nvim_win_set_cursor(state.win, { 13, 0 })
      assert.are.equal(29, state.map:file_line(13, "new"))
      view.expand_all()
      assert.are.equal(29, state.map:file_line(cursor(state), "new"))
    end)

    it("shows and hides every section", function()
      local state = open_long()
      assert.is_true(view.expand_all())
      assert.are.equal(40 + 2 + 2, #lines_of(state.buf))
      assert.are.equal(40, state.map:file_line(state.map:len(), "new"))

      assert.is_true(view.collapse_all())
      assert.are.equal(19, #lines_of(state.buf))
    end)

    it("reports a line without a collapsed section", function()
      local state = open_long()
      api.nvim_win_set_cursor(state.win, { 2, 0 })
      assert.is_false(view.toggle_context())
    end)

    it("walks the hunks and the sections with the keymaps", function()
      local state = open_long()
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 1, 0 })

      press("]h")
      assert.are.equal(10, cursor(state))
      press("[h")
      assert.are.equal(1, cursor(state))

      api.nvim_win_set_cursor(state.win, { 9, 0 })
      press("za")
      assert.are.equal("context", state.map:kind(9))
      press("zM")
      assert.are.equal(19, #lines_of(state.buf))
      press("zR")
      assert.are.equal(44, #lines_of(state.buf))
    end)

    it("takes a list of keys for one action", function()
      assert(require("codeview.config").setup({ keymaps = { next_hunk = { "]h", "]c" } } }))
      local state = open_long()
      api.nvim_set_current_win(state.win)

      api.nvim_win_set_cursor(state.win, { 1, 0 })
      press("]c")
      assert.are.equal(10, cursor(state))

      api.nvim_win_set_cursor(state.win, { 1, 0 })
      press("]h")
      assert.are.equal(10, cursor(state))
    end)

    it("reports no file for the diff actions", function()
      view.close()
      assert.is_nil(view.next_hunk())
      assert.is_nil(view.prev_hunk())
      assert.is_false(view.toggle_context())
      assert.is_false(view.expand_all())
      assert.is_false(view.collapse_all())
      assert.is_nil(view.render())
      assert.is_nil(view.map())
      assert.is_nil(view.diff())
    end)

    describe("the layout", function()
      it("keeps the width of the sidebar when a file opens", function()
        local sidebar = require("codeview.sidebar")
        local review = open_session()
        local bar = assert(sidebar.open({ session = review }))
        local win = bar.panel:window()
        api.nvim_win_set_width(win, 28)

        -- The second open is the one that moved the width before: it closes the
        -- window of the first file, which gave its room to the sidebar.
        assert(view.open(review, 1))
        assert.are.equal(28, api.nvim_win_get_width(win))
        assert(view.open(review, 2))
        assert.are.equal(28, api.nvim_win_get_width(win))
        assert(view.open(review, 3))
        assert.are.equal(28, api.nvim_win_get_width(win))

        sidebar.close()
      end)

      it("keeps the width of the sidebar through a style change", function()
        local sidebar = require("codeview.sidebar")
        local review = open_session()
        local bar = assert(sidebar.open({ session = review }))
        local win = bar.panel:window()
        api.nvim_win_set_width(win, 26)

        assert(view.open(review, 1))
        view.set_style("split")
        assert.are.equal(26, api.nvim_win_get_width(win))
        assert(view.open(review, 2))
        assert.are.equal(26, api.nvim_win_get_width(win))
        view.set_style("inline")
        assert.are.equal(26, api.nvim_win_get_width(win))

        sidebar.close()
      end)

      it("opens the file in one window of its own", function()
        local sidebar = require("codeview.sidebar")
        local review = open_session()
        sidebar.open({ session = review })
        local before = #api.nvim_tabpage_list_wins(0)

        assert(view.open(review, 1))
        local after = #api.nvim_tabpage_list_wins(0)
        assert(view.open(review, 2))
        -- A second file takes the window of the first one, so the count holds.
        assert.are.equal(after, #api.nvim_tabpage_list_wins(0))
        assert.is_true(after <= before + 1, "the open added more than one window")

        sidebar.close()
      end)
    end)

    it("removes the fixture", function()
      diff_fixture.cleanup()
      assert.are.equal(0, vim.fn.isdirectory(diff_fixture.dir))
    end)
  end)

  describe("the diff style", function()
    local diff_fixture = fixtures.git_diff()
    local config

    ---Open the diff of long.txt, the file with two hunks.
    ---@return codeview.view.State
    local function open_long()
      local review, err = session_mod.open(diff_fixture.ids.base .. ".." .. diff_fixture.ids.change, {
        dir = diff_fixture.dir,
      })
      assert.is_nil(err)
      opened = assert(review)
      config = require("codeview.config")
      return assert(view.open(review, assert(review:index_of("long.txt"))))
    end

    it("opens two aligned windows", function()
      local state = open_long()
      assert.are.equal("inline", state.style)
      assert.are.equal("split", view.set_style("split"))

      state = assert(view.current())
      local old_win = state.old_win --[[@as integer]]
      assert.are.equal("split", state.style)
      assert.is_true(api.nvim_win_is_valid(old_win))
      assert.are.equal(state.old_buf, api.nvim_win_get_buf(old_win))
      assert.are.equal(state.buf, api.nvim_win_get_buf(state.win))
      -- The old side is the left window of the two.
      assert.is_true(api.nvim_win_get_position(old_win)[2] < api.nvim_win_get_position(state.win)[2])

      local old_lines = lines_of(state.old_buf)
      local new_lines = lines_of(state.buf)
      assert.are.equal(#old_lines, #new_lines)
      assert.are.equal("line 03", old_lines[4])
      assert.are.equal("line 03 changed", new_lines[4])
      assert.are.equal(state.map:len(), state.old_map:len())
    end)

    it("binds the scrolling and the cursor of the two windows", function()
      open_long()
      view.set_style("split")
      local state = assert(view.current())
      local old_win = state.old_win --[[@as integer]]
      assert.is_true(vim.wo[state.win][0].scrollbind)
      assert.is_true(vim.wo[state.win][0].cursorbind)
      assert.is_true(vim.wo[old_win][0].scrollbind)
      assert.is_true(vim.wo[old_win][0].cursorbind)
    end)

    it("keeps the cursor on the same content line in both directions", function()
      local state = open_long()
      -- Row 5 of the inline style is the added line of the first hunk.
      api.nvim_win_set_cursor(state.win, { 5, 0 })
      assert.are.equal(3, (state.map:file_line(5, "new")))

      view.set_style("split")
      state = assert(view.current())
      local row = api.nvim_win_get_cursor(state.win)[1]
      assert.are.equal(3, (state.map:file_line(row, "new")))
      assert.are.equal(row, api.nvim_win_get_cursor(state.old_win --[[@as integer]])[1])

      view.set_style("inline")
      state = assert(view.current())
      assert.are.equal(5, api.nvim_win_get_cursor(state.win)[1])
      assert.are.equal(3, (state.map:file_line(5, "new")))
    end)

    it("keeps a removed line on the old side", function()
      local state = open_long()
      -- Row 4 of the inline style is the removed line of the first hunk.
      api.nvim_win_set_cursor(state.win, { 4, 0 })
      assert.are.equal(3, (state.map:file_line(4, "old")))
      api.nvim_set_current_win(state.win)

      view.set_style("split")
      state = assert(view.current())
      local old_win = state.old_win --[[@as integer]]
      local row = api.nvim_win_get_cursor(old_win)[1]
      assert.are.equal(3, (state.old_map:file_line(row, "old")))
      assert.are.equal(old_win, api.nvim_get_current_win())

      view.set_style("inline")
      assert.are.equal(4, api.nvim_win_get_cursor(assert(view.current()).win)[1])
    end)

    it("keeps the cursor on the header of a hunk", function()
      local state = open_long()
      api.nvim_set_current_win(state.win)
      api.nvim_win_set_cursor(state.win, { 1, 0 })
      press("]h")
      assert.are.equal(10, api.nvim_win_get_cursor(state.win)[1])
      assert.are.equal("header", state.map:kind(10))

      view.set_style("split")
      state = assert(view.current())
      local row = api.nvim_win_get_cursor(state.win)[1]
      assert.are.equal("header", state.map:kind(row))
      assert.are.equal(state.map:hunk_starts()[2], row)

      view.set_style("inline")
      assert.are.equal(10, api.nvim_win_get_cursor(assert(view.current()).win)[1])
    end)

    it("keeps the cursor on the row of a collapsed section", function()
      local state = open_long()
      api.nvim_win_set_cursor(state.win, { 9, 0 })
      assert.are.equal("filler", state.map:kind(9))
      assert.are.equal(1, assert(state.map:row(9)).gap)

      view.set_style("split")
      state = assert(view.current())
      local row = api.nvim_win_get_cursor(state.win)[1]
      assert.are.equal("filler", state.map:kind(row))
      assert.are.equal(1, assert(state.map:row(row)).gap)

      view.set_style("inline")
      assert.are.equal(9, api.nvim_win_get_cursor(assert(view.current()).win)[1])
    end)

    it("takes the inline style after a window of the split closes", function()
      open_long()
      view.set_style("split")
      local state = assert(view.current())
      local old_win = state.old_win --[[@as integer]]

      api.nvim_win_close(old_win, true)
      assert.is_true(vim.wait(1000, function()
        return assert(view.current()).style == "inline"
      end, 10))

      state = assert(view.current())
      assert.is_nil(state.old_win)
      assert.is_nil(state.old_map)
      assert.is_true(api.nvim_win_is_valid(state.win))
      assert.are.equal(state.buf, api.nvim_win_get_buf(state.win))
      assert.are.equal("@@ -1,6 +1,6 @@", lines_of(state.buf)[1])
      -- The option keeps the style that the user asked for.
      assert.are.equal("split", config.get().diff.style)
    end)

    it("keeps the handles of the session at the windows that live", function()
      open_long()
      local review = assert(opened)
      for _ = 1, 3 do
        view.set_style("split")
        view.set_style("inline")
      end
      for _, win in ipairs(review.windows) do
        assert.is_true(api.nvim_win_is_valid(win))
      end
      for _, buf in ipairs(review.buffers) do
        assert.is_true(api.nvim_buf_is_valid(buf))
      end
    end)

    it("shows the same hunks in both styles", function()
      local state = open_long()
      local hunks = state.map:hunk_count()
      view.set_style("split")
      state = assert(view.current())
      assert.are.equal(hunks, state.map:hunk_count())
      assert.are.equal(hunks, state.old_map:hunk_count())
      assert.are.same(state.map:hunk_starts(), state.old_map:hunk_starts())
    end)

    it("reads the file once for both styles", function()
      local state = open_long()
      local before = state.diff
      local reads = 0
      state.session.repo.file_content = function(...)
        reads = reads + 1
        return nil, nil, select(4, ...)
      end
      view.set_style("split")
      assert.are.equal(0, reads)
      assert.are.equal(before, assert(view.current()).diff)
    end)

    it("stores the style in the configuration", function()
      open_long()
      view.set_style("split")
      assert.are.equal("split", config.get().diff.style)
      assert.are.equal("split", view.style())

      -- The next file opens in the style of the configuration.
      local review = assert(opened)
      local state = assert(view.open(review, assert(review:index_of("added.txt"))))
      assert.are.equal("split", state.style)
      assert.is_truthy(state.old_win)
    end)

    it("switches with one key", function()
      local state = open_long()
      api.nvim_set_current_win(state.win)
      local key = config.get().keymaps.toggle_style:gsub("<leader>", vim.g.mapleader or "\\")

      press(key)
      assert.are.equal("split", assert(view.current()).style)
      press(key)
      assert.are.equal("inline", assert(view.current()).style)
    end)

    it("takes the other style without an argument", function()
      open_long()
      assert.are.equal("split", view.toggle_style())
      assert.are.equal("inline", view.toggle_style())
    end)

    it("reports an unknown style", function()
      local state = open_long()
      assert.is_nil(view.set_style("unified"))
      assert.are.equal("inline", assert(view.current()).style)
      assert.are.equal(state.buf, assert(view.current()).buf)
    end)

    it("keeps the style of the configuration without a file", function()
      view.close()
      session_mod.close()
      assert.are.equal("split", view.set_style("split"))
      assert.are.equal("inline", view.toggle_style())
    end)

    it("closes both buffers and the window of the old side", function()
      open_long()
      view.set_style("split")
      local state = assert(view.current())
      local old_win, old_buf, buf = state.old_win, state.old_buf, state.buf

      assert.is_true(view.close())
      assert.is_false(api.nvim_win_is_valid(old_win))
      assert.is_false(api.nvim_buf_is_valid(old_buf))
      assert.is_false(api.nvim_buf_is_valid(buf))
    end)

    it("closes the windows of the split with the session", function()
      open_long()
      view.set_style("split")
      local state = assert(view.current())
      local old_win = state.old_win --[[@as integer]]
      opened:close()
      assert.is_false(api.nvim_win_is_valid(old_win))
      assert.is_nil(view.current())
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
