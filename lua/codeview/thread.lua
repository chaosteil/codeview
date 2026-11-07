---@brief The write actions on the review threads of GitHub.
---
--- A thread of GitHub is the first comment of a review comment and its
--- replies, see |codeview.remote.threads()|. This module changes a thread
--- on GitHub at once, without a submit:
---
--- - Resolve a thread, or open it again, with the GraphQL mutations
---   `resolveReviewThread` and `unresolveReviewThread`.
--- - Show or hide the comments of a resolved thread in the diff.
--- - Change the text of a comment of your own, with
---   `PATCH repos/{repo}/pulls/comments/{id}`.
--- - Delete a comment of your own, with
---   `DELETE repos/{repo}/pulls/comments/{id}`.
--- - Add a reaction to a comment, or remove your own reaction, with the
---   GraphQL mutations `addReaction` and `removeReaction`.
--- - Open the first comment of a thread in the browser.
---
--- Only a reply waits for a send, see |codeview.comments.reply()|.
---
--- Each action takes the thread under the cursor. When more than one thread
--- covers the line, |vim.ui.select()| asks which one. After a success, the
--- call reads the threads of GitHub again. A failure gives one notification.

local errors = require("codeview.error")
local gh = require("codeview.gh")
local notify = require("codeview.notify")

local M = {}

---@class codeview.thread.Opts
---@field thread codeview.remote.Thread? Thread of the action. The thread under the cursor by default.
---@field view codeview.view.State? View of the cursor. The open diff by default.
---@field session codeview.Session? Session of the thread. The session of the view by default.

---Mutation that resolves a thread.
---@type string
M.resolve_mutation = [[
mutation($id: ID!) {
  resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
}
]]

---Mutation that opens a thread again.
---@type string
M.unresolve_mutation = [[
mutation($id: ID!) {
  unresolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
}
]]

---Mutation that adds a reaction.
---@type string
M.add_reaction_mutation = [[
mutation($subject: ID!, $content: ReactionContent!) {
  addReaction(input: {subjectId: $subject, content: $content}) { reaction { content } }
}
]]

---Mutation that removes a reaction.
---@type string
M.remove_reaction_mutation = [[
mutation($subject: ID!, $content: ReactionContent!) {
  removeReaction(input: {subjectId: $subject, content: $content}) { reaction { content } }
}
]]

---@class codeview.thread.Context
---@field session codeview.Session
---@field view codeview.view.State?
---@field pr codeview.pr.Info

---Session, view, and pull request of one action.
---@param opts codeview.thread.Opts
---@return codeview.thread.Context? ctx
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
  local info = require("codeview.pr").current(session)
  if not info or (info.repo or "") == "" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the session does not review a pull request")
  end
  return { session = session, view = view, pr = info }, nil
end

---Options of one call of the GitHub API.
---@param ctx codeview.thread.Context
---@param method string? HTTP method.
---@param payload table? Request body.
---@return codeview.gh.ApiOpts
local function api_opts(ctx, method, payload)
  ---@type codeview.gh.ApiOpts
  local opts = { cwd = ctx.session.repo.root, hostname = gh.host(ctx.pr.url) }
  if method then
    opts.method = method
  end
  if payload then
    opts.input = "-"
    opts.stdin = vim.json.encode(payload)
  end
  return opts
end

---Report the answer of a write, and read the threads again after a success.
---@param ctx codeview.thread.Context
---@param message string Report of a success.
---@return fun(value: any?, err: codeview.Error?)
local function after(ctx, message)
  return function(value, err)
    if value == nil then
      notify.error(require("codeview.submit").error_text(err --[[@as codeview.Error]]))
      return
    end
    notify.info(message)
    require("codeview.remote").load(ctx.session, { silent = true })
  end
end

---Run an action on the thread of the options, or on the thread under the
---cursor.
---@param opts codeview.thread.Opts
---@param prompt string Question of the picker.
---@param fn fun(ctx: codeview.thread.Context, thread: codeview.remote.Thread)
---@return boolean started False without a thread.
local function with_thread(opts, prompt, fn)
  local ctx, err = context(opts)
  if not ctx then
    notify.warn(tostring(err))
    return false
  end
  if opts.thread then
    fn(ctx, opts.thread)
    return true
  end
  local comments = require("codeview.comments")
  local threads = ctx.view and comments.threads_at_cursor(ctx.view) or {}
  if not comments.pick_thread(threads, prompt, function(thread)
    fn(ctx, thread)
  end) then
    notify.warn("no thread of GitHub on this line")
    return false
  end
  return true
end

---Short text of one comment, for a picker.
---@param comment codeview.remote.Comment
---@return string
local function label(comment)
  local who = (comment.author or "") ~= "" and ("@" .. comment.author) or "remote"
  local first = vim.split(vim.trim(comment.body or ""), "\n", { plain = true })[1] or ""
  return who .. ": " .. first
end

---Take one comment of a list.
---@param list codeview.remote.Comment[]
---@param prompt string
---@param cb fun(comment: codeview.remote.Comment)
local function pick_comment(list, prompt, cb)
  if #list == 1 then
    cb(list[1])
    return
  end
  vim.ui.select(list, { prompt = "codeview: " .. prompt, format_item = label }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

---Resolve the thread under the cursor on GitHub, or open it again.
---@param opts? codeview.thread.Opts
---@return boolean started
function M.resolve(opts)
  opts = opts or {}
  return with_thread(opts, "resolve which thread?", function(ctx, thread)
    local remote = require("codeview.remote")
    if not thread.id then
      notify.warn(remote.no_state)
      return
    end
    if thread.resolved and not thread.can_unresolve then
      notify.warn("GitHub does not let you open this thread again")
      return
    end
    if not thread.resolved and not thread.can_resolve then
      notify.warn("GitHub does not let you resolve this thread")
      return
    end
    local query = thread.resolved and M.unresolve_mutation or M.resolve_mutation
    local message = thread.resolved and "opened the thread again on GitHub" or "resolved the thread on GitHub"
    gh.graphql(query, { id = thread.id }, api_opts(ctx), after(ctx, message))
  end)
end

---Show or hide the comments of the resolved thread under the cursor.
---@param opts? codeview.thread.Opts
---@return boolean started
function M.toggle(opts)
  opts = opts or {}
  return with_thread(opts, "show or hide which thread?", function(ctx, thread)
    local remote = require("codeview.remote")
    if not thread.resolved then
      notify.info("the thread is open, so it shows every comment")
      return
    end
    remote.set_expanded(ctx.session, thread, not remote.is_expanded(ctx.session, thread))
    remote.decorate(ctx.view)
  end)
end

---Change the text of a comment of your own in the thread under the cursor.
---
--- The editor opens with the text of the comment. A save sends the new text
--- to GitHub at once. A save of an empty text changes nothing.
---@param opts? codeview.thread.Opts|{ comment?: codeview.remote.Comment }
---@return boolean started
function M.edit(opts)
  opts = opts or {}
  return with_thread(opts, "edit a comment of which thread?", function(ctx, thread)
    local remote = require("codeview.remote")
    if not thread.id then
      notify.warn(remote.no_state)
      return
    end
    local own = opts.comment and { opts.comment }
      or vim.tbl_filter(function(comment)
        return comment.can_update == true
      end, thread.comments)
    if #own == 0 then
      notify.warn("the thread holds no comment that you can edit")
      return
    end
    pick_comment(own, "edit which comment?", function(comment)
      ---@param body string
      local function save(body)
        local path = string.format("repos/%s/pulls/comments/%d", ctx.pr.repo, comment.id)
        gh.api(path, api_opts(ctx, "PATCH", { body = body }), after(ctx, "the new text went to GitHub"))
      end
      local comments = require("codeview.comments")
      require("codeview.editor").open({
        title = "Edit on GitHub: " .. ((comment.author or "") ~= "" and ("@" .. comment.author) or "remote"),
        text = comment.body,
        anchor = comments.editor_anchor(ctx.view, thread),
        on_save = save,
        on_send = save,
        on_empty = function()
          notify.warn("an empty text does not change the comment on GitHub. Delete it with the delete key")
        end,
      })
    end)
  end)
end

---Delete a comment of your own in the thread under the cursor on GitHub.
---@param opts? codeview.thread.Opts|{ comment?: codeview.remote.Comment, confirm?: boolean } `confirm = false` skips the question.
---@return boolean started
function M.delete(opts)
  opts = opts or {}
  return with_thread(opts, "delete a comment of which thread?", function(ctx, thread)
    local remote = require("codeview.remote")
    if not thread.id then
      notify.warn(remote.no_state)
      return
    end
    local own = opts.comment and { opts.comment }
      or vim.tbl_filter(function(comment)
        return comment.can_delete == true
      end, thread.comments)
    if #own == 0 then
      notify.warn("the thread holds no comment that you can delete")
      return
    end
    pick_comment(own, "delete which comment?", function(comment)
      if opts.confirm ~= false then
        local answer = vim.fn.confirm("Delete the comment on GitHub?\n" .. label(comment), "&Yes\n&No", 2, "Question")
        if answer ~= 1 then
          return
        end
      end
      local path = string.format("repos/%s/pulls/comments/%d", ctx.pr.repo, comment.id)
      local api = api_opts(ctx, "DELETE")
      api.allow_empty = true
      gh.api(path, api, after(ctx, "deleted the comment on GitHub"))
    end)
  end)
end

---Add a reaction to a comment of the thread under the cursor, or remove
---your own reaction.
---
--- When the thread holds more than one comment, |vim.ui.select()| asks for
--- the comment. A second picker asks for the reaction. Your own reactions
--- carry a `✓`, and a pick of one of them removes it.
---@param opts? codeview.thread.Opts|{ comment?: codeview.remote.Comment, content?: string }
---@return boolean started
function M.react(opts)
  opts = opts or {}
  return with_thread(opts, "react on which thread?", function(ctx, thread)
    local remote = require("codeview.remote")
    if not thread.id then
      notify.warn(remote.no_state)
      return
    end
    local list = opts.comment and { opts.comment } or thread.comments
    pick_comment(list, "react on which comment?", function(comment)
      if not comment.node_id then
        notify.warn(remote.no_state)
        return
      end
      ---@type table<string, boolean>
      local mine = {}
      for _, reaction in ipairs(comment.reactions or {}) do
        mine[reaction.content] = reaction.mine
      end

      ---@param content string
      local function send(content)
        local query = mine[content] and M.remove_reaction_mutation or M.add_reaction_mutation
        local message = mine[content] and "removed the reaction on GitHub" or "added the reaction on GitHub"
        gh.graphql(query, { subject = comment.node_id, content = content }, api_opts(ctx), after(ctx, message))
      end

      if opts.content then
        send(opts.content)
        return
      end
      vim.ui.select(remote.reaction_kinds, {
        prompt = "codeview: reaction",
        format_item = function(kind)
          return kind.emoji .. " " .. kind.content .. (mine[kind.content] and " ✓" or "")
        end,
      }, function(choice)
        if choice then
          send(choice.content)
        end
      end)
    end)
  end)
end

---Open the first comment of the thread under the cursor in the browser.
---
--- Without a thread under the cursor, the call opens the file name or the
--- address under the cursor, the same as the default `gx`.
---@param opts? codeview.thread.Opts
---@return boolean started
function M.open(opts)
  opts = opts or {}
  if opts.thread then
    return M.open_url(opts.thread.root.url)
  end
  local view = opts.view or require("codeview.view").current()
  local threads = view and require("codeview.comments").threads_at_cursor(view) or {}
  if #threads == 0 then
    local target = vim.fn.expand("<cfile>")
    if target == "" then
      notify.warn("no thread of GitHub and no address under the cursor")
      return false
    end
    return M.open_url(target)
  end
  return require("codeview.comments").pick_thread(threads, "open which thread?", function(thread)
    M.open_url(thread.root.url)
  end)
end

---Open an address with |vim.ui.open()|.
---@param url string
---@return boolean started
function M.open_url(url)
  if (url or "") == "" then
    notify.warn("the comment has no address")
    return false
  end
  local _, err = vim.ui.open(url)
  if err then
    notify.error(tostring(err))
    return false
  end
  return true
end

return M
