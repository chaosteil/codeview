---@brief The side-by-side diff style: the old side left, the new side right.
---
--- The renderer turns a |codeview.diff.File| into two aligned buffers. It
--- reads the plan of |codeview.layout|, the same plan that the inline style
--- reads, so both styles show the same hunks and the same collapsed sections.
--- `build()` is a pure function, so the tests read the result without a
--- window. `render()` writes the result into two buffers.
---
--- Both sides hold the same number of rows. Row 5 of the left buffer and row 5
--- of the right buffer show the same change:
--- >
---     @@ -1,4 @@            @@ +1,5 @@
---      one                   one
---      two                   two changed
---      three                 three
---                            four
--- <
--- A change with more new lines than old lines needs a filler row on the left,
--- and the other way around. A filler row holds no text. The renderer marks it
--- with a highlight and with virtual text, so that it never reads as a line of
--- the file. Because both sides hold the same row count, 'scrollbind' and
--- 'cursorbind' keep the two windows aligned, also across the fillers.
---
--- The buffers hold the text of the file, without a marker column. The line
--- numbers come from the status column: the left window shows the numbers of
--- the old file, and the right window the numbers of the new file.
---
--- The renderer builds one |codeview.LineMap| per side. Both maps hold one
--- record per aligned row, so the row of a line in one map is the row of the
--- same change in the other map.

local config = require("codeview.config")
local layout = require("codeview.layout")
local linemap = require("codeview.linemap")

local api = vim.api

local M = {}

---Namespace of the diff highlights.
---@type integer
M.ns = api.nvim_create_namespace("codeview.split")

---Value for the 'statuscolumn' option of a diff window.
---@type string
M.statuscolumn_expr = "%!v:lua.require'codeview.split'.statuscolumn()"

---Character of the virtual text of a filler row.
---@type string
M.filler_char = "╱"

---Highest number of columns that the virtual text of a filler row covers.
---
--- The render sizes the text to the widest window of the buffer, and never
--- above this number. Neovim cuts the text at the edge of the window, so a
--- wider text only costs memory on every filler row.
---@type integer
M.filler_width = 200

---Highlight group of a whole row, per row kind.
---@type table<codeview.linemap.Kind, string>
M.line_hl = {
  add = "CodeViewDiffAdd",
  delete = "CodeViewDiffDelete",
  header = "CodeViewDiffHunk",
  message = "CodeViewDiffMessage",
}

---Window options of a diff window. They apply to the buffer of the window.
---
--- The two windows scroll and move the cursor together. Both sides hold the
--- same rows, so the same row number names the same change in both windows.
---@type table<string, any>
M.window_options = vim.tbl_extend("force", layout.window_options, {
  scrollbind = true,
  cursorbind = true,
})

---@class codeview.split.Row
---@field kind "context"|"change"|"delete"|"add"|"header"|"filler"|"message" Kind of the aligned row.
---@field old integer? Line in the old file, from 1.
---@field new integer? Line in the new file, from 1.
---@field hunk integer? Position of the hunk in the hunk list of the diff.
---@field gap integer? Number of the collapsed section of a filler row.
---@field text table<codeview.linemap.Side, string>? Text of a header row or a message row.

---@class codeview.split.Side
---@field lines string[] Text of every buffer row.
---@field map codeview.LineMap Map between the rows and the file lines.
---@field marks codeview.layout.Mark[] Highlights inside a row.
---@field fillers integer[] Rows that hold no line of this side, ascending.

---@class codeview.split.Build
---@field old codeview.split.Side Left side of the view.
---@field new codeview.split.Side Right side of the view.
---@field rows codeview.split.Row[] One record per aligned row, from 1.
---@field gaps codeview.layout.Gap[] Collapsed sections, by number.
---@field width { old: integer, new: integer } Column width of the line numbers.

---@class codeview.split.Opts
---@field context integer? Unchanged lines around a hunk. The `diff.context` option by default.
---@field word_diff boolean? Highlight the changed part of a line. The `diff.word_diff` option by default.
---@field expanded table<integer, boolean>? Sections that show their hidden lines.

---@class codeview.split.State
---@field side codeview.linemap.Side Side that the buffer shows.
---@field diff codeview.diff.File Diff that the buffer shows.
---@field build codeview.split.Build Result of the last render.
---@field opts codeview.split.Opts Options of the last render.

---Render state of each diff buffer.
---@type table<integer, codeview.split.State>
local states = {}

--- Build -----------------------------------------------------------------------

---Plan the aligned rows of a diff.
---
--- One row holds the old line, the new line, or both. A change with a
--- different line count on the two sides gives a row without a line on the
--- shorter side.
---@param blocks codeview.layout.Block[]
---@return codeview.split.Row[] rows
local function rows_of(blocks)
  ---@type codeview.split.Row[]
  local rows = {}
  local seen = {}

  for _, block in ipairs(blocks) do
    if block.group and not seen[block.group] then
      seen[block.group] = true
      rows[#rows + 1] = {
        kind = "header",
        hunk = block.group.hunk,
        text = {
          old = layout.side_header(block.group, "old"),
          new = layout.side_header(block.group, "new"),
        },
      }
    end

    if block.kind == "context" then
      for step = 0, block.count - 1 do
        rows[#rows + 1] = {
          kind = "context",
          old = block.old + step,
          new = block.new + step,
          hunk = block.hunk_index,
        }
      end
    elseif block.kind == "gap" then
      local gap = block.gap --[[@as codeview.layout.Gap]]
      if gap.expanded then
        for step = 0, gap.count - 1 do
          rows[#rows + 1] = { kind = "context", old = gap.old + step, new = gap.new + step, gap = gap.id }
        end
        gap.row = nil
      else
        rows[#rows + 1] = { kind = "filler", gap = gap.id }
        gap.row = #rows
      end
    else
      local hunk = block.hunk --[[@as codeview.diff.Hunk]]
      for step = 0, math.max(hunk.old_count, hunk.new_count) - 1 do
        local old_line = step < hunk.old_count and hunk.old_first + step or nil
        local new_line = step < hunk.new_count and hunk.new_first + step or nil
        local kind = "add"
        if old_line and new_line then
          kind = "change"
        elseif old_line then
          kind = "delete"
        end
        rows[#rows + 1] = { kind = kind, old = old_line, new = new_line, hunk = hunk.index }
      end
    end
  end
  return rows
end

---Text and map record of one aligned row, on one side.
---@param row codeview.split.Row
---@param side codeview.linemap.Side
---@param diff codeview.diff.File
---@param gaps codeview.layout.Gap[]
---@return string text
---@return codeview.linemap.Row record
local function cell_of(row, side, diff, gaps)
  if row.kind == "header" or row.kind == "message" then
    return (row.text or {})[side] or "", { kind = row.kind, hunk = row.hunk }
  end
  if row.kind == "context" then
    local text = diff.new_lines[row.new] or diff.old_lines[row.old] or ""
    return text, { kind = "context", old = row.old, new = row.new, hunk = row.hunk, gap = row.gap }
  end
  if row.kind == "filler" then
    -- The section is collapsed. Both sides hide the same lines.
    local gap = gaps[row.gap]
    return gap and layout.filler_text(gap) or "", { kind = "filler", gap = row.gap }
  end

  local line = row.old
  if side == "new" then
    line = row.new
  end
  if not line then
    -- The other side holds a line of the change here. This side stays free.
    return "", { kind = "filler", hunk = row.hunk }
  end
  if side == "old" then
    return diff.old_lines[line] or "", { kind = "delete", old = line, hunk = row.hunk }
  end
  return diff.new_lines[line] or "", { kind = "add", new = line, hunk = row.hunk }
end

---Build the rows of a side-by-side diff.
---@param diff codeview.diff.File Diff of one file.
---@param opts? codeview.split.Opts
---@return codeview.split.Build build
function M.build(diff, opts)
  opts = opts or {}
  local cfg = config.get().diff
  local ctx = opts.context or diff.context or cfg.context
  local word_diff = opts.word_diff
  if word_diff == nil then
    word_diff = cfg.word_diff
  end

  ---@type codeview.split.Build
  local build = {
    old = { lines = {}, map = linemap.new(), marks = {}, fillers = {} },
    new = { lines = {}, map = linemap.new(), marks = {}, fillers = {} },
    rows = {},
    gaps = {},
    width = { old = layout.digits(#diff.old_lines), new = layout.digits(#diff.new_lines) },
  }

  if diff.binary then
    build.rows = { { kind = "message", text = { old = "Binary file. It has no text diff.", new = "" } } }
  elseif #diff.hunks == 0 then
    local empty = #diff.old_lines == 0 and #diff.new_lines == 0
    local note = empty and "The file is empty." or "The file has no changes."
    build.rows = { { kind = "message", text = { old = note, new = note } } }
  else
    local blocks, gaps = layout.plan(diff, { context = ctx, expanded = opts.expanded })
    build.gaps = gaps
    -- The row of a collapsed section counts the aligned rows. Both sides hold
    -- the same rows, so the number fits both buffers.
    build.rows = rows_of(blocks)
  end

  for lnum, row in ipairs(build.rows) do
    local old_text, old_record = cell_of(row, "old", diff, build.gaps)
    local new_text, new_record = cell_of(row, "new", diff, build.gaps)
    build.old.lines[lnum], build.new.lines[lnum] = old_text, new_text
    build.old.map:add(old_record)
    build.new.map:add(new_record)
    if old_record.kind == "filler" and not old_record.gap then
      build.old.fillers[#build.old.fillers + 1] = lnum
    end
    if new_record.kind == "filler" and not new_record.gap then
      build.new.fillers[#build.new.fillers + 1] = lnum
    end

    -- Two lines of the same position are a pair only when the hunk replaces
    -- as many lines as it adds.
    local hunk = word_diff and row.kind == "change" and diff.hunks[row.hunk] or nil
    if hunk and hunk.old_count == hunk.new_count then
      local prefix, old_to, new_to = layout.word_range(old_text, new_text)
      if prefix then
        if old_to > prefix then
          build.old.marks[#build.old.marks + 1] =
            { row = lnum, col = prefix, end_col = old_to, hl = "CodeViewDiffText" }
        end
        if new_to > prefix then
          build.new.marks[#build.new.marks + 1] =
            { row = lnum, col = prefix, end_col = new_to, hl = "CodeViewDiffText" }
        end
      end
    end
  end

  return build
end

--- Render ----------------------------------------------------------------------

---Forget the state of a buffer that goes away.
---@param buf integer
local function watch(buf)
  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    desc = "Forget the codeview diff of a buffer",
    callback = function()
      states[buf] = nil
    end,
  })
end

---Virtual text of the last render, with the width that it covers.
---@type { width: integer, char: string, text: string }
local fill = { width = -1, char = "", text = "" }

---Virtual text that marks a filler row.
---
--- Every filler row of a render shares one string, because a render writes the
--- text on each row of a side that holds no line.
---@param width integer Columns to cover.
---@return string text
local function filler_text(width)
  if fill.width ~= width or fill.char ~= M.filler_char then
    fill = { width = width, char = M.filler_char, text = M.filler_char:rep(width) }
  end
  return fill.text
end

---Columns that the filler text of a buffer covers.
---
--- A window of the buffer gives the width. Without a window the call takes the
--- cap of |codeview.split.filler_width|.
---@param buf integer
---@return integer width
local function fill_width(buf)
  local width = 0
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == buf then
      width = math.max(width, api.nvim_win_get_width(win))
    end
  end
  return math.min(width > 0 and width or M.filler_width, M.filler_width)
end

---Highlight group of a whole row.
---@param row codeview.linemap.Row
---@return string? group
local function group_of(row)
  if row.kind == "filler" then
    return row.gap and "CodeViewDiffFold" or "CodeViewDiffFiller"
  end
  return M.line_hl[row.kind]
end

---Write the content and the highlights of one side.
---@param buf integer
---@param build codeview.split.Build
---@param side codeview.linemap.Side
local function write(buf, build, side)
  local content = build[side]

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false

  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  -- Every filler row of the side shares one chunk list. Neovim copies it.
  local chunks = { { filler_text(fill_width(buf)), "CodeViewDiffFiller" } }
  for lnum, row in ipairs(content.map.rows) do
    local group = group_of(row)
    if group then
      local extmark = { line_hl_group = group }
      if row.kind == "filler" and not row.gap then
        -- The row is not part of the file. Virtual text marks it as free.
        extmark.virt_text = chunks
        extmark.virt_text_pos = "overlay"
      end
      api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, extmark)
    end
  end
  for _, mark in ipairs(content.marks) do
    local width = #content.lines[mark.row]
    local col = math.min(mark.col, width)
    local end_col = math.min(mark.end_col, width)
    if end_col > col then
      api.nvim_buf_set_extmark(buf, M.ns, mark.row - 1, col, { end_col = end_col, hl_group = mark.hl })
    end
  end

  if not states[buf] then
    watch(buf)
  end
end

---Render a diff into two buffers.
---
--- The call replaces the content of both buffers, writes the highlights, and
--- keeps the result for |codeview.split.get()|.
---@param old_buf integer Buffer of the old side.
---@param new_buf integer Buffer of the new side.
---@param diff codeview.diff.File Diff of one file.
---@param opts? codeview.split.Opts
---@return codeview.split.Build build
function M.render(old_buf, new_buf, diff, opts)
  opts = opts or {}
  local build = M.build(diff, opts)

  for side, buf in pairs({ old = old_buf, new = new_buf }) do
    if api.nvim_buf_is_valid(buf) then
      write(buf, build, side)
      states[buf] = { side = side, diff = diff, build = build, opts = opts }
    end
  end
  return build
end

---Set the window options of one side of a side-by-side view.
---@param win integer Window handle.
function M.attach_window(win)
  layout.attach_window(win, M.window_options, M.statuscolumn_expr)
end

---Bind the scrolling and the cursor of the two windows.
---
--- Both windows hold the same number of rows, so the same top line puts the
--- two sides on the same screen row. 'scrollbind' keeps them there.
---
--- A bound window keeps the offset that it had when the binding started. The
--- call releases the binding first, puts the two top lines on the same row,
--- and binds again. The offset of the new binding is then zero.
---
--- The call runs no ":syncbind" command. That command makes Neovim drop the
--- next scroll of a bound window, which moves one side alone.
---@param old_win integer Window of the old side.
---@param new_win integer Window of the new side.
---@return boolean bound False when a window is gone.
function M.bind(old_win, new_win)
  if not old_win or not new_win then
    return false
  end
  if not api.nvim_win_is_valid(old_win) or not api.nvim_win_is_valid(new_win) then
    return false
  end

  local wins = { old_win, new_win }
  for _, win in ipairs(wins) do
    pcall(function()
      vim.wo[win][0].scrollbind = false
    end)
  end

  local view = api.nvim_win_call(new_win, vim.fn.winsaveview)
  api.nvim_win_call(old_win, function()
    vim.fn.winrestview({ topline = view.topline, leftcol = view.leftcol })
  end)

  -- Neovim records the top line of a window when 'scrollbind' becomes true.
  for _, win in ipairs(wins) do
    pcall(function()
      vim.wo[win][0].scrollbind = true
      vim.wo[win][0].cursorbind = true
    end)
  end
  return true
end

---Read the render state of a buffer.
---@param buf integer Buffer handle.
---@return codeview.split.State? state Nil when the buffer holds no diff.
function M.get(buf)
  return states[buf]
end

---Read the line map of a buffer.
---@param buf integer Buffer handle.
---@return codeview.LineMap? map Nil when the buffer holds no diff.
function M.map(buf)
  local state = states[buf]
  return state and state.build[state.side].map or nil
end

---Collapsed section of one buffer row.
---@param buf integer Buffer handle.
---@param lnum integer Buffer row, from 1.
---@return codeview.layout.Gap? gap Nil when the row belongs to no section.
function M.gap_at(buf, lnum)
  local state = states[buf]
  if not state then
    return nil
  end
  local row = state.build.rows[lnum]
  if not row or not row.gap then
    return nil
  end
  return state.build.gaps[row.gap]
end

---Sections that the buffers can show or hide.
---@param buf integer Buffer handle.
---@return codeview.layout.Gap[] gaps
function M.gaps(buf)
  local state = states[buf]
  return state and state.build.gaps or {}
end

---Line number of one buffer row, as the status column shows it.
---@param buf integer Buffer handle.
---@param lnum integer Buffer row, from 1.
---@return string text Empty text when the buffer holds no diff.
function M.number_column(buf, lnum)
  local state = states[buf]
  if not state then
    return ""
  end
  local side = state.side
  local line = state.build[side].map:file_line(lnum, side)
  return layout.pad(line, state.build.width[side]) .. " "
end

---Value of the 'statuscolumn' option of a side-by-side window.
---@return string text
function M.statuscolumn()
  return layout.statuscolumn(M.number_column)
end

return M
