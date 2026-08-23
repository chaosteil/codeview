---@brief The internal events of codeview.
---
--- A part of the plugin that changes a comment sends an event. The parts that
--- show comments subscribe to it and draw themselves again. The sender knows
--- no receiver. A delete in the comment overview clears the extmarks of the
--- diff view. A comment in the diff view reaches the overview.
---
--- Every event also runs a |User| autocmd with the name of
--- |codeview.events.autocmds|, so that a configuration outside the plugin can
--- watch the same events: >lua
---
---     vim.api.nvim_create_autocmd("User", {
---       pattern = "CodeViewCommentAdded",
---       callback = function(event)
---         vim.print(event.data.file)
---       end,
---     })
--- <
--- The handlers run before the autocmd. An error in one handler does not stop
--- the other handlers.

local api = vim.api

local M = {}

---@alias codeview.events.Name
---| "comment_added" # A new comment went into the store.
---| "comment_changed" # The body or the state of a comment changed.
---| "comment_deleted" # A comment left the store.
---| "review_submitted" # A submit sent comments to GitHub and marked them as synced.
---| "remote_loaded" # The review comments of a pull request arrived.

---Name of the |User| autocmd of each event.
---@type table<codeview.events.Name, string>
M.autocmds = {
  comment_added = "CodeViewCommentAdded",
  comment_changed = "CodeViewCommentChanged",
  comment_deleted = "CodeViewCommentDeleted",
  review_submitted = "CodeViewReviewSubmitted",
  remote_loaded = "CodeViewRemoteLoaded",
}

---Every event that changes the comments of a session.
---@type codeview.events.Name[]
M.comment = { "comment_added", "comment_changed", "comment_deleted", "review_submitted" }

---Every event of the remote comments of a pull request.
---@type codeview.events.Name[]
M.remote = { "remote_loaded" }

---@class codeview.events.Data
---@field id string? Id of the comment.
---@field file string? Path of the file of the comment.
---@field session integer? Id of the session that holds the comment.
---@field state codeview.store.State? State of the comment after the change.
---@field count integer? Number of comments that a submit sent.
---@field review string? Id of the review on GitHub.

---Handlers of each event, by subscription number.
---@type table<string, table<integer, fun(data: codeview.events.Data, name: string)>>
local handlers = {}

---Number of subscriptions that this Neovim made.
---@type integer
local counter = 0

---Call a function on one event, or on a list of events.
---@param names codeview.events.Name|codeview.events.Name[] Event to watch.
---@param fn fun(data: codeview.events.Data, name: string) Handler of the event.
---@return integer id Number for |codeview.events.off()|.
function M.on(names, fn)
  vim.validate("fn", fn, "callable")
  counter = counter + 1
  for _, name in ipairs(type(names) == "table" and names or { names }) do
    handlers[name] = handlers[name] or {}
    handlers[name][counter] = fn
  end
  return counter
end

---Drop a subscription.
---@param id integer Number from |codeview.events.on()|.
---@return boolean removed False when the subscription is gone already.
function M.off(id)
  local removed = false
  for _, list in pairs(handlers) do
    if list[id] then
      list[id] = nil
      removed = true
    end
  end
  return removed
end

---Send one event.
---
--- The handlers run in the order of their subscription. The |User| autocmd
--- runs after them.
---@param name codeview.events.Name Event to send.
---@param data? codeview.events.Data Payload of the event.
---@return integer count Number of handlers that ran.
function M.emit(name, data)
  data = data or {}
  local list = handlers[name] or {}
  local ids = vim.tbl_keys(list)
  table.sort(ids)
  local count = 0
  for _, id in ipairs(ids) do
    local fn = list[id]
    if fn then
      count = count + 1
      local ok, err = pcall(fn, data, name)
      if not ok then
        vim.notify("codeview: an event handler failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  local pattern = M.autocmds[name]
  if pattern then
    pcall(api.nvim_exec_autocmds, "User", { pattern = pattern, data = data })
  end
  return count
end

---Drop every subscription.
function M.clear()
  handlers = {}
end

return M
