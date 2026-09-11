---@brief The inline diff style: one unified diff in one buffer.
---
--- The renderer turns a |codeview.diff.File| into buffer lines, a
--- |codeview.LineMap|, and a list of highlights. `build()` is a pure function:
--- it takes the diff and gives the lines, so the tests read the result without
--- a window. `render()` writes that result into a buffer.
---
--- The layout follows the unified diff format:
---
--- >
---     @@ -1,4 +1,5 @@
---      one
---     -two
---     +two changed
---      three
---     ⋯ 24 unchanged lines
--- <
---
--- The first character of a line is the marker. A space marks an unchanged
--- line, `-` marks a removed line, and `+` marks an added line. The line
--- numbers of both sides come from the status column. A yank of a line
--- therefore gives the text of the file with one marker in front.
---
--- The renderer shows `diff.context` unchanged lines around each hunk. It
--- hides a longer unchanged section behind one filler row. The row keeps the
--- number of the section, so a key can show the hidden lines again. The hunk
--- header keeps the line numbers of the collapsed form. The header names the
--- position of the hunk in the file, not the state of the fold.
---
--- |codeview.layout| holds the plan of the rows: the blocks, the collapsed
--- sections, and the hunk headers. The side-by-side style of M5 reads the same
--- plan from the same diff, so both styles show the same hunks.

local config = require("codeview.config")
local layout = require("codeview.layout")
local linemap = require("codeview.linemap")

local api = vim.api

local M = {}

---Namespace of the diff highlights.
---@type integer
M.ns = api.nvim_create_namespace("codeview.inline")

---Filetype of a diff buffer.
---@type string
M.filetype = "codeview-diff"

---Value for the 'statuscolumn' option of a diff window.
---@type string
M.statuscolumn_expr = "%!v:lua.require'codeview.inline'.statuscolumn()"

---Marker character of each row kind.
---@type table<codeview.linemap.Kind, string>
M.markers = {
  context = " ",
  add = "+",
  delete = "-",
}

---Highlight group of a whole row, per row kind.
---@type table<codeview.linemap.Kind, string>
M.line_hl = {
  add = "CodeViewDiffAdd",
  delete = "CodeViewDiffDelete",
  header = "CodeViewDiffHunk",
  filler = "CodeViewDiffFold",
  message = "CodeViewDiffMessage",
}

---Priority of a row highlight. One below the default of an extmark, so
--- the word marks and the marks of other plugins paint over a row.
---@type integer
M.row_priority = 4095

---Window options of a diff window. They apply to the buffer of the window.
---@type table<string, any>
M.window_options = layout.window_options

---@class codeview.inline.Build
---@field lines string[] Text of every buffer row.
---@field map codeview.LineMap Map between the rows and the file lines.
---@field marks codeview.layout.Mark[] Highlights inside a row.
---@field gaps codeview.layout.Gap[] Collapsed sections, by number.
---@field width { old: integer, new: integer } Column width of the line numbers.

---@class codeview.inline.Opts
---@field context integer? Unchanged lines around a hunk. The `diff.context` option by default.
---@field word_diff boolean? Highlight the changed part of a line. The `diff.word_diff` option by default.
---@field expanded table<integer, boolean>? Sections that show their hidden lines.

---@class codeview.inline.State
---@field diff codeview.diff.File Diff that the buffer shows.
---@field build codeview.inline.Build Result of the last render.
---@field opts codeview.inline.Opts Options of the last render.

---Render state of each diff buffer.
---@type table<integer, codeview.inline.State>
local states = {}

--- Build -----------------------------------------------------------------------

---Build the rows of a unified diff.
---@param diff codeview.diff.File Diff of one file.
---@param opts? codeview.inline.Opts
---@return codeview.inline.Build build
function M.build(diff, opts)
  opts = opts or {}
  local cfg = config.get().diff
  local ctx = opts.context or diff.context or cfg.context
  local word_diff = opts.word_diff
  if word_diff == nil then
    word_diff = cfg.word_diff
  end
  local expanded = opts.expanded or {}

  local lines = {}
  local marks = {}
  local map = linemap.new()

  ---@param text string
  ---@param row codeview.linemap.Row
  ---@return integer lnum
  local function emit(text, row)
    lines[#lines + 1] = text
    return map:add(row)
  end

  ---@type codeview.inline.Build
  local build = {
    lines = lines,
    map = map,
    marks = marks,
    gaps = {},
    width = { old = layout.digits(#diff.old_lines), new = layout.digits(#diff.new_lines) },
  }

  if diff.message then
    -- The commit message is a document, not a diff. Every row holds a line of
    -- the new side, so a comment anchors to it like a comment on code.
    for index, text in ipairs(diff.new_lines) do
      emit(text, { kind = "context", new = index })
    end
    return build
  end
  if diff.binary then
    emit("The file is binary. It has no text diff.", { kind = "message" })
    return build
  end
  if diff.limited then
    for _, text in ipairs(layout.limit_lines(diff)) do
      emit(text, { kind = "message" })
    end
    return build
  end
  if #diff.hunks == 0 then
    local empty = #diff.old_lines == 0 and #diff.new_lines == 0
    emit(empty and "The file is empty." or "The file has no changes.", { kind = "message" })
    return build
  end

  local blocks, gaps = layout.plan(diff, { context = ctx, expanded = expanded })
  build.gaps = gaps

  ---Highlight the changed part of a pair of lines.
  ---@param old_text string
  ---@param new_text string
  ---@param old_row integer
  ---@param new_row integer
  local function mark_words(old_text, new_text, old_row, new_row)
    -- The marker takes one byte in front of the text of the line.
    local prefix, old_to, new_to = layout.word_range(old_text, new_text)
    if not prefix then
      return
    end
    if old_to > prefix then
      marks[#marks + 1] = { row = old_row, col = prefix + 1, end_col = old_to + 1, hl = "CodeViewDiffTextDelete" }
    end
    if new_to > prefix then
      marks[#marks + 1] = { row = new_row, col = prefix + 1, end_col = new_to + 1, hl = "CodeViewDiffTextAdd" }
    end
  end

  ---@param block table
  ---@param gap codeview.layout.Gap?
  local function emit_context(block, gap)
    for step = 0, block.count - 1 do
      local old_line, new_line = block.old + step, block.new + step
      local text = diff.new_lines[new_line] or diff.old_lines[old_line] or ""
      emit(M.markers.context .. text, {
        kind = "context",
        old = old_line,
        new = new_line,
        hunk = block.hunk_index,
        gap = gap and gap.id or nil,
      })
    end
  end

  local seen = {}
  for _, block in ipairs(blocks) do
    if block.group and not seen[block.group] then
      seen[block.group] = true
      emit(block.group.header, { kind = "header", hunk = block.group.hunk })
    end

    if block.kind == "context" then
      emit_context(block, nil)
    elseif block.kind == "gap" then
      local gap = block.gap
      if gap.expanded then
        emit_context({ old = gap.old, new = gap.new, count = gap.count }, gap)
        gap.row = nil
      else
        gap.row = emit(layout.filler_text(gap), { kind = "filler", gap = gap.id })
      end
    else
      local hunk = block.hunk
      local delete_rows, add_rows = {}, {}
      for step = 0, hunk.old_count - 1 do
        local line = hunk.old_first + step
        delete_rows[step + 1] = emit(M.markers.delete .. (diff.old_lines[line] or ""), {
          kind = "delete",
          old = line,
          hunk = hunk.index,
        })
      end
      for step = 0, hunk.new_count - 1 do
        local line = hunk.new_first + step
        add_rows[step + 1] = emit(M.markers.add .. (diff.new_lines[line] or ""), {
          kind = "add",
          new = line,
          hunk = hunk.index,
        })
      end
      -- The diff aligns similar lines inside a hunk, so a hunk that replaces
      -- as many lines as it adds pairs its lines by position. A hunk with
      -- other counts holds lines that are too different to pair.
      if word_diff and hunk.old_count == hunk.new_count then
        for step = 1, hunk.old_count do
          mark_words(
            diff.old_lines[hunk.old_first + step - 1] or "",
            diff.new_lines[hunk.new_first + step - 1] or "",
            delete_rows[step],
            add_rows[step]
          )
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
    group = api.nvim_create_augroup("codeview.inline", { clear = false }),
    buffer = buf,
    once = true,
    desc = "Forget the codeview diff of a buffer",
    callback = function()
      states[buf] = nil
    end,
  })
end

---Write the highlights of one render.
---@param buf integer
---@param build codeview.inline.Build
local function apply_marks(buf, build)
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  -- A line highlight covers every range mark of the line, so the rows are range
  -- marks and the word marks paint over them.
  for lnum, row in ipairs(build.map.rows) do
    local group = M.line_hl[row.kind]
    if group then
      api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, {
        end_row = lnum, -- the next row (0-based), so the range covers the line break
        end_col = 0,
        hl_eol = true, -- paint to the end of the screen line, like a line highlight
        hl_group = group,
        priority = M.row_priority,
        strict = false, -- the last row has no next row
      })
    end
  end
  for _, mark in ipairs(build.marks) do
    local width = #build.lines[mark.row]
    local col = math.min(mark.col, width)
    local end_col = math.min(mark.end_col, width)
    if end_col > col then
      api.nvim_buf_set_extmark(buf, M.ns, mark.row - 1, col, { end_col = end_col, hl_group = mark.hl })
    end
  end
end

---Render a diff into a buffer.
---
--- The call replaces the content of the buffer, writes the highlights, and
--- keeps the result for |codeview.inline.get()|.
---@param buf integer Buffer handle.
---@param diff codeview.diff.File Diff of one file.
---@param opts? codeview.inline.Opts
---@return codeview.inline.Build build
function M.render(buf, diff, opts)
  opts = opts or {}
  local build = M.build(diff, opts)

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, build.lines)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false

  apply_marks(buf, build)
  -- The marker column shifts every capture of the parse by its width.
  require("codeview.syntax").apply(buf, diff, build.map, { offset = #M.markers.context })
  if not states[buf] then
    watch(buf)
  end
  states[buf] = { diff = diff, build = build, opts = opts }
  return build
end

---Set the window options of a diff window.
---@param win integer Window handle.
function M.attach_window(win)
  layout.attach_window(win, M.window_options, M.statuscolumn_expr)
end

---Read the render state of a buffer.
---@param buf integer Buffer handle.
---@return codeview.inline.State? state Nil when the buffer holds no diff.
function M.get(buf)
  return states[buf]
end

---Read the line map of a buffer.
---@param buf integer Buffer handle.
---@return codeview.LineMap? map Nil when the buffer holds no diff.
function M.map(buf)
  local state = states[buf]
  return state and state.build.map or nil
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
  local row = state.build.map:row(lnum)
  if not row or not row.gap then
    return nil
  end
  return state.build.gaps[row.gap]
end

---Sections that the buffer can show or hide.
---@param buf integer Buffer handle.
---@return codeview.layout.Gap[] gaps
function M.gaps(buf)
  local state = states[buf]
  return state and state.build.gaps or {}
end

---Line numbers of one buffer row, as the status column shows them.
---@param buf integer Buffer handle.
---@param lnum integer Buffer row, from 1.
---@return string text Empty text when the buffer holds no diff.
function M.number_column(buf, lnum)
  local state = states[buf]
  if not state then
    return ""
  end
  local map = state.build.map
  local width = state.build.width
  local old = map:file_line(lnum, "old")
  local new = map:file_line(lnum, "new")
  return string.format("%s %s ", layout.pad(old, width.old), layout.pad(new, width.new))
end

---Value of the 'statuscolumn' option of a diff window.
---
--- Neovim calls the function for every row of the window.
---@return string text
function M.statuscolumn()
  return layout.statuscolumn(M.number_column)
end

return M
