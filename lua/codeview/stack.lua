---@brief The boxes of the comments in the diff, one extmark per row.
---
--- Many comments can end on the same row: local comments, the threads of
--- GitHub, and the items of pr-agent. Each of them shows as a box of virtual
--- lines under the row. Neovim does not keep the order of the creation of
--- two extmarks on one row when they also hold a sign. The boxes of one row
--- then show in a broken order.
---
--- This module is the one place that draws the boxes. It puts the virtual
--- lines of every box of one row into one extmark, in the namespace
--- |codeview.stack.ns|. The order of the boxes is the time of their first
--- comment, oldest first, then the id. The signs stay in the namespace of
--- each kind of comment.
---
--- The space of the inline comment editor goes into the same extmark, see
--- |codeview.stack.reserve()|. The editor window sits on that space. The
--- space of an edit takes the place of the box of the comment. The space of
--- a new comment comes after the boxes of the row. The other boxes keep
--- their order and stay in sight.
---
--- In the side-by-side style, the other side takes one extmark per row with
--- blank virtual lines of the same number. Both windows then grow by the
--- same number of screen rows, and 'scrollbind' keeps the two sides on the
--- same row.

local anchor = require("codeview.anchor")
local box = require("codeview.box")
local config = require("codeview.config")
local highlight = require("codeview.highlight")

local api = vim.api

local M = {}

---Namespace of the boxes.
---@type integer
M.ns = api.nvim_create_namespace("codeview.boxes")

---Priority that each sign of a comment adds to the priority of its entry.
---
--- The column shows one sign per row. An extmark of another plugin has the
--- priority 4096 by default, for example the sign of a heading of a markdown
--- render plugin in a commit document. The sign of a comment therefore goes
--- above that default, so the row keeps the mark of its comment.
---@type integer
M.sign_raise = 4096

---@class codeview.stack.Entry
---@field buf integer Buffer that holds the rows.
---@field rows integer[] Rows of the anchor, from 1, in buffer order.
---@field side codeview.linemap.Side Side of the anchor.
---@field ns integer Namespace of the signs.
---@field priority integer Priority of the signs among the signs of codeview. |codeview.stack.sign_raise| comes on top.
---@field sign string Sign text. Empty for no sign.
---@field sign_hl string Group of the sign.
---@field box (fun(width: integer): table[][])? Virtual lines of the box. Nil when the entry draws no box.
---@field time number Time of the first comment of the box, in seconds since the epoch.
---@field id string Id for the order of two boxes of the same time.

---@class codeview.stack.Result
---@field comments { count: integer, hidden: integer } Local comments that the view shows, and the ones it holds no row for.
---@field remote { count: integer, hidden: integer } Items of every source of |codeview.remote.sources|.

---@class codeview.stack.Space
---@field buf integer Buffer that holds the row.
---@field row integer Row from 1. The space goes under it.
---@field height integer Number of virtual lines.
---@field id string? Id of the local comment that the editor edits. The space takes the place of its box.
---@field place fun(offset: integer)? Handler of the position. It gets the number of virtual lines above the space.

---Space that the inline comment editor holds under a row.
---
--- The editor window sits on these virtual lines, so it covers no row of
--- the diff. The space goes into the extmark of the row, the same as a box.
--- The order of the boxes and the space then stays fixed, and the other
--- side of the split takes blank lines for the space too.
---@type codeview.stack.Space?
local space = nil

---Extmark of the space in a buffer that no view shows.
---@type { buf: integer, id: integer }?
local loose = nil

---Virtual lines of a space, in the color of a comment box.
---@param height integer
---@return string[][][] lines
local function space_lines(height)
  local out = {}
  for index = 1, height do
    out[index] = { { "", "CodeViewCommentBox" } }
  end
  return out
end

---Virtual lines that hold no text.
---@param count integer
---@return string[][][] lines
local function blank_lines(count)
  local out = {}
  for index = 1, count do
    out[index] = { { "" } }
  end
  return out
end

---Report whether the box of one entry comes before the box of another.
---@param a codeview.stack.Entry
---@param b codeview.stack.Entry
---@return boolean
local function earlier(a, b)
  if a.time ~= b.time then
    return a.time < b.time
  end
  return tostring(a.id) < tostring(b.id)
end

---Place the signs of one entry.
---@param entry codeview.stack.Entry
local function place_signs(entry)
  for _, row in ipairs(entry.rows) do
    local opts = {
      sign_text = entry.sign ~= "" and entry.sign or nil,
      sign_hl_group = entry.sign_hl,
      priority = M.sign_raise + entry.priority,
    }
    local ok = pcall(api.nvim_buf_set_extmark, entry.buf, entry.ns, row - 1, 0, opts)
    if not ok then
      -- A sign of more than two cells is not valid. Keep the mark of the row.
      opts.sign_text, opts.sign_hl_group = nil, nil
      pcall(api.nvim_buf_set_extmark, entry.buf, entry.ns, row - 1, 0, opts)
    end
  end
end

---Draw the comments of the file that a view shows.
---
--- The call removes the old marks of the view first: the boxes, and the
--- signs of the local comments and of every source. The text and the line
--- count of the diff buffers do not change, so the line map stays correct.
---@param view? codeview.view.State View to decorate. The open file by default.
---@return codeview.stack.Result result
function M.decorate(view)
  view = view or require("codeview.view").current()
  ---@type codeview.stack.Result
  local result = { comments = { count = 0, hidden = 0 }, remote = { count = 0, hidden = 0 } }
  if not view or not api.nvim_buf_is_valid(view.buf) then
    return result
  end

  highlight.setup()
  local marks = require("codeview.marks")
  local remote = require("codeview.remote")

  local bufs = { view.buf }
  if view.old_buf and api.nvim_buf_is_valid(view.old_buf) then
    bufs[#bufs + 1] = view.old_buf
  end
  local namespaces = { M.ns, marks.ns }
  for _, source in ipairs(remote.sources) do
    namespaces[#namespaces + 1] = source.ns
  end
  for _, buf in ipairs(bufs) do
    for _, ns in ipairs(namespaces) do
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end

  local display = config.get().comments.display
  ---@type codeview.stack.Entry[]
  local entries = {}
  -- The sources come first. They find the lines of an outdated thread, and
  -- a local reply to a thread draws in the box of the thread.
  for _, source in ipairs(remote.sources) do
    local items, item_count, item_hidden = remote.collect(view, source, display)
    vim.list_extend(entries, items)
    result.remote.count = result.remote.count + item_count
    result.remote.hidden = result.remote.hidden + item_hidden
  end
  local store = require("codeview.comments").store(view.session)
  local found, count, hidden = marks.collect(view, store, display)
  vim.list_extend(entries, found)
  result.comments = { count = count, hidden = hidden }

  -- The boxes of one row go into one list, so they share one extmark.
  ---@type table<string, codeview.stack.Entry[]>
  local rows = {}
  ---@type string[]
  local keys = {}
  ---@param entry codeview.stack.Entry
  local function add_box(entry)
    local key = entry.buf .. ":" .. entry.rows[#entry.rows]
    if not rows[key] then
      rows[key] = {}
      keys[#keys + 1] = key
    end
    local list = rows[key]
    list[#list + 1] = entry
  end
  for _, entry in ipairs(entries) do
    place_signs(entry)
    if entry.box then
      add_box(entry)
    end
  end
  ---@type codeview.stack.Entry?
  local slot = nil
  if space and (space.buf == view.buf or space.buf == view.old_buf) then
    -- The space of an edit takes the place of the box of the comment: the
    -- time and the id of that comment. The box itself is gone while the
    -- editor is open, see |codeview.marks.editing()|. A new comment is the
    -- newest, so its space comes after the other boxes of the row, where
    -- its box shows after the save.
    local time, id = math.huge, ""
    for _, entry in ipairs(entries) do
      if space.id and entry.id == space.id then
        time, id = entry.time, entry.id
        break
      end
    end
    local height = space.height
    slot = {
      buf = space.buf,
      rows = { space.row },
      side = space.buf == view.old_buf and "old" or "new",
      ns = M.ns,
      priority = 200,
      sign = "",
      sign_hl = "",
      box = function()
        return space_lines(height)
      end,
      time = time,
      id = id,
    }
    add_box(slot)
  end

  ---@type table<integer, integer>
  local widths = {}
  for _, key in ipairs(keys) do
    local list = rows[key]
    table.sort(list, earlier)
    local first = list[1]
    local buf, row = first.buf, first.rows[#first.rows]
    widths[buf] = widths[buf] or box.width_for(buf, view.win)
    local lines = {}
    for _, entry in ipairs(list) do
      if entry == slot and space and space.place then
        space.place(#lines)
      end
      vim.list_extend(lines, entry.box(widths[buf]))
    end
    pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, {
      virt_lines = lines,
      virt_lines_above = false,
      priority = 200,
    })
    local other = anchor.mirror(view, first.side)
    if other then
      pcall(api.nvim_buf_set_extmark, other, M.ns, row - 1, 0, {
        virt_lines = blank_lines(#lines),
        virt_lines_above = false,
        priority = 200,
      })
    end
  end

  if #entries > 0 and display == "virtual" then
    box.refit(view, function()
      M.decorate(view)
    end)
  end
  return result
end

---View that shows a buffer.
---@param buf integer
---@return codeview.view.State? view Nil when the open view does not show the buffer.
local function view_of(buf)
  local view = require("codeview.view").current()
  if view and (view.buf == buf or view.old_buf == buf) then
    return view
  end
  return nil
end

---Draw the space again in one buffer.
---
--- A buffer of a view takes the space in the extmark of its row, so the
--- call draws the whole view again. Another buffer, for example a test
--- buffer, takes one extmark of its own.
---@param buf integer
local function draw_space(buf)
  if loose then
    if api.nvim_buf_is_valid(loose.buf) then
      pcall(api.nvim_buf_del_extmark, loose.buf, M.ns, loose.id)
    end
    loose = nil
  end
  local view = view_of(buf)
  if view then
    M.decorate(view)
    return
  end
  if space and space.buf == buf and api.nvim_buf_is_valid(buf) then
    local ok, id = pcall(api.nvim_buf_set_extmark, buf, M.ns, space.row - 1, 0, {
      virt_lines = space_lines(space.height),
    })
    if ok then
      loose = { buf = buf, id = id }
    end
    if space.place then
      space.place(0)
    end
  end
end

---Hold space under a row for the inline comment editor.
---
--- The space replaces the space that an earlier call holds.
---@param spec codeview.stack.Space
function M.reserve(spec)
  local old = space
  space = spec
  if old and old.buf ~= spec.buf then
    draw_space(old.buf)
  end
  draw_space(spec.buf)
end

---Give the space of a call to |codeview.stack.reserve()| back.
---@param spec codeview.stack.Space Value that the call took. Space of another call stays.
function M.release(spec)
  if space ~= spec then
    return
  end
  space = nil
  draw_space(spec.buf)
end

---Extmarks of the boxes in one buffer.
---@param buf integer Buffer of a diff.
---@return table[] marks Result of `nvim_buf_get_extmarks()`, with details.
function M.marks(buf)
  if not api.nvim_buf_is_valid(buf) then
    return {}
  end
  return api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, { details = true })
end

return M
