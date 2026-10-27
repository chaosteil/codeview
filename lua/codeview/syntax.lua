---@brief Syntax highlights inside a diff.
---
--- A diff buffer holds the lines of two revisions, each with a marker column
--- in front. Neither side is the file on disk, so |vim.treesitter.start()| has
--- nothing to attach to: the buffer text is no valid program.
---
--- This module highlights the code anyway. It parses each side of the diff as
--- a whole file, which is valid text. Then it copies the captures of the
--- highlights query into the diff buffer. The line map of the render says
--- which buffer row holds which file line, and the marker column shifts every
--- capture by its width.
---
--- The module keeps the captures of each diff record, so a fold, an unfold,
--- or a switch of the style parses no side again. The keys of that cache are
--- weak: the captures go away with the diff record.
---
--- The colors of the diff itself stay in the background, so the two layers
--- read together. The background says added or removed. The foreground says
--- what the code is. See |codeview-highlights|.

local config = require("codeview.config")

local api = vim.api
local ts = vim.treesitter

local M = {}

---Namespace of the syntax highlights.
---@type integer
M.ns = api.nvim_create_namespace("codeview.syntax")

---Highest number of lines that one side can hold for a parse.
---
--- A parse of a very large file costs more than the reader gains. The line
--- limit of the diff already stops the biggest files, and this limit stops a
--- file that passes it with two long sides.
---@type integer
M.max_lines = 20000

---Highest number of bytes that one side can hold for a parse.
---
--- A line count says little about a file with very long lines. One line of a
--- generated file can hold megabytes, and its parse blocks the editor.
---@type integer
M.max_bytes = 1000000

---Highest number of bytes of one line that gets highlights.
---
--- The parse still reads the line, so the lines after it keep their colors.
--- The line itself shows the colors of the diff only.
---@type integer
M.max_line_bytes = 10000

---@class codeview.syntax.Entry
---@field lang string|false Language of the path. False when no parser answers.
---@field sides table<codeview.linemap.Side, table<integer, table[]>> Captures of each side, by line from 0.

---Captures of each diff record.
---
--- A diff record never changes after |codeview.diff.compute()|, so its
--- captures stay valid. The weak keys drop an entry when the view drops the
--- diff. No value refers to its key, so the collector can free both.
---@type table<codeview.diff.File, codeview.syntax.Entry>
local cache = setmetatable({}, { __mode = "k" })

---Language of a path.
---@param path string Path of the file in the repository.
---@return string? lang Nil when no parser answers for the path.
function M.language(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local filetype = vim.filetype.match({ filename = path })
  if not filetype then
    return nil
  end
  local lang = ts.language.get_lang(filetype) or filetype
  -- Neovim 0.11 returns nil and a message for a missing parser. It throws
  -- only for an invalid name.
  local ok, added = pcall(ts.language.add, lang)
  if not ok or not added then
    return nil
  end
  return lang
end

---Captures of one text, by line.
---
--- The call parses the text as one file and returns the ranges of the
--- highlights query, from 0. A range that covers more than one line becomes
--- one range per line, because the diff buffer holds the lines apart.
---
--- A query of a user can be invalid, and a parser can fail. The call then
--- returns no capture, so the diff renders without syntax colors.
---@param text string Whole text of one side.
---@param lang string Language of the parser.
---@return table<integer, { col: integer, end_col: integer, hl: string, priority: integer }[]> by_line
local function captures_of(text, lang)
  ---@type table<integer, { col: integer, end_col: integer, hl: string, priority: integer }[]>
  local by_line = {}

  local ok, parser = pcall(ts.get_string_parser, text, lang)
  if not ok or not parser then
    return by_line
  end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then
    return by_line
  end
  local found, query = pcall(ts.query.get, lang, "highlights")
  if not found or not query then
    return by_line
  end

  local lines = vim.split(text, "\n", { plain = true })

  ---@param line integer Line of the text, from 0.
  ---@param col integer
  ---@param end_col integer
  ---@param name string Name of the capture.
  ---@param priority integer
  local function keep(line, col, end_col, name, priority)
    if end_col <= col or #(lines[line + 1] or "") > M.max_line_bytes then
      return
    end
    by_line[line] = by_line[line] or {}
    local list = by_line[line]
    list[#list + 1] = { col = col, end_col = end_col, hl = "@" .. name, priority = priority }
  end

  local walked = pcall(function()
    for id, node, metadata in query:iter_captures(trees[1]:root(), text) do
      local name = query.captures[id]
      -- A capture of the spell checker carries no color.
      if name ~= "spell" and name ~= "nospell" then
        local priority = tonumber(metadata.priority or (metadata[id] and metadata[id].priority)) or 100
        local srow, scol, erow, ecol = node:range()
        if srow == erow then
          keep(srow, scol, ecol, name, priority)
        else
          for row = srow, math.min(erow, #lines - 1) do
            local first = row == srow and scol or 0
            local last = row == erow and ecol or #(lines[row + 1] or "")
            keep(row, first, last, name, priority)
          end
        end
      end
    end
  end)
  if not walked then
    return {}
  end
  return by_line
end

---Text of one side of a diff.
---@param lines string[]
---@return string? text Nil when the side is empty, too long, or too large.
local function side_text(lines)
  if #lines == 0 or #lines > M.max_lines then
    return nil
  end
  -- Each line adds its line break.
  local bytes = 0
  for _, line in ipairs(lines) do
    bytes = bytes + #line + 1
    if bytes > M.max_bytes then
      return nil
    end
  end
  return table.concat(lines, "\n")
end

---Write the syntax highlights of a render into a buffer.
---
--- The call clears its own namespace only, so the diff highlights and the
--- comment decorations of the other namespaces stay.
---@param buf integer Buffer of the render.
---@param diff codeview.diff.File Diff that the buffer shows.
---@param map codeview.LineMap Map between the rows and the file lines.
---@param opts? { offset?: integer, side?: codeview.linemap.Side } `offset` is the width of the marker column.
---@return integer count Number of highlights.
function M.apply(buf, diff, map, opts)
  opts = opts or {}
  if not api.nvim_buf_is_valid(buf) then
    return 0
  end
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  if not config.get().diff.syntax or diff.binary or diff.limited or diff.message then
    return 0
  end
  local entry = cache[diff]
  if not entry then
    entry = { lang = M.language(diff.path) or false, sides = {} }
    cache[diff] = entry
  end
  local lang = entry.lang
  if not lang then
    return 0
  end

  local offset = opts.offset or 0
  local sides = entry.sides

  ---Captures of one side, read once per diff.
  ---@param side_name codeview.linemap.Side
  ---@return table<integer, table[]>
  local function side(side_name)
    if sides[side_name] then
      return sides[side_name]
    end
    local text = side_text(side_name == "old" and diff.old_lines or diff.new_lines)
    sides[side_name] = text and captures_of(text, lang) or {}
    return sides[side_name]
  end

  local count = 0
  local buf_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for lnum, row in ipairs(map.rows) do
    -- A row of the wanted side only. The old window of the split style holds
    -- the old side, the new window and the inline style hold the new side.
    local side_name = row.kind == "delete" and "old" or (row.new and "new" or nil)
    if row.kind == "context" and opts.side == "old" and row.old then
      side_name = "old"
    end
    local line = side_name == "old" and row.old or row.new
    if side_name and line then
      local width = #(buf_lines[lnum] or "")
      for _, capture in ipairs(side(side_name)[line - 1] or {}) do
        local col = math.min(capture.col + offset, width)
        local end_col = math.min(capture.end_col + offset, width)
        if end_col > col then
          pcall(api.nvim_buf_set_extmark, buf, M.ns, lnum - 1, col, {
            end_col = end_col,
            hl_group = capture.hl,
            priority = capture.priority,
          })
          count = count + 1
        end
      end
    end
  end
  return count
end

---Number of diff records with kept captures.
---
--- The count includes a dropped record until the next garbage collection.
---@return integer count
function M.cached()
  local count = 0
  for _ in pairs(cache) do
    count = count + 1
  end
  return count
end

---Remove the syntax highlights of a buffer.
---@param buf integer
function M.clear(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

return M
