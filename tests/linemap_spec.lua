local helpers = require("tests.helpers")

describe("codeview.linemap", function()
  local linemap

  ---Map of a small diff of a modified file.
  ---
  ---     1  @@ -1,4 +1,4 @@
  ---     2   one          old 1  new 1
  ---     3  -two          old 2
  ---     4  +two changed         new 2
  ---     5   three        old 3  new 3
  ---     6  ⋯ 12 unchanged lines
  ---     7   sixteen      old 16 new 16
  ---@return codeview.LineMap
  local function modified()
    return linemap.from({
      { kind = "header", hunk = 1 },
      { kind = "context", old = 1, new = 1, hunk = 1 },
      { kind = "delete", old = 2, hunk = 1 },
      { kind = "add", new = 2, hunk = 1 },
      { kind = "context", old = 3, new = 3, hunk = 1 },
      { kind = "filler", gap = 1 },
      { kind = "context", old = 16, new = 16, hunk = 2 },
    })
  end

  before_each(function()
    helpers.unload()
    linemap = require("codeview.linemap")
  end)

  after_each(function()
    helpers.unload()
  end)

  describe("rows", function()
    it("counts the rows and keeps their order", function()
      local map = modified()
      assert.are.equal(7, map:len())
      assert.are.equal("header", map:kind(1))
      assert.are.equal("delete", map:kind(3))
      assert.are.equal("filler", map:kind(6))
      assert.is_nil(map:row(8))
      assert.is_nil(map:kind(0))
      assert.is_nil(map:kind("two"))
    end)

    it("takes the kind context by default", function()
      local map = linemap.from({ { old = 1, new = 1 } })
      assert.are.equal("context", map:kind(1))
    end)

    it("copies the record of a row", function()
      local record = { kind = "add", new = 1, hunk = 1 }
      local map = linemap.from({ record })
      record.new = 99
      assert.are.equal(1, map:row(1).new)
    end)

    it("reports a map of this module", function()
      assert.is_true(linemap.is(linemap.new()))
      assert.is_false(linemap.is({}))
      assert.is_false(linemap.is(nil))
    end)

    it("gives the row number of an added record", function()
      local map = linemap.new()
      assert.are.equal(1, map:add({ kind = "header" }))
      assert.are.equal(2, map:add({ kind = "add", new = 1 }))
    end)
  end)

  describe("a row to a file line", function()
    it("reads both sides of a context row", function()
      local map = modified()
      assert.are.equal(1, map:file_line(2, "old"))
      assert.are.equal(1, map:file_line(2, "new"))
      assert.are.equal("new", map:side(2))
    end)

    it("reads one side of a changed row", function()
      local map = modified()
      assert.are.equal(2, map:file_line(3, "old"))
      assert.is_nil(map:file_line(3, "new"))
      assert.are.equal("old", map:side(3))

      assert.are.equal(2, map:file_line(4, "new"))
      assert.is_nil(map:file_line(4, "old"))
      assert.are.equal("new", map:side(4))
    end)

    it("reads the side of the row without an argument", function()
      local map = modified()
      local line, side = map:file_line(3)
      assert.are.equal(2, line)
      assert.are.equal("old", side)
    end)

    it("gives no line for a row without a file line", function()
      local map = modified()
      assert.is_nil(map:file_line(1))
      assert.is_nil(map:file_line(6))
      assert.is_nil(map:side(1))
      assert.is_nil(map:side(6))
      assert.is_nil(map:file_line(99))
    end)
  end)

  describe("a file line to a row", function()
    it("finds the row of a line of each side", function()
      local map = modified()
      assert.are.equal(2, map:buf_row(1, "old"))
      assert.are.equal(3, map:buf_row(2, "old"))
      assert.are.equal(4, map:buf_row(2, "new"))
      assert.are.equal(7, map:buf_row(16, "new"))
    end)

    it("gives no row for a line that the buffer hides", function()
      local map = modified()
      assert.is_nil(map:buf_row(8, "new"))
      assert.is_nil(map:buf_row(99, "old"))
      assert.is_nil(map:buf_row(1, "both"))
      assert.is_nil(map:buf_row("1", "new"))
    end)

    it("finds the closest row above a hidden line", function()
      local map = modified()
      assert.are.equal(5, map:nearest_row(8, "new"))
      assert.are.equal(5, map:nearest_row(15, "old"))
      assert.are.equal(7, map:nearest_row(40, "new"))
      assert.are.equal(3, map:nearest_row(2, "old"))
      assert.is_nil(map:nearest_row(0, "new"))
    end)

    it("keeps the sequence of a side in order", function()
      local map = linemap.from({
        { kind = "context", old = 5, new = 5 },
        { kind = "context", old = 1, new = 1 },
        { kind = "context", old = 3, new = 3 },
      })
      assert.are.equal(2, map:nearest_row(2, "old"))
      assert.are.equal(3, map:nearest_row(4, "old"))
      assert.are.equal(1, map:nearest_row(9, "old"))
    end)
  end)

  describe("hunks", function()
    it("counts the hunks and finds their rows", function()
      local map = modified()
      assert.are.equal(2, map:hunk_count())
      assert.are.same({ 1, 7 }, map:hunk_starts())
      assert.are.same({ 1, 5 }, { map:hunk_rows(1) })
      assert.are.same({ 7, 7 }, { map:hunk_rows(2) })
      assert.is_nil(map:hunk_rows(3))
      assert.are.equal(1, map:hunk(3))
      assert.is_nil(map:hunk(6))
    end)

    it("walks to the next hunk and to the previous hunk", function()
      local map = modified()
      assert.are.equal(1, map:next_hunk(0))
      assert.are.equal(7, map:next_hunk(1))
      assert.is_nil(map:next_hunk(7))
      assert.are.equal(1, map:prev_hunk(7))
      assert.is_nil(map:prev_hunk(1))
    end)

    it("continues at the other end on request", function()
      local map = modified()
      assert.are.equal(1, map:next_hunk(7, { wrap = true }))
      assert.are.equal(7, map:prev_hunk(1, { wrap = true }))
    end)

    it("gives no row without a hunk", function()
      local map = linemap.from({ { kind = "message" } })
      assert.are.equal(0, map:hunk_count())
      assert.is_nil(map:next_hunk(0))
      assert.is_nil(map:prev_hunk(2))
      assert.is_nil(map:next_hunk(0, { wrap = true }))
    end)
  end)

  describe("anchor", function()
    it("anchors one row to its side", function()
      local map = modified()
      assert.are.same({ side = "new", start_line = 1, end_line = 1 }, map:anchor(2))
      assert.are.same({ side = "old", start_line = 2, end_line = 2 }, map:anchor(3))
    end)

    it("keeps the rows of the side of the first row", function()
      local map = modified()
      -- Rows 3 to 5 hold one removed line, one added line, and one context
      -- line. The anchor takes the old side, so the added line drops out.
      assert.are.same({ side = "old", start_line = 2, end_line = 3 }, map:anchor(3, 5))
      assert.are.same({ side = "new", start_line = 2, end_line = 3 }, map:anchor(4, 5))
    end)

    it("takes the first row that holds a file line", function()
      local map = modified()
      assert.are.same({ side = "new", start_line = 1, end_line = 1 }, map:anchor(1, 2))
    end)

    it("sorts the two ends of the range", function()
      local map = modified()
      assert.are.same(map:anchor(2, 5), map:anchor(5, 2))
    end)

    it("gives no anchor for a range without a file line", function()
      local map = modified()
      assert.is_nil(map:anchor(1))
      assert.is_nil(map:anchor(6))
      assert.is_nil(map:anchor(99))
      assert.is_nil(map:anchor(nil))
    end)
  end)
end)
