---@brief A framed box of virtual lines, for a comment in the diff.
---
--- A comment in the diff shows as a box under its rows. The header goes into
--- the top border, the body lines go between two side borders, and the
--- bottom border closes the box. Spaces fill each line to the full width, so
--- the background of the box covers a rectangle.
---
--- A box can hold more than one section, for example the comments of one
--- review thread. Each section after the first starts with a divider line
--- that holds its header.
---
--- The box is as wide as the space to the right of the line numbers of its
--- window, minus one column. The inline comment editor has the same width,
--- so the box and the editor line up.
---
--- The module also holds the size helpers that |codeview.editor| uses for
--- its window.

local api = vim.api

local M = {}

---Smallest width of a box, in screen cells.
---@type integer
M.min_width = 20

---@class codeview.box.Chars
---@field top_left string
---@field top_right string
---@field bottom_left string
---@field bottom_right string
---@field horizontal string
---@field vertical string
---@field left_tee string? Left end of a divider line. The vertical character without it.
---@field right_tee string? Right end of a divider line. The vertical character without it.

---Characters of each border style that draws on all four sides.
---@type table<string, codeview.box.Chars>
M.chars = {
  rounded = {
    top_left = "╭",
    top_right = "╮",
    bottom_left = "╰",
    bottom_right = "╯",
    horizontal = "─",
    vertical = "│",
    left_tee = "├",
    right_tee = "┤",
  },
  single = {
    top_left = "┌",
    top_right = "┐",
    bottom_left = "└",
    bottom_right = "┘",
    horizontal = "─",
    vertical = "│",
    left_tee = "├",
    right_tee = "┤",
  },
  double = {
    top_left = "╔",
    top_right = "╗",
    bottom_left = "╚",
    bottom_right = "╝",
    horizontal = "═",
    vertical = "║",
    left_tee = "╠",
    right_tee = "╣",
  },
  bold = {
    top_left = "┏",
    top_right = "┓",
    bottom_left = "┗",
    bottom_right = "┛",
    horizontal = "━",
    vertical = "┃",
    left_tee = "┣",
    right_tee = "┫",
  },
  solid = {
    top_left = " ",
    top_right = " ",
    bottom_left = " ",
    bottom_right = " ",
    horizontal = " ",
    vertical = " ",
    left_tee = " ",
    right_tee = " ",
  },
}

---Report whether a border style draws no frame around a box.
---
--- The "shadow" border of a window draws on two sides only. A box of virtual
--- lines has no shadow, so it takes no frame.
---@param border string
---@return boolean
local function frameless(border)
  return border == "none" or border == "" or border == "shadow"
end

---Characters of the frame of a box.
---@param border string Value of the `comments.border` option.
---@return codeview.box.Chars? chars Nil when the border draws no frame. An unknown name takes "single".
function M.frame(border)
  if frameless(border) then
    return nil
  end
  return M.chars[border] or M.chars.single
end

---Rows and columns that a border adds to a window.
---
--- The "shadow" border draws only on the right side and on the bottom side.
--- Every other border except "none" draws on all four sides.
---@param border string
---@return integer rows
---@return integer cols
function M.border_size(border)
  if border == "none" or border == "" then
    return 0, 0
  end
  if border == "shadow" then
    return 1, 1
  end
  return 2, 2
end

---Width of the columns in front of the text of a window.
---
--- The width includes the status column, the number column, the sign column,
--- and the fold column.
---@param win integer
---@return integer
function M.text_offset(win)
  local info = vim.fn.getwininfo(win)[1]
  return info and info.textoff or 0
end

---Width of a box in one window.
---
--- The box fills the space to the right of the line numbers, minus one
--- column, the same as the inline comment editor.
---@param win integer
---@return integer width Width in screen cells. Not less than |codeview.box.min_width|.
function M.width(win)
  return math.max(api.nvim_win_get_width(win) - M.text_offset(win) - 1, M.min_width)
end

---Width of a box in the window that shows a buffer.
---
--- A window of the current tab page comes first. When no window shows the
--- buffer, the fallback window gives the width. Without a fallback window,
--- the width of the screen gives it.
---@param buf integer Buffer that holds the box.
---@param fallback integer? Window that gives the width when no window shows the buffer.
---@return integer width
function M.width_for(buf, fallback)
  local tab = api.nvim_get_current_tabpage()
  local found = nil
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_get_config(win).relative == "" then
      if api.nvim_win_get_tabpage(win) == tab then
        found = win
        break
      end
      found = found or win
    end
  end
  found = found or (fallback and api.nvim_win_is_valid(fallback) and fallback or nil)
  if found then
    return M.width(found)
  end
  return math.max(vim.o.columns - 1, M.min_width)
end

---Width of the boxes on each side of a view.
---@param view codeview.view.State
---@return integer[] widths Width of the new side, then of the old side in the split style.
local function view_widths(view)
  local out = { M.width_for(view.buf, view.win) }
  if view.old_buf and api.nvim_buf_is_valid(view.old_buf) then
    out[2] = M.width_for(view.old_buf, view.win)
  end
  return out
end

---Draw the boxes of a view again when the screen changes their width.
---
--- Neovim measures the line numbers and the sign column of a window on a
--- redraw, not before. A box that the call draws before the first redraw of a
--- new buffer, or before the redraw that shows the first sign, therefore
--- takes the old width. The check runs on the next tick, after the redraw.
--- When the width of a side changed, `redraw` draws the boxes again.
---@param view codeview.view.State
---@param redraw fun() Call that draws the boxes of the view again.
function M.refit(view, redraw)
  local before = view_widths(view)
  vim.schedule(function()
    if not api.nvim_buf_is_valid(view.buf) then
      return
    end
    if not vim.deep_equal(before, view_widths(view)) then
      redraw()
    end
  end)
end

---Characters of a text, one entry per character.
---@param text string
---@return string[] chars
local function characters(text)
  return vim.fn.split(text, "\\zs")
end

---Cut a text to a width, with "…" at the end of a cut.
---@param text string
---@param width integer Width in screen cells.
---@return string text
function M.truncate(text, width)
  if api.nvim_strwidth(text) <= width then
    return text
  end
  local out, used = "", 0
  for _, char in ipairs(characters(text)) do
    local size = api.nvim_strwidth(char)
    if used + size > width - 1 then
      break
    end
    out, used = out .. char, used + size
  end
  return out .. "…"
end

---Split a word that is wider than a line into parts that fit.
---@param word string
---@param width integer
---@return string[] parts
local function break_word(word, width)
  local parts = {}
  local part, used = "", 0
  for _, char in ipairs(characters(word)) do
    local size = api.nvim_strwidth(char)
    if used + size > width and part ~= "" then
      parts[#parts + 1] = part
      part, used = "", 0
    end
    part, used = part .. char, used + size
  end
  if part ~= "" then
    parts[#parts + 1] = part
  end
  return parts
end

---Wrap one line of text at word boundaries.
---
--- A word that is wider than the line breaks at the width. The spaces at a
--- break go away. The spaces at the start of the line stay, so an indent
--- keeps its place on the first part.
---@param line string
---@param width integer Width in screen cells.
---@return string[] lines Never empty. An empty line gives one empty line.
function M.wrap(line, width)
  line = line:gsub("%s+$", "")
  local out = {}
  local current, used = "", 0
  for gap, word in line:gmatch("(%s*)(%S+)") do
    local gap_size, word_size = api.nvim_strwidth(gap), api.nvim_strwidth(word)
    if used + gap_size + word_size <= width then
      current, used = current .. gap .. word, used + gap_size + word_size
    else
      if used > 0 then
        out[#out + 1] = current
      end
      local parts = word_size > width and break_word(word, width) or { word }
      for index = 1, #parts - 1 do
        out[#out + 1] = parts[index]
      end
      current = parts[#parts]
      used = api.nvim_strwidth(current)
    end
  end
  if used > 0 or #out == 0 then
    out[#out + 1] = current
  end
  return out
end

---Spaces that fill a text to a width.
---@param text string
---@param width integer
---@return string text
local function pad(text, width)
  return text .. string.rep(" ", math.max(width - api.nvim_strwidth(text), 0))
end

---@class codeview.box.Section
---@field header string Text of the header.
---@field header_hl string Group of the header text.
---@field body string? Text of the body. Lines split at "\n". Nil gives no body lines.
---@field body_hl string? Group of the body text.
---@field footer string? Text of one more line after the body, for example the reactions of a comment.
---@field footer_hl string? Group of the footer text.

---@class codeview.box.Spec
---@field sections codeview.box.Section[]? Sections of the box. Without it, `header` and `body` make one section.
---@field header string? Text of the header of a box with one section.
---@field header_hl string? Group of the header text.
---@field body string? Text of the body of a box with one section. Lines split at "\n".
---@field body_hl string? Group of the body text.
---@field box_hl string Group of the background of the box.
---@field border_hl string Group of the frame.
---@field border string Value of the `comments.border` option.
---@field width integer Width of the box, in screen cells.

---Sections of a box spec.
---@param spec codeview.box.Spec
---@return codeview.box.Section[]
local function sections_of(spec)
  if spec.sections then
    return spec.sections
  end
  return {
    { header = spec.header or "", header_hl = spec.header_hl, body = spec.body or "", body_hl = spec.body_hl },
  }
end

---Wrapped text lines of the body and the footer of one section.
---@param section codeview.box.Section
---@param inner integer Width of the text, in screen cells.
---@return { text: string, hl: string? }[] lines
local function text_lines(section, inner)
  local out = {}
  ---@param text string
  ---@param hl string?
  local function add(text, hl)
    for _, raw in ipairs(vim.split(text, "\n", { plain = true })) do
      for _, line in ipairs(M.wrap(raw, inner)) do
        out[#out + 1] = { text = line, hl = hl }
      end
    end
  end
  if section.body then
    add(section.body, section.body_hl)
  end
  if section.footer and section.footer ~= "" then
    add(section.footer, section.footer_hl or section.body_hl)
  end
  return out
end

---Virtual lines of one box.
---
--- A chunk of text takes a list of two groups: its own group, and the group
--- of the box. The text then keeps its color and takes the background of the
--- box.
---
--- The header of the first section goes into the top border. Each next
--- section starts with a divider line `├─ header ─…┤`. A section without a
--- body takes no body lines.
---
--- Without a frame, the box is the header line and the body lines of each
--- section, each with one space of padding on both sides.
---@param spec codeview.box.Spec
---@return table[][] lines Chunks of every virtual line.
function M.lines(spec)
  local width = math.max(spec.width, M.min_width)
  local chars = M.frame(spec.border)
  local out = {}

  ---@param hl string?
  ---@return string[]
  local function with_box(hl)
    return { hl, spec.box_hl }
  end

  if not chars then
    local inner = width - 2
    for _, section in ipairs(sections_of(spec)) do
      out[#out + 1] = { { " " .. pad(M.truncate(section.header, inner), inner) .. " ", with_box(section.header_hl) } }
      for _, line in ipairs(text_lines(section, inner)) do
        out[#out + 1] = { { " " .. pad(line.text, inner) .. " ", with_box(line.hl) } }
      end
    end
    return out
  end

  ---A border line with a header: "╭─ header ─…─╮" or "├─ header ─…─┤". Six
  ---cells hold the ends, the first dash, the two spaces, and at least one
  ---dash after the header.
  ---@param left string
  ---@param right string
  ---@param section codeview.box.Section
  ---@return table[]
  local function header_line(left, right, section)
    local header = M.truncate(section.header, width - 6)
    local fill = width - 5 - api.nvim_strwidth(header)
    return {
      { left .. chars.horizontal .. " ", spec.border_hl },
      { header, with_box(section.header_hl) },
      { " " .. string.rep(chars.horizontal, fill) .. right, spec.border_hl },
    }
  end

  local inner = width - 4
  for index, section in ipairs(sections_of(spec)) do
    if index == 1 then
      out[#out + 1] = header_line(chars.top_left, chars.top_right, section)
    else
      out[#out + 1] = header_line(chars.left_tee or chars.vertical, chars.right_tee or chars.vertical, section)
    end
    for _, line in ipairs(text_lines(section, inner)) do
      out[#out + 1] = {
        { chars.vertical, spec.border_hl },
        { " " .. pad(line.text, inner) .. " ", with_box(line.hl) },
        { chars.vertical, spec.border_hl },
      }
    end
  end
  out[#out + 1] = {
    { chars.bottom_left .. string.rep(chars.horizontal, width - 2) .. chars.bottom_right, spec.border_hl },
  }
  return out
end

return M
