---@brief Extmarks of the comments in the diff.
---
--- A comment never becomes a line of the diff buffer. This module shows it
--- with extmarks only: a sign on every covered row, and virtual lines below
--- the range. |codeview.anchor| gives the rows. The call only writes
--- extmarks, so the text and the line map of the diff stay as they were.

local anchor = require("codeview.anchor")
local config = require("codeview.config")
local highlight = require("codeview.highlight")
local store_mod = require("codeview.store")

local api = vim.api

local M = {}

---Namespace of the comment decorations.
---@type integer
M.ns = api.nvim_create_namespace("codeview.comments")

---Comment that the editor has open, while it edits an existing comment.
---
--- The diff keeps the sign of the comment, but drops its virtual lines. The
--- editor shows the same body right under that row, and one body is enough.
---@type string?
M.editing = nil

---Text of a line range, without a prefix.
---@param first integer
---@param last integer
---@return string
function M.lines_text(first, last)
  if first == last then
    return tostring(first)
  end
  return string.format("%d-%d", first, last)
end

---Text of the line range of a comment.
---@param comment codeview.store.Comment
---@return string
local function range_text(comment)
  return "L" .. M.lines_text(comment.start_line, comment.end_line)
end

---Header line of a comment.
---@param comment codeview.store.Comment
---@return string
function M.header_text(comment)
  local text = string.format("comment %s (%s)", range_text(comment), comment.side)
  if comment.state == "resolved" then
    text = text .. " · resolved"
  end
  if store_mod.is_synced(comment) then
    text = text .. " · synced"
  end
  return text
end

---Sign text of one comment.
---
--- A resolved comment takes its own sign, so that the diff and the comment
--- overview both show the state without a word.
---@param comment codeview.store.Comment
---@return string text Empty when the option holds no sign.
function M.sign(comment)
  local cfg = config.get().comments
  local text = (comment.state == "resolved" and cfg.resolved_sign or cfg.sign) or ""
  while vim.fn.strdisplaywidth(text) > 2 do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text
end

---Highlight group of the sign of one comment.
---@param comment codeview.store.Comment
---@return string group
function M.sign_group(comment)
  return comment.state == "resolved" and "CodeViewCommentResolved" or "CodeViewCommentSign"
end

---Virtual lines of one comment.
---@param comment codeview.store.Comment
---@return string[][][] lines Chunks of every virtual line.
local function virt_lines(comment)
  local prefix = M.sign(comment) .. " "
  local header = comment.state == "resolved" and "CodeViewCommentResolved" or "CodeViewCommentHeader"
  local out = { { { prefix .. M.header_text(comment), header } } }
  for _, line in ipairs(vim.split(comment.body, "\n", { plain = true })) do
    out[#out + 1] = { { prefix .. line, "CodeViewComment" } }
  end
  return out
end

---Virtual lines that hold no text.
---
--- The other side of a side-by-side view takes them, so that a comment adds
--- the same number of screen rows to both windows.
---@param count integer Number of lines.
---@return string[][][] lines
local function blank_lines(count)
  local out = {}
  for index = 1, count do
    out[index] = { { "" } }
  end
  return out
end

---Place the marks of one comment.
---
--- In the side-by-side style the other side takes virtual lines of the same
--- number, without text. Both windows then grow by the same number of screen
--- rows, and 'scrollbind' keeps the two sides on the same row.
---@param view codeview.view.State
---@param comment codeview.store.Comment
---@param display "virtual"|"float"
---@return boolean placed False when the render hides the lines of the comment.
function M.place(view, comment, display)
  local buf, map = anchor.side_of(view, comment.side)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  if M.editing == comment.id then
    -- The editor holds the body of this comment, one row under the sign. The
    -- virtual lines then print the same text twice.
    display = "float"
  end
  local rows = anchor.comment_rows(map, comment)
  if #rows == 0 then
    return false
  end
  local sign = M.sign(comment)
  for _, row in ipairs(rows) do
    local opts = {
      sign_text = sign ~= "" and sign or nil,
      sign_hl_group = M.sign_group(comment),
      priority = 200,
    }
    if display == "virtual" and row == rows[#rows] then
      opts.virt_lines = virt_lines(comment)
      opts.virt_lines_above = false
    end
    local ok = pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, opts)
    if not ok then
      -- A sign of more than two cells is not valid. Keep the virtual lines.
      opts.sign_text, opts.sign_hl_group = nil, nil
      pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, opts)
    end
    local other = opts.virt_lines and anchor.mirror(view, comment.side) or nil
    if other then
      pcall(api.nvim_buf_set_extmark, other, M.ns, row - 1, 0, {
        virt_lines = blank_lines(#opts.virt_lines),
        virt_lines_above = false,
        priority = 200,
      })
    end
  end
  return true
end

---Draw the comments of the file that a view shows.
---
--- The call removes the old marks of the view first. The text and the line
--- count of the diff buffers do not change, so the line map stays correct.
---@param view codeview.view.State View to decorate.
---@param store codeview.store.Store? Comments of the session. Nil removes the marks only.
---@return integer count Number of comments that the view shows.
---@return integer hidden Number of comments that the render holds no row for.
function M.decorate(view, store)
  if not api.nvim_buf_is_valid(view.buf) then
    return 0, 0
  end

  highlight.setup()
  api.nvim_buf_clear_namespace(view.buf, M.ns, 0, -1)
  if view.old_buf and api.nvim_buf_is_valid(view.old_buf) then
    api.nvim_buf_clear_namespace(view.old_buf, M.ns, 0, -1)
  end

  if not store then
    return 0, 0
  end

  local display = config.get().comments.display
  local count, hidden = 0, 0
  for _, comment in ipairs(store:for_file(view.path)) do
    if M.place(view, comment, display) then
      count = count + 1
    else
      hidden = hidden + 1
    end
  end
  return count, hidden
end

---Extmarks of the comments in one buffer.
---@param buf integer Buffer of a diff.
---@return table[] marks Result of `nvim_buf_get_extmarks()`, with details.
function M.marks(buf)
  if not api.nvim_buf_is_valid(buf) then
    return {}
  end
  return api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, { details = true })
end

return M
