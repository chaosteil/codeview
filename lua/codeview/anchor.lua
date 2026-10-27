---@brief Anchors of comments over the line map.
---
--- A comment anchors to a file, a side of the diff, a first line, and a last
--- line. This module turns the rows of a diff view into such an anchor, and
--- an anchor back into rows. It reads no store and draws nothing.
---
--- Every anchor goes through the |codeview.LineMap| of the render. The map
--- turns a buffer row into a file line and back, for both diff styles and for
--- both sides. Virtual lines do not shift the map, because they hold no buffer
--- row.

local message = require("codeview.message")

local api = vim.api

local M = {}

---@class codeview.comments.Target
---@field view codeview.view.State View that holds the lines.
---@field buf integer Buffer that shows the side of the anchor.
---@field map codeview.LineMap Map of that buffer.
---@field file string Path of the file in the review.
---@field side codeview.linemap.Side Side of the diff.
---@field start_line integer First line of the file, from 1.
---@field end_line integer Last line of the file.
---@field commit string Revision of the side.
---@field win integer Window that the reviewer marked the lines in.
---@field row integer Last marked row of that window. The inline editor opens under it.

---Buffer and map of one side of a view.
---@param view codeview.view.State
---@param side codeview.linemap.Side
---@return integer buf
---@return codeview.LineMap map
function M.side_of(view, side)
  if view.style == "split" and side == "old" and view.old_buf and view.old_map then
    return view.old_buf, view.old_map
  end
  return view.buf, view.map
end

---Revision that one side of a view comes from.
---@param view codeview.view.State
---@param side codeview.linemap.Side
---@return string commit
local function commit_of(view, side)
  if side == "old" then
    return view.old_rev or view.rev or ""
  end
  return view.new_rev or view.rev or ""
end

---Rows of the view that the cursor covers.
---@param view codeview.view.State
---@param opts? { visual?: boolean, first?: integer, last?: integer }
---@return integer first
---@return integer last
---@return integer win Window that the rows come from.
local function rows_of(view, opts)
  opts = opts or {}
  local win = api.nvim_get_current_win()
  local windows = { view.win, view.old_win }
  if not vim.tbl_contains(windows, win) then
    win = view.win
  end
  if opts.first then
    return opts.first, opts.last or opts.first, win
  end
  if opts.visual then
    local first = vim.fn.line("v")
    local last = vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    return first, last, win
  end
  local row = 1
  if api.nvim_win_is_valid(win) then
    row = api.nvim_win_get_cursor(win)[1]
  end
  return row, row, win
end

---Anchor of a row range of the view.
---
--- The map of the window with the cursor answers first. A row that this side
--- does not hold goes to the other side. An example is the filler row of an
--- added line in the old window.
---@param view? codeview.view.State View to read. The open file by default.
---@param opts? { visual?: boolean, first?: integer, last?: integer }
---@return codeview.comments.Target? target Nil on a range without a file line.
function M.target(view, opts)
  view = view or require("codeview.view").current()
  if not view then
    return nil
  end
  local first, last, win = rows_of(view, opts)

  local maps = { view.map }
  if view.old_map then
    maps = win == view.old_win and { view.old_map, view.map } or { view.map, view.old_map }
  end

  for _, map in ipairs(maps) do
    local anchor = map:anchor(first, last)
    if anchor then
      local buf, side_map = M.side_of(view, anchor.side)
      return {
        view = view,
        buf = buf,
        map = side_map,
        file = view.path,
        side = anchor.side,
        start_line = anchor.start_line,
        end_line = anchor.end_line,
        -- A commit document belongs to one commit, so its comments take that
        -- commit and not the head of the range.
        commit = message.commit_id(view.path) or commit_of(view, anchor.side),
        win = win,
        row = last,
      }
    end
  end
  return nil
end

---Row of the collapsed section that hides one line of a comment.
---
--- The call answers for a line that no row of the side is at or above. Such a
--- line belongs to a section at the start of the file. The filler row of that
--- section is the first row that the reader sees, so the comment goes there.
---@param map codeview.LineMap
---@param comment codeview.store.Comment
---@return integer? row Nil for a map without rows.
local function hidden_row(map, comment)
  local below = map:next_row(comment.start_line, comment.side)
  for lnum = (below or map:len() + 1) - 1, 1, -1 do
    local record = map:row(lnum)
    if record and record.kind == "filler" and record.gap then
      return lnum
    end
  end
  if below then
    return below
  end
  -- The side holds no line at all, for example on a message row. The first row
  -- keeps the comment in the view.
  return map:len() > 0 and 1 or nil
end

---Rows of a buffer that hold the lines of a comment.
---@param map codeview.LineMap
---@param comment codeview.store.Comment
---@return integer[] rows Rows from 1, in buffer order.
function M.comment_rows(map, comment)
  local rows, seen = {}, {}
  for line = comment.start_line, comment.end_line do
    local row = map:buf_row(line, comment.side)
    if row and not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end
  if #rows == 0 then
    -- A collapsed section hides the lines. The sign goes to the row above it,
    -- so that the comment stays visible. A section at the start of the file has
    -- no row above it, so the sign goes on the row of the section.
    local row = map:nearest_row(comment.start_line, comment.side) or hidden_row(map, comment)
    if row then
      rows[1] = row
    end
  end
  table.sort(rows)
  return rows
end

---Rows of a view that hold the lines of one anchor.
---
--- |codeview.remote| places its own marks on the same rows, so the two kinds
--- of comment sit next to each other.
---@param view codeview.view.State View that shows the file.
---@param anchor { start_line: integer, end_line: integer, side: codeview.linemap.Side } Lines of the anchor.
---@return integer[] rows Rows from 1, in buffer order. Empty when the render hides the lines.
---@return integer buf Buffer of the side of the anchor.
---@return codeview.LineMap map Map of that buffer.
function M.rows(view, anchor)
  local buf, map = M.side_of(view, anchor.side)
  return M.comment_rows(map, anchor --[[@as codeview.store.Comment]]), buf, map
end

---Comments that a collapsed section hides, with their sign on one row.
---
--- The sign of a hidden comment sits on a row that holds another line, or no
--- line at all. That row answers for the comment, so that edit and delete
--- reach a comment which the render does not show at its own line.
---@param view codeview.view.State
---@param store codeview.store.Store
---@param row integer Buffer row of the cursor, from 1.
---@param buf integer Buffer under the cursor.
---@return codeview.store.Comment[] comments
function M.marked_at(view, store, row, buf)
  local out = {}
  for _, comment in ipairs(store:for_file(view.path)) do
    local side_buf, map = M.side_of(view, comment.side)
    if side_buf == buf then
      for _, lnum in ipairs(M.comment_rows(map, comment)) do
        if lnum == row then
          out[#out + 1] = comment
          break
        end
      end
    end
  end
  return out
end

---Comments of a store under the cursor of a view.
---@param view codeview.view.State View to read.
---@param store codeview.store.Store? Comments of the session. Nil gives no comment.
---@return codeview.store.Comment[] comments
---@return codeview.comments.Target? target Position of the cursor.
function M.at_cursor(view, store)
  local target = M.target(view)
  if not store then
    return {}, target
  end
  if target then
    local found = store:at(target.file, target.side, target.start_line)
    if #found > 0 then
      return found, target
    end
  end

  local row, _, win = rows_of(view)
  local buf = view.buf
  if api.nvim_win_is_valid(win) then
    buf = api.nvim_win_get_buf(win)
  end
  return M.marked_at(view, store, row, buf), target
end

---Buffer of the other side of a side-by-side view.
---
--- Virtual lines in that buffer keep the two windows on the same screen row.
--- |codeview.remote| needs the same alignment for its own marks.
---@param view codeview.view.State
---@param side codeview.linemap.Side Side that holds the comment.
---@return integer? buf Nil outside the split style.
function M.mirror(view, side)
  if view.style ~= "split" or not view.old_buf then
    return nil
  end
  local buf = side == "old" and view.buf or view.old_buf
  if type(buf) == "number" and api.nvim_buf_is_valid(buf) then
    return buf
  end
  return nil
end

return M
