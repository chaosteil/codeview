---@brief Send the comments of a session to a GitHub pull request.
---
--- `:Codeview submit` posts every comment of the session that no submit sent
--- yet. The plugin sends the comments as one review, with
--- `POST /pulls/<n>/reviews`. The pull request then shows one entry with all
--- the lines, not one entry per comment.
---
--- `:Codeview submit` is explicit. The call shows a summary first: the number
--- of comments, the event, and every comment that the diff of the pull
--- request does not hold. Nothing reaches GitHub before the user confirms
--- that summary. No autocommand and no save posts by itself.
---
--- The send key of the comment editor is the one key that posts. It saves
--- the comment of the editor and posts that one comment, with
--- |codeview.submit.send()|. A comment on a line goes to
--- `POST /pulls/<n>/comments`. A comment on the pull request document goes
--- to `POST /issues/<n>/comments`, so it reads in the conversation of the
--- pull request and not on a line of the code.
---
--- A comment on the pull request document is an overall comment. A submit of
--- the session takes every such comment as the text of the review, so the
--- summary of the review and the notes on the lines go out together.
---
--- The position of a comment comes from |codeview.position|, on a line map of
--- the diff. The map runs with the diff settings of git, because GitHub
--- accepts only the lines of the diff of git. It answers whether the pull
--- request diff holds a line of a side:
---
--- - `side` is LEFT for the old side and RIGHT for the new side.
--- - `line` is the last line of the comment.
--- - `start_line` and `start_side` come with a comment over more than one line.
---
--- A comment that maps to no line of the diff stays local. The call collects
--- those comments and reports them, so that the reviewer can move them or
--- export them.
---
--- The sync state lives in the session file. |codeview.store| holds
--- `synced_at`, `review_id`, and `remote_id` per comment, and a comment gets
--- them only after the API confirms the post. A failed post writes nothing, so
--- a second submit sends the same comments again and loses nothing.
---
--- A comment that went out and then got a new text holds a `remote_id`. The
--- next submit changes the text of that comment on GitHub with a PATCH call,
--- and posts no new comment.
---
--- A post that the time limit killed can still reach GitHub. Before a review
--- post, the call lists the reviews of the pull request. A review of the user
--- that is logged in, on the same commit, with the same text and the same
--- comments, is the review of an earlier try. The call then marks the
--- comments as sent and posts nothing.
---
--- One session runs one submit or one send at a time. A second call during
--- the first one reports an error, so no comment goes out twice.

local errors = require("codeview.error")
local events = require("codeview.events")
local gh = require("codeview.gh")
local notify = require("codeview.notify")
local mapper = require("codeview.position")
local session_mod = require("codeview.session")
local store_mod = require("codeview.store")
local util = require("codeview.util")

local api = vim.api

local before = util.comment_before
local done = util.done

local M = {}

---Event of the review API for each name that the user writes.
---@type table<string, string>
M.events = {
  comment = "COMMENT",
  approve = "APPROVE",
  ["request-changes"] = "REQUEST_CHANGES",
}

---Names of the events, in the order of the picker.
---@type string[]
M.event_names = { "comment", "approve", "request-changes" }

---Events that GitHub rejects without a review body.
---@type table<string, boolean>
M.needs_body = { comment = true, ["request-changes"] = true }

---Body of a review that needs one and got none.
---@type string
M.fallback_body = "Review from codeview."

---Number of unchanged lines that the diff of GitHub keeps around a hunk.
---
--- The value of |codeview.position.context|.
---@type integer
M.context = mapper.context

---Settings of the diff that the position mapping runs on.
---
--- The value of |codeview.position.diff_opts|.
---@type codeview.diff.Opts
M.diff_opts = mapper.diff_opts

---@alias codeview.submit.Position codeview.position.Position
---@alias codeview.submit.Block codeview.position.Block
---@alias codeview.submit.Coverage codeview.position.Coverage
---@alias codeview.submit.FileDiff codeview.position.FileDiff

---@class codeview.submit.Entry
---@field comment codeview.store.Comment Comment of the session.
---@field position codeview.submit.Position Fields of the review API.

---@class codeview.submit.Skipped
---@field comment codeview.store.Comment Comment that stays local.
---@field reason string One line that says why the comment does not map.

---@class codeview.submit.Plan
---@field session codeview.Session Session that holds the comments.
---@field store codeview.store.Store Comment store of the session.
---@field pr codeview.pr.Info Pull request that receives the review.
---@field dir string Directory that gh runs in.
---@field event string Name of the event: comment, approve, or request-changes.
---@field body string Text of the review itself.
---@field entries codeview.submit.Entry[] Comments that the post carries.
---@field notes codeview.store.Comment[] Comments on the pull request document. They go into the text of the review.
---@field edits codeview.store.Comment[] Comments that went out and got a new text. The submit changes their text on GitHub.
---@field skipped codeview.submit.Skipped[] Comments that stay local.
---@field synced integer Number of comments that an earlier submit sent.
---@field total integer Number of comments of the session.

---@class codeview.submit.Opts
---@field session codeview.Session? Session to submit. The session that runs by default.
---@field event string? Event of the review. The picker asks without it.
---@field body string? Text of the review. The prompt asks without it.
---@field dir string? Directory that gh runs in. The repository root by default.
---@field notify boolean? False silences the reports of the call.

---@class codeview.submit.Result
---@field posted integer Number of comments that GitHub took.
---@field skipped integer Number of comments that stay local.
---@field cancelled boolean True when the call posted nothing.
---@field review table? Review object of the answer of GitHub.
---@field url string Address of the review. Empty when GitHub sent none.
---@field existing boolean? True when GitHub held the review already, so the call posted nothing.

---Sessions with a submit or a send that runs, by session id.
---@type table<integer, boolean>
local busy = {}

---Text of an error, with every line that the server sent.
---
--- |codeview.Error| shows one line. GitHub answers a bad position with more
--- than one line. Every line names a comment that it did not take, so the
--- report keeps them all.
---@param err codeview.Error
---@return string text
function M.error_text(err)
  local text = tostring(err)
  for _, line in ipairs(vim.split(vim.trim(err.stderr or ""), "\n", { plain = true })) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not text:find(trimmed, 1, true) then
      text = text .. "\n  " .. trimmed
    end
  end
  return text
end

---Run one step per entry of a list, one after the other.
---
--- Without a callback the steps run in the sync form. The step calls its own
--- callback when it is finished.
---@param items any[]
---@param step fun(item: any, cb?: fun())
---@param cb? fun() Handler of the end of the list.
local function each(items, step, cb)
  if not cb then
    for _, item in ipairs(items) do
      step(item)
    end
    return
  end
  local index = 0
  local function run()
    index = index + 1
    if items[index] == nil then
      cb()
      return
    end
    step(items[index], run)
  end
  run()
end

--- Events ------------------------------------------------------------------

---Read the name of an event.
---
--- The call takes the name of the picker, the value of the API, and the form
--- with an underscore, in any case.
---@param text string? Name of an event.
---@return string? name Nil when no event has the name.
function M.normalize_event(text)
  local wanted = tostring(text or ""):lower():gsub("_", "-")
  for _, name in ipairs(M.event_names) do
    if wanted == name or wanted == M.events[name]:lower():gsub("_", "-") then
      return name
    end
  end
  return nil
end

---Line that describes one event.
---@param name string Name of the event.
---@return string
function M.event_label(name)
  if name == "approve" then
    return "approve: the review approves the pull request"
  end
  if name == "request-changes" then
    return "request-changes: the review asks for changes"
  end
  return "comment: the review adds comments only"
end

--- Position mapping ---------------------------------------------------------

-- |codeview.position| holds the mapping. These names stay for the callers of
-- this module.

---Side of the review API of a side of the diff. See |codeview.position.api_side()|.
M.api_side = mapper.api_side

---Lines that the diff of the pull request holds, per side. See |codeview.position.coverage()|.
M.coverage = mapper.coverage

---Number of the block that holds one line. See |codeview.position.block_of()|.
M.block_of = mapper.block_of

---Map one comment onto the diff of its file. See |codeview.position.to_api()|.
M.position = mapper.to_api

---Group comments by file.
---@param comments codeview.store.Comment[]
---@return table<string, codeview.store.Comment[]> by_file
---@return string[] paths Paths of the files, by name.
local function group(comments)
  local by_file, paths = {}, {}
  for _, comment in ipairs(comments) do
    if not by_file[comment.file] then
      by_file[comment.file] = {}
      paths[#paths + 1] = comment.file
    end
    local list = by_file[comment.file]
    list[#list + 1] = comment
  end
  table.sort(paths)
  for _, list in pairs(by_file) do
    table.sort(list, before)
  end
  return by_file, paths
end

--- Plan --------------------------------------------------------------------

---Session, pull request, and comment store of a call.
---@param opts codeview.submit.Opts|codeview.submit.SendOpts
---@return codeview.Session? session
---@return codeview.pr.Info? info
---@return codeview.store.Store? store
---@return codeview.Error? err
local function target(opts)
  local session = opts.session or session_mod.current()
  if not session or not session:is_active() then
    return nil, nil, nil, errors.new(errors.codes.INVALID_ARG, "no review session")
  end
  local info = require("codeview.pr").current(session)
  if not info then
    return nil, nil, nil, errors.new(errors.codes.INVALID_ARG, "the session does not review a pull request")
  end
  if info.repo == "" then
    return nil, nil, nil, errors.new(errors.codes.NOT_FOUND, "the pull request has no repository")
  end
  local store, store_err = require("codeview.comments").store(session)
  if not store then
    return nil, nil, nil, store_err
  end
  return session, info, store, nil
end

---Collect the comments of a session for one review.
---
--- The call reads the diff of every file that holds a comment and maps every
--- unsynced comment onto it. It does not talk to GitHub.
---@param opts? codeview.submit.Opts
---@param cb? fun(plan: codeview.submit.Plan?, err: codeview.Error?) Callback for the async form.
---@return codeview.submit.Plan? plan
---@return codeview.Error? err
function M.plan(opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}

  local session, info, store, target_err = target(opts)
  if not session then
    return done(cb, nil, target_err)
  end
  local event = M.normalize_event(opts.event or "comment")
  if not event then
    return done(
      cb,
      nil,
      errors.new(
        errors.codes.INVALID_ARG,
        "unknown review event: " .. tostring(opts.event) .. ". Use " .. table.concat(M.event_names, ", ")
      )
    )
  end

  local synced = 0
  for _, comment in ipairs(store.comments) do
    synced = synced + (store_mod.is_synced(comment) and 1 or 0)
  end

  ---@type codeview.submit.Plan
  local plan = {
    session = session,
    store = store,
    pr = info,
    dir = opts.dir or session.repo.root,
    event = event,
    body = type(opts.body) == "string" and opts.body or "",
    entries = {},
    notes = {},
    edits = {},
    skipped = {},
    synced = synced,
    total = #store.comments,
  }

  -- A comment on the pull request document is an overall comment. It takes no
  -- position of the diff, so it goes into the text of the review. A comment
  -- with an id on GitHub went out before, so only its text changes.
  local message = require("codeview.message")
  local on_lines = {}
  for _, comment in ipairs(store:unsynced()) do
    if (comment.remote_id or "") ~= "" then
      plan.edits[#plan.edits + 1] = comment
    elseif message.is_pr(comment.file) then
      plan.notes[#plan.notes + 1] = comment
    else
      on_lines[#on_lines + 1] = comment
    end
  end

  local by_file, paths = group(on_lines)

  ---Keep every comment of one file as unmappable.
  ---@param path string
  ---@param reason string
  local function skip_file(path, reason)
    for _, comment in ipairs(by_file[path]) do
      plan.skipped[#plan.skipped + 1] = { comment = comment, reason = reason }
    end
  end

  ---Map every comment of one file.
  ---@param path string
  ---@param entry codeview.submit.FileDiff
  local function map_file(path, entry)
    for _, comment in ipairs(by_file[path]) do
      local position, reason = mapper.to_api(entry.map, comment, entry.coverage)
      if position then
        plan.entries[#plan.entries + 1] = { comment = comment, position = position }
      else
        plan.skipped[#plan.skipped + 1] = { comment = comment, reason = reason or "the comment does not map" }
      end
    end
  end

  ---Handle one file of the group.
  ---@param path string
  ---@param step_cb? fun()
  local function step(path, step_cb)
    local index = session:index_of(path)
    local file = index and session:file(index) or nil
    if not file or file.virtual then
      -- The review API of GitHub writes on the lines of the diff. The commit
      -- message is no file of the diff, so such a comment stays local.
      skip_file(
        path,
        file and file.virtual and "GitHub takes no comment on a commit message"
          or "the pull request does not change this file"
      )
      if step_cb then
        step_cb()
      end
      return
    end

    ---@param entry codeview.submit.FileDiff?
    ---@param reason string?
    local function keep(entry, reason)
      if entry then
        map_file(path, entry)
      else
        skip_file(path, reason or "the file has no diff")
      end
    end

    if not step_cb then
      keep(mapper.map_of(session, file))
      return
    end
    mapper.map_of(session, file, function(entry, reason)
      keep(entry, reason)
      step_cb()
    end)
  end

  if not cb then
    each(paths, step)
    return plan, nil
  end
  each(paths, step, function()
    cb(plan, nil)
  end)
  return nil, nil
end

--- Summary -----------------------------------------------------------------

---Text of the line range of a comment.
---@param comment codeview.store.Comment
---@return string
local function lines_text(comment)
  if comment.start_line == comment.end_line then
    return "L" .. comment.start_line
  end
  return string.format("L%d-%d", comment.start_line, comment.end_line)
end

---First line of the body of a comment.
---@param comment codeview.store.Comment
---@param width integer Highest number of characters.
---@return string
local function preview(comment, width)
  local text = vim.split(vim.trim(comment.body or ""), "\n", { plain = true })[1] or ""
  if vim.fn.strchars(text) > width then
    text = vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end
  return text
end

---Count of comments, with the right word.
---@param count integer
---@return string
local function comment_count(count)
  return string.format("%d %s", count, count == 1 and "comment" or "comments")
end

---Number of comments that a plan sends.
---@param plan codeview.submit.Plan
---@return integer count
local function outgoing(plan)
  return #plan.entries + #plan.notes + #(plan.edits or {})
end

---Lines of the summary of a plan.
---
--- The user reads these lines before the post. They hold every comment that
--- goes out and every comment that stays local.
---@param plan codeview.submit.Plan
---@return string[] lines
function M.summary(plan)
  local out = {
    string.format(
      "submit %s to PR #%d of %s as %s",
      comment_count(outgoing(plan)),
      plan.pr.number,
      plan.pr.repo,
      plan.event
    ),
  }
  for _, entry in ipairs(plan.entries) do
    local position = entry.position
    out[#out + 1] = string.format(
      "  %s %s %s  %s",
      position.path,
      lines_text(entry.comment),
      entry.comment.side,
      preview(entry.comment, 50)
    )
  end
  if #plan.notes > 0 then
    out[#out + 1] = string.format(
      "%s %s into the text of the review:",
      comment_count(#plan.notes),
      #plan.notes == 1 and "goes" or "go"
    )
    for _, note in ipairs(plan.notes) do
      out[#out + 1] = "  " .. preview(note, 70)
    end
  end
  if #(plan.edits or {}) > 0 then
    out[#out + 1] =
      string.format("%s %s a new text on GitHub:", comment_count(#plan.edits), #plan.edits == 1 and "gets" or "get")
    for _, edit in ipairs(plan.edits) do
      out[#out + 1] = string.format("  %s %s %s  %s", edit.file, lines_text(edit), edit.side, preview(edit, 50))
    end
  end
  if #plan.skipped > 0 then
    out[#out + 1] = string.format("%s stays local:", comment_count(#plan.skipped))
    for _, skipped in ipairs(plan.skipped) do
      out[#out + 1] = string.format(
        "  %s %s %s: %s",
        skipped.comment.file,
        lines_text(skipped.comment),
        skipped.comment.side,
        skipped.reason
      )
    end
  end
  if plan.synced > 0 then
    out[#out + 1] = string.format("%s went to the pull request already", comment_count(plan.synced))
  end
  return out
end

---Show the summary of a plan in the message area.
---@param plan codeview.submit.Plan
---@return string text The summary as one text.
function M.show_summary(plan)
  local text = table.concat(M.summary(plan), "\n")
  pcall(api.nvim_echo, { { "codeview: " .. text } }, true, {})
  return text
end

--- Payload -----------------------------------------------------------------

---Text of the review itself.
---
--- The text of the review holds the text of the user and every comment on the
--- pull request document, one after the other.
---
--- GitHub rejects a review without a body for the comment event and for the
--- request-changes event. A plan without a body then takes the fallback text.
---@param plan codeview.submit.Plan
---@return string body
function M.body(plan)
  local parts = {}
  local text = vim.trim(plan.body or "")
  if text ~= "" then
    parts[#parts + 1] = text
  end
  for _, note in ipairs(plan.notes or {}) do
    parts[#parts + 1] = vim.trim(note.body or "")
  end
  local body = table.concat(parts, "\n\n")
  if body == "" and M.needs_body[plan.event] then
    return M.fallback_body
  end
  return body
end

---Build the request body of one review.
---@param plan codeview.submit.Plan
---@return table payload Value for `POST /repos/{owner}/{repo}/pulls/{n}/reviews`.
function M.payload(plan)
  local comments = {}
  for _, entry in ipairs(plan.entries) do
    local position = entry.position
    local item = {
      path = position.path,
      side = position.side,
      line = position.line,
      body = entry.comment.body,
    }
    if position.start_line then
      item.start_line = position.start_line
      item.start_side = position.start_side
    end
    comments[#comments + 1] = item
  end

  local payload = {
    commit_id = plan.pr.head_sha,
    event = M.events[plan.event],
    body = M.body(plan),
  }
  -- An empty list encodes as a JSON object, which the API rejects. A review
  -- without line comments needs no `comments` field at all.
  if #comments > 0 then
    payload.comments = comments
  end
  return payload
end

---Endpoint and request body of one comment.
---
--- Without a position the comment goes to the conversation of the pull
--- request. With a position it goes to the review comments, on the line of
--- the position.
---@param info codeview.pr.Info Pull request that receives the comment.
---@param comment codeview.store.Comment Comment of the session.
---@param position codeview.submit.Position? Position of a comment on a line.
---@return string path Path of the endpoint.
---@return table payload Request body.
function M.send_payload(info, comment, position)
  local number = math.floor(info.number)
  if not position then
    return string.format("repos/%s/issues/%d/comments", info.repo, number), { body = comment.body }
  end
  local payload = {
    body = comment.body,
    commit_id = info.head_sha,
    path = position.path,
    line = position.line,
    side = position.side,
  }
  if position.start_line then
    payload.start_line = position.start_line
    payload.start_side = position.start_side
  end
  return string.format("repos/%s/pulls/%d/comments", info.repo, number), payload
end

---Endpoint and request body of the new text of a comment on GitHub.
---
--- A comment on the pull request document lives in the conversation of the
--- pull request. Every other comment is a review comment.
---@param info codeview.pr.Info Pull request that holds the comment.
---@param comment codeview.store.Comment Comment of the session, with a `remote_id`.
---@return string path Path of the endpoint.
---@return table payload Request body.
function M.edit_payload(info, comment)
  local kind = require("codeview.message").is_pr(comment.file) and "issues" or "pulls"
  return string.format("repos/%s/%s/comments/%s", info.repo, kind, comment.remote_id), { body = comment.body }
end

--- Post --------------------------------------------------------------------

---Options of one API call on the pull request.
---@param info codeview.pr.Info
---@param dir string Directory that gh runs in.
---@param method? string HTTP method of a write. A write gets the long time limit of |codeview.gh|.
---@param payload? table Request body.
---@return codeview.gh.ApiOpts
local function api_opts(info, dir, method, payload)
  ---@type codeview.gh.ApiOpts
  local opts = { cwd = dir, hostname = gh.host(info.url) }
  if method then
    opts.method = method
    opts.timeout = gh.write_timeout
  end
  if payload then
    -- `--input -` sends the request body from standard input, so a nested
    -- comment list keeps its shape. `--field` cannot hold a list of objects.
    opts.input = "-"
    opts.stdin = vim.json.encode(payload)
  end
  return opts
end

---Id of an object of the answer of GitHub.
---@param object table?
---@return string id Empty when the answer holds no id.
local function id_of(object)
  local id = type(object) == "table" and object.id or nil
  if type(id) == "number" then
    return string.format("%d", math.floor(id))
  end
  if type(id) == "string" then
    return id
  end
  return ""
end

---Post one review to GitHub.
---
--- The call posts at once. |codeview.submit.run()| asks the user first, so
--- call this function only after a confirmation.
---@param plan codeview.submit.Plan
---@param cb? fun(review: table?, err: codeview.Error?) Callback for the async form.
---@return table? review Review object of the answer.
---@return codeview.Error? err
function M.post(plan, cb)
  if type(plan) ~= "table" or type(plan.pr) ~= "table" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the call needs a submit plan"))
  end
  local path = string.format("repos/%s/pulls/%d/reviews", plan.pr.repo, math.floor(plan.pr.number))
  return gh.api(path, api_opts(plan.pr, plan.dir, "POST", M.payload(plan)), cb)
end

---Text of a comment body, for a comparison.
---@param text any
---@return string
local function body_key(text)
  return vim.trim((tostring(text or ""):gsub("\r\n", "\n")))
end

---Report whether a review comment of GitHub is one comment of a payload.
---@param item table Comment of the payload of |codeview.submit.payload()|.
---@param remote table Comment of `GET /pulls/{n}/reviews/{id}/comments`.
---@return boolean same
local function same_comment(item, remote)
  if type(remote) ~= "table" or remote.path ~= item.path or (remote.side or "RIGHT") ~= item.side then
    return false
  end
  if (tonumber(remote.line) or tonumber(remote.original_line)) ~= item.line then
    return false
  end
  if (tonumber(remote.start_line) or tonumber(remote.original_start_line)) ~= item.start_line then
    return false
  end
  return body_key(remote.body) == body_key(item.body)
end

---Pair the comments of a payload with the review comments of GitHub.
---@param items table[] Comments of the payload.
---@param remotes table[] Review comments of GitHub.
---@return table<integer, table> pairs Review comment of each payload comment, by index.
---@return boolean complete True when every comment on both sides has a partner.
local function pair_comments(items, remotes)
  local out, used, count = {}, {}, 0
  for index, item in ipairs(items) do
    for at, remote in ipairs(remotes) do
      if not used[at] and same_comment(item, remote) then
        used[at], out[index] = true, remote
        count = count + 1
        break
      end
    end
  end
  return out, count == #items and count == #remotes
end

---Read the comments of one review.
---@param plan codeview.submit.Plan
---@param id string Id of the review.
---@param cb fun(comments: table[]?, err: codeview.Error?)
local function review_comments(plan, id, cb)
  local path = string.format("repos/%s/pulls/%d/reviews/%s/comments", plan.pr.repo, math.floor(plan.pr.number), id)
  gh.api_list(path, api_opts(plan.pr, plan.dir), cb)
end

---@class codeview.submit.Found
---@field review table Review object of GitHub.
---@field comments table[] Review comments of that review.

---Find the review of an earlier try of the same post.
---
--- The call lists the reviews of the pull request. A review on the same
--- commit and with the same text is a candidate. A candidate of the user that
--- is logged in, with the same comments, is the review of an earlier try.
---@param plan codeview.submit.Plan
---@param cb fun(found: codeview.submit.Found?, err: codeview.Error?) `found` is nil when GitHub holds no such review.
local function find_review(plan, cb)
  local payload = M.payload(plan)
  local items = payload.comments or {}
  local opts = api_opts(plan.pr, plan.dir)
  local path = string.format("repos/%s/pulls/%d/reviews", plan.pr.repo, math.floor(plan.pr.number))
  gh.api_list(path, opts, function(reviews, err)
    if not reviews then
      cb(nil, err)
      return
    end
    local candidates = {}
    for _, review in ipairs(reviews) do
      if
        type(review) == "table"
        and review.commit_id == payload.commit_id
        and body_key(review.body) == body_key(payload.body)
      then
        candidates[#candidates + 1] = review
      end
    end
    if #candidates == 0 then
      cb(nil, nil)
      return
    end
    gh.api("user", opts, function(user, user_err)
      if not user then
        cb(nil, user_err)
        return
      end
      -- The newest candidate comes first, because the list is oldest first.
      local index = #candidates + 1
      local function next_candidate()
        index = index - 1
        local review = candidates[index]
        if not review then
          cb(nil, nil)
          return
        end
        if (review.user or {}).login ~= user.login then
          next_candidate()
          return
        end
        review_comments(plan, id_of(review), function(comments, comments_err)
          if not comments then
            cb(nil, comments_err)
            return
          end
          if select(2, pair_comments(items, comments)) then
            cb({ review = review, comments = comments }, nil)
            return
          end
          next_candidate()
        end)
      end
      next_candidate()
    end)
  end)
end

---Mark the comments of a plan as sent, and write the session file.
---
--- The call runs only after GitHub confirmed the post. A write error leaves
--- the comments marked in memory and reports the problem, because the review
--- is on GitHub already.
---
--- With the review comments of GitHub, every comment on a line gets the id of
--- its comment on GitHub, so that a later edit changes that comment.
---@param plan codeview.submit.Plan
---@param review table? Answer of GitHub.
---@param remotes? table[] Review comments of the review, from `GET /pulls/{n}/reviews/{id}/comments`.
---@return integer count Number of comments that the call marked.
---@return codeview.Error? err Error of the write of the session file.
function M.apply(plan, review, remotes)
  local id = id_of(review)
  local time = os.time()
  local count = 0
  local paired = remotes and pair_comments(M.payload(plan).comments or {}, remotes) or {}
  for index, entry in ipairs(plan.entries) do
    local remote_id = paired[index] and id_of(paired[index]) or nil
    local comment = plan.store:mark_synced(entry.comment.id, { time = time, review_id = id, remote_id = remote_id })
    if comment then
      count = count + 1
    end
  end
  for _, note in ipairs(plan.notes or {}) do
    local comment = plan.store:mark_synced(note.id, { time = time, review_id = id })
    if comment then
      count = count + 1
    end
  end
  if count == 0 then
    return 0, nil
  end
  local ok, err = plan.store:save()
  if not ok then
    return count, err
  end
  events.emit("review_submitted", {
    session = plan.session.id,
    count = count,
    review = id,
  })
  return count, nil
end

--- Confirmation -------------------------------------------------------------

---Ask for the event of the review.
---@param plan codeview.submit.Plan
---@param cb fun(name: string?) Nil when the user cancels.
local function ask_event(plan, cb)
  vim.ui.select(M.event_names, {
    prompt = string.format("codeview: submit %s to PR #%d as", comment_count(outgoing(plan)), plan.pr.number),
    format_item = M.event_label,
  }, function(choice)
    cb(choice and M.normalize_event(choice) or nil)
  end)
end

---Ask for the text of the review.
---@param plan codeview.submit.Plan
---@param cb fun(body: string?) Nil when the user cancels.
local function ask_body(plan, cb)
  vim.ui.input({
    prompt = string.format("codeview: text of the %s review: ", plan.event),
  }, function(text)
    cb(text)
  end)
end

---Ask whether the review goes out.
---
--- The default asks with |vim.ui.select()|, after the summary. Replace the
--- function only in a test. The plugin never posts without a confirmation.
---@param plan codeview.submit.Plan
---@param cb fun(ok: boolean)
function M.confirm(plan, cb)
  M.show_summary(plan)
  vim.ui.select({ "submit", "cancel" }, {
    prompt = string.format(
      "codeview: post %s to PR #%d as %s?",
      comment_count(outgoing(plan)),
      plan.pr.number,
      plan.event
    ),
  }, function(choice)
    cb(choice == "submit")
  end)
end

--- Command -----------------------------------------------------------------

---Take the lock of the session of a call.
---@param opts codeview.submit.Opts|codeview.submit.SendOpts
---@return integer? key Session id that the call holds. Nil without a session.
---@return codeview.Error? err Set when another call of the session runs.
local function lock(opts)
  local session = opts.session or session_mod.current()
  local key = type(session) == "table" and session.id or nil
  if key == nil then
    return nil, nil
  end
  if busy[key] then
    return nil,
      errors.new(errors.codes.INVALID_ARG, "a submit of this session runs already. Wait for its answer, then try again")
  end
  busy[key] = true
  return key, nil
end

---Report a session file that did not change after a post.
---@param err codeview.Error
---@param what string Text that names what went to GitHub.
local function report_save(err, what)
  notify.error(
    what .. " is on GitHub, but the session file did not change: " .. tostring(err) .. ". Do not send it again"
  )
end

---Send the comments of a session to the pull request.
---
--- The call collects the comments and asks for the event and for the text of
--- the review. It shows the summary and posts only after the user confirms it.
--- A failed post marks nothing, so every comment stays in the session file.
---
--- Before the post the call looks for the review of an earlier try. When
--- GitHub holds it, the call marks the comments as sent and posts nothing.
--- After the review, the call changes the text of every edited comment.
---
--- The callback always runs on the main loop, after the call returns. That
--- holds for an early exit too.
---@param opts? codeview.submit.Opts
---@param cb? fun(result: codeview.submit.Result?, err: codeview.Error?) Handler of the answer.
function M.run(opts, cb)
  opts = opts or {}
  local loud = opts.notify ~= false
  ---@type integer?
  local key

  ---@param result codeview.submit.Result?
  ---@param err codeview.Error?
  local function finish(result, err)
    if key then
      busy[key] = nil
      key = nil
    end
    if err and loud then
      notify.error(M.error_text(err))
    end
    if cb then
      -- An early exit runs on the stack of the caller. `done` sends every
      -- answer through the main loop, so the callback never runs before the
      -- call returns.
      done(cb, result, err)
    end
  end

  local lock_err
  key, lock_err = lock(opts)
  if lock_err then
    finish(nil, lock_err)
    return
  end

  ---Report the comments that stay local.
  ---@param plan codeview.submit.Plan
  local function report_skipped(plan)
    if #plan.skipped == 0 or not loud then
      return
    end
    local lines = { comment_count(#plan.skipped) .. " stays local:" }
    for _, skipped in ipairs(plan.skipped) do
      lines[#lines + 1] =
        string.format("  %s %s: %s", skipped.comment.file, lines_text(skipped.comment), skipped.reason)
    end
    notify.warn(table.concat(lines, "\n"))
  end

  ---Change the text of every edited comment on GitHub, one after the other.
  ---
  --- The first failure stops the rest. A comment that GitHub took is marked
  --- as sent.
  ---@param plan codeview.submit.Plan
  ---@param after fun(count: integer, err: codeview.Error?)
  local function send_edits(plan, after)
    local count = 0
    ---@type codeview.Error?
    local failed
    each(plan.edits, function(comment, step_cb)
      if failed then
        step_cb()
        return
      end
      local path, payload = M.edit_payload(plan.pr, comment)
      gh.api(path, api_opts(plan.pr, plan.dir, "PATCH", payload), function(answer, err)
        if answer then
          plan.store:mark_synced(comment.id, { time = os.time() })
          count = count + 1
        else
          failed = err
        end
        step_cb()
      end)
    end, function()
      if count > 0 then
        local ok, save_err = plan.store:save()
        if not ok and loud then
          report_save(save_err --[[@as codeview.Error]], "the new text")
        end
        events.emit("review_submitted", { session = plan.session.id, count = count, review = "" })
      end
      after(count, failed)
    end)
  end

  ---Change the edited comments, then report the end of the submit.
  ---@param plan codeview.submit.Plan
  ---@param review table? Review of GitHub. Nil when the plan holds edits only.
  ---@param existing boolean True when GitHub held the review already.
  ---@param count integer Number of comments that the review marked.
  local function after_review(plan, review, existing, count)
    send_edits(plan, function(edited, edit_err)
      local total = count + edited
      local url = review and type(review.html_url) == "string" and review.html_url or ""
      if loud and total > 0 then
        local message = string.format("%s went to PR #%d", comment_count(total), plan.pr.number)
        if existing then
          message = string.format(
            "PR #%d holds this review already, so nothing new went out. %s marked as sent",
            plan.pr.number,
            comment_count(count)
          )
        end
        notify.info(url ~= "" and (message .. ": " .. url) or message)
      end
      report_skipped(plan)
      if edit_err then
        finish(nil, edit_err)
        return
      end
      finish({
        posted = total,
        skipped = #plan.skipped,
        cancelled = false,
        review = review,
        url = url,
        existing = existing,
      }, nil)
    end)
  end

  ---@param plan codeview.submit.Plan
  local function send(plan)
    if #plan.entries + #plan.notes == 0 then
      after_review(plan, nil, false, 0)
      return
    end
    find_review(plan, function(found, find_err)
      if find_err then
        -- The call cannot tell whether an earlier try reached GitHub, so it
        -- posts nothing.
        report_skipped(plan)
        finish(nil, find_err)
        return
      end
      if found then
        local count, save_err = M.apply(plan, found.review, found.comments)
        if save_err and loud then
          report_save(save_err, "the review")
        end
        after_review(plan, found.review, true, count)
        return
      end
      M.post(plan, function(review, err)
        if not review then
          -- The call marks nothing, so every comment stays local and a later
          -- submit sends it again. The comments that do not map stay local too,
          -- and the report names them next to the error.
          report_skipped(plan)
          finish(nil, err)
          return
        end
        -- The ids of the new review comments let a later edit change them. A
        -- failed read only loses the ids.
        review_comments(plan, id_of(review), function(remotes)
          local count, save_err = M.apply(plan, review, remotes)
          if save_err and loud then
            report_save(save_err, "the review")
          end
          after_review(plan, review, false, count)
        end)
      end)
    end)
  end

  M.plan(opts, function(plan, err)
    if not plan then
      finish(nil, err)
      return
    end
    if outgoing(plan) == 0 then
      if loud then
        local reason = "no comment to submit"
        if #plan.skipped > 0 then
          reason = "no comment maps to the diff of the pull request"
        elseif plan.synced > 0 then
          reason = "every comment went to the pull request already"
        end
        notify.info(reason)
      end
      report_skipped(plan)
      finish({ posted = 0, skipped = #plan.skipped, cancelled = true, review = nil, url = "" }, nil)
      return
    end

    ---@param body string?
    local function with_body(body)
      if body == nil then
        finish({ posted = 0, skipped = #plan.skipped, cancelled = true, review = nil, url = "" }, nil)
        return
      end
      plan.body = body
      M.confirm(plan, function(ok)
        if not ok then
          if loud then
            notify.info("you canceled the submit. Nothing went to GitHub")
          end
          finish({ posted = 0, skipped = #plan.skipped, cancelled = true, review = nil, url = "" }, nil)
          return
        end
        send(plan)
      end)
    end

    ---@param event string?
    local function with_event(event)
      if not event then
        finish({ posted = 0, skipped = #plan.skipped, cancelled = true, review = nil, url = "" }, nil)
        return
      end
      plan.event = event
      if type(opts.body) == "string" then
        with_body(opts.body)
        return
      end
      if #plan.notes > 0 or #plan.entries == 0 then
        -- The notes are the text of the review, so the call asks for none. A
        -- plan of edits alone posts no review, so it needs no text either.
        with_body("")
        return
      end
      ask_body(plan, with_body)
    end

    if opts.event then
      with_event(M.normalize_event(opts.event))
      return
    end
    ask_event(plan, with_event)
  end)
end

---@class codeview.submit.SendOpts
---@field id string Id of the comment in the store of the session.
---@field session codeview.Session? Session that holds the comment. The session that runs by default.
---@field dir string? Directory that gh runs in. The repository root by default.
---@field notify boolean? False silences the reports of the call.

---Send one comment to the pull request.
---
--- The send key of the comment editor calls this function. It posts at once,
--- without a summary, because the reviewer pressed the key on the one
--- comment that goes out. A comment on a line goes to the review comments
--- of the pull request. A comment on the pull request document goes to the
--- conversation of the pull request. A comment on a commit message stays
--- local, because GitHub has no place for it.
---
--- A comment that went out already stays as it is. A comment that went out
--- and got a new text changes its text on GitHub. A failed post marks
--- nothing.
---
--- The callback always runs on the main loop, after the call returns. That
--- holds for an early exit too.
---@param opts codeview.submit.SendOpts
---@param cb? fun(result: codeview.submit.Result?, err: codeview.Error?) Handler of the answer.
function M.send(opts, cb)
  opts = opts or {}
  local loud = opts.notify ~= false
  ---@type integer?
  local key

  ---@param result codeview.submit.Result?
  ---@param err codeview.Error?
  local function finish(result, err)
    if key then
      busy[key] = nil
      key = nil
    end
    if err and loud then
      notify.error(M.error_text(err))
    end
    if cb then
      -- An early exit runs on the stack of the caller. `done` sends every
      -- answer through the main loop, so the callback never runs before the
      -- call returns.
      done(cb, result, err)
    end
  end

  local session, info, store, target_err = target(opts)
  if not session then
    finish(nil, target_err)
    return
  end
  if type(opts.id) ~= "string" then
    finish(nil, errors.new(errors.codes.INVALID_ARG, "the call needs the id of a comment"))
    return
  end
  local comment = store:get(opts.id)
  if not comment then
    finish(nil, errors.new(errors.codes.NOT_FOUND, "no comment with the id " .. opts.id))
    return
  end
  if store_mod.is_synced(comment) then
    if loud then
      notify.info("the comment went to the pull request already")
    end
    finish({ posted = 0, skipped = 0, cancelled = true, review = nil, url = "" }, nil)
    return
  end
  local lock_err
  key, lock_err = lock({ session = session })
  if lock_err then
    finish(nil, lock_err)
    return
  end
  local dir = opts.dir or session.repo.root

  ---Write one comment to GitHub and mark it after GitHub confirms it.
  ---@param method "POST"|"PATCH"
  ---@param path string
  ---@param payload table
  local function write(method, path, payload)
    gh.api(path, api_opts(info, dir, method, payload), function(answer, post_err)
      if not answer then
        finish(nil, post_err)
        return
      end
      ---@type { time: integer, review_id?: string, remote_id?: string }
      local mark = { time = os.time() }
      local id = comment.review_id or ""
      if method == "POST" then
        -- A line comment belongs to a review of one comment. A comment of the
        -- conversation belongs to no review, so its id is empty.
        id = id_of({ id = answer.pull_request_review_id })
        mark.review_id = id
        mark.remote_id = id_of(answer)
      end
      store:mark_synced(comment.id, mark)
      local ok, save_err = store:save()
      if not ok and loud then
        report_save(save_err --[[@as codeview.Error]], "the comment")
      end
      events.emit("review_submitted", { session = session.id, count = 1, review = id })
      local url = type(answer.html_url) == "string" and answer.html_url or ""
      if loud then
        local message = method == "PATCH" and string.format("the new text went to PR #%d", info.number)
          or string.format("the comment went to PR #%d", info.number)
        notify.info(url ~= "" and (message .. ": " .. url) or message)
      end
      finish({ posted = 1, skipped = 0, cancelled = false, review = answer, url = url }, nil)
    end)
  end

  if (comment.remote_id or "") ~= "" then
    write("PATCH", M.edit_payload(info, comment))
    return
  end

  local index = session:index_of(comment.file)
  local file = index and session:file(index)
  if not file then
    finish(nil, errors.new(errors.codes.NOT_FOUND, "the pull request does not change this file"))
    return
  end

  local message = require("codeview.message")
  if message.is_pr(file.path) then
    write("POST", M.send_payload(info, comment, nil))
    return
  end
  if file.virtual then
    finish(
      nil,
      errors.new(
        errors.codes.INVALID_ARG,
        "GitHub takes no comment on a commit message. Write an overall comment on the pull request document"
      )
    )
    return
  end

  mapper.map_of(session, file, function(entry, reason)
    if not entry then
      finish(nil, errors.new(errors.codes.INVALID_ARG, reason or "the file has no diff"))
      return
    end
    local position, why = mapper.to_api(entry.map, comment, entry.coverage)
    if not position then
      finish(nil, errors.new(errors.codes.INVALID_ARG, why or "the comment does not map"))
      return
    end
    write("POST", M.send_payload(info, comment, position))
  end)
end

return M
