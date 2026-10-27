---@brief Inline comments in the diff.
---
--- A comment belongs to a file, a line range, a side of the diff, and a
--- commit. |codeview.store| keeps the comments of a session in one markdown
--- file. This module holds the store of each session, runs the edit flow,
--- and sets the keymaps. |codeview.anchor| maps rows to anchors, and
--- |codeview.marks| draws the extmarks. The functions of those two modules
--- are also available here, for the callers of this module.
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
--- The insert keys open the editor. `i`, `a`, `o`, and `O` do nothing in a
--- read-only buffer. The diff buffer maps them to the one thing a reviewer
--- wants to type: a comment on the line under the cursor. In visual mode `I`,
--- `A`, and `c` comment on the selected lines, like the GitHub review UI. `i`
--- stays free in visual mode, because it is the prefix of the text objects.

local anchor_mod = require("codeview.anchor")
local config = require("codeview.config")
local errors = require("codeview.error")
local events = require("codeview.events")
local marks = require("codeview.marks")
local notify = require("codeview.notify")
local store_mod = require("codeview.store")

local api = vim.api

local M = {}

---Namespace of the comment decorations. See |codeview.marks|.
---@type integer
M.ns = marks.ns

---Store of each open session, by session id.
---@type table<integer, codeview.store.Store>
local stores = {}

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
    -- store that the session does not own any more. A later save then writes
    -- it over the file of the next session.
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

--- Anchors and marks ----------------------------------------------------------

---Anchor of a row range of the view. See |codeview.anchor.target()|.
---@param view? codeview.view.State View to read. The open file by default.
---@param opts? { visual?: boolean, first?: integer, last?: integer }
---@return codeview.comments.Target? target Nil on a range without a file line.
function M.target(view, opts)
  return anchor_mod.target(view, opts)
end

---Rows of a view that hold the lines of one anchor. See |codeview.anchor.rows()|.
---@param view codeview.view.State View that shows the file.
---@param anchor { start_line: integer, end_line: integer, side: codeview.linemap.Side } Lines of the anchor.
---@return integer[] rows Rows from 1, in buffer order. Empty when the render hides the lines.
---@return integer buf Buffer of the side of the anchor.
---@return codeview.LineMap map Map of that buffer.
function M.rows(view, anchor)
  return anchor_mod.rows(view, anchor)
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
  return anchor_mod.at_cursor(view, (M.store(view.session)))
end

---Buffer of the other side of a side-by-side view. See |codeview.anchor.mirror()|.
---@param view codeview.view.State
---@param side codeview.linemap.Side Side that holds the comment.
---@return integer? buf Nil outside the split style.
function M.mirror(view, side)
  return anchor_mod.mirror(view, side)
end

---Sign text of one comment. See |codeview.marks.sign()|.
---@param comment codeview.store.Comment
---@return string text Empty when the option holds no sign.
function M.sign(comment)
  return marks.sign(comment)
end

---Highlight group of the sign of one comment.
---@param comment codeview.store.Comment
---@return string group
function M.sign_group(comment)
  return marks.sign_group(comment)
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
  return marks.decorate(view, (M.store(view.session)))
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
  return marks.marks(buf)
end

--- Edit flow -------------------------------------------------------------------

---Write the store and report a failure.
---@param store codeview.store.Store
---@return boolean ok
local function persist(store)
  local ok, err = store:save()
  if not ok then
    notify.error(tostring(err))
  end
  return ok
end

---@class codeview.comments.Context
---@field session codeview.Session Session that owns the comments.
---@field store codeview.store.Store Comments of the session.
---@field view codeview.view.State? Diff view of the session, while a file is open.

---Session, store, and view of one comment action.
---
--- The comment overview acts without a diff view, so the session answers when
--- no file is open.
---@param opts { view?: codeview.view.State, session?: codeview.Session }
---@return codeview.comments.Context? context
---@return codeview.Error? err
local function context(opts)
  local view = opts.view or require("codeview.view").current()
  local session = opts.session or (view and view.session) or require("codeview.session").current()
  if not session or not session:is_active() then
    return nil, errors.new(errors.codes.INVALID_ARG, "no review session")
  end
  if view and view.session ~= session then
    view = nil
  end
  local store, err = M.store(session)
  if not store then
    return nil, err
  end
  return { session = session, store = store, view = view }, nil
end

---Send the event of a change of one comment.
---@param name codeview.events.Name
---@param session codeview.Session
---@param comment codeview.store.Comment
local function announce(name, session, comment)
  events.emit(name, {
    id = comment.id,
    file = comment.file,
    session = session.id,
    state = comment.state,
  })
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
    marks.lines_text(target.start_line, target.end_line),
    target.side
  )
end

---Anchor of the inline editor for one target.
---
--- The editor opens under the last marked row, in the window that the reviewer
--- marked it in. A window that closed in the meantime gives no anchor, and the
--- editor opens the float instead.
---@param target codeview.comments.Target
---@return codeview.editor.Anchor? anchor
local function anchor_of(target)
  if not target.win or not api.nvim_win_is_valid(target.win) then
    return nil
  end
  return { win = target.win, buf = api.nvim_win_get_buf(target.win), row = target.row }
end

---Handler of the send key of the editor.
---
--- A local review has no pull request, so its editor gets no handler and the
--- key reports that. In a pull request session the handler saves the
--- comment with `save` and posts it with |codeview.submit.send()|.
---@param session codeview.Session
---@param save fun(body: string): codeview.store.Comment? Writes the comment and gives it back.
---@return fun(body: string)? handler
local function send_handler(session, save)
  if not require("codeview.pr").current(session) then
    return nil
  end
  return function(body)
    local comment = save(body)
    if comment then
      require("codeview.submit").send({ session = session, id = comment.id })
    end
  end
end

---Open the editor for a new comment.
---
--- In normal mode the comment covers the line under the cursor. In visual mode
--- it covers the selected lines. The diff buffer stays read-only: the editor
--- holds the only modifiable buffer.
---@param opts? { visual?: boolean, first?: integer, last?: integer, view?: codeview.view.State }
---@return boolean opened False when the cursor is not on a line of the file, or when the reviewer keeps the open editor.
function M.add(opts)
  opts = opts or {}
  local view = opts.view or require("codeview.view").current()
  if not view then
    notify.warn("no diff view")
    return false
  end
  local store, err = M.store(view.session)
  if not store then
    notify.error(tostring(err))
    return false
  end
  local target = M.target(view, opts)
  if not target then
    notify.warn("this row holds no line of the file")
    return false
  end

  ---Write the new comment into the store.
  ---@param body string
  ---@return codeview.store.Comment? comment Nil after an error.
  local function save(body)
    -- The store comes again from the session, because a session that closes
    -- while the editor is open drops its store.
    local live, live_err = M.store(view.session)
    if not live then
      notify.error(tostring(live_err))
      return nil
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
      notify.error(tostring(add_err))
      return nil
    end
    persist(live)
    announce("comment_added", view.session, comment)
    return comment
  end

  local buf = require("codeview.editor").open({
    title = title_of(target, "Comment on"),
    anchor = anchor_of(target),
    on_save = save,
    on_send = send_handler(view.session, save),
  })
  return buf ~= nil
end

---Comment of one action.
---
--- `opts.id` names a comment of the store. Without an id the comment comes
--- from the cursor, which needs an open diff view.
---@param ctx codeview.comments.Context
---@param opts { id?: string }
---@return codeview.store.Comment? comment
local function pick(ctx, opts)
  if opts.id then
    -- The parentheses drop the second return value of `get`.
    return (ctx.store:get(opts.id))
  end
  if not ctx.view then
    return nil
  end
  return M.at_cursor(ctx.view)[1]
end

---Message for a cursor that no comment of the store covers.
---
--- A comment of a pull request sits at the same anchor, but it lives on
--- GitHub. The message says so, instead of "no comment on this line".
---@param ctx codeview.comments.Context
---@return string
local function nothing_here(ctx)
  if ctx.view then
    local target = M.target(ctx.view)
    local remote = target and require("codeview.remote").at(ctx.session, target.file, target.side, target.start_line)
    if remote and #remote > 0 then
      return "the review comments of GitHub are read-only"
    end
  end
  return "no comment on this line"
end

---Anchor of the inline editor for a comment that a view shows.
---
--- The editor opens under the last row of the comment. A comment that the
--- render hides, or an action from the overview without a diff view, gives no
--- anchor. A view of another file gives no anchor too. The editor then opens
--- the float instead.
---@param view codeview.view.State?
---@param comment codeview.store.Comment
---@return codeview.editor.Anchor? anchor
local function comment_anchor(view, comment)
  if not view or view.path ~= comment.file then
    return nil
  end
  local rows, buf = M.rows(view, comment)
  local row = rows[#rows]
  if not row then
    return nil
  end
  local win = buf == view.buf and view.win or view.old_win
  if not win or not api.nvim_win_is_valid(win) then
    return nil
  end
  return { win = win, buf = buf, row = row }
end

---Open the editor for the comment under the cursor.
---@param opts? { id?: string, view?: codeview.view.State, session?: codeview.Session }
---@return boolean opened False when no comment covers the cursor, or when the reviewer keeps the open editor.
function M.edit(opts)
  opts = opts or {}
  local ctx, ctx_err = context(opts)
  if not ctx then
    notify.warn(tostring(ctx_err))
    return false
  end
  local session = ctx.session

  local comment = pick(ctx, opts)
  if not comment then
    notify.warn(nothing_here(ctx))
    return false
  end

  local anchor = comment_anchor(ctx.view, comment)

  ---Show the body of the comment in the diff again.
  ---
  --- A refresh during the edit replaces the view, so the call draws the view
  --- that is open now.
  local function release()
    if marks.editing == comment.id then
      marks.editing = nil
      M.decorate()
    end
  end

  ---Write the new body of the comment into the store.
  ---@param body string
  ---@return codeview.store.Comment? comment Nil after an error.
  local function save(body)
    release()
    -- The store comes again from the session, because a session that closes
    -- while the editor is open drops its store.
    local live, live_err = M.store(session)
    if not live then
      notify.error(tostring(live_err))
      return nil
    end
    local changed, err = live:update(comment.id, { body = body })
    if not changed then
      notify.error(tostring(err))
      return nil
    end
    persist(live)
    announce("comment_changed", session, changed)
    return changed
  end

  local buf = require("codeview.editor").open({
    title = string.format(
      "Edit %s:%s (%s)",
      comment.file,
      marks.lines_text(comment.start_line, comment.end_line),
      comment.side
    ),
    text = comment.body,
    anchor = anchor,
    id = comment.id,
    on_save = save,
    on_send = send_handler(session, save),
    on_cancel = release,
  })
  if not buf then
    return false
  end

  -- The editor sits under the row of the comment, where the virtual lines of
  -- the body are. Drop them while the editor holds the same text.
  if anchor and require("codeview.editor").current() then
    marks.editing = comment.id
    M.decorate(ctx.view)
  end
  return true
end

---Edit the comment under the cursor, or write a new one.
---
--- The insert keys land here. A line that already holds a comment opens that
--- comment, because a reviewer who presses `i` on their own note wants to
--- change it. A line without a comment starts a new one. The `comment_add`
--- keys always start a new comment, so a second comment on the same line stays
--- one keypress away.
---@param opts? { visual?: boolean, first?: integer, last?: integer, view?: codeview.view.State }
---@return boolean opened
function M.edit_or_add(opts)
  opts = opts or {}
  local view = opts.view or require("codeview.view").current()
  if view and not opts.first and not opts.last then
    local found = M.at_cursor(view)
    if #found > 0 then
      return M.edit({ view = view })
    end
  end
  return M.add(opts)
end

---Delete the comment under the cursor.
---
--- An open editor of the same comment closes without a question, and a
--- message reports the close.
---@param opts? { id?: string, confirm?: boolean, view?: codeview.view.State, session?: codeview.Session } `confirm = false` skips the question.
---@return boolean removed False when no comment went away.
function M.remove(opts)
  opts = opts or {}
  local ctx, ctx_err = context(opts)
  if not ctx then
    notify.warn(tostring(ctx_err))
    return false
  end
  local store = ctx.store

  local comment = pick(ctx, opts)
  if not comment then
    notify.warn(nothing_here(ctx))
    return false
  end

  if opts.confirm ~= false then
    local answer = vim.fn.confirm(
      string.format(
        "Delete the comment on %s:%s?",
        comment.file,
        marks.lines_text(comment.start_line, comment.end_line)
      ),
      "&Yes\n&No",
      2,
      "Question"
    )
    if answer ~= 1 then
      return false
    end
  end

  -- An editor of the comment can save nothing after the delete. It closes
  -- without a question, because the reviewer asked for the delete.
  local editor = require("codeview.editor")
  local open = editor.current()
  local closed = open ~= nil and open.id == comment.id and editor.cancel()

  store:remove(comment.id)
  persist(store)
  announce("comment_deleted", ctx.session, comment)
  if closed then
    notify.warn("the open editor of this comment closed")
  end
  return true
end

---Set the state of the comment under the cursor.
---
--- The state lives in the `state` field of the comment, so it survives a
--- restart with the rest of the comment.
---@param opts? { id?: string, state?: codeview.store.State, view?: codeview.view.State, session?: codeview.Session } Without a state the call takes the other state.
---@return codeview.store.Comment? comment The comment after the change.
function M.set_state(opts)
  opts = opts or {}
  local ctx, ctx_err = context(opts)
  if not ctx then
    notify.warn(tostring(ctx_err))
    return nil
  end

  local comment = pick(ctx, opts)
  if not comment then
    notify.warn(nothing_here(ctx))
    return nil
  end

  local state = opts.state
  if state ~= "open" and state ~= "resolved" then
    state = comment.state == "resolved" and "open" or "resolved"
  end
  local changed, err = ctx.store:update(comment.id, { state = state })
  if not changed then
    notify.error(tostring(err))
    return nil
  end
  persist(ctx.store)
  announce("comment_changed", ctx.session, changed)
  return changed
end

---Show the comment under the cursor in a float.
---
--- The float closes on the next cursor move. It is the display for the
--- `comments.display = "float"` option, and it also works next to the virtual
--- lines. The float holds the local comments of the line first, and the
--- read-only comments of a pull request after them.
---@param opts? { view?: codeview.view.State }
---@return integer? buf Buffer of the float.
---@return integer? win Window of the float.
function M.show(opts)
  opts = opts or {}
  local view = opts.view or require("codeview.view").current()
  if not view then
    return nil, nil
  end
  local remote_mod = require("codeview.remote")
  local found, target = M.at_cursor(view)
  local remote = target and remote_mod.at(view.session, target.file, target.side, target.start_line) or {}
  if #found == 0 and #remote == 0 then
    notify.info("no comment on this line")
    return nil, nil
  end

  local lines = {}
  for index, comment in ipairs(found) do
    if index > 1 then
      lines[#lines + 1] = "---"
    end
    lines[#lines + 1] = "### " .. marks.header_text(comment)
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(comment.body, "\n", { plain = true }))
  end
  for _, comment in ipairs(remote) do
    if #lines > 0 then
      lines[#lines + 1] = "---"
    end
    lines[#lines + 1] = "### " .. remote_mod.header(comment)
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
    group = api.nvim_create_augroup("codeview.comments.float", { clear = false }),
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

  ---Edit the comment of the line, or write the first one.
  local function edit_or_add()
    M.edit_or_add({ view = view_of() })
  end

  add("n", keys.comment, edit_or_add, "edit or write the comment of the line")
  add("n", keys.comment_insert, edit_or_add, "edit or write the comment of the line")
  add("n", keys.comment_add, normal, "write another comment on the line")
  add("x", keys.comment, visual, "comment on the selected lines")
  add("x", keys.comment_visual, visual, "comment on the selected lines")
  add("n", keys.edit_comment, function()
    M.edit({ view = view_of() })
  end, "edit the comment")
  add("n", keys.delete_comment, function()
    M.remove({ view = view_of() })
  end, "delete the comment")
  add("n", keys.resolve_comment, function()
    M.set_state({ view = view_of() })
  end, "resolve the comment")
  add("n", keys.show_comment, function()
    M.show({ view = view_of() })
  end, "show the comment")
  add("n", keys.toggle_overview, function()
    require("codeview.overview").toggle({ session = session, focus = true })
  end, "open or close the comment overview")
end

--- Events ---------------------------------------------------------------------

-- The decorations of the diff follow the store. A change from the comment
-- overview then reaches the extmarks of the diff view, without a call from the
-- overview into this module.
events.on(events.comment, function()
  M.refresh()
end)

return M
