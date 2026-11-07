---@brief Extmarks of the comments in the diff.
---
--- A comment never becomes a line of the diff buffer. It shows with extmarks
--- only: a sign on every covered row, and a box of virtual lines below the
--- range. |codeview.anchor| gives the rows. This module collects the rows,
--- the sign, and the box of each local comment of a view, and
--- |codeview.stack| draws them. The text and the line map of the diff stay as
--- they were.

local anchor = require("codeview.anchor")
local box = require("codeview.box")
local config = require("codeview.config")
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
---
--- The comment shows as a box: the header in the top border, and the body
--- between the side borders. |codeview.box| builds it.
---@param comment codeview.store.Comment
---@param width integer Width of the box, in screen cells.
---@return table[][] lines Chunks of every virtual line.
local function virt_lines(comment, width)
  local header = M.header_text(comment)
  if (comment.reply_to or "") ~= "" then
    header = header .. " · reply"
  end
  return box.lines({
    header = header,
    header_hl = comment.state == "resolved" and "CodeViewCommentResolved" or "CodeViewCommentHeader",
    body = comment.body,
    body_hl = "CodeViewComment",
    box_hl = "CodeViewCommentBox",
    border_hl = "CodeViewCommentBorder",
    border = config.get().comments.border,
    width = width,
  })
end

---Collect the local comments of the file that a view shows.
---
--- Each comment that the render holds a row for gives one entry for
--- |codeview.stack|. The comment that the editor has open gives no box,
--- because the editor shows the same body under the row.
---
--- A reply to a GitHub thread that the view shows gives no box either. It is
--- a section of the box of the thread, see
--- |codeview.remote.thread_sections()|. A reply to a thread that the session
--- does not hold shows as a box of its own, with ` · reply` in the header.
---@param view codeview.view.State View to decorate.
---@param store codeview.store.Store? Comments of the session. Nil gives no entry.
---@param display "virtual"|"float"
---@return codeview.stack.Entry[] entries
---@return integer count Number of comments that the view shows.
---@return integer hidden Number of comments that the render holds no row for.
function M.collect(view, store, display)
  local out, count, hidden = {}, 0, 0
  if not store then
    return out, 0, 0
  end
  local remote = require("codeview.remote")
  ---Keys of the threads that the view shows a box for.
  ---@type table<string, boolean>
  local shown = {}
  for _, thread in ipairs(remote.threads(view.session)) do
    if thread.file == view.path and thread.anchored ~= false and #anchor.rows(view, thread) > 0 then
      shown[remote.thread_key(thread)] = true
    end
  end
  for _, comment in ipairs(store:for_file(view.path)) do
    local buf, map = anchor.side_of(view, comment.side)
    local rows = api.nvim_buf_is_valid(buf) and anchor.comment_rows(map, comment) or {}
    if #rows == 0 then
      hidden = hidden + 1
    else
      count = count + 1
      local boxed = display == "virtual" and M.editing ~= comment.id and not shown[comment.reply_to or ""]
      out[#out + 1] = {
        buf = buf,
        rows = rows,
        side = comment.side,
        ns = M.ns,
        priority = 200,
        sign = M.sign(comment),
        sign_hl = M.sign_group(comment),
        box = boxed and function(width)
          return virt_lines(comment, width)
        end or nil,
        time = comment.created_at or 0,
        id = comment.id,
      }
    end
  end
  return out, count, hidden
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
