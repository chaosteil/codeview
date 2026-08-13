---@brief Inline comments in the diff.
---
--- A comment belongs to a file, a line range, a side of the diff, and a
--- commit. |codeview.store| keeps the comments of a session in one markdown
--- file. This module puts them into the diff view and runs the edit flow.
---
--- The diff buffer stays read-only through the whole flow:
---
--- - A comment never becomes a line of the buffer. The view shows it with
---   extmarks only: a sign on every covered row, and virtual lines below the
---   range, or a float on a key.
--- - The reviewer types in |codeview.editor|, a floating window with its own
---   markdown buffer. That buffer is the only modifiable buffer of the flow.
--- - The session file is the only write target. The reviewed files of the
---   repository never change.
---
--- Every anchor goes through the |codeview.LineMap| of the render. The map
--- turns a buffer row into a file line and back, for both diff styles and for
--- both sides. Virtual lines do not shift the map, because they hold no buffer
--- row.
---
--- The insert keys open the editor. `i`, `a`, `o`, and `O` do nothing in a
--- read-only buffer, so the diff buffer maps them to the one thing a reviewer
--- wants to type: a comment on the line under the cursor. In visual mode `I`,
--- `A`, and `c` comment on the selected lines, like the GitHub review UI. `i`
--- stays free in visual mode, because it is the prefix of the text objects.

local config = require("codeview.config")
local errors = require("codeview.error")
local highlight = require("codeview.highlight")
local store_mod = require("codeview.store")

local api = vim.api

local M = {}

---Namespace of the comment decorations.
---@type integer
M.ns = api.nvim_create_namespace("codeview.comments")

---@class codeview.comments.Target
---@field view codeview.view.State View that holds the lines.
---@field buf integer Buffer that shows the side of the anchor.
---@field map codeview.LineMap Map of that buffer.
---@field file string Path of the file in the review.
---@field side codeview.linemap.Side Side of the diff.
---@field start_line integer First line of the file, from 1.
---@field end_line integer Last line of the file.
---@field commit string Revision of the side.

---Store of each open session, by session id.
---@type table<integer, codeview.store.Store>
local stores = {}

---Report a message of the comment flow.
---@param message string
---@param level integer? A `vim.log.levels` value. INFO by default.
local function notify(message, level)
  vim.notify("codeview: " .. message, level or vim.log.levels.INFO)
end

--- Store ------------------------------------------------------------------------

---Load the comment file of a session.
---
--- The call runs on every session open. A range without a file gives an empty
--- store, so the first comment writes the file.
---@param session codeview.Session
---@return codeview.store.Store? store
---@return codeview.Error? err
function M.attach(session)
  if type(session) ~= "table" or type(session.id) ~= "number" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the call needs a review session")
  end
  local held = stores[session.id]
  if held then
    return held, nil
  end
  if session.closed then
    return nil, errors.new(errors.codes.INVALID_ARG, "the session is closed")
  end
  local store, err = store_mod.for_session(session)
  if not store then
    return nil, err
  end
  stores[session.id] = store
  session:on_close(function(closed)
    stores[closed.id] = nil
    -- The editor float belongs to the session. A float that stays open holds a
    -- store that the session does not own any more, and a later save writes it
    -- over the file of the next session.
    require("codeview.editor").cancel()
  end)
  return store, nil
end

---Store of a session.
---@param session? codeview.Session Session of the store. The active session by default.
---@return codeview.store.Store? store
---@return codeview.Error? err
function M.store(session)
  session = session or require("codeview.session").current()
  if not session then
    return nil, errors.new(errors.codes.INVALID_ARG, "no review session")
  end
  return M.attach(session)
end

---Comments of the session that runs.
---@param session? codeview.Session
---@return codeview.store.Comment[] comments
function M.list(session)
  local store = M.store(session)
  return store and store.comments or {}
end

--- Anchors ---------------------------------------------------------------------

---Buffer and map of one side of a view.
---@param view codeview.view.State
---@param side codeview.linemap.Side
---@return integer buf
---@return codeview.LineMap map
local function side_of(view, side)
  if view.style == "split" and side == "old" and view.old_buf and view.old_map then
    return view.old_buf, view.old_map
  end
  return view.buf, view.map
end

---Revision that one side of a view comes from.
---@param view codeview.view.State
---@param side codeview.linemap.Side
---@return string commit
local function commit_of(view, side)
  if side == "old" then
    return view.old_rev or view.rev or ""
  end
  return view.new_rev or view.rev or ""
end

---Rows of the view that the cursor covers.
---@param view codeview.view.State
---@param opts? { visual?: boolean, first?: integer, last?: integer }
---@return integer first
---@return integer last
---@return integer win Window that the rows come from.
local function rows_of(view, opts)
  opts = opts or {}
  local win = api.nvim_get_current_win()
  local windows = { view.win, view.old_win }
  if not vim.tbl_contains(windows, win) then
    win = view.win
  end
  if opts.first then
    return opts.first, opts.last or opts.first, win
  end
  if opts.visual then
    local first = vim.fn.line("v")
    local last = vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    return first, last, win
  end
  local row = 1
  if api.nvim_win_is_valid(win) then
    row = api.nvim_win_get_cursor(win)[1]
  end
  return row, row, win
end

---Anchor of a row range of the view.
---
--- The map of the window with the cursor answers first. A row that this side
--- does not hold, for example the filler row of an added line in the old
--- window, falls back to the other side.
---@param view? codeview.view.State View to read. The open file by default.
---@param opts? { visual?: boolean, first?: integer, last?: integer }
---@return codeview.comments.Target? target Nil on a range without a file line.
function M.target(view, opts)
  view = view or require("codeview.view").current()
  if not view then
    return nil
  end
  local first, last, win = rows_of(view, opts)

  local maps = { view.map }
  if view.old_map then
    maps = win == view.old_win and { view.old_map, view.map } or { view.map, view.old_map }
  end

  for _, map in ipairs(maps) do
    local anchor = map:anchor(first, last)
    if anchor then
      local buf, side_map = side_of(view, anchor.side)
      return {
        view = view,
        buf = buf,
        map = side_map,
        file = view.path,
        side = anchor.side,
        start_line = anchor.start_line,
        end_line = anchor.end_line,
        commit = commit_of(view, anchor.side),
      }
    end
  end
  return nil
end

---Row of the collapsed section that hides one line of a comment.
---
--- The call answers for a line that no row of the side is at or above, which
--- is a line of a section at the start of the file. The filler row of that
--- section is the first row that the reader sees, so the comment goes there.
---@param map codeview.LineMap
---@param comment codeview.store.Comment
---@return integer? row Nil for a map without rows.
local function hidden_row(map, comment)
  local below = map:next_row(comment.start_line, comment.side)
  for lnum = (below or map:len() + 1) - 1, 1, -1 do
    local record = map:row(lnum)
    if record and record.kind == "filler" and record.gap then
      return lnum
    end
  end
  if below then
    return below
  end
  -- The side holds no line at all, for example on a message row. The first row
  -- keeps the comment in the view.
  return map:len() > 0 and 1 or nil
end

---Rows of a buffer that hold the lines of a comment.
---@param map codeview.LineMap
---@param comment codeview.store.Comment
---@return integer[] rows Rows from 1, in buffer order.
local function comment_rows(map, comment)
  local rows, seen = {}, {}
  for line = comment.start_line, comment.end_line do
    local row = map:buf_row(line, comment.side)
    if row and not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end
  if #rows == 0 then
    -- A collapsed section hides the lines. The sign goes to the row above it,
    -- so that the comment stays visible. A section at the start of the file has
    -- no row above it, so the sign goes on the row of the section.
    local row = map:nearest_row(comment.start_line, comment.side) or hidden_row(map, comment)
    if row then
      rows[1] = row
    end
  end
  table.sort(rows)
  return rows
end

---Comments that a collapsed section hides, with their sign on one row.
---
--- The sign of a hidden comment sits on a row that holds another line, or no
--- line at all. That row answers for the comment, so that edit and delete
--- reach a comment which the render does not show at its own line.
---@param view codeview.view.State
---@param store codeview.store.Store
---@param row integer Buffer row of the cursor, from 1.
---@param buf integer Buffer under the cursor.
---@return codeview.store.Comment[] comments
local function marked_at(view, store, row, buf)
  local out = {}
  for _, comment in ipairs(store:for_file(view.path)) do
    local side_buf, map = side_of(view, comment.side)
    if side_buf == buf then
      for _, lnum in ipairs(comment_rows(map, comment)) do
        if lnum == row then
          out[#out + 1] = comment
          break
        end
      end
    end
  end
  return out
end

---Comments under the cursor.
---@param view? codeview.view.State View to read. The open file by default.
---@return codeview.store.Comment[] comments
---@return codeview.comments.Target? target Position of the cursor.
function M.at_cursor(view)
  view = view or require("codeview.view").current()
  if not view then
    return {}, nil
  end
  local target = M.target(view)
  local store = M.store(view.session)
  if not store then
    return {}, target
  end
  if target then
    local found = store:at(target.file, target.side, target.start_line)
    if #found > 0 then
      return found, target
    end
  end

  local row, _, win = rows_of(view)
  local buf = view.buf
  if api.nvim_win_is_valid(win) then
    buf = api.nvim_win_get_buf(win)
  end
  return marked_at(view, store, row, buf), target
end

--- Decoration ------------------------------------------------------------------

---Text of a line range, without a prefix.
---@param first integer
---@param last integer
---@return string
local function lines_text(first, last)
  if first == last then
    return tostring(first)
  end
  return string.format("%d-%d", first, last)
end

---Text of the line range of a comment.
---@param comment codeview.store.Comment
---@return string
local function range_text(comment)
  return "L" .. lines_text(comment.start_line, comment.end_line)
end

---Header line of a comment.
---@param comment codeview.store.Comment
---@return string
local function header_text(comment)
  local text = string.format("comment %s (%s)", range_text(comment), comment.side)
  if comment.state == "resolved" then
    text = text .. " · resolved"
  end
  return text
end

---Sign text of a commented row.
---@return string? text Nil when the option holds no sign.
local function sign_text()
  local text = config.get().comments.sign or ""
  while vim.fn.strdisplaywidth(text) > 2 do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  if text == "" then
    return nil
  end
  return text
end

---Virtual lines of one comment.
---@param comment codeview.store.Comment
---@return string[][][] lines Chunks of every virtual line.
local function virt_lines(comment)
  local prefix = (config.get().comments.sign or "") .. " "
  local out = { { { prefix .. header_text(comment), "CodeViewCommentHeader" } } }
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

---Buffer of the other side of a side-by-side view.
---@param view codeview.view.State
---@param side codeview.linemap.Side Side that holds the comment.
---@return integer? buf Nil outside the split style.
local function mirror_of(view, side)
  if view.style ~= "split" or not view.old_buf then
    return nil
  end
  local buf = side == "old" and view.buf or view.old_buf
  if type(buf) == "number" and api.nvim_buf_is_valid(buf) then
    return buf
  end
  return nil
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
local function place(view, comment, display)
  local buf, map = side_of(view, comment.side)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  local rows = comment_rows(map, comment)
  if #rows == 0 then
    return false
  end
  local sign = sign_text()
  for _, row in ipairs(rows) do
    local opts = {
      sign_text = sign,
      sign_hl_group = "CodeViewCommentSign",
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
    local other = opts.virt_lines and mirror_of(view, comment.side) or nil
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
--- The call only writes extmarks. The text and the line count of the diff
--- buffers do not change, so the line map stays correct.
---@param view? codeview.view.State View to decorate. The open file by default.
---@return integer count Number of comments that the view shows.
---@return integer hidden Number of comments that the render holds no row for.
function M.decorate(view)
  view = view or require("codeview.view").current()
  if not view or not api.nvim_buf_is_valid(view.buf) then
    return 0, 0
  end

  highlight.setup()
  api.nvim_buf_clear_namespace(view.buf, M.ns, 0, -1)
  if view.old_buf and api.nvim_buf_is_valid(view.old_buf) then
    api.nvim_buf_clear_namespace(view.old_buf, M.ns, 0, -1)
  end

  local store = M.store(view.session)
  if not store then
    return 0, 0
  end

  local display = config.get().comments.display
  local count, hidden = 0, 0
  for _, comment in ipairs(store:for_file(view.path)) do
    if place(view, comment, display) then
      count = count + 1
    else
      hidden = hidden + 1
    end
  end
  return count, hidden
end

---Draw the comments of the file that is open again.
---@return integer count
---@return integer hidden Number of comments that the render holds no row for.
function M.refresh()
  return M.decorate()
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

--- Edit flow -------------------------------------------------------------------

---Write the store and report a failure.
---@param store codeview.store.Store
---@return boolean ok
local function persist(store)
  local ok, err = store:save()
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

---Title of the editor window for one anchor.
---@param target codeview.comments.Target
---@param action string
---@return string
local function title_of(target, action)
  return string.format(
    "%s %s:%s (%s)",
    action,
    target.file,
    lines_text(target.start_line, target.end_line),
    target.side
  )
end

---Open the editor for a new comment.
---
--- In normal mode the comment covers the line under the cursor. In visual mode
--- it covers the selected lines. The diff buffer stays read-only: the editor
--- holds the only modifiable buffer.
---@param opts? { visual?: boolean, first?: integer, last?: integer, view?: codeview.view.State }
---@return boolean opened False when the cursor is not on a line of the file.
function M.add(opts)
  opts = opts or {}
  local view = opts.view or require("codeview.view").current()
  if not view then
    notify("no diff view", vim.log.levels.WARN)
    return false
  end
  local store, err = M.store(view.session)
  if not store then
    notify(tostring(err), vim.log.levels.ERROR)
    return false
  end
  local target = M.target(view, opts)
  if not target then
    notify("this row holds no line of the file", vim.log.levels.WARN)
    return false
  end

  require("codeview.editor").open({
    title = title_of(target, "Comment on"),
    on_save = function(body)
      -- The store comes again from the session, because a session that closes
      -- while the editor is open drops its store.
      local live, live_err = M.store(view.session)
      if not live then
        notify(tostring(live_err), vim.log.levels.ERROR)
        return
      end
      local comment, add_err = live:add({
        file = target.file,
        start_line = target.start_line,
        end_line = target.end_line,
        side = target.side,
        commit = target.commit,
        body = body,
      })
      if not comment then
        notify(tostring(add_err), vim.log.levels.ERROR)
        return
      end
      persist(live)
      M.refresh()
    end,
  })
  return true
end

---Open the editor for the comment under the cursor.
---@param opts? { id?: string, view?: codeview.view.State }
---@return boolean opened False when no comment covers the cursor.
function M.edit(opts)
  opts = opts or {}
  local view = opts.view or require("codeview.view").current()
  if not view then
    notify("no diff view", vim.log.levels.WARN)
    return false
  end
  local store = M.store(view.session)
  if not store then
    return false
  end

  local comment
  if opts.id then
    comment = store:get(opts.id)
  else
    comment = M.at_cursor(view)[1]
  end
  if not comment then
    notify("no comment on this line", vim.log.levels.WARN)
    return false
  end

  require("codeview.editor").open({
    title = string.format(
      "Edit %s:%s (%s)",
      comment.file,
      lines_text(comment.start_line, comment.end_line),
      comment.side
    ),
    text = comment.body,
    on_save = function(body)
      -- The store comes again from the session, because a session that closes
      -- while the editor is open drops its store.
      local live, live_err = M.store(view.session)
      if not live then
        notify(tostring(live_err), vim.log.levels.ERROR)
        return
      end
      local _, err = live:update(comment.id, { body = body })
      if err then
        notify(tostring(err), vim.log.levels.ERROR)
        return
      end
      persist(live)
      M.refresh()
    end,
  })
  return true
end

---Delete the comment under the cursor.
---@param opts? { id?: string, confirm?: boolean, view?: codeview.view.State } `confirm = false` skips the question.
---@return boolean removed False when no comment went away.
function M.remove(opts)
  opts = opts or {}
  local view = opts.view or require("codeview.view").current()
  if not view then
    notify("no diff view", vim.log.levels.WARN)
    return false
  end
  local store = M.store(view.session)
  if not store then
    return false
  end

  local comment
  if opts.id then
    comment = store:get(opts.id)
  else
    comment = M.at_cursor(view)[1]
  end
  if not comment then
    notify("no comment on this line", vim.log.levels.WARN)
    return false
  end

  if opts.confirm ~= false then
    local answer = vim.fn.confirm(
      string.format("Delete the comment on %s:%s?", comment.file, lines_text(comment.start_line, comment.end_line)),
      "&Yes\n&No",
      2,
      "Question"
    )
    if answer ~= 1 then
      return false
    end
  end

  store:remove(comment.id)
  persist(store)
  M.refresh()
  return true
end

---Show the comment under the cursor in a float.
---
--- The float closes on the next cursor move. It is the display for the
--- `comments.display = "float"` option, and it also works next to the virtual
--- lines.
---@param opts? { view?: codeview.view.State }
---@return integer? buf Buffer of the float.
---@return integer? win Window of the float.
function M.show(opts)
  opts = opts or {}
  local view = opts.view or require("codeview.view").current()
  if not view then
    return nil, nil
  end
  local found = M.at_cursor(view)
  if #found == 0 then
    notify("no comment on this line", vim.log.levels.INFO)
    return nil, nil
  end

  local lines = {}
  for index, comment in ipairs(found) do
    if index > 1 then
      lines[#lines + 1] = "---"
    end
    lines[#lines + 1] = "### " .. header_text(comment)
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(comment.body, "\n", { plain = true }))
  end

  local cfg = config.get().comments
  local width = math.max(math.min(cfg.width, vim.o.columns - 4), 20)
  local height = math.max(math.min(#lines, cfg.height), 1)

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = cfg.border,
    focusable = true,
  })
  vim.wo[win][0].wrap = true

  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave", "InsertEnter" }, {
    once = true,
    desc = "Close the codeview comment float",
    callback = function()
      if api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, true)
      end
    end,
  })
  return buf, win
end

--- Keymaps ---------------------------------------------------------------------

---Set the comment keymaps of a diff buffer.
---
--- The maps are buffer-local, so they never reach a normal file buffer. Every
--- key comes from the `keymaps` option, and `false` disables it.
---
--- The insert keys are dead keys in a read-only buffer, so they open the
--- editor. Visual `i` stays free, because `vi(` must still select a text
--- object.
---@param session codeview.Session Session that owns the buffer.
---@param buf integer Buffer of a diff.
function M.set_keymaps(session, buf)
  local keys = config.get().keymaps

  ---@param mode string|string[]
  ---@param value string|string[]|false|nil
  ---@param action fun()
  ---@param desc string
  local function add(mode, value, action, desc)
    for _, lhs in ipairs(config.keys(value)) do
      vim.keymap.set(mode, lhs, action, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = "codeview: " .. desc,
      })
    end
  end

  ---View of the session, while the session runs.
  ---@return codeview.view.State?
  local function view_of()
    if not session:is_active() then
      return nil
    end
    local view = require("codeview.view").current()
    return view and view.session == session and view or nil
  end

  ---Leave visual mode and comment on the lines of the selection.
  local function visual()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    M.add({ first = first, last = last, view = view_of() })
  end

  local function normal()
    M.add({ view = view_of() })
  end

  add("n", keys.comment, normal, "comment on the line")
  add("n", keys.comment_insert, normal, "comment on the line")
  add("x", keys.comment, visual, "comment on the selected lines")
  add("x", keys.comment_visual, visual, "comment on the selected lines")
  add("n", keys.edit_comment, function()
    M.edit({ view = view_of() })
  end, "edit the comment")
  add("n", keys.delete_comment, function()
    M.remove({ view = view_of() })
  end, "delete the comment")
  add("n", keys.show_comment, function()
    M.show({ view = view_of() })
  end, "show the comment")
end

return M
