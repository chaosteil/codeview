---@brief Code that the inline style and the side-by-side style share.
---
--- |codeview.layout| holds the plan of the rows. This module holds the steps
--- after the plan, which both renderers run in the same way:
---
--- - the render state of each diff buffer, and the calls that read it,
--- - the notes of a diff that shows no hunk,
--- - the rule that pairs the lines of a hunk for the word marks,
--- - the write of the lines, the row highlights, and the word marks,
--- - the line numbers of the status column.

local layout = require("codeview.layout")

local api = vim.api

local M = {}

---Priority of a row highlight. One below the default of an extmark, so
--- the word marks and the marks of other plugins paint over a row.
---@type integer
M.row_priority = 4095

---Text of the notes of a diff without hunks.
---@type table<string, string>
M.notes = {
  binary = "The file is binary. It has no text diff.",
  empty = "The file is empty.",
  unchanged = "The file has no changes.",
  line_endings = "The file changes only its line endings (CRLF and LF).",
  no_newline = "\\ No newline at end of file",
}

--- Notes -----------------------------------------------------------------------

---Note rows of a diff that shows no hunk.
---
--- A document of |codeview.message| holds no hunk, but it shows its lines.
--- The call gives nil for it.
---@param diff codeview.diff.File
---@return string[]? lines Nil when the diff shows lines of the file.
function M.notes_of(diff)
  if diff.message then
    return nil
  end
  if diff.binary then
    return { M.notes.binary }
  end
  if diff.limited then
    return layout.limit_lines(diff)
  end
  if diff.line_endings then
    return { M.notes.line_endings }
  end
  if #diff.hunks == 0 then
    local empty = #diff.old_lines == 0 and #diff.new_lines == 0
    return { empty and M.notes.empty or M.notes.unchanged }
  end
  return nil
end

---Sides that need the note of a missing final newline after one row.
---
--- Git shows "\ No newline at end of file" after the last line of a side
--- without a final line break. The note follows the row that holds that line.
---@param diff codeview.diff.File
---@param old integer? Old line of the row. Nil when the row holds none.
---@param new integer? New line of the row. Nil when the row holds none.
---@return boolean old_note True when the old side needs the note.
---@return boolean new_note True when the new side needs the note.
function M.eol_notes(diff, old, new)
  local old_note = diff.old_eol == false and old ~= nil and old == #diff.old_lines
  local new_note = diff.new_eol == false and new ~= nil and new == #diff.new_lines
  return old_note, new_note
end

--- Word marks ------------------------------------------------------------------

---Report whether the lines of a hunk pair up for the word marks.
---
--- The diff aligns similar lines inside a hunk, so a hunk that replaces as
--- many lines as it adds pairs its lines by position. A hunk with other
--- counts holds lines that are too different to pair.
---@param hunk codeview.diff.Hunk
---@return boolean
function M.pairs(hunk)
  return hunk.old_count == hunk.new_count
end

---Marks of the changed part of a pair of lines.
---@param old_text string Text of the old line.
---@param new_text string Text of the new line.
---@param old_row integer Buffer row of the old line, from 1.
---@param new_row integer Buffer row of the new line, from 1.
---@param offset integer Bytes in front of the text of the line, for example the marker column.
---@return codeview.layout.Mark? old_mark Nil when the old line holds no changed part.
---@return codeview.layout.Mark? new_mark Nil when the new line holds no changed part.
function M.word_marks(old_text, new_text, old_row, new_row, offset)
  local prefix, old_to, new_to = layout.word_range(old_text, new_text)
  if not prefix then
    return nil, nil
  end
  local old_mark, new_mark
  if old_to > prefix then
    old_mark = { row = old_row, col = prefix + offset, end_col = old_to + offset, hl = "CodeViewDiffTextDelete" }
  end
  if new_to > prefix then
    new_mark = { row = new_row, col = prefix + offset, end_col = new_to + offset, hl = "CodeViewDiffTextAdd" }
  end
  return old_mark, new_mark
end

--- Write -----------------------------------------------------------------------

---Replace the lines of a read-only buffer.
---@param buf integer
---@param lines string[]
function M.write_lines(buf, lines)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false
end

---Write the row highlights and the word marks of one buffer.
---
--- A line highlight covers every range mark of the line, so the rows are
--- range marks and the word marks paint over them.
---@param buf integer
---@param ns integer Namespace of the renderer. The call clears it first.
---@param lines string[] Text of every buffer row.
---@param map codeview.LineMap Map of the buffer.
---@param marks codeview.layout.Mark[] Highlights inside a row.
---@param group_of fun(row: codeview.linemap.Row): string? Highlight group of a whole row.
---@param decorate? fun(row: codeview.linemap.Row, extmark: table) Adds options to the extmark of a row.
function M.paint(buf, ns, lines, map, marks, group_of, decorate)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for lnum, row in ipairs(map.rows) do
    local group = group_of(row)
    if group then
      local extmark = {
        end_row = lnum, -- the next row (0-based), so the range covers the line break
        end_col = 0,
        hl_eol = true, -- paint to the end of the screen line, like a line highlight
        hl_group = group,
        priority = M.row_priority,
        strict = false, -- the last row has no next row
      }
      if decorate then
        decorate(row, extmark)
      end
      api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, extmark)
    end
  end
  for _, mark in ipairs(marks) do
    local width = #(lines[mark.row] or "")
    local col = math.min(mark.col, width)
    local end_col = math.min(mark.end_col, width)
    if end_col > col then
      api.nvim_buf_set_extmark(buf, ns, mark.row - 1, col, { end_col = end_col, hl_group = mark.hl })
    end
  end
end

--- Status column ---------------------------------------------------------------

---Line numbers of one buffer row, as the status column shows them.
---@param map codeview.LineMap Map of the buffer.
---@param width table<codeview.linemap.Side, integer> Column width of the line numbers.
---@param lnum integer Buffer row, from 1.
---@param sides codeview.linemap.Side[] Sides to show, from left to right.
---@return string text
function M.number_column(map, width, lnum, sides)
  local parts = {}
  for index, side in ipairs(sides) do
    parts[index] = layout.pad(map:file_line(lnum, side), width[side])
  end
  return table.concat(parts, " ") .. " "
end

--- State -----------------------------------------------------------------------

---@class codeview.render.State
---@field diff codeview.diff.File Diff that the buffer shows.
---@field map codeview.LineMap Map of the buffer.
---@field build { gaps: codeview.layout.Gap[] } Result of the last render.

---Render state of the diff buffers of one renderer.
---@class codeview.render.Registry
---@field private name string Name of the autocmd group.
---@field private states table<integer, codeview.render.State> State of each buffer.
---@field private watched table<integer, boolean> Buffers with a wipe autocmd.
local Registry = {}
Registry.__index = Registry

---Build an empty registry.
---@param name string Name of the autocmd group, for example "codeview.inline".
---@return codeview.render.Registry
function M.registry(name)
  return setmetatable({ name = name, states = {}, watched = {} }, Registry)
end

---Keep the state of a buffer.
---
--- The first call for a buffer adds one autocmd that forgets the state when
--- the buffer goes away. A later call adds none, also after a failed render.
---@param buf integer
---@param state codeview.render.State
function Registry:set(buf, state)
  if not self.watched[buf] then
    self.watched[buf] = true
    api.nvim_create_autocmd("BufWipeout", {
      group = api.nvim_create_augroup(self.name, { clear = false }),
      buffer = buf,
      once = true,
      desc = "Forget the codeview diff of a buffer",
      callback = function()
        self.states[buf] = nil
        self.watched[buf] = nil
      end,
    })
  end
  self.states[buf] = state
end

---Read the state of a buffer.
---@param buf integer
---@return codeview.render.State? state Nil when the buffer holds no diff.
function Registry:get(buf)
  return self.states[buf]
end

---Read the line map of a buffer.
---@param buf integer
---@return codeview.LineMap? map Nil when the buffer holds no diff.
function Registry:map(buf)
  local state = self.states[buf]
  return state and state.map or nil
end

---Collapsed section of one buffer row.
---
--- The record of the row in the map names the section. A filler row of a
--- collapsed section and a row of an expanded section both hold it.
---@param buf integer
---@param lnum integer Buffer row, from 1.
---@return codeview.layout.Gap? gap Nil when the row belongs to no section.
function Registry:gap_at(buf, lnum)
  local state = self.states[buf]
  if not state then
    return nil
  end
  local row = state.map:row(lnum)
  if not row or not row.gap then
    return nil
  end
  return state.build.gaps[row.gap]
end

---Sections that the buffer can show or hide.
---@param buf integer
---@return codeview.layout.Gap[] gaps
function Registry:gaps(buf)
  local state = self.states[buf]
  return state and state.build.gaps or {}
end

return M
