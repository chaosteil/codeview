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
--- The first character of a line is the marker: a space for an unchanged line,
--- `-` for a removed line, and `+` for an added line. The line numbers of both
--- sides come from the status column, so a yank of a line gives the text of
--- the file with one marker in front.
---
--- The renderer shows `diff.context` unchanged lines around each hunk. It
--- hides a longer unchanged section behind one filler row. The row keeps the
--- number of the section, so a key can show the hidden lines again. The hunk
--- header keeps the line numbers of the collapsed form, because the header
--- names the position of the hunk in the file, not the state of the fold.
---
--- A section that hides fewer lines than `MIN_HIDDEN` stays open. A filler row
--- for one line costs the same screen row as the line, and it splits one
--- readable hunk into two.

local config = require("codeview.config")
local linemap = require("codeview.linemap")

local api = vim.api

local M = {}

---Smallest number of lines that a collapsed section hides.
---@type integer
local MIN_HIDDEN = 2

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

---Window options of a diff window. They apply to the buffer of the window.
---@type table<string, any>
M.window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "auto",
  foldcolumn = "0",
  foldenable = false,
  wrap = false,
  spell = false,
  list = false,
  cursorline = true,
  cursorlineopt = "number,line",
  colorcolumn = "",
}

---@class codeview.inline.Gap
---@field id integer Number of the collapsed section, from 1.
---@field count integer Number of unchanged lines in the section.
---@field old integer First old line of the section.
---@field new integer First new line of the section.
---@field expanded boolean True while the section shows its lines.
---@field row integer? Buffer row of the filler line, while the section is collapsed.

---@class codeview.inline.Mark
---@field row integer Buffer row, from 1.
---@field col integer Start column, in bytes, from 0.
---@field end_col integer End column, in bytes.
---@field hl string Highlight group.

---@class codeview.inline.Build
---@field lines string[] Text of every buffer row.
---@field map codeview.LineMap Map between the rows and the file lines.
---@field marks codeview.inline.Mark[] Highlights inside a row.
---@field gaps codeview.inline.Gap[] Collapsed sections, by number.
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

--- Text helpers ----------------------------------------------------------------

---Report whether a byte continues a multi-byte character.
---@param byte integer?
---@return boolean
local function is_continuation(byte)
  return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

---Number of leading bytes that two lines share.
---
--- The result never splits a multi-byte character.
---@param a string
---@param b string
---@return integer count
local function common_prefix(a, b)
  local limit = math.min(#a, #b)
  local count = 0
  while count < limit and a:byte(count + 1) == b:byte(count + 1) do
    count = count + 1
  end
  while count > 0 and is_continuation(a:byte(count + 1)) do
    count = count - 1
  end
  return count
end

---Number of trailing bytes that two lines share, above one prefix.
---@param a string
---@param b string
---@param prefix integer Bytes that the two lines share at the start.
---@return integer count
local function common_suffix(a, b, prefix)
  local limit = math.min(#a, #b) - prefix
  local count = 0
  while count < limit and a:byte(#a - count) == b:byte(#b - count) do
    count = count + 1
  end
  while count > 0 and is_continuation(a:byte(#a - count + 1)) do
    count = count - 1
  end
  return count
end

---Number of digits of a line count.
---@param value integer
---@return integer width
local function digits(value)
  return #tostring(math.max(value, 1))
end

---Right-align a line number in one column.
---@param value integer? Line number, or nil for an empty column.
---@param width integer
---@return string
local function pad(value, width)
  if not value then
    return string.rep(" ", width)
  end
  return string.format("%" .. width .. "d", value)
end

---Text of the range of one side of a hunk header.
---@param from integer First line, or the line before an insert.
---@param count integer Number of lines.
---@return string
local function range_text(from, count)
  if count == 0 then
    return string.format("%d,0", from)
  end
  if count == 1 then
    return tostring(from)
  end
  return string.format("%d,%d", from, count)
end

--- Build -----------------------------------------------------------------------

---Split a diff into unchanged segments and change segments.
---@param diff codeview.diff.File
---@return table[] segments
local function segments_of(diff)
  local out = {}
  local old_pos, new_pos = 1, 1
  for _, hunk in ipairs(diff.hunks) do
    out[#out + 1] = {
      kind = "same",
      old = old_pos,
      new = new_pos,
      count = math.max(hunk.old_first - old_pos, 0),
    }
    out[#out + 1] = { kind = "change", hunk = hunk }
    old_pos = hunk.old_first + hunk.old_count
    new_pos = hunk.new_first + hunk.new_count
  end
  out[#out + 1] = {
    kind = "same",
    old = old_pos,
    new = new_pos,
    count = math.max(#diff.old_lines - old_pos + 1, 0),
  }
  return out
end

---Turn the segments into the blocks that the buffer shows.
---
--- An unchanged segment gives up to three blocks: the context after the change
--- above it, the hidden middle, and the context before the change below it. A
--- segment that is short enough gives one context block. A middle that holds
--- fewer than `MIN_HIDDEN` lines also gives one context block.
---@param diff codeview.diff.File
---@param ctx integer Context length.
---@param expanded table<integer, boolean>
---@return table[] blocks
---@return codeview.inline.Gap[] gaps
local function blocks_of(diff, ctx, expanded)
  local blocks, gaps = {}, {}
  local segments = segments_of(diff)

  for index, segment in ipairs(segments) do
    if segment.kind == "change" then
      blocks[#blocks + 1] = { kind = "change", hunk = segment.hunk }
    else
      local lead = index == 1 and 0 or math.min(ctx, segment.count)
      local tail = index == #segments and 0 or math.min(ctx, segment.count - lead)
      local hidden = segment.count - lead - tail
      if hidden < MIN_HIDDEN then
        if segment.count > 0 then
          blocks[#blocks + 1] = { kind = "context", old = segment.old, new = segment.new, count = segment.count }
        end
      else
        if lead > 0 then
          blocks[#blocks + 1] = { kind = "context", old = segment.old, new = segment.new, count = lead }
        end
        local id = #gaps + 1
        ---@type codeview.inline.Gap
        local gap = {
          id = id,
          count = hidden,
          old = segment.old + lead,
          new = segment.new + lead,
          expanded = expanded[id] == true,
        }
        gaps[id] = gap
        blocks[#blocks + 1] = { kind = "gap", gap = gap }
        if tail > 0 then
          blocks[#blocks + 1] = {
            kind = "context",
            old = segment.old + lead + hidden,
            new = segment.new + lead + hidden,
            count = tail,
          }
        end
      end
    end
  end
  return blocks, gaps
end

---Group the blocks between the collapsed sections.
---
--- One group holds one hunk with its context, and it starts with a hunk
--- header. A group grows over more than one hunk when no collapsed section
--- separates them.
---
--- Each block also keeps the hunk that owns its rows: the change above it, or
--- the first change of the group for a leading context block. The rows of two
--- hunks of one group then stay apart in the line map.
---@param blocks table[]
---@return table[] groups
local function groups_of(blocks)
  local groups = {}
  local run = nil
  for _, block in ipairs(blocks) do
    if block.kind == "gap" then
      run = nil
    else
      if not run then
        run = { blocks = {} }
        groups[#groups + 1] = run
      end
      run.blocks[#run.blocks + 1] = block
      block.group = run
      if block.kind == "change" then
        run.hunk = run.hunk or block.hunk.index
      end
    end
  end

  for _, group in ipairs(groups) do
    local old_from, old_count, new_from, new_count
    local insert_old, insert_new
    local owner = nil
    for _, block in ipairs(group.blocks) do
      if block.kind == "change" then
        owner = block.hunk.index
      end
      block.hunk_index = owner or group.hunk
      if block.kind == "context" then
        old_from = old_from or block.old
        new_from = new_from or block.new
        old_count = (old_count or 0) + block.count
        new_count = (new_count or 0) + block.count
      else
        local hunk = block.hunk
        insert_old, insert_new = hunk.old_start, hunk.new_start
        if hunk.old_count > 0 then
          old_from = old_from or hunk.old_first
          old_count = (old_count or 0) + hunk.old_count
        end
        if hunk.new_count > 0 then
          new_from = new_from or hunk.new_first
          new_count = (new_count or 0) + hunk.new_count
        end
      end
    end
    group.old_from, group.old_count = old_from or insert_old or 0, old_count or 0
    group.new_from, group.new_count = new_from or insert_new or 0, new_count or 0
    group.header = string.format(
      "@@ -%s +%s @@",
      range_text(group.old_from, group.old_count),
      range_text(group.new_from, group.new_count)
    )
  end
  return groups
end

---Text of the filler row of a collapsed section.
---@param gap codeview.inline.Gap
---@return string
local function filler_text(gap)
  return string.format("⋯ %d unchanged %s", gap.count, gap.count == 1 and "line" or "lines")
end

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
    width = { old = digits(#diff.old_lines), new = digits(#diff.new_lines) },
  }

  if diff.binary then
    emit("Binary file. It has no text diff.", { kind = "message" })
    return build
  end
  if #diff.hunks == 0 then
    local empty = #diff.old_lines == 0 and #diff.new_lines == 0
    emit(empty and "The file is empty." or "The file has no changes.", { kind = "message" })
    return build
  end

  local blocks, gaps = blocks_of(diff, ctx, expanded)
  build.gaps = gaps
  groups_of(blocks)

  ---Highlight the changed part of a pair of lines.
  ---@param old_text string
  ---@param new_text string
  ---@param old_row integer
  ---@param new_row integer
  local function mark_words(old_text, new_text, old_row, new_row)
    local prefix = common_prefix(old_text, new_text)
    local suffix = common_suffix(old_text, new_text, prefix)
    if prefix == 0 and suffix == 0 then
      return
    end
    -- The marker takes one byte in front of the text of the line.
    local old_to, new_to = #old_text - suffix, #new_text - suffix
    if old_to > prefix then
      marks[#marks + 1] = { row = old_row, col = prefix + 1, end_col = old_to + 1, hl = "CodeViewDiffText" }
    end
    if new_to > prefix then
      marks[#marks + 1] = { row = new_row, col = prefix + 1, end_col = new_to + 1, hl = "CodeViewDiffText" }
    end
  end

  ---@param block table
  ---@param gap codeview.inline.Gap?
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
        gap.row = emit(filler_text(gap), { kind = "filler", gap = gap.id })
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
  for lnum, row in ipairs(build.map.rows) do
    local group = M.line_hl[row.kind]
    if group then
      api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, { line_hl_group = group })
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
  if not states[buf] then
    watch(buf)
  end
  states[buf] = { diff = diff, build = build, opts = opts }
  return build
end

---Set the window options of a diff window.
---
--- The options apply to the buffer of the window, so another buffer in the
--- same window keeps its own values.
---@param win integer Window handle.
function M.attach_window(win)
  if not api.nvim_win_is_valid(win) then
    return
  end
  for name, value in pairs(M.window_options) do
    pcall(function()
      vim.wo[win][0][name] = value
    end)
  end
  pcall(function()
    vim.wo[win][0].statuscolumn = M.statuscolumn_expr
  end)
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
---@return codeview.inline.Gap? gap Nil when the row belongs to no section.
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
---@return codeview.inline.Gap[] gaps
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
  return string.format("%s %s ", pad(old, width.old), pad(new, width.new))
end

---Value of the 'statuscolumn' option of a diff window.
---
--- Neovim calls the function for every row of the window.
---@return string text
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local buf
  if type(win) == "number" and api.nvim_win_is_valid(win) then
    buf = api.nvim_win_get_buf(win)
  else
    buf = api.nvim_get_current_buf()
  end
  return "%#CodeViewDiffNumber#" .. M.number_column(buf, vim.v.lnum) .. "%*%s"
end

return M
