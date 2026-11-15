---@brief The context menu of the selected comment.
---
--- The menu key opens a list of the actions that apply to the selected box,
--- see |codeview.select|. |vim.ui.select()| shows the list, so a picker
--- plugin of the user styles it. The menu shows only the actions that
--- apply:
---
--- - A local comment: edit, delete, resolve or reopen, send it to the pull
---   request now, comment on the same lines again, and show it in a float.
--- - A draft reply: edit, delete, send it now, and show it.
--- - A thread of GitHub: reply as a draft, reply and send at once, resolve
---   or reopen, show or hide a resolved thread, and the actions of the
---   selected comment of the thread. These are an edit and a delete of a
---   comment of your own, a reaction, and the open in the browser.
--- - An item of pr-agent: adopt it, and show it.
---
--- GitHub decides who can reply, resolve, and change a comment. The menu
--- reads these rights from the thread state.

local notify = require("codeview.notify")

local M = {}

---@class codeview.menu.Entry
---@field label string Text of the entry.
---@field run fun() Action of the entry.

---@class codeview.menu.Opts
---@field session codeview.Session? Session of the comment. The session of the view by default.
---@field view codeview.view.State? Diff view of the comment. The open view by default. Nil in the overview.
---@field selection codeview.select.Selection? Box of the menu. The selection of the session by default.
---@field select (fun(items: any[], opts: table, on_choice: fun(item: any?, index: integer?)))? Selector. |vim.ui.select()| by default.

---Comment of a thread that a key of |codeview.remote.thread_subs()| names.
---@param thread codeview.remote.Thread
---@param sub string?
---@return codeview.remote.Comment? comment
local function remote_of(thread, sub)
  local id = sub and sub:match("^remote:(.+)$")
  if not id then
    return nil
  end
  for _, comment in ipairs(thread.comments) do
    if tostring(comment.id) == id then
      return comment
    end
  end
  return nil
end

---pr-agent item of a session with one id.
---@param session codeview.Session
---@param id string
---@return codeview.agent.Item? item
local function agent_item(session, id)
  local source = require("codeview.remote").source("agent")
  for _, item in ipairs(source and source.list(session) or {}) do
    if tostring(item.id) == id then
      return item
    end
  end
  return nil
end

---Entries of one local comment: a comment of its own box, or a draft reply.
---@param ctx { session: codeview.Session, view: codeview.view.State? }
---@param comment codeview.store.Comment
---@param out codeview.menu.Entry[]
local function local_entries(ctx, comment, out)
  local comments = require("codeview.comments")
  local submit = require("codeview.submit")
  local store_mod = require("codeview.store")
  local session, view = ctx.session, ctx.view
  local reply = (comment.reply_to or "") ~= ""
  local remote_copy = submit.is_remote_copy(session, comment)
  local noun = reply and "the reply" or "the comment"

  out[#out + 1] = {
    label = remote_copy and ("Edit " .. noun .. " (also on GitHub)") or ("Edit " .. noun),
    run = function()
      comments.edit({ id = comment.id, session = session, view = view })
    end,
  }
  out[#out + 1] = {
    label = remote_copy and ("Delete " .. noun .. " (also on GitHub)") or ("Delete " .. noun),
    run = function()
      comments.remove({ id = comment.id, session = session, view = view })
    end,
  }
  if not reply then
    out[#out + 1] = {
      label = comment.state == "resolved" and "Reopen the comment" or "Resolve the comment",
      run = function()
        comments.set_state({ id = comment.id, session = session, view = view })
      end,
    }
  end
  if require("codeview.pr").current(session) and not store_mod.is_synced(comment) then
    out[#out + 1] = {
      label = reply and "Send the reply now" or "Send the comment to the pull request now",
      run = function()
        submit.send({ session = session, id = comment.id })
      end,
    }
  end
  if not reply and view and view.path == comment.file then
    out[#out + 1] = {
      label = "Add another comment on these lines",
      run = function()
        comments.add_on(view, comment)
      end,
    }
  end
end

---Entries of a thread of GitHub and of its selected comment.
---@param ctx { session: codeview.Session, view: codeview.view.State? }
---@param thread codeview.remote.Thread
---@param sub string? Selected comment of the thread.
---@param out codeview.menu.Entry[]
local function thread_entries(ctx, thread, sub, out)
  local comments = require("codeview.comments")
  local thread_mod = require("codeview.thread")
  local session, view = ctx.session, ctx.view
  local opts = { thread = thread, session = session, view = view }

  if thread.can_reply then
    out[#out + 1] = {
      label = "Reply (draft)",
      run = function()
        comments.reply(opts)
      end,
    }
    out[#out + 1] = {
      label = "Reply and send now",
      run = function()
        comments.reply(vim.tbl_extend("force", opts, { send = true }))
      end,
    }
  end
  if thread.resolved and thread.can_unresolve then
    out[#out + 1] = {
      label = "Reopen the thread",
      run = function()
        thread_mod.resolve(opts)
      end,
    }
  elseif not thread.resolved and thread.can_resolve then
    out[#out + 1] = {
      label = "Resolve the thread",
      run = function()
        thread_mod.resolve(opts)
      end,
    }
  end
  if thread.resolved then
    local shown = require("codeview.remote").is_expanded(session, thread)
    out[#out + 1] = {
      label = shown and "Hide the comments of the thread" or "Show the comments of the thread",
      run = function()
        thread_mod.toggle(opts)
      end,
    }
  end

  local reply_id = sub and sub:match("^local:(.+)$")
  if reply_id then
    local store = comments.store(session)
    local reply = store and store:get(reply_id)
    if reply then
      local_entries(ctx, reply, out)
    end
    return
  end

  local comment = remote_of(thread, sub)
  if comment then
    local with = vim.tbl_extend("force", opts, { comment = comment })
    if comment.can_update then
      out[#out + 1] = {
        label = "Edit this comment on GitHub",
        run = function()
          thread_mod.edit(with)
        end,
      }
    end
    if comment.can_delete then
      out[#out + 1] = {
        label = "Delete this comment on GitHub",
        run = function()
          thread_mod.delete(with)
        end,
      }
    end
    if comment.node_id then
      out[#out + 1] = {
        label = "Add or remove a reaction",
        run = function()
          thread_mod.react(with)
        end,
      }
    end
  end
  local url = (comment or thread.root).url
  if (url or "") ~= "" then
    out[#out + 1] = {
      label = "Open in the browser",
      run = function()
        thread_mod.open_url(url)
      end,
    }
  end
end

---Title and entries of the menu of one box.
---
--- The call gives no entry for a box that the session does not hold any
--- more, for example a deleted comment.
---@param session codeview.Session
---@param view codeview.view.State?
---@param selection codeview.select.Selection
---@return string title
---@return codeview.menu.Entry[] entries
function M.entries(session, view, selection)
  local marks = require("codeview.marks")
  local remote = require("codeview.remote")
  local ctx = { session = session, view = view }
  ---@type codeview.menu.Entry[]
  local out = {}
  local title = ""
  if selection.kind == "local" then
    local store = require("codeview.comments").store(session)
    local comment = store and store:get(selection.id)
    if comment then
      title = marks.header_text(comment)
      local_entries(ctx, comment, out)
    end
  elseif selection.kind == "thread" then
    local thread = remote.thread_by_key(session, selection.id)
    if thread then
      title = remote.thread_header(thread)
      thread_entries(ctx, thread, selection.sub, out)
    end
  elseif selection.kind == "agent" then
    local item = agent_item(session, selection.id)
    if item then
      title = require("codeview.agent").header(item)
      out[#out + 1] = {
        label = "Adopt as a comment",
        run = function()
          require("codeview.agent").adopt({ item = item, session = session, view = view })
        end,
      }
    end
  end
  if #out > 0 and view and view.path == selection.file then
    out[#out + 1] = {
      label = "Show in a float",
      run = function()
        require("codeview.comments").show({ view = view, only = selection })
      end,
    }
  end
  return title, out
end

---Show the menu of one box.
---@param session codeview.Session
---@param view codeview.view.State?
---@param selection codeview.select.Selection
---@param picker fun(items: any[], opts: table, on_choice: fun(item: any?, index: integer?))
---@return boolean shown False when no action applies.
local function show(session, view, selection, picker)
  local title, entries = M.entries(session, view, selection)
  if #entries == 0 then
    notify.warn("no action applies to this comment")
    return false
  end
  picker(entries, {
    prompt = "codeview: " .. title,
    format_item = function(entry)
      return entry.label
    end,
  }, function(choice)
    if choice then
      choice.run()
    end
  end)
  return true
end

---Open the menu of the selected comment.
---
--- In the diff view the menu takes the selected box while the cursor is on
--- it. Else it takes the boxes under the cursor: one box opens its menu at
--- once, and for more than one box a first picker asks which one.
---@param opts? codeview.menu.Opts
---@return boolean shown False without a comment.
function M.open(opts)
  opts = opts or {}
  local select_mod = require("codeview.select")
  local view = opts.view
  if view == nil and opts.selection == nil then
    view = require("codeview.view").current()
  end
  local session = opts.session or (view and view.session) or require("codeview.session").current()
  if not session or not session:is_active() then
    notify.warn("no review session")
    return false
  end
  if view and view.session ~= session then
    view = nil
  end
  local picker = opts.select or vim.ui.select
  if opts.selection then
    return show(session, view, opts.selection, picker)
  end
  if not view then
    notify.warn("no diff view")
    return false
  end

  local found = select_mod.at_cursor(view)
  local current = select_mod.get(session)
  if current then
    for _, stop in ipairs(found) do
      if select_mod.key(stop) == select_mod.key(current) then
        return show(session, view, current, picker)
      end
    end
  end
  if #found == 0 then
    notify.warn("no comment on this line")
    return false
  end
  if #found == 1 then
    local selection = select_mod.of_stop(session, found[1])
    select_mod.set(session, selection)
    return show(session, view, selection, picker)
  end
  picker(found, {
    prompt = "codeview: which comment?",
    format_item = function(stop)
      local title = M.entries(session, view, select_mod.of_stop(session, stop))
      return title ~= "" and title or (stop.kind .. " L" .. stop.start_line)
    end,
  }, function(choice)
    if choice then
      local selection = select_mod.of_stop(session, choice)
      select_mod.set(session, selection)
      show(session, view, selection, picker)
    end
  end)
  return true
end

return M
