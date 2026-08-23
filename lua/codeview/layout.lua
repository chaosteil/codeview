---@brief The plan that both diff styles share.
---
--- The inline style and the side-by-side style show the same hunks, the same
--- context lines, and the same collapsed sections. This module holds that
--- plan, so that the two renderers read one result of |vim.diff()| and never
--- compute a second one.
---
--- |codeview.layout.plan()| turns a |codeview.diff.File| into blocks, in file
--- order:
---
--- - a context block, with the unchanged lines around a change,
--- - a gap block, for an unchanged section that the view hides,
--- - a change block, with one hunk.
---
--- The blocks come in groups. One group holds one hunk with its context, and
--- it starts with a hunk header. A group grows over more than one hunk when no
--- collapsed section separates them.
---
--- The module also holds:
---
--- - the text of a hunk header,
--- - the text of a filler row,
--- - the word range of a modified line,
--- - the window options of a diff window.

local api = vim.api

local M = {}

---Smallest number of lines that a collapsed section hides.
---
--- A filler row for one line costs the same screen row as the line, and it
--- splits one readable hunk into two.
---@type integer
M.MIN_HIDDEN = 2

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

---@class codeview.layout.Gap
---@field id integer Number of the collapsed section, from 1.
---@field count integer Number of unchanged lines in the section.
---@field old integer First old line of the section.
---@field new integer First new line of the section.
---@field expanded boolean True while the section shows its lines.
---@field row integer? Buffer row of the filler line, while the section is collapsed.

---@class codeview.layout.Group
---@field blocks codeview.layout.Block[] Blocks of the group, in file order.
---@field hunk integer? Position of the first hunk of the group.
---@field old_from integer First old line that the group shows.
---@field old_count integer Number of old lines that the group shows.
---@field new_from integer First new line that the group shows.
---@field new_count integer Number of new lines that the group shows.
---@field header string Unified header of the group, for example `@@ -1,4 +1,5 @@`.

---@class codeview.layout.Block
---@field kind "context"|"gap"|"change" Kind of the block.
---@field old integer? First old line of a context block.
---@field new integer? First new line of a context block.
---@field count integer? Number of lines of a context block.
---@field hunk codeview.diff.Hunk? Hunk of a change block.
---@field gap codeview.layout.Gap? Collapsed section of a gap block.
---@field group codeview.layout.Group? Group of the block. Nil for a gap block.
---@field hunk_index integer? Hunk that owns the rows of the block.

---@class codeview.layout.Mark
---@field row integer Buffer row, from 1.
---@field col integer Start column, in bytes, from 0.
---@field end_col integer End column, in bytes.
---@field hl string Highlight group.

---@class codeview.layout.Opts
---@field context integer Unchanged lines around a hunk.
---@field expanded table<integer, boolean>? Sections that show their hidden lines.

--- Text ------------------------------------------------------------------------

---Number of digits of a line count.
---@param value integer
---@return integer width
function M.digits(value)
  return #tostring(math.max(value, 1))
end

---Right-align a line number in one column.
---@param value integer? Line number, or nil for an empty column.
---@param width integer
---@return string
function M.pad(value, width)
  if not value then
    return string.rep(" ", width)
  end
  return string.format("%" .. width .. "d", value)
end

---Text of the range of one side of a hunk header.
---@param from integer First line, or the line before an insert.
---@param count integer Number of lines.
---@return string
function M.range_text(from, count)
  if count == 0 then
    return string.format("%d,0", from)
  end
  if count == 1 then
    return tostring(from)
  end
  return string.format("%d,%d", from, count)
end

---Header of one side of a group, for the side-by-side style.
---@param group codeview.layout.Group
---@param side codeview.linemap.Side
---@return string
function M.side_header(group, side)
  if side == "old" then
    return string.format("@@ -%s @@", M.range_text(group.old_from, group.old_count))
  end
  return string.format("@@ +%s @@", M.range_text(group.new_from, group.new_count))
end

---Text of the filler row of a collapsed section.
---@param gap codeview.layout.Gap
---@return string
function M.filler_text(gap)
  return string.format("⋯ %d unchanged %s", gap.count, gap.count == 1 and "line" or "lines")
end

---Rows that a diff above the line limit shows.
---
--- The second row names the key that renders the diff anyway. Without that
--- key it names the option, so the reader always has one way forward.
---@param diff codeview.diff.File Diff with the field `limited`.
---@return string[] lines Two rows of text.
function M.limit_lines(diff)
  local config = require("codeview.config")
  local key = config.keys(config.get().keymaps.load_diff)[1]
  return {
    require("codeview.diff").limit_message(diff),
    key and ("Press " .. key .. " to show it.") or "Set diff.max_lines higher to show it.",
  }
end

--- Word ranges -----------------------------------------------------------------

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

---Range of the changed part of two lines.
---
--- The two ends never split a multi-byte character. Two lines without a common
--- part give nil, because the whole line is the change then.
---@param old_text string Text of the old line.
---@param new_text string Text of the new line.
---@return integer? prefix Bytes that both lines share at the start.
---@return integer? old_to End byte of the changed part of the old line.
---@return integer? new_to End byte of the changed part of the new line.
function M.word_range(old_text, new_text)
  local prefix = common_prefix(old_text, new_text)
  local suffix = common_suffix(old_text, new_text, prefix)
  if prefix == 0 and suffix == 0 then
    return nil, nil, nil
  end
  return prefix, #old_text - suffix, #new_text - suffix
end

--- Blocks ----------------------------------------------------------------------

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
---@return codeview.layout.Block[] blocks
---@return codeview.layout.Gap[] gaps
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
      if hidden < M.MIN_HIDDEN then
        if segment.count > 0 then
          blocks[#blocks + 1] = { kind = "context", old = segment.old, new = segment.new, count = segment.count }
        end
      else
        if lead > 0 then
          blocks[#blocks + 1] = { kind = "context", old = segment.old, new = segment.new, count = lead }
        end
        local id = #gaps + 1
        ---@type codeview.layout.Gap
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
--- Each block also keeps the hunk that owns its rows: the change above it, or
--- the first change of the group for a leading context block. The rows of two
--- hunks of one group then stay apart in the line map.
---@param blocks codeview.layout.Block[]
---@return codeview.layout.Group[] groups
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
      M.range_text(group.old_from, group.old_count),
      M.range_text(group.new_from, group.new_count)
    )
  end
  return groups
end

---Plan the rows of a diff.
---
--- Both diff styles call this function with the same |codeview.diff.File|, so
--- both show the same hunks and the same collapsed sections.
---@param diff codeview.diff.File Diff of one file.
---@param opts codeview.layout.Opts
---@return codeview.layout.Block[] blocks Blocks, in file order.
---@return codeview.layout.Gap[] gaps Collapsed sections, by number.
---@return codeview.layout.Group[] groups Groups, in file order.
function M.plan(diff, opts)
  local blocks, gaps = blocks_of(diff, opts.context, opts.expanded or {})
  return blocks, gaps, groups_of(blocks)
end

--- Windows ---------------------------------------------------------------------

---Set the options of a diff window.
---
--- The options apply to the buffer of the window, so another buffer in the
--- same window keeps its own values.
---@param win integer Window handle.
---@param options table<string, any> Options of the style.
---@param statuscolumn string? Value for the 'statuscolumn' option.
function M.attach_window(win, options, statuscolumn)
  if not api.nvim_win_is_valid(win) then
    return
  end
  for name, value in pairs(options) do
    pcall(function()
      vim.wo[win][0][name] = value
    end)
  end
  if statuscolumn then
    pcall(function()
      vim.wo[win][0].statuscolumn = statuscolumn
    end)
  end
end

---Value of the 'statuscolumn' option of a diff window.
---
--- Neovim calls the function of the option for every row of the window. The
--- window names its buffer in `v:lua`, so one expression serves every diff
--- window of a style.
---@param number fun(buf: integer, lnum: integer): string Text of one row.
---@return string text
function M.statuscolumn(number)
  local win = vim.g.statusline_winid
  local buf
  if type(win) == "number" and api.nvim_win_is_valid(win) then
    buf = api.nvim_win_get_buf(win)
  else
    buf = api.nvim_get_current_buf()
  end
  return "%#CodeViewDiffNumber#" .. number(buf, vim.v.lnum) .. "%*%s"
end

---Report whether a window is a panel of codeview.
---
--- The check reads the window variable that |codeview.panel| sets, so this
--- module needs no reference to the panel module.
---@param win integer
---@return boolean
local function is_panel(win)
  local ok, value = pcall(api.nvim_win_get_var, win, "codeview_panel")
  return ok and value == true
end

---Run a call that opens or closes windows, and keep the layout around them.
---
--- Neovim makes the windows of a tab page equal again after every open and
--- every close, when 'equalalways' is on. A sidebar with 'winfixwidth' keeps
--- its width while other windows change. But it still takes the room of a
--- window that closes next to it, and it never gives that room back.
---
--- The call therefore holds 'equalalways' off, and puts the width of every
--- panel back afterwards. The reader then keeps the sidebar that the reader
--- set, and only a resize by hand changes it.
---@generic T
---@param fn fun(): T
---@return T
function M.keep(fn)
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false

  ---@type { win: integer, width: integer }[]
  local panels = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if is_panel(win) and api.nvim_win_get_config(win).relative == "" then
      panels[#panels + 1] = { win = win, width = api.nvim_win_get_width(win) }
    end
  end

  local ok, result = pcall(fn)

  for _, held in ipairs(panels) do
    if api.nvim_win_is_valid(held.win) and api.nvim_win_get_width(held.win) ~= held.width then
      pcall(api.nvim_win_set_width, held.win, held.width)
    end
  end
  vim.o.equalalways = equalalways

  if not ok then
    error(result, 0)
  end
  return result
end

return M
