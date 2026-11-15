---@brief The selected comment box of the diff.
---
--- A comment never becomes a line of the diff buffer, so the cursor cannot
--- stand on it. This module keeps one selected box per session instead. The
--- box of the selection shows a frame and a header in the
--- `CodeViewCommentSelected` group, see |codeview.stack|.
---
--- These boxes can take the selection:
---
--- - A local comment with a box of its own.
--- - A thread of GitHub. A local reply to the thread is a part of its box.
--- - An item of pr-agent, see |codeview.agent|.
---
--- The comment keys `]c` and `[c` select the box that they stop at. The
--- selection also follows the cursor: a cursor on the rows of a box selects
--- that box, and a cursor on a row without a box clears the selection. A
--- row with more than one box keeps the box that the selection holds, or
--- takes the first box in the order of the screen.

local api = vim.api

local M = {}

---Group of the frame and the header of the selected box.
---@type string
M.hl = "CodeViewCommentSelected"

---@alias codeview.select.Kind "local"|"thread"|"agent"

---@class codeview.select.Selection
---@field kind codeview.select.Kind Kind of the box.
---@field id string Id of the comment, the key of the thread (see |codeview.remote.thread_key()|), or the id of the pr-agent item.
---@field file string Path of the file in the review.
---@field sub string? Comment of a thread that the selection holds: "remote:<id>" or "local:<id>". Nil for a box of one comment.

---@class codeview.select.Stop : codeview.select.Selection
---@field start_line integer First line of the box.
---@field end_line integer Last line of the box.
---@field side codeview.linemap.Side Side of the diff.
---@field anchored boolean? False when the current version holds no line of the box.
---@field time number Time of the first comment of the box, in seconds since the epoch.
---@field order string Id for the order of two boxes of the same time.

---Selection of each open session, by session id.
---@type table<integer, codeview.select.Selection>
local held = {}

---Sessions that have a close handler of this module.
---@type table<integer, boolean>
local watched = {}

---Key of a selection, the same as the key of its box in |codeview.stack|.
---@param selection { kind: codeview.select.Kind, id: string }
---@return string key For example "local:68a1c2f30b7a" or "thread:501".
function M.key(selection)
  return selection.kind .. ":" .. tostring(selection.id)
end

---Selection of a session.
---@param session codeview.Session?
---@return codeview.select.Selection? selection Nil when no box is selected.
function M.get(session)
  if not session then
    return nil
  end
  return held[session.id]
end

---Draw the boxes of the open view of a session again.
---@param session codeview.Session
local function redraw(session)
  local view = require("codeview.view").current()
  if view and view.session == session then
    require("codeview.stack").decorate(view)
  end
end

---Report whether two selections hold the same box and the same comment.
---@param a codeview.select.Selection?
---@param b codeview.select.Selection?
---@return boolean
local function same(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return M.key(a) == M.key(b) and a.sub == b.sub and a.file == b.file
end

---Select a box, or clear the selection.
---
--- A change draws the boxes of the view again. A selection that does not
--- change draws nothing.
---@param session codeview.Session
---@param selection codeview.select.Selection? Nil clears the selection.
---@return boolean changed
function M.set(session, selection)
  if not session or session.closed then
    return false
  end
  local copy = selection
      and { kind = selection.kind, id = tostring(selection.id), file = selection.file, sub = selection.sub }
    or nil
  if same(held[session.id], copy) then
    return false
  end
  held[session.id] = copy
  if not watched[session.id] then
    watched[session.id] = true
    session:on_close(function(closed)
      held[closed.id] = nil
      watched[closed.id] = nil
    end)
  end
  redraw(session)
  return true
end

---Clear the selection of a session.
---@param session codeview.Session
---@return boolean changed
function M.clear(session)
  return M.set(session, nil)
end

---Report whether a reply of the session goes into the box of a thread.
---@param session codeview.Session
---@param comment codeview.store.Comment
---@return boolean
local function in_thread(session, comment)
  if (comment.reply_to or "") == "" then
    return false
  end
  local thread = require("codeview.remote").thread_by_key(session, comment.reply_to)
  return thread ~= nil and thread.anchored ~= false
end

---Boxes of a session that can take the selection, by file.
---
--- A local reply to a thread of the session is no box of its own. An
--- outdated thread or item that the diff holds no line for is no box.
---@param session codeview.Session
---@return table<string, codeview.select.Stop[]> stops Boxes by file path.
function M.stops(session)
  local remote = require("codeview.remote")
  local out = {}
  ---@param stop codeview.select.Stop
  local function add(stop)
    local list = out[stop.file] or {}
    out[stop.file] = list
    list[#list + 1] = stop
  end
  for _, comment in ipairs(require("codeview.comments").list(session)) do
    if not in_thread(session, comment) then
      add({
        kind = "local",
        id = comment.id,
        file = comment.file,
        start_line = comment.start_line,
        end_line = comment.end_line,
        side = comment.side,
        time = comment.created_at or 0,
        order = tostring(comment.id),
      })
    end
  end
  for _, thread in ipairs(remote.threads(session)) do
    if thread.anchored ~= false then
      add({
        kind = "thread",
        id = remote.thread_key(thread),
        file = thread.file,
        start_line = thread.start_line,
        end_line = thread.end_line,
        side = thread.side,
        anchored = thread.anchored,
        time = thread.root.created_at or 0,
        order = tostring(thread.root.id),
      })
    end
  end
  for _, source in ipairs(remote.sources) do
    if source.name == "agent" then
      for _, item in ipairs(source.list(session)) do
        if item.anchored ~= false and item.file then
          add({
            kind = "agent",
            id = tostring(item.id),
            file = item.file,
            start_line = item.start_line,
            end_line = item.end_line,
            side = item.side or "new",
            anchored = item.anchored,
            time = item.created_at or 0,
            order = tostring(item.id),
          })
        end
      end
    end
  end
  return out
end

---First comment of a thread that the selection can hold.
---@param session codeview.Session
---@param key string Key of the thread.
---@return string? sub Nil for a collapsed thread, or for a key that the session does not hold.
function M.first_sub(session, key)
  local remote = require("codeview.remote")
  local thread = remote.thread_by_key(session, key)
  if not thread or remote.collapsed(session, thread) then
    return nil
  end
  return remote.thread_subs(session, thread)[1]
end

---Selection of one stop.
---
--- A thread starts with its first comment, while it shows its comments.
---@param session codeview.Session
---@param stop codeview.select.Stop
---@return codeview.select.Selection
function M.of_stop(session, stop)
  return {
    kind = stop.kind,
    id = stop.id,
    file = stop.file,
    sub = stop.kind == "thread" and M.first_sub(session, stop.id) or nil,
  }
end

---Boxes under the cursor of a view, in the order of the screen.
---
--- The boxes cover the line under the cursor, on the side of the cursor. A
--- comment that a collapsed section hides answers for the row of its sign.
--- The order is the last row of the box, then the time of its first
--- comment, then its id: the order of the boxes on the screen.
---@param view codeview.view.State
---@return codeview.select.Stop[] stops
function M.at_cursor(view)
  local comments = require("codeview.comments")
  local remote = require("codeview.remote")
  local session = view.session
  local out = {}
  local found, target = comments.at_cursor(view)
  for _, comment in ipairs(found) do
    if not in_thread(session, comment) then
      out[#out + 1] = {
        kind = "local",
        id = comment.id,
        file = comment.file,
        start_line = comment.start_line,
        end_line = comment.end_line,
        side = comment.side,
        time = comment.created_at or 0,
        order = tostring(comment.id),
      }
    end
  end
  if target then
    for _, thread in ipairs(remote.threads_at(session, target.file, target.side, target.start_line)) do
      out[#out + 1] = {
        kind = "thread",
        id = remote.thread_key(thread),
        file = thread.file,
        start_line = thread.start_line,
        end_line = thread.end_line,
        side = thread.side,
        time = thread.root.created_at or 0,
        order = tostring(thread.root.id),
      }
    end
    for _, entry in ipairs(remote.items_at(session, target.file, target.side, target.start_line)) do
      if entry.source.name == "agent" then
        local item = entry.item
        out[#out + 1] = {
          kind = "agent",
          id = tostring(item.id),
          file = item.file,
          start_line = item.start_line,
          end_line = item.end_line,
          side = item.side or "new",
          time = item.created_at or 0,
          order = tostring(item.id),
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.end_line ~= b.end_line then
      return a.end_line < b.end_line
    end
    if a.time ~= b.time then
      return a.time < b.time
    end
    return a.order < b.order
  end)
  return out
end

---Select the box under the cursor of a view.
---
--- The selection stays when it holds a box under the cursor. Else the first
--- box under the cursor takes it. A cursor without a box clears it.
---@param view codeview.view.State
---@return codeview.select.Selection? selection The selection after the call.
function M.follow(view)
  local session = view.session
  local current = held[session.id]
  local found = M.at_cursor(view)
  if current then
    for _, stop in ipairs(found) do
      if M.key(stop) == M.key(current) then
        return current
      end
    end
  end
  if #found == 0 then
    M.clear(session)
    return nil
  end
  M.set(session, M.of_stop(session, found[1]))
  return held[session.id]
end

---@class codeview.select.Target
---@field comment codeview.store.Comment? Local comment of a box of its own, or the selected draft reply of a thread.
---@field thread codeview.remote.Thread? Thread of GitHub of the box.
---@field remote codeview.remote.Comment? Selected comment of GitHub in the thread.
---@field item codeview.agent.Item? Item of pr-agent of the box.

---Objects that a selection names.
---@param session codeview.Session
---@param selection codeview.select.Selection
---@return codeview.select.Target? target Nil when the session does not hold the box any more.
function M.resolve(session, selection)
  local remote = require("codeview.remote")
  if selection.kind == "local" then
    local store = require("codeview.comments").store(session)
    local comment = store and store:get(selection.id)
    return comment and { comment = comment } or nil
  end
  if selection.kind == "thread" then
    local thread = remote.thread_by_key(session, selection.id)
    if not thread then
      return nil
    end
    ---@type codeview.select.Target
    local out = { thread = thread }
    local sub = selection.sub or ""
    local remote_id = sub:match("^remote:(.+)$")
    local local_id = sub:match("^local:(.+)$")
    if remote_id then
      for _, comment in ipairs(thread.comments) do
        if tostring(comment.id) == remote_id then
          out.remote = comment
        end
      end
    elseif local_id then
      local store = require("codeview.comments").store(session)
      out.comment = store and store:get(local_id) or nil
    end
    return out
  end
  local source = remote.source(selection.kind)
  for _, item in ipairs(source and source.list(session) or {}) do
    if tostring(item.id) == selection.id then
      return { item = item }
    end
  end
  return nil
end

---Selection of a session while the cursor of a view is on its box.
---
--- The comment keys act on this box. A selection that the cursor left, or
--- a box that the session does not hold any more, gives nil.
---@param view codeview.view.State?
---@return codeview.select.Selection? selection
---@return codeview.select.Target? target
function M.under_cursor(view)
  if not view then
    return nil, nil
  end
  local current = held[view.session.id]
  if not current or current.file ~= view.path then
    return nil, nil
  end
  for _, stop in ipairs(M.at_cursor(view)) do
    if M.key(stop) == M.key(current) then
      local target = M.resolve(view.session, current)
      if target then
        return current, target
      end
    end
  end
  return nil, nil
end

---Move the selection to the next or the previous comment of a thread.
---
--- The step needs a selected thread. Without one, the thread under the
--- cursor takes the selection first. A resolved thread that shows only its
--- header line shows its comments, and the step selects its first comment.
--- The step does not go past the first or the last comment of the thread.
---@param view codeview.view.State
---@param delta integer 1 for the next comment, -1 for the previous comment.
---@return string? sub Key of the selected comment after the step. Nil when the step did not move.
---@return string? message Report for the user when the step did not move.
function M.step_in_thread(view, delta)
  local remote = require("codeview.remote")
  local session = view.session
  local current = held[session.id]
  if not current or current.kind ~= "thread" then
    for _, stop in ipairs(M.at_cursor(view)) do
      if stop.kind == "thread" then
        M.set(session, M.of_stop(session, stop))
        current = held[session.id]
        break
      end
    end
  end
  if not current or current.kind ~= "thread" then
    return nil, "no thread of GitHub is selected"
  end
  local thread = remote.thread_by_key(session, current.id)
  if not thread then
    return nil, "no thread of GitHub is selected"
  end
  if remote.collapsed(session, thread) then
    remote.set_expanded(session, thread, true)
    local first = remote.thread_subs(session, thread)[1]
    M.set(session, { kind = "thread", id = current.id, file = current.file, sub = first })
    -- A change of the expanded state alone draws nothing, so the call draws.
    redraw(session)
    return first, nil
  end
  local subs = remote.thread_subs(session, thread)
  local at = 0
  for index, sub in ipairs(subs) do
    if sub == current.sub then
      at = index
    end
  end
  local target = subs[at + delta]
  if at == 0 then
    target = delta > 0 and subs[1] or subs[#subs]
  end
  if not target then
    return nil, delta > 0 and "no comment after this one in the thread" or "no comment before this one in the thread"
  end
  M.set(session, { kind = "thread", id = current.id, file = current.file, sub = target })
  return target, nil
end

---Make the selection follow the cursor in a diff buffer.
---
--- The autocmd lives in the group of the session, so it ends with the
--- session. A cursor move while the inline editor is open changes nothing,
--- because the editor window has the focus.
---@param session codeview.Session Session that owns the buffer.
---@param buf integer Buffer of a diff.
function M.attach(session, buf)
  api.nvim_create_autocmd("CursorMoved", {
    group = session:augroup(),
    buffer = buf,
    desc = "Select the codeview comment box under the cursor",
    callback = function()
      local view = require("codeview.view").current()
      if not view or view.session ~= session or session.closed then
        return
      end
      if buf ~= view.buf and buf ~= view.old_buf then
        return
      end
      M.follow(view)
    end,
  })
end

return M
