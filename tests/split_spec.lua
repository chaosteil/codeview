local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.split", function()
  local diff, inline, split

  ---Numbered lines, for a diff with a wide gap.
  ---@param count integer
  ---@param mark? table<integer, string>
  ---@return string
  local function numbered(count, mark)
    mark = mark or {}
    local lines = {}
    for index = 1, count do
      lines[index] = string.format("line %02d%s", index, mark[index] or "")
    end
    return table.concat(lines, "\n") .. "\n"
  end

  ---Kind of every aligned row of a build.
  ---@param build codeview.split.Build
  ---@return string[]
  local function kinds_of(build)
    local out = {}
    for lnum, row in ipairs(build.rows) do
      out[lnum] = row.kind
    end
    return out
  end

  ---Two buffers with a rendered diff.
  ---@param file codeview.diff.File
  ---@param opts? codeview.split.Opts
  ---@return integer old_buf
  ---@return integer new_buf
  ---@return codeview.split.Build build
  local function render(file, opts)
    local old_buf = api.nvim_create_buf(false, true)
    local new_buf = api.nvim_create_buf(false, true)
    return old_buf, new_buf, split.render(old_buf, new_buf, file, opts)
  end

  ---Line highlight of every row of a buffer.
  ---@param buf integer
  ---@return table<integer, string>
  local function line_groups(buf)
    local out = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, split.ns, 0, -1, { details = true })) do
      if mark[4].line_hl_group then
        out[mark[2] + 1] = mark[4].line_hl_group
      end
    end
    return out
  end

  ---Highlights inside a row of a buffer.
  ---@param buf integer
  ---@return { row: integer, col: integer, end_col: integer, hl: string }[]
  local function inner_marks(buf)
    local out = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, split.ns, 0, -1, { details = true })) do
      if mark[4].hl_group then
        out[#out + 1] = { row = mark[2] + 1, col = mark[3], end_col = mark[4].end_col, hl = mark[4].hl_group }
      end
    end
    return out
  end

  ---Run a key sequence in the current window.
  ---@param lhs string
  local function press(lhs)
    api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "nx", false)
  end

  ---Delete a list of buffers.
  ---@param ... integer
  local function drop(...)
    for _, buf in ipairs({ ... }) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_delete(buf, { force = true })
      end
    end
  end

  before_each(function()
    helpers.unload()
    diff = require("codeview.diff")
    inline = require("codeview.inline")
    split = require("codeview.split")
  end)

  after_each(function()
    pcall(api.nvim_del_augroup_by_name, "codeview.highlight")
    helpers.unload()
  end)

  describe("build", function()
    it("puts the old side left and the new side right", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\nfour\nfive\n")
      local build = split.build(file)

      assert.are.same({
        "@@ -1,3 @@",
        "one",
        "two",
        "three",
        "",
        "",
      }, build.old.lines)
      assert.are.same({
        "@@ +1,5 @@",
        "one",
        "two changed",
        "three",
        "four",
        "five",
      }, build.new.lines)
      assert.are.same({ "header", "context", "change", "context", "add", "add" }, kinds_of(build))
    end)

    it("keeps the two sides on the same rows", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\nfour\nfive\n")
      local build = split.build(file)
      assert.are.equal(#build.old.lines, #build.new.lines)
      assert.are.equal(#build.rows, build.old.map:len())
      assert.are.equal(#build.rows, build.new.map:len())
    end)

    it("reports the filler rows of the side without lines", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\nfour\nfive\n")
      local build = split.build(file)

      assert.are.same({ 5, 6 }, build.old.fillers)
      assert.are.same({}, build.new.fillers)
      assert.are.equal("filler", build.old.map:kind(5))
      assert.are.equal("add", build.new.map:kind(5))
      assert.is_nil(build.old.map:file_line(5))
      assert.are.equal(4, build.new.map:file_line(5, "new"))
    end)

    it("puts the filler on the new side for a removal", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\nthree\n")
      local build = split.build(file)

      assert.are.same({ "@@ -1,3 @@", "one", "two", "three" }, build.old.lines)
      assert.are.same({ "@@ +1,2 @@", "one", "", "three" }, build.new.lines)
      assert.are.same({ 3 }, build.new.fillers)
      assert.are.same({}, build.old.fillers)
      assert.are.equal("delete", build.old.map:kind(3))
      assert.are.equal(2, build.old.map:file_line(3, "old"))
    end)

    it("aligns a change that adds more lines than it removes", function()
      local file = diff.compute("one\ntwo\n", "one\ntwo changed\nthree\nfour\n")
      local build = split.build(file)

      assert.are.same({ "@@ -1,2 @@", "one", "two", "", "" }, build.old.lines)
      assert.are.same({ "@@ +1,4 @@", "one", "two changed", "three", "four" }, build.new.lines)
      assert.are.same({ 4, 5 }, build.old.fillers)
    end)

    it("maps a row to the line of each side", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\n")
      local build = split.build(file)

      assert.are.same({ kind = "context", old = 1, new = 1, hunk = 1 }, build.old.map:row(2))
      assert.are.same({ kind = "delete", old = 2, hunk = 1 }, build.old.map:row(3))
      assert.are.same({ kind = "add", new = 2, hunk = 1 }, build.new.map:row(3))
      assert.are.equal(3, build.old.map:buf_row(2, "old"))
      assert.are.equal(3, build.new.map:buf_row(2, "new"))
      assert.are.equal("old", build.old.map:side(3))
      assert.are.equal("new", build.new.map:side(3))
    end)

    it("shows the same hunks as the inline style", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local build = split.build(file)
      local unified = inline.build(file)

      assert.are.equal(unified.map:hunk_count(), build.new.map:hunk_count())
      assert.are.equal(unified.map:hunk_count(), build.old.map:hunk_count())
      assert.are.same(build.new.map:hunk_starts(), build.old.map:hunk_starts())
      assert.are.equal(#unified.gaps, #build.gaps)
      assert.are.equal(unified.gaps[1].count, build.gaps[1].count)
    end)

    it("hides an unchanged section on both sides", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local build = split.build(file)

      -- A change is one row of the side-by-side view, so the section starts
      -- one row above the row of the inline style.
      assert.are.equal("⋯ 20 unchanged lines", build.old.lines[8])
      assert.are.equal("⋯ 20 unchanged lines", build.new.lines[8])
      assert.are.equal("filler", build.old.map:kind(8))
      assert.are.equal(1, build.gaps[1].id)
      assert.are.equal(8, build.gaps[1].row)
      assert.are.equal(1, assert(build.rows[8]).gap)
      assert.are.same({ 1, 9 }, build.new.map:hunk_starts())
    end)

    it("shows the lines of a section on request", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local build = split.build(file, { expanded = { [1] = true } })

      assert.are.equal("line 07", build.old.lines[8])
      assert.are.equal("line 07", build.new.lines[8])
      assert.are.equal("context", build.old.map:kind(8))
      assert.are.equal(7, build.new.map:file_line(8, "new"))
      assert.is_true(build.gaps[1].expanded)
      assert.is_nil(build.gaps[1].row)
    end)

    it("renders a note of a file without a text diff", function()
      local file = diff.compute("same\n", "same\n")
      local build = split.build(file)
      assert.are.same({ "The file has no changes." }, build.old.lines)
      assert.are.same({ "The file has no changes." }, build.new.lines)
      assert.are.equal("message", build.new.map:kind(1))

      local binary = split.build(diff.compute("a\0b", "a\0c"))
      assert.are.same({ "The file is binary. It has no text diff." }, binary.old.lines)
      assert.are.same({ "" }, binary.new.lines)

      local empty = split.build(diff.compute("", ""))
      assert.are.same({ "The file is empty." }, empty.new.lines)
    end)

    it("marks the changed part of a line on both sides", function()
      local file = diff.compute("local value = 1\n", "local value = 2\n")
      local build = split.build(file, { word_diff = true })
      assert.are.same({ { row = 2, col = 14, end_col = 15, hl = "CodeViewDiffText" } }, build.old.marks)
      assert.are.same({ { row = 2, col = 14, end_col = 15, hl = "CodeViewDiffText" } }, build.new.marks)
    end)

    it("marks nothing when the option is off", function()
      local file = diff.compute("local value = 1\n", "local value = 2\n")
      local build = split.build(file, { word_diff = false })
      assert.are.same({}, build.old.marks)
      assert.are.same({}, build.new.marks)
    end)
  end)

  describe("render", function()
    it("writes both buffers and keeps them read-only", function()
      local file = diff.compute("one\ntwo\n", "one\ntwo changed\nthree\n")
      local old_buf, new_buf, build = render(file)

      assert.are.same(build.old.lines, api.nvim_buf_get_lines(old_buf, 0, -1, false))
      assert.are.same(build.new.lines, api.nvim_buf_get_lines(new_buf, 0, -1, false))
      assert.is_false(vim.bo[old_buf].modified)
      assert.are.equal("old", assert(split.get(old_buf)).side)
      assert.are.equal("new", assert(split.get(new_buf)).side)
      assert.are.equal(build.old.map, split.map(old_buf))
      assert.are.equal(build.new.map, split.map(new_buf))
      drop(old_buf, new_buf)
    end)

    it("highlights the removals left and the additions right", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\nfour\n")
      local old_buf, new_buf = render(file)
      local old_groups, new_groups = line_groups(old_buf), line_groups(new_buf)

      assert.are.equal("CodeViewDiffHunk", old_groups[1])
      assert.are.equal("CodeViewDiffHunk", new_groups[1])
      assert.is_nil(old_groups[2])
      assert.are.equal("CodeViewDiffDelete", old_groups[3])
      assert.are.equal("CodeViewDiffAdd", new_groups[3])
      assert.are.equal("CodeViewDiffFiller", old_groups[5])
      assert.are.equal("CodeViewDiffAdd", new_groups[5])
      drop(old_buf, new_buf)
    end)

    it("marks a filler row with virtual text", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\nfour\n")
      local old_buf, new_buf = render(file)

      local marks = api.nvim_buf_get_extmarks(old_buf, split.ns, { 4, 0 }, { 4, -1 }, { details = true })
      assert.are.equal(1, #marks)
      local details = marks[1][4]
      assert.are.equal("CodeViewDiffFiller", details.line_hl_group)
      assert.are.equal("CodeViewDiffFiller", details.virt_text[1][2])
      assert.is_truthy(details.virt_text[1][1]:find(split.filler_char, 1, true))
      drop(old_buf, new_buf)
    end)

    it("highlights the row of a collapsed section on both sides", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local old_buf, new_buf = render(file)
      assert.are.equal("CodeViewDiffFold", line_groups(old_buf)[8])
      assert.are.equal("CodeViewDiffFold", line_groups(new_buf)[8])
      assert.are.equal(1, assert(split.gap_at(new_buf, 8)).id)
      assert.are.equal(2, #split.gaps(new_buf))
      assert.is_nil(split.gap_at(new_buf, 2))
      drop(old_buf, new_buf)
    end)

    it("highlights the changed part of a line", function()
      local old_buf, new_buf = render(diff.compute("local value = 1\n", "local value = 2\n"), { word_diff = true })
      assert.are.same({ { row = 2, col = 14, end_col = 15, hl = "CodeViewDiffText" } }, inner_marks(old_buf))
      assert.are.same({ { row = 2, col = 14, end_col = 15, hl = "CodeViewDiffText" } }, inner_marks(new_buf))
      drop(old_buf, new_buf)
    end)

    it("forgets the state of a buffer that goes away", function()
      local old_buf, new_buf = render(diff.compute("one\n", "two\n"))
      drop(old_buf, new_buf)
      assert.is_nil(split.get(old_buf))
      assert.is_nil(split.map(new_buf))
      assert.are.same({}, split.gaps(new_buf))
    end)

    it("renders the same buffers again", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local old_buf, new_buf = render(file)
      local build = split.render(old_buf, new_buf, file, { expanded = { [1] = true } })
      assert.are.equal(#build.rows, #api.nvim_buf_get_lines(old_buf, 0, -1, false))
      assert.are.equal(#build.rows, #api.nvim_buf_get_lines(new_buf, 0, -1, false))
      drop(old_buf, new_buf)
    end)
  end)

  describe("the status column", function()
    it("shows the number of the side of the buffer", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed" }))
      local old_buf, new_buf = render(file)

      assert.are.equal("   ", split.number_column(old_buf, 1))
      assert.are.equal(" 1 ", split.number_column(old_buf, 2))
      assert.are.equal(" 3 ", split.number_column(old_buf, 4))
      assert.are.equal(" 3 ", split.number_column(new_buf, 4))
      assert.are.equal("   ", split.number_column(new_buf, 8))
      assert.are.equal("", split.number_column(api.nvim_create_buf(false, true), 1))
      drop(old_buf, new_buf)
    end)

    it("reads the buffer of the window that asks", function()
      local old_buf, new_buf = render(diff.compute("one\ntwo\n", "one\ntwo changed\n"))
      local win = api.nvim_open_win(old_buf, false, { split = "right" })

      vim.g.statusline_winid = win
      vim.v.lnum = 2
      assert.are.equal("%#CodeViewDiffNumber#1 %*%s", split.statuscolumn())

      split.attach_window(win)
      assert.are.equal(split.statuscolumn_expr, vim.wo[win][0].statuscolumn)
      assert.is_true(vim.wo[win][0].scrollbind)
      assert.is_true(vim.wo[win][0].cursorbind)
      assert.is_false(vim.wo[win][0].wrap)

      api.nvim_win_close(win, true)
      drop(old_buf, new_buf)
    end)
  end)

  describe("bind", function()
    it("puts the two windows on the same top line", function()
      local file = diff.compute(numbered(200), numbered(200, { [150] = " changed" }))
      local old_buf, new_buf, build = render(file)

      local new_win = api.nvim_open_win(new_buf, true, { split = "right" })
      local old_win = api.nvim_open_win(old_buf, false, { split = "left", win = new_win })
      split.attach_window(old_win)
      split.attach_window(new_win)

      api.nvim_win_set_cursor(new_win, { build.new.map:len(), 0 })
      api.nvim_win_call(new_win, function()
        vim.cmd("normal! zt")
      end)
      assert.is_true(split.bind(old_win, new_win))

      local top_of = function(win)
        return api.nvim_win_call(win, function()
          return vim.fn.line("w0")
        end)
      end
      assert.are.equal(top_of(new_win), top_of(old_win))

      api.nvim_win_close(old_win, true)
      api.nvim_win_close(new_win, true)
      drop(old_buf, new_buf)
    end)

    it("keeps the two windows on the same top line during a scroll", function()
      local file = diff.compute(numbered(200), numbered(200, { [150] = " changed" }))
      local old_buf, new_buf = render(file)

      local new_win = api.nvim_open_win(new_buf, true, { split = "right" })
      local old_win = api.nvim_open_win(old_buf, false, { split = "left", win = new_win })
      split.attach_window(old_win)
      split.attach_window(new_win)
      assert.is_true(split.bind(old_win, new_win))

      local top_of = function(win)
        return api.nvim_win_call(win, function()
          return vim.fn.line("w0")
        end)
      end
      -- The first scroll after the bind counts too. A ":syncbind" call makes
      -- Neovim drop it, which moves the new side alone.
      api.nvim_set_current_win(new_win)
      press("<C-e>")
      assert.is_true(top_of(new_win) > 1)
      assert.are.equal(top_of(new_win), top_of(old_win))

      press("<C-d>")
      assert.are.equal(top_of(new_win), top_of(old_win))

      -- A scroll of the old side moves the new side as well.
      api.nvim_set_current_win(old_win)
      press("<C-e><C-e>")
      assert.are.equal(top_of(old_win), top_of(new_win))

      api.nvim_win_close(old_win, true)
      api.nvim_win_close(new_win, true)
      drop(old_buf, new_buf)
    end)

    it("reports a window that is gone", function()
      assert.is_false(split.bind(nil, nil))
      assert.is_false(split.bind(9999, 9998))
    end)
  end)
end)
