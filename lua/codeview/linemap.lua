---@brief The map between the rows of a diff buffer and the lines of a file.
---
--- A diff buffer holds more rows than the file holds lines. It repeats a
--- changed line on both sides, it adds a hunk header, and it hides the
--- unchanged sections behind a filler row. The map keeps one record per buffer
--- row, so that every later feature can go from a row to a file line and back.
---
--- The record holds the kind of the row, the line number in the old file, the
--- line number in the new file, and the hunk that the row belongs to. A row
--- that only one side holds keeps the number of that side, and nil for the
--- other side.
---
--- The map answers in both directions:
---
--- - row to file line: |codeview.LineMap:file_line()| and |codeview.LineMap:row()|.
--- - file line to row: |codeview.LineMap:buf_row()|, |codeview.LineMap:nearest_row()|,
---   and |codeview.LineMap:next_row()|.
---
--- The renderer of a diff style builds the map. M5 builds one map per side,
--- M7 anchors the comments through it, and M11 maps an anchor to a position of
--- the GitHub diff.
---
--- The rows come in file order. Both the old numbers and the new numbers grow
--- from the first row to the last row, so a lookup by file line is a binary
--- search over the rows of one side.

local M = {}

---@alias codeview.linemap.Side "old"|"new"

---@alias codeview.linemap.Kind
---| "context" # Unchanged line. Both sides hold it.
---| "add" # Line that only the new side holds.
---| "delete" # Line that only the old side holds.
---| "header" # Hunk header, for example `@@ -1,4 +1,5 @@`.
---| "filler" # Placeholder of a collapsed section, or an alignment row.
---| "message" # Note of the renderer, for example the note of a binary file.

---@class codeview.linemap.Row
---@field kind codeview.linemap.Kind Kind of the row.
---@field old integer? Line in the old file, from 1.
---@field new integer? Line in the new file, from 1.
---@field hunk integer? Position of the hunk in the hunk list of the diff.
---@field gap integer? Number of the collapsed section of a filler row.

---@class codeview.linemap.Entry
---@field line integer Line in the file.
---@field row integer Row in the buffer.

---@class codeview.LineMap
---@field rows codeview.linemap.Row[] One record per buffer row, from 1.
---@field private index table<codeview.linemap.Side, table<integer, integer>> File line to buffer row.
---@field private seq table<codeview.linemap.Side, codeview.linemap.Entry[]> File lines of one side, ascending.
---@field private starts integer[] First row of each hunk, ascending.
---@field private first table<integer, integer> Hunk to its first row.
---@field private last table<integer, integer> Hunk to its last row.
local LineMap = {}
LineMap.__index = LineMap

---Kind of a row that holds a line of the new file.
---@type table<codeview.linemap.Kind, boolean>
local ON_NEW = { context = true, add = true }

---Kind of a row that holds a line of the old file.
---@type table<codeview.linemap.Kind, boolean>
local ON_OLD = { context = true, delete = true }

---Keep one file line in the ascending sequence of a side.
---@param seq codeview.linemap.Entry[]
---@param line integer
---@param row integer
local function push(seq, line, row)
  local last = seq[#seq]
  if not last or line > last.line then
    seq[#seq + 1] = { line = line, row = row }
    return
  end
  -- A caller that adds the rows out of order still gets a sorted sequence.
  local at = #seq
  while at > 0 and seq[at].line > line do
    at = at - 1
  end
  if at > 0 and seq[at].line == line then
    return
  end
  table.insert(seq, at + 1, { line = line, row = row })
end

---Find the last entry whose file line is at or below one line.
---@param seq codeview.linemap.Entry[]
---@param line integer
---@return codeview.linemap.Entry? entry Nil when every entry is above the line.
local function find_le(seq, line)
  local lo, hi, found = 1, #seq, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if seq[mid].line <= line then
      found = seq[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

---Find the first entry whose file line is at or above one line.
---@param seq codeview.linemap.Entry[]
---@param line integer
---@return codeview.linemap.Entry? entry Nil when every entry is below the line.
local function find_ge(seq, line)
  local lo, hi, found = 1, #seq, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if seq[mid].line >= line then
      found = seq[mid]
      hi = mid - 1
    else
      lo = mid + 1
    end
  end
  return found
end

---Build an empty map.
---@return codeview.LineMap
function M.new()
  return setmetatable({
    rows = {},
    index = { old = {}, new = {} },
    seq = { old = {}, new = {} },
    starts = {},
    first = {},
    last = {},
  }, LineMap)
end

---Build a map from a list of records.
---
--- The call is for tests and for a caller that already holds every record.
---@param rows codeview.linemap.Row[] Records, in buffer order.
---@return codeview.LineMap
function M.from(rows)
  local map = M.new()
  for _, row in ipairs(rows or {}) do
    map:add(row)
  end
  return map
end

---Report whether a value is a map of this module.
---@param value any
---@return boolean
function M.is(value)
  return type(value) == "table" and getmetatable(value) == LineMap
end

---Append the record of one buffer row.
---@param row codeview.linemap.Row Record of the row. The call copies it.
---@return integer lnum Buffer row of the record, from 1.
function LineMap:add(row)
  local lnum = #self.rows + 1
  local record = {
    kind = row.kind or "context",
    old = row.old,
    new = row.new,
    hunk = row.hunk,
    gap = row.gap,
  }
  self.rows[lnum] = record

  if record.old and ON_OLD[record.kind] then
    if not self.index.old[record.old] then
      self.index.old[record.old] = lnum
    end
    push(self.seq.old, record.old, lnum)
  end
  if record.new and ON_NEW[record.kind] then
    if not self.index.new[record.new] then
      self.index.new[record.new] = lnum
    end
    push(self.seq.new, record.new, lnum)
  end

  if record.hunk then
    if not self.first[record.hunk] then
      self.first[record.hunk] = lnum
      self.starts[#self.starts + 1] = lnum
    end
    self.last[record.hunk] = lnum
  end
  return lnum
end

---Number of buffer rows in the map.
---@return integer count
function LineMap:len()
  return #self.rows
end

---Record of one buffer row.
---@param lnum integer Buffer row, from 1.
---@return codeview.linemap.Row? row Nil outside the buffer.
function LineMap:row(lnum)
  if type(lnum) ~= "number" then
    return nil
  end
  return self.rows[lnum]
end

---Kind of one buffer row.
---@param lnum integer Buffer row, from 1.
---@return codeview.linemap.Kind? kind Nil outside the buffer.
function LineMap:kind(lnum)
  local row = self:row(lnum)
  return row and row.kind or nil
end

---Side of the file that one buffer row belongs to.
---
--- A context row belongs to both sides. The call reports the new side for it,
--- because a comment on an unchanged line goes to the new side.
---@param lnum integer Buffer row, from 1.
---@return codeview.linemap.Side? side Nil for a row without a file line.
function LineMap:side(lnum)
  local row = self:row(lnum)
  if not row then
    return nil
  end
  if row.new and ON_NEW[row.kind] then
    return "new"
  end
  if row.old and ON_OLD[row.kind] then
    return "old"
  end
  return nil
end

---File line of one buffer row.
---@param lnum integer Buffer row, from 1.
---@param side codeview.linemap.Side? Side to read. The side of the row by default.
---@return integer? line Nil when the side does not hold the row.
---@return codeview.linemap.Side? side Side of the answer.
function LineMap:file_line(lnum, side)
  local row = self:row(lnum)
  if not row then
    return nil, nil
  end
  if not side then
    side = self:side(lnum)
    if not side then
      return nil, nil
    end
  end
  if side == "old" and row.old and ON_OLD[row.kind] then
    return row.old, "old"
  end
  if side == "new" and row.new and ON_NEW[row.kind] then
    return row.new, "new"
  end
  return nil, nil
end

---Buffer row of one file line.
---@param line integer Line in the file, from 1.
---@param side codeview.linemap.Side Side that holds the line.
---@return integer? lnum Nil when the buffer does not show the line.
function LineMap:buf_row(line, side)
  local index = self.index[side]
  if not index or type(line) ~= "number" then
    return nil
  end
  return index[line]
end

---Buffer row of one file line, or of the closest line above it.
---
--- Use this call after a re-render that hides a line, for example after a
--- collapse of an unchanged section.
---@param line integer Line in the file, from 1.
---@param side codeview.linemap.Side Side that holds the line.
---@return integer? lnum Nil when no row of the side is at or above the line.
function LineMap:nearest_row(line, side)
  local exact = self:buf_row(line, side)
  if exact then
    return exact
  end
  local seq = self.seq[side]
  if not seq or type(line) ~= "number" then
    return nil
  end
  local entry = find_le(seq, line)
  return entry and entry.row or nil
end

---Buffer row of one file line, or of the closest line below it.
---
--- Use this call for a line that the render hides above every row of the side,
--- for example a line of a collapsed section at the start of the file.
---@param line integer Line in the file, from 1.
---@param side codeview.linemap.Side Side that holds the line.
---@return integer? lnum Nil when no row of the side is at or below the line.
function LineMap:next_row(line, side)
  local exact = self:buf_row(line, side)
  if exact then
    return exact
  end
  local seq = self.seq[side]
  if not seq or type(line) ~= "number" then
    return nil
  end
  local entry = find_ge(seq, line)
  return entry and entry.row or nil
end

---Hunk of one buffer row.
---@param lnum integer Buffer row, from 1.
---@return integer? hunk Position in the hunk list. Nil outside a hunk.
function LineMap:hunk(lnum)
  local row = self:row(lnum)
  return row and row.hunk or nil
end

---Number of hunks that the map holds.
---@return integer count
function LineMap:hunk_count()
  return #self.starts
end

---First and last buffer row of one hunk.
---@param index integer Position in the hunk list, from 1.
---@return integer? first Nil when the map does not hold the hunk.
---@return integer? last
function LineMap:hunk_rows(index)
  return self.first[index], self.last[index]
end

---First buffer row of every hunk, in buffer order.
---@return integer[] rows
function LineMap:hunk_starts()
  return vim.deepcopy(self.starts)
end

---First row of the hunk after one buffer row.
---@param lnum integer Buffer row, from 1.
---@param opts? { wrap?: boolean } `wrap = true` continues at the first hunk.
---@return integer? row Nil when no hunk follows.
function LineMap:next_hunk(lnum, opts)
  lnum = lnum or 0
  for _, row in ipairs(self.starts) do
    if row > lnum then
      return row
    end
  end
  if opts and opts.wrap then
    return self.starts[1]
  end
  return nil
end

---First row of the hunk before one buffer row.
---@param lnum integer Buffer row, from 1.
---@param opts? { wrap?: boolean } `wrap = true` continues at the last hunk.
---@return integer? row Nil when no hunk is above the row.
function LineMap:prev_hunk(lnum, opts)
  lnum = lnum or 0
  for index = #self.starts, 1, -1 do
    if self.starts[index] < lnum then
      return self.starts[index]
    end
  end
  if opts and opts.wrap then
    return self.starts[#self.starts]
  end
  return nil
end

---Anchor of a range of buffer rows.
---
--- A comment anchors to one side, a first line, and a last line. The call
--- reads the side of the first row that holds a file line, and keeps only the
--- rows of that side. A range without a file line has no anchor.
---@param first integer First buffer row, from 1.
---@param last integer? Last buffer row. The first row by default.
---@return { side: codeview.linemap.Side, start_line: integer, end_line: integer }? anchor
function LineMap:anchor(first, last)
  last = last or first
  if type(first) ~= "number" or type(last) ~= "number" then
    return nil
  end
  if first > last then
    first, last = last, first
  end

  local side, start_line, end_line
  for lnum = first, last do
    local row = self:row(lnum)
    if row then
      if not side then
        side = self:side(lnum)
      end
      if side then
        local line = self:file_line(lnum, side)
        if line then
          start_line = start_line or line
          end_line = line
        end
      end
    end
  end
  if not side or not start_line then
    return nil
  end
  return { side = side, start_line = start_line, end_line = end_line }
end

return M
