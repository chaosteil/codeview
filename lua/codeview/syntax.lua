---@brief Syntax highlights inside a diff.
---
--- A diff buffer holds the lines of two revisions, each with a marker column
--- in front. Neither side is the file on disk, so |vim.treesitter.start()| has
--- nothing to attach to: the buffer text is no valid program.
---
--- This module highlights the code anyway. It parses each side of the diff as
--- a whole file, which is valid text, and copies the captures of the
--- highlights query into the diff buffer. The line map of the render says
--- which buffer row holds which file line, and the marker column shifts every
--- capture by its width.
---
--- The colors of the diff itself stay in the background, so the two layers
--- read together: the background says added or removed, the foreground says
--- what the code is. See |codeview-highlights|.

local config = require("codeview.config")

local api = vim.api
local ts = vim.treesitter

local M = {}

---Namespace of the syntax highlights.
---@type integer
M.ns = api.nvim_create_namespace("codeview.syntax")

---Highest number of lines that one side may hold for a parse.
---
--- A parse of a very large file costs more than the reader gains. The line
--- limit of the diff already stops the biggest files, and this limit stops a
--- file that passes it with two long sides.
---@type integer
M.max_lines = 20000

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
  local ok = pcall(ts.language.add, lang)
  if not ok then
    return nil
  end
  return lang
end

---Captures of one text, by line.
---
--- The call parses the text as one file and returns the ranges of the
--- highlights query, from 0. A range that covers more than one line becomes
--- one range per line, because the diff buffer holds the lines apart.
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
  local trees = parser:parse()
  if not trees or not trees[1] then
    return by_line
  end
  local query = ts.query.get(lang, "highlights")
  if not query then
    return by_line
  end

  local lines = vim.split(text, "\n", { plain = true })

  ---@param line integer Line of the text, from 0.
  ---@param col integer
  ---@param end_col integer
  ---@param name string Name of the capture.
  ---@param priority integer
  local function keep(line, col, end_col, name, priority)
    if end_col <= col then
      return
    end
    by_line[line] = by_line[line] or {}
    local list = by_line[line]
    list[#list + 1] = { col = col, end_col = end_col, hl = "@" .. name, priority = priority }
  end

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

  return by_line
end

---Text of one side of a diff.
---@param lines string[]
---@return string? text Nil when the side is empty or too long.
local function side_text(lines)
  if #lines == 0 or #lines > M.max_lines then
    return nil
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
  local lang = M.language(diff.path)
  if not lang then
    return 0
  end

  local offset = opts.offset or 0
  ---@type table<codeview.linemap.Side, table<integer, table[]>>
  local sides = {}

  ---Captures of one side, read once per call.
  ---@param side codeview.linemap.Side
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
  for lnum, row in ipairs(map.rows) do
    -- A row of the wanted side only. The old window of the split style holds
    -- the old side, the new window and the inline style hold the new side.
    local side_name = row.kind == "delete" and "old" or (row.new and "new" or nil)
    if row.kind == "context" and opts.side == "old" and row.old then
      side_name = "old"
    end
    local line = side_name == "old" and row.old or row.new
    if side_name and line then
      local width = #(api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or "")
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

---Remove the syntax highlights of a buffer.
---@param buf integer
function M.clear(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

return M
