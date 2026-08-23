local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.inline", function()
  local diff, inline, highlight

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

  ---Kind of every row of a build.
  ---@param build codeview.inline.Build
  ---@return string[]
  local function kinds_of(build)
    local out = {}
    for lnum in ipairs(build.lines) do
      out[lnum] = build.map:kind(lnum)
    end
    return out
  end

  ---Buffer with a rendered diff.
  ---@param file codeview.diff.File
  ---@param opts? codeview.inline.Opts
  ---@return integer buf
  ---@return codeview.inline.Build build
  local function render(file, opts)
    local buf = api.nvim_create_buf(false, true)
    local build = inline.render(buf, file, opts)
    return buf, build
  end

  ---Line highlight of every row of a buffer.
  ---@param buf integer
  ---@return table<integer, string>
  local function line_groups(buf)
    local out = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, inline.ns, 0, -1, { details = true })) do
      local details = mark[4]
      if details.line_hl_group then
        out[mark[2] + 1] = details.line_hl_group
      end
    end
    return out
  end

  ---Highlights inside a row of a buffer.
  ---@param buf integer
  ---@return { row: integer, col: integer, end_col: integer, hl: string }[]
  local function inner_marks(buf)
    local out = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, inline.ns, 0, -1, { details = true })) do
      local details = mark[4]
      if details.hl_group then
        out[#out + 1] = { row = mark[2] + 1, col = mark[3], end_col = details.end_col, hl = details.hl_group }
      end
    end
    return out
  end

  before_each(function()
    helpers.unload()
    diff = require("codeview.diff")
    inline = require("codeview.inline")
    highlight = require("codeview.highlight")
  end)

  after_each(function()
    pcall(api.nvim_del_augroup_by_name, "codeview.highlight")
    helpers.unload()
  end)

  describe("build", function()
    it("renders a unified diff with markers", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\n")
      local build = inline.build(file)
      assert.are.same({
        "@@ -1,3 +1,3 @@",
        " one",
        "-two",
        "+two changed",
        " three",
      }, build.lines)
      assert.are.same({ "header", "context", "delete", "add", "context" }, kinds_of(build))
    end)

    it("maps every row to the old line and the new line", function()
      local file = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\n")
      local map = inline.build(file).map

      assert.are.same({ kind = "header", hunk = 1 }, map:row(1))
      assert.are.same({ kind = "context", old = 1, new = 1, hunk = 1 }, map:row(2))
      assert.are.same({ kind = "delete", old = 2, hunk = 1 }, map:row(3))
      assert.are.same({ kind = "add", new = 2, hunk = 1 }, map:row(4))
      assert.are.same({ kind = "context", old = 3, new = 3, hunk = 1 }, map:row(5))

      assert.are.equal(3, map:buf_row(2, "old"))
      assert.are.equal(4, map:buf_row(2, "new"))
      assert.are.equal(2, map:buf_row(1, "old"))
      assert.are.equal(2, map:buf_row(1, "new"))
    end)

    it("renders an added file", function()
      local file = diff.compute("", "one\ntwo\n")
      file.status = "added"
      local build = inline.build(file)
      assert.are.same({ "@@ -0,0 +1,2 @@", "+one", "+two" }, build.lines)
      assert.are.same({ "header", "add", "add" }, kinds_of(build))
      assert.are.equal(1, build.map:file_line(2, "new"))
      assert.is_nil(build.map:file_line(2, "old"))
      assert.is_nil(build.map:buf_row(1, "old"))
      assert.are.equal(3, build.map:buf_row(2, "new"))
    end)

    it("renders a deleted file", function()
      local file = diff.compute("one\ntwo\n", "")
      file.status = "deleted"
      local build = inline.build(file)
      assert.are.same({ "@@ -1,2 +0,0 @@", "-one", "-two" }, build.lines)
      assert.are.same({ "header", "delete", "delete" }, kinds_of(build))
      assert.are.equal(2, build.map:file_line(3, "old"))
      assert.is_nil(build.map:file_line(3, "new"))
      assert.are.equal("old", build.map:side(2))
    end)

    it("renders a renamed file without a content change", function()
      local file = diff.compute("same\n", "same\n")
      file.status = "renamed"
      file.old_path = "old/name.txt"
      file.path = "new/name.txt"
      local build = inline.build(file)
      assert.are.same({ "The file has no changes." }, build.lines)
      assert.are.same({ "message" }, kinds_of(build))
      assert.is_nil(build.map:side(1))
      assert.is_nil(build.map:file_line(1))
      assert.are.equal(0, build.map:hunk_count())
    end)

    it("renders an empty file", function()
      local file = diff.compute("", "")
      file.status = "added"
      local build = inline.build(file)
      assert.are.same({ "The file is empty." }, build.lines)
      assert.are.same({ "message" }, kinds_of(build))
      assert.is_nil(build.map:buf_row(1, "new"))
    end)

    it("renders a binary file", function()
      local file = diff.compute("a\0b", "a\0c")
      local build = inline.build(file)
      assert.are.same({ "The file is binary. It has no text diff." }, build.lines)
      assert.are.same({ "message" }, kinds_of(build))
      assert.are.equal(0, build.map:hunk_count())
      assert.is_nil(build.map:file_line(1))
    end)

    it("keeps the context of the configuration around a hunk", function()
      local file = diff.compute(numbered(20), numbered(20, { [10] = " changed" }), { context = 1 })
      local build = inline.build(file)
      assert.are.same({
        "⋯ 8 unchanged lines",
        "@@ -9,3 +9,3 @@",
        " line 09",
        "-line 10",
        "+line 10 changed",
        " line 11",
        "⋯ 9 unchanged lines",
      }, build.lines)
    end)

    it("hides the unchanged section between two hunks", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local build = inline.build(file)

      assert.are.equal("⋯ 20 unchanged lines", build.lines[9])
      assert.are.equal("filler", build.map:kind(9))
      assert.are.equal(2, #build.gaps)
      assert.are.equal(20, build.gaps[1].count)
      assert.are.equal(7, build.gaps[1].old)
      assert.are.equal(9, build.gaps[1].row)
      assert.is_false(build.gaps[1].expanded)
      assert.are.equal(2, build.map:hunk_count())
      assert.are.same({ 1, 10 }, build.map:hunk_starts())
      assert.are.same({ 1, 8 }, { build.map:hunk_rows(1) })
    end)

    it("shows a short unchanged section in full", function()
      -- The section between the two changes holds 7 lines. A filler row for
      -- 1 hidden line saves no screen row, so the section stays open.
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [11] = " changed" }))
      local build = inline.build(file)

      assert.are.same({
        "@@ -1,14 +1,14 @@",
        " line 01",
        " line 02",
        "-line 03",
        "+line 03 changed",
        " line 04",
        " line 05",
        " line 06",
        " line 07",
        " line 08",
        " line 09",
        " line 10",
        "-line 11",
        "+line 11 changed",
        " line 12",
        " line 13",
        " line 14",
        "⋯ 26 unchanged lines",
      }, build.lines)
      assert.are.equal(1, #build.gaps)
    end)

    it("gives every row of a group the hunk that owns it", function()
      local file = diff.compute(numbered(20), numbered(20, { [5] = " changed", [12] = " changed" }))
      local build = inline.build(file, { context = 5 })

      -- One group holds both hunks. The rows of the two hunks stay apart.
      assert.are.equal(1, #build.gaps)
      assert.are.equal(2, build.map:hunk_count())
      assert.are.same({ 1, 13 }, { build.map:hunk_rows(1) })
      assert.are.same({ 14, 20 }, { build.map:hunk_rows(2) })
      assert.are.same({ 1, 14 }, build.map:hunk_starts())
      assert.are.equal(2, build.map:hunk(20))
      assert.is_nil(build.map:hunk(21))
    end)

    it("shows the lines of a section on request", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local build = inline.build(file, { expanded = { [1] = true } })

      assert.are.equal(" line 07", build.lines[9])
      assert.are.equal("context", build.map:kind(9))
      assert.are.equal(7, build.map:file_line(9, "old"))
      assert.are.equal(1, build.map:row(9).gap)
      assert.is_nil(build.map:row(9).hunk)
      assert.is_true(build.gaps[1].expanded)
      assert.is_nil(build.gaps[1].row)
      -- The header of the second hunk keeps the numbers of the file.
      assert.are.equal("@@ -27,7 +27,7 @@", build.lines[29])
    end)

    it("finds the row of a hidden line above the section", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local build = inline.build(file)
      assert.is_nil(build.map:buf_row(15, "new"))
      assert.are.equal(8, build.map:nearest_row(15, "new"))
    end)

    it("marks the changed part of a line", function()
      local file = diff.compute("local value = 1\n", "local value = 2\n")
      local build = inline.build(file, { word_diff = true })
      assert.are.same({
        { row = 2, col = 15, end_col = 16, hl = "CodeViewDiffText" },
        { row = 3, col = 15, end_col = 16, hl = "CodeViewDiffText" },
      }, build.marks)
    end)

    it("keeps a multi-byte character whole", function()
      local file = diff.compute("héllo wörld\n", "héllo wérld\n")
      local build = inline.build(file, { word_diff = true })
      local mark = build.marks[1]
      local text = build.lines[2]:sub(mark.col + 1, mark.end_col)
      assert.are.equal("ö", text)
    end)

    it("marks nothing without a common part", function()
      local file = diff.compute("aaa\n", "bbb\n")
      assert.are.same({}, inline.build(file, { word_diff = true }).marks)
    end)

    it("marks nothing when the option is off", function()
      local file = diff.compute("local value = 1\n", "local value = 2\n")
      assert.are.same({}, inline.build(file, { word_diff = false }).marks)
    end)

    it("marks nothing when the two sides have another line count", function()
      local file = diff.compute("one\n", "one changed\ntwo\n")
      assert.are.same({}, inline.build(file, { word_diff = true }).marks)
    end)
  end)

  describe("render", function()
    it("writes the lines and keeps the buffer read-only", function()
      local file = diff.compute("one\ntwo\n", "one\ntwo changed\n")
      local buf = api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = false
      local build = inline.render(buf, file)

      assert.are.same(build.lines, api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_false(vim.bo[buf].modifiable)
      assert.is_false(vim.bo[buf].modified)
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("highlights the added lines and the removed lines", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local buf = render(file)
      local groups = line_groups(buf)

      assert.are.equal("CodeViewDiffHunk", groups[1])
      assert.is_nil(groups[2])
      assert.are.equal("CodeViewDiffDelete", groups[4])
      assert.are.equal("CodeViewDiffAdd", groups[5])
      assert.are.equal("CodeViewDiffFold", groups[9])
      assert.are.equal("CodeViewDiffHunk", groups[10])
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("highlights the note of a binary file", function()
      local buf = render(diff.compute("a\0b", "a\0c"))
      assert.are.equal("CodeViewDiffMessage", line_groups(buf)[1])
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("highlights the changed part of a line", function()
      local buf = render(diff.compute("local value = 1\n", "local value = 2\n"), { word_diff = true })
      assert.are.same({
        { row = 2, col = 15, end_col = 16, hl = "CodeViewDiffText" },
        { row = 3, col = 15, end_col = 16, hl = "CodeViewDiffText" },
      }, inner_marks(buf))
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("keeps the state of the buffer", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local buf, build = render(file)

      local state = assert(inline.get(buf))
      assert.are.equal(file, state.diff)
      assert.are.equal(build.map, inline.map(buf))
      assert.are.equal(2, #inline.gaps(buf))
      assert.are.equal(1, assert(inline.gap_at(buf, 9)).id)
      assert.is_nil(inline.gap_at(buf, 2))

      api.nvim_buf_delete(buf, { force = true })
      assert.is_nil(inline.get(buf))
      assert.is_nil(inline.map(buf))
      assert.are.same({}, inline.gaps(buf))
    end)

    it("renders the same buffer again", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed", [30] = " changed" }))
      local buf = render(file)
      local build = inline.render(buf, file, { expanded = { [1] = true } })
      assert.are.equal(38, #api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.equal(38, build.map:len())
      api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("the status column", function()
    it("shows the old line number and the new line number", function()
      local file = diff.compute(numbered(40), numbered(40, { [3] = " changed" }))
      local buf = render(file)

      assert.are.equal("      ", inline.number_column(buf, 1))
      assert.are.equal(" 1  1 ", inline.number_column(buf, 2))
      assert.are.equal(" 3    ", inline.number_column(buf, 4))
      assert.are.equal("    3 ", inline.number_column(buf, 5))
      assert.are.equal("      ", inline.number_column(buf, 9))
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("gives an empty text for a buffer without a diff", function()
      local buf = api.nvim_create_buf(false, true)
      assert.are.equal("", inline.number_column(buf, 1))
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("reads the buffer of the window that asks", function()
      local file = diff.compute("one\ntwo\n", "one\ntwo changed\n")
      local buf = render(file)
      local win = api.nvim_open_win(buf, false, { split = "right" })

      vim.g.statusline_winid = win
      vim.v.lnum = 2
      assert.are.equal("%#CodeViewDiffNumber#1 1 %*%s", inline.statuscolumn())

      inline.attach_window(win)
      assert.are.equal(inline.statuscolumn_expr, vim.wo[win][0].statuscolumn)
      assert.is_false(vim.wo[win][0].wrap)

      api.nvim_win_close(win, true)
      api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("the highlight groups", function()
    local background

    before_each(function()
      background = vim.o.background
    end)

    after_each(function()
      vim.o.background = background
      vim.cmd.colorscheme("default")
    end)

    ---Colors of one group, with the links followed.
    ---@param name string
    ---@return table
    local function resolve(name)
      local value = api.nvim_get_hl(0, { name = name, link = false })
      assert.is_truthy(next(value), name .. " has no colors")
      return value
    end

    it("links every diff group to a standard group", function()
      -- The row groups of the added and the removed lines follow the
      -- `diff.syntax` option, so they link only while the option is off. See
      -- tests/syntax_spec.lua for the other case.
      require("codeview.config").setup({ diff = { syntax = false } })
      highlight.apply()
      assert.are.equal("DiffAdd", api.nvim_get_hl(0, { name = "CodeViewDiffAdd" }).link)
      assert.are.equal("DiffDelete", api.nvim_get_hl(0, { name = "CodeViewDiffDelete" }).link)
      assert.are.equal("DiffText", api.nvim_get_hl(0, { name = "CodeViewDiffText" }).link)
      assert.are.equal("Title", api.nvim_get_hl(0, { name = "CodeViewDiffHunk" }).link)
      assert.are.equal("Folded", api.nvim_get_hl(0, { name = "CodeViewDiffFold" }).link)
      assert.are.equal("LineNr", api.nvim_get_hl(0, { name = "CodeViewDiffNumber" }).link)
    end)

    it("gives other colors on a light background and on a dark background", function()
      local groups = { "CodeViewDiffAdd", "CodeViewDiffDelete", "CodeViewDiffText", "CodeViewDiffFold" }
      local seen = {}
      for _, name in ipairs({ "dark", "light" }) do
        vim.o.background = name
        vim.cmd.colorscheme("default")
        highlight.apply()
        seen[name] = {}
        for _, group in ipairs(groups) do
          seen[name][group] = resolve(group)
        end
        assert.are_not.same(seen[name].CodeViewDiffAdd, seen[name].CodeViewDiffDelete)
      end
      for _, group in ipairs(groups) do
        assert.are_not.same(seen.dark[group], seen.light[group])
      end
    end)
  end)
end)
