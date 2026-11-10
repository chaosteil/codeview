---@brief The review comments that a pull request already holds.
---
--- A pull request review starts with the comments of the other reviewers. This
--- module reads them with `gh api`, maps every comment to a file and a line,
--- and shows them in the diff next to the local anchors.
---
--- A remote comment lives on GitHub, not in the session file of
--- |codeview.store|. The module also reads the review threads of the pull
--- request with the GraphQL API: the resolved state of each thread, the
--- rights of the user on each comment, and the reactions. A thread is the
--- first comment and its replies, oldest first, see |codeview.remote.threads()|.
--- When the GraphQL call fails, the comments show without the thread state,
--- and one warning tells the user.
---
--- The signs use their own namespace, so the two kinds of comment never
--- overwrite each other. |codeview.stack| draws the boxes of both kinds. A
--- thread of GitHub shows as one box: the first comment, then the replies.
---
--- A comment that a submit of this session sent lives twice: on GitHub and in
--- the session file. The module drops the copy of GitHub, so the review shows
--- the local comment alone, with its sync mark.
---
--- GitHub reports the position of a comment in two ways:
---
--- 1. `line` and `start_line`: the lines of the newest version of the diff.
---    `side` names the side of `line`, and `start_side` the side of
---    `start_line`. A range over the two sides keeps its last line only,
---    because one anchor holds the lines of one side.
--- 2. No `line`: a later push changed the lines, and the comment is outdated.
---    `original_line` and the end of `diff_hunk` name the lines of the older
---    version, which can hold other text now. The display does not draw the
---    comment there. It looks for the last lines of `diff_hunk` in the current
---    file instead, see |codeview.remote.locate()|. Without one clear match
---    the comment stays unanchored: the overview lists it, but no row of the
---    diff holds its sign.
---
--- `side` is LEFT for the old side of the diff and RIGHT for the new side.
--- |codeview.position.from_api()| maps these fields to the lines of an anchor.
---
--- The render path draws more than the comments of GitHub. Each source of
--- read-only items in |codeview.remote.sources| gets the same anchor, the same
--- search for the lines of an outdated item, the same virtual lines, and the
--- same float. The pr-agent suggestions of |codeview.agent| are the second
--- source.

local box = require("codeview.box")
local config = require("codeview.config")
local errors = require("codeview.error")
local events = require("codeview.events")
local gh = require("codeview.gh")
local notify = require("codeview.notify")
local mapper = require("codeview.position")
local util = require("codeview.util")

local api = vim.api

local done = util.done

local M = {}

---Namespace of the remote comment decorations.
---@type integer
M.ns = api.nvim_create_namespace("codeview.remote")

---@class codeview.remote.Comment
---@field id integer Id of the comment on GitHub.
---@field file string Path of the file in the review.
---@field start_line integer First line of the range, from 1.
---@field end_line integer Last line of the range.
---@field side codeview.linemap.Side Side of the diff that holds the lines.
---@field commit string Commit that the author wrote the comment on.
---@field author string Login of the author.
---@field body string Markdown text of the comment.
---@field url string Address of the comment.
---@field review_id string Id of the review that holds the comment. Empty when the answer names none.
---@field created_at integer Time of the comment, in seconds since the epoch.
---@field outdated boolean True when a later push moved the lines of the comment.
---@field anchored boolean? False when the current version holds no line of the comment. Its lines are then the lines of the older version.
---@field hunk string[]? Text of the last lines of `diff_hunk` on the side of an outdated comment. The display looks for them in the current file.
---@field reply_to integer? Id of the comment that this one answers. GitHub names the first comment of the thread.
---@field node_id string? GraphQL id of the comment. Nil without the thread state.
---@field can_update boolean? True when the user can change the text of the comment.
---@field can_delete boolean? True when the user can delete the comment.
---@field reactions codeview.remote.Reaction[] Reactions of the comment, in the order of |codeview.remote.reaction_kinds|.
---@field thread codeview.remote.ThreadState? State of the thread of the comment. Nil without the thread state.

---@class codeview.remote.Reaction
---@field content string Name of the reaction in the GraphQL API, for example THUMBS_UP.
---@field count integer Number of users with the reaction.
---@field mine boolean True when the user that is logged in gave the reaction.

---@class codeview.remote.ThreadState
---@field id string GraphQL id of the thread.
---@field resolved boolean True when somebody resolved the thread.
---@field resolved_by string Login of the user that resolved the thread. Empty when unknown.
---@field can_resolve boolean True when the user can resolve the thread.
---@field can_unresolve boolean True when the user can open the thread again.
---@field can_reply boolean True when the user can reply to the thread.

---@class codeview.remote.Thread
---@field root codeview.remote.Comment First comment of the thread.
---@field comments codeview.remote.Comment[] Every comment of the thread, oldest first.
---@field id string? GraphQL id of the thread. Nil without the thread state.
---@field resolved boolean True when somebody resolved the thread.
---@field resolved_by string Login of the user that resolved the thread. Empty when unknown.
---@field can_resolve boolean
---@field can_unresolve boolean
---@field can_reply boolean
---@field file string Path of the file of the root.
---@field start_line integer First line of the root.
---@field end_line integer Last line of the root.
---@field side codeview.linemap.Side Side of the root.
---@field outdated boolean True when the root is outdated.
---@field anchored boolean? False when the current version holds no line of the root.
---@field hunk string[]? Last lines of the `diff_hunk` of the root.

---Kinds of reaction of GitHub, in the order of the display.
---
--- `content` is the name in the GraphQL API, `rest` is the key of the
--- `reactions` field of the REST API.
---@type { content: string, emoji: string, rest: string }[]
M.reaction_kinds = {
  { content = "THUMBS_UP", emoji = "👍", rest = "+1" },
  { content = "THUMBS_DOWN", emoji = "👎", rest = "-1" },
  { content = "LAUGH", emoji = "😄", rest = "laugh" },
  { content = "HOORAY", emoji = "🎉", rest = "hooray" },
  { content = "CONFUSED", emoji = "😕", rest = "confused" },
  { content = "HEART", emoji = "❤️", rest = "heart" },
  { content = "ROCKET", emoji = "🚀", rest = "rocket" },
  { content = "EYES", emoji = "👀", rest = "eyes" },
}

---Message of an action that needs the thread state when it is missing.
---@type string
M.no_state = "the thread state of GitHub is not available"

---Comments of each open session, by session id.
---@type table<integer, codeview.remote.Comment[]>
local stores = {}

---Resolved threads that show every comment, by session id, then by the key
---of |codeview.remote.thread_key()|.
---@type table<integer, table<string, boolean>>
local expanded = {}

--- Mapping ---------------------------------------------------------------------

---Number of lines above the commented lines that |codeview.remote.locate()|
---also looks for.
---@type integer
M.hunk_context = 3

---Side of the diff of a GitHub `side` field. See |codeview.position.side()|.
---@param text string? LEFT or RIGHT.
---@return codeview.linemap.Side side
function M.side(text)
  return mapper.side(text)
end

---Text of the lines of one side of a diff hunk.
---@param hunk string? Value of the `diff_hunk` field.
---@param side codeview.linemap.Side
---@return string[] lines Lines of the side, in order, without the mark of the diff.
local function side_lines(hunk, side)
  local out = {}
  local inside = false
  for _, text in ipairs(vim.split(tostring(hunk or ""), "\n", { plain = true })) do
    if text:match("^@@%s+%-%d+") then
      inside = true
    elseif inside and text ~= "" then
      local mark = text:sub(1, 1)
      if mark == " " or (mark == "+" and side == "new") or (mark == "-" and side == "old") then
        out[#out + 1] = (text:sub(2):gsub("\r$", ""))
      end
    end
  end
  return out
end

---Last lines of one side of a diff hunk.
---
--- The hunk of a comment ends at the commented line. The call keeps the
--- commented lines and |codeview.remote.hunk_context| lines above them.
---@param hunk string? Value of the `diff_hunk` field.
---@param side codeview.linemap.Side
---@param count integer Number of commented lines.
---@return string[] lines Empty when the hunk holds no line of the side.
function M.hunk_lines(hunk, side, count)
  local lines = side_lines(hunk, side)
  local first = math.max(#lines - math.max(count, 1) - M.hunk_context + 1, 1)
  return vim.list_slice(lines, first, #lines)
end

---Find the lines of a hunk in a file.
---@param wanted string[] Lines to find, in order.
---@param lines string[] Lines of the file.
---@return integer? last Line of the file that holds the last wanted line. Nil without exactly one match.
function M.locate(wanted, lines)
  if #wanted == 0 then
    return nil
  end
  local found
  for start = 1, #lines - #wanted + 1 do
    local same = true
    for offset = 1, #wanted do
      if lines[start + offset - 1] ~= wanted[offset] then
        same = false
        break
      end
    end
    if same then
      if found then
        return nil
      end
      found = start + #wanted - 1
    end
  end
  return found
end

---Last line of a diff hunk, on one side.
---
--- GitHub sends the hunk of every comment in `diff_hunk`, and the hunk ends at
--- the commented line. The call walks the hunk from its header and counts the
--- lines of the side.
---@param hunk string? Value of the `diff_hunk` field.
---@param side codeview.linemap.Side Side that holds the line.
---@return integer? line Nil when the text holds no hunk header.
function M.hunk_line(hunk, side)
  local lines = vim.split(tostring(hunk or ""), "\n", { plain = true })
  local old_line, new_line
  local last
  for _, text in ipairs(lines) do
    local old_start, new_start = text:match("^@@%s+%-(%d+)%D.-%+(%d+)")
    if old_start then
      old_line, new_line = tonumber(old_start), tonumber(new_start)
    elseif old_line and new_line and text ~= "" then
      local mark = text:sub(1, 1)
      -- "\ No newline at end of file" belongs to the line above it, so it
      -- moves no counter.
      if mark == "+" then
        if side == "new" then
          last = new_line
        end
        new_line = new_line + 1
      elseif mark == "-" then
        if side == "old" then
          last = old_line
        end
        old_line = old_line + 1
      elseif mark ~= "\\" then
        last = side == "old" and old_line or new_line
        old_line, new_line = old_line + 1, new_line + 1
      end
    end
  end
  return last
end

---@class codeview.remote.Anchor
---@field start_line integer First line of the range.
---@field end_line integer Last line of the range.
---@field side codeview.linemap.Side Side that holds the lines.
---@field outdated boolean True when the lines come from an older push.
---@field anchored boolean False when the current version holds no line of the comment.
---@field hunk string[]? Last lines of `diff_hunk` on the side of an outdated comment.

---Anchor of one comment of the GitHub API.
---@param entry table Entry of `GET /repos/{owner}/{repo}/pulls/{n}/comments`.
---@return codeview.remote.Anchor? anchor Nil when the entry holds no position.
function M.anchor(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local side = M.side(entry.side)

  -- An outdated comment has no `line`. The lines of the older version take
  -- its place, so the overview can name them.
  local outdated = tonumber(entry.line) == nil
  local lines = mapper.from_api({
    side = entry.side,
    line = outdated and (tonumber(entry.original_line) or M.hunk_line(entry.diff_hunk, side)) or entry.line,
    start_line = outdated and entry.original_start_line or entry.start_line,
    start_side = entry.start_side,
  })
  if not lines then
    return nil
  end

  ---@type codeview.remote.Anchor
  local anchor = {
    start_line = lines.start_line,
    end_line = lines.end_line,
    side = side,
    outdated = outdated,
    anchored = not outdated,
  }
  if outdated then
    local hunk = M.hunk_lines(entry.diff_hunk, side, lines.end_line - lines.start_line + 1)
    anchor.hunk = #hunk > 0 and hunk or nil
  end
  return anchor
end

---Id of a review, in the form that the session file holds.
---@param value string|number|nil Value of a review id field.
---@return string id Empty without an id.
function M.review_id(value)
  if type(value) == "number" then
    return string.format("%d", math.floor(value))
  end
  if type(value) == "string" then
    return value
  end
  return ""
end

---Read the text of a comment.
---
--- GitHub keeps the line endings of the web editor, so a body can hold CRLF.
--- A carriage return shows as `^M` in a virtual line and in the float, so the
--- call drops it.
---@param text string? Value of the `body` field.
---@return string body
local function body_text(text)
  local out = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.trim(out)
end

---Reactions of the `reactions` field of the REST API.
---
--- The field holds the counts only, so no reaction is `mine`.
---@param rollup table? Value of the `reactions` field.
---@return codeview.remote.Reaction[] reactions
local function rest_reactions(rollup)
  local out = {}
  if type(rollup) ~= "table" then
    return out
  end
  for _, kind in ipairs(M.reaction_kinds) do
    local count = tonumber(rollup[kind.rest]) or 0
    if count > 0 then
      out[#out + 1] = { content = kind.content, count = math.floor(count), mine = false }
    end
  end
  return out
end

---Read the comments of the GitHub API.
---
--- An entry without a file or without a position drops out, because the diff
--- holds no row for it.
---@param entries table[]? Answer of the review comments endpoint.
---@return codeview.remote.Comment[] comments Oldest first.
function M.parse(entries)
  local store_mod = require("codeview.store")
  local out = {}
  for _, entry in ipairs(entries or {}) do
    local path = type(entry) == "table" and entry.path or nil
    local anchor = M.anchor(entry)
    if type(path) == "string" and path ~= "" and anchor then
      local reply = tonumber(entry.in_reply_to_id)
      out[#out + 1] = {
        id = math.floor(tonumber(entry.id) or 0),
        file = path,
        start_line = anchor.start_line,
        end_line = anchor.end_line,
        side = anchor.side,
        commit = tostring(entry.original_commit_id or entry.commit_id or ""),
        author = (entry.user or {}).login or "",
        body = body_text(entry.body),
        url = tostring(entry.html_url or ""),
        review_id = M.review_id(entry.pull_request_review_id),
        created_at = store_mod.from_iso(entry.created_at) or 0,
        outdated = anchor.outdated,
        anchored = anchor.anchored,
        hunk = anchor.hunk,
        reply_to = reply and math.floor(reply),
        reactions = rest_reactions(entry.reactions),
      }
    end
  end
  return out
end

--- Fetch -----------------------------------------------------------------------

---Number of threads that one page of the GraphQL query asks for.
---@type integer
M.thread_page = 50

---Highest number of pages of threads that a fetch reads.
---@type integer
M.thread_pages = 10

---Query of the review threads of a pull request.
---@type string
M.threads_query = [[
query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: ]] .. M.thread_page .. [[, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved resolvedBy { login } viewerCanResolve viewerCanUnresolve viewerCanReply
          comments(first: 100) {
            nodes {
              databaseId id viewerCanUpdate viewerCanDelete
              reactionGroups { content viewerHasReacted reactors { totalCount } }
            }
          }
        }
      }
    }
  }
}
]]

---Reactions of the `reactionGroups` field of the GraphQL API.
---@param groups table? Value of the field.
---@return codeview.remote.Reaction[] reactions In the order of |codeview.remote.reaction_kinds|.
local function graphql_reactions(groups)
  local by_content = {}
  for _, group in ipairs(type(groups) == "table" and groups or {}) do
    if type(group) == "table" and type(group.content) == "string" then
      by_content[group.content] = group
    end
  end
  local out = {}
  for _, kind in ipairs(M.reaction_kinds) do
    local group = by_content[kind.content]
    if group then
      local count = tonumber(type(group.reactors) == "table" and group.reactors.totalCount) or 0
      local mine = group.viewerHasReacted == true
      if count > 0 or mine then
        out[#out + 1] = { content = kind.content, count = math.floor(math.max(count, mine and 1 or 0)), mine = mine }
      end
    end
  end
  return out
end

---Add the thread state of the GraphQL API to the comments of the REST API.
---
--- A comment and a GraphQL node are the same when the `databaseId` of the
--- node is the id of the comment. A comment without a node keeps its fields.
---@param comments codeview.remote.Comment[] Comments of |codeview.remote.parse()|. The call changes them in place.
---@param threads table[] Nodes of `reviewThreads`.
---@return codeview.remote.Comment[] comments
function M.join(comments, threads)
  local by_id = {}
  for _, thread in ipairs(threads or {}) do
    if type(thread) == "table" and type(thread.id) == "string" then
      ---@type codeview.remote.ThreadState
      local state = {
        id = thread.id,
        resolved = thread.isResolved == true,
        resolved_by = type(thread.resolvedBy) == "table" and tostring(thread.resolvedBy.login or "") or "",
        can_resolve = thread.viewerCanResolve == true,
        can_unresolve = thread.viewerCanUnresolve == true,
        can_reply = thread.viewerCanReply == true,
      }
      local nodes = type(thread.comments) == "table" and thread.comments.nodes or {}
      for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
        local id = type(node) == "table" and tonumber(node.databaseId) or nil
        if id then
          by_id[math.floor(id)] = { node = node, state = state }
        end
      end
    end
  end
  for _, comment in ipairs(comments or {}) do
    local found = by_id[comment.id]
    if found then
      comment.node_id = type(found.node.id) == "string" and found.node.id or nil
      comment.can_update = found.node.viewerCanUpdate == true
      comment.can_delete = found.node.viewerCanDelete == true
      comment.reactions = graphql_reactions(found.node.reactionGroups)
      comment.thread = found.state
    end
  end
  return comments
end

---Read the review threads of one pull request with the GraphQL API.
---
--- The call reads pages of |codeview.remote.thread_page| threads, and stops
--- after |codeview.remote.thread_pages| pages.
---@param opts { repo: string, number: integer, dir?: string, host?: string }
---@param cb? fun(threads: table[]?, err: codeview.Error?) Callback for the async form.
---@return table[]? threads Nodes of `reviewThreads`.
---@return codeview.Error? err
function M.fetch_threads(opts, cb)
  local owner, name = tostring(opts.repo or ""):match("^([^/]+)/([^/]+)$")
  if not owner then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the repository is not owner/name"))
  end
  local gql_opts = { hostname = opts.host or gh.default_host, cwd = opts.dir }
  local nodes = {}

  ---@param cursor string?
  ---@return table
  local function variables(cursor)
    return { owner = owner, name = name, number = math.floor(opts.number), cursor = cursor }
  end

  ---Keep the threads of one page.
  ---@param data table
  ---@return string? cursor Cursor of the next page. Nil after the last page.
  ---@return codeview.Error? err
  local function keep(data)
    local repository = type(data.repository) == "table" and data.repository or {}
    local pull = type(repository.pullRequest) == "table" and repository.pullRequest or {}
    local threads = pull.reviewThreads
    if type(threads) ~= "table" then
      return nil, errors.new(errors.codes.NOT_FOUND, "gh: the answer holds no review threads")
    end
    vim.list_extend(nodes, type(threads.nodes) == "table" and threads.nodes or {})
    local info = type(threads.pageInfo) == "table" and threads.pageInfo or {}
    if info.hasNextPage == true and type(info.endCursor) == "string" then
      return info.endCursor, nil
    end
    return nil, nil
  end

  if not cb then
    local cursor = nil
    for _ = 1, M.thread_pages do
      local data, err = gh.graphql(M.threads_query, variables(cursor), gql_opts)
      if not data then
        return nil, err
      end
      local keep_err
      cursor, keep_err = keep(data)
      if keep_err then
        return nil, keep_err
      end
      if not cursor then
        break
      end
    end
    return nodes, nil
  end

  local page = 0
  ---@param cursor string?
  local function step(cursor)
    page = page + 1
    gh.graphql(M.threads_query, variables(cursor), gql_opts, function(data, err)
      if not data then
        cb(nil, err)
        return
      end
      local next_cursor, keep_err = keep(data)
      if keep_err then
        cb(nil, keep_err)
        return
      end
      if next_cursor and page < M.thread_pages then
        step(next_cursor)
        return
      end
      cb(nodes, nil)
    end)
  end
  step(nil)
  return nil, nil
end

---Read the review comments of one pull request.
---
--- `host` names the GitHub server. A GitHub Enterprise repository needs it,
--- because `gh` takes github.com without it. `dir` names the directory that
--- `gh` runs in.
---
--- The endpoint answers the oldest comment first. When the fetch stops at
--- `max` and GitHub holds more comments, the list holds the field
--- `truncated = true`.
---@param opts { repo: string, number: integer, max?: integer, dir?: string, host?: string } `repo` is `owner/name`.
---@param cb? fun(comments: codeview.remote.Comment[]?, err: codeview.Error?) Callback for the async form.
---@return codeview.remote.Comment[]? comments
---@return codeview.Error? err
function M.fetch(opts, cb)
  opts = opts or {}
  if type(opts.repo) ~= "string" or opts.repo == "" or type(opts.number) ~= "number" then
    local err = errors.new(errors.codes.INVALID_ARG, "the call needs a repository and a pull request number")
    return done(cb, nil, err)
  end

  local path = string.format("repos/%s/pulls/%d/comments", opts.repo, math.floor(opts.number))
  local api_opts = {
    max = opts.max or config.get().github.max_comments,
    cwd = opts.dir,
    hostname = opts.host or gh.default_host,
  }

  ---@param entries table[]
  ---@return codeview.remote.Comment[]
  local function read(entries)
    local comments = M.parse(entries)
    if entries.truncated then
      comments.truncated = true
    end
    return comments
  end

  ---Add the thread state to the comments.
  ---
  --- A failure of the GraphQL call does not stop the review. The comments
  --- keep the field `thread_error`, and |codeview.remote.load()| warns once.
  ---@param comments codeview.remote.Comment[]
  ---@param threads table[]?
  ---@param err codeview.Error?
  ---@return codeview.remote.Comment[]
  local function with_threads(comments, threads, err)
    if threads then
      M.join(comments, threads)
    else
      comments.thread_error = err
    end
    return comments
  end

  local thread_opts = { repo = opts.repo, number = opts.number, dir = opts.dir, host = api_opts.hostname }

  if not cb then
    local entries, err = gh.api_list(path, api_opts)
    if not entries then
      return nil, err
    end
    local comments = read(entries)
    return with_threads(comments, M.fetch_threads(thread_opts)), nil
  end

  gh.api_list(path, api_opts, function(entries, err)
    if not entries then
      cb(nil, err)
      return
    end
    local comments = read(entries)
    M.fetch_threads(thread_opts, function(threads, thread_err)
      cb(with_threads(comments, threads, thread_err), nil)
    end)
  end)
  return nil, nil
end

--- Store ------------------------------------------------------------------------

---Report whether a remote comment is the copy of a local comment.
---
--- A submit sends a local comment to the pull request and marks it as synced.
--- The comment then lives twice: in the session file and in the answer of the
--- review comments endpoint. A local comment with a `remote_id` is the copy
--- of the comment of GitHub with that id. Without a `remote_id`, the two
--- copies hold the same file, the same lines, the same side, and the same
--- text. With a review id on both sides, the two ids must be equal too.
---@param comment codeview.store.Comment Comment of the session file.
---@param entry codeview.remote.Comment Comment of GitHub.
---@return boolean same
function M.same(comment, entry)
  -- A comment with an id on GitHub is the copy of the comment with that id.
  if (comment.remote_id or "") ~= "" then
    return comment.remote_id == M.review_id(entry.id)
  end
  if not require("codeview.store").is_synced(comment) then
    return false
  end
  if comment.file ~= entry.file or comment.side ~= entry.side then
    return false
  end
  if comment.start_line ~= entry.start_line or comment.end_line ~= entry.end_line then
    return false
  end
  local held_id, entry_id = comment.review_id or "", entry.review_id or ""
  if held_id ~= "" and entry_id ~= "" and held_id ~= entry_id then
    return false
  end
  return vim.trim(comment.body or "") == vim.trim(entry.body or "")
end

---Drop the remote copies of the comments that a submit sent.
---
--- Without the call the diff and the overview show such a comment twice: once
--- as the local comment with the sync mark, once as the answer of GitHub.
---@param session codeview.Session Session that holds the local comments.
---@param comments codeview.remote.Comment[] Comments of GitHub.
---@return codeview.remote.Comment[] comments Comments that no local comment holds.
function M.dedupe(session, comments)
  local list = comments or {}
  local store = require("codeview.comments").store(session)
  if not store then
    return list
  end
  local out = {}
  for _, entry in ipairs(list) do
    local copy = false
    for _, comment in ipairs(store.comments) do
      if M.same(comment, entry) then
        copy = true
        break
      end
    end
    if not copy then
      out[#out + 1] = entry
    end
  end
  return out
end

---Keep the comments of one session.
---
--- The call drops every comment that a submit of this session sent, so that no
--- comment shows twice.
---@param session codeview.Session
---@param comments codeview.remote.Comment[]
---@return codeview.remote.Comment[] comments
function M.attach(session, comments)
  if type(session) ~= "table" or type(session.id) ~= "number" or session.closed then
    return {}
  end
  local held = stores[session.id]
  stores[session.id] = M.dedupe(session, comments or {})
  if not held then
    session:on_close(function(closed)
      stores[closed.id] = nil
      expanded[closed.id] = nil
    end)
  end
  events.emit("remote_loaded", { session = session.id })
  return stores[session.id]
end

---Comments of one session.
---@param session? codeview.Session Session to read. The active session by default.
---@return codeview.remote.Comment[] comments
function M.list(session)
  session = session or require("codeview.session").current()
  if not session then
    return {}
  end
  return stores[session.id] or {}
end

---Comments of one file.
---@param session codeview.Session
---@param file string Path of the file in the review.
---@return codeview.remote.Comment[] comments
function M.for_file(session, file)
  local out = {}
  for _, comment in ipairs(M.list(session)) do
    if comment.file == file then
      out[#out + 1] = comment
    end
  end
  return out
end

---Items of a list that cover one line of a file.
---@param list codeview.remote.Comment[]
---@param file string Path of the file in the review.
---@param side codeview.linemap.Side Side that holds the line.
---@param line integer Line in the file, from 1.
---@return codeview.remote.Comment[] items
local function covering(list, file, side, line)
  local out = {}
  for _, comment in ipairs(list) do
    if
      comment.file == file
      and comment.anchored ~= false
      and comment.side == side
      and comment.start_line <= line
      and line <= comment.end_line
    then
      out[#out + 1] = comment
    end
  end
  return out
end

---Comments that cover one line of a file.
---@param session codeview.Session
---@param file string Path of the file in the review.
---@param side codeview.linemap.Side Side that holds the line.
---@param line integer Line in the file, from 1.
---@return codeview.remote.Comment[] comments
function M.at(session, file, side, line)
  return covering(M.list(session), file, side, line)
end

---Threads of one session.
---
--- GitHub sets `in_reply_to_id` of every reply to the first comment of the
--- thread, so the comments with the same `reply_to or id` form one thread.
--- The comments of a thread are oldest first, by `created_at`, then by id.
--- The thread takes the anchor of its first comment.
---@param session? codeview.Session Session to read. The active session by default.
---@return codeview.remote.Thread[] threads Oldest first.
function M.threads(session)
  local groups, keys = {}, {}
  for _, comment in ipairs(M.list(session)) do
    local key = comment.reply_to or comment.id
    if not groups[key] then
      groups[key] = {}
      keys[#keys + 1] = key
    end
    local list = groups[key]
    list[#list + 1] = comment
  end

  ---@param a codeview.remote.Comment
  ---@param b codeview.remote.Comment
  ---@return boolean
  local function older(a, b)
    if (a.created_at or 0) ~= (b.created_at or 0) then
      return (a.created_at or 0) < (b.created_at or 0)
    end
    return a.id < b.id
  end

  local out = {}
  for _, key in ipairs(keys) do
    local list = groups[key]
    table.sort(list, older)
    local root = list[1]
    local state = nil
    for _, comment in ipairs(list) do
      state = state or comment.thread
    end
    out[#out + 1] = {
      root = root,
      comments = list,
      id = state and state.id or nil,
      resolved = state ~= nil and state.resolved,
      resolved_by = state and state.resolved_by or "",
      can_resolve = state ~= nil and state.can_resolve,
      can_unresolve = state ~= nil and state.can_unresolve,
      can_reply = state ~= nil and state.can_reply,
      file = root.file,
      start_line = root.start_line,
      end_line = root.end_line,
      side = root.side,
      outdated = root.outdated,
      anchored = root.anchored,
      hunk = root.hunk,
    }
  end
  table.sort(out, function(a, b)
    return older(a.root, b.root)
  end)
  return out
end

---Threads that cover one line of a file.
---@param session codeview.Session
---@param file string Path of the file in the review.
---@param side codeview.linemap.Side Side that holds the line.
---@param line integer Line in the file, from 1.
---@return codeview.remote.Thread[] threads
function M.threads_at(session, file, side, line)
  return covering(M.threads(session), file, side, line)
end

---Items of every source that cover one line of a file.
---@param session codeview.Session
---@param file string Path of the file in the review.
---@param side codeview.linemap.Side Side that holds the line.
---@param line integer Line in the file, from 1.
---@return { source: codeview.remote.Source, item: codeview.remote.Comment }[] found In the order of the sources.
function M.items_at(session, file, side, line)
  local out = {}
  for _, source in ipairs(M.sources) do
    for _, item in ipairs(covering(source.list(session), file, side, line)) do
      out[#out + 1] = { source = source, item = item }
    end
  end
  return out
end

---Drop the comments of one session.
---@param session codeview.Session
---@return boolean removed False when the session held no comments.
function M.clear(session)
  if type(session) ~= "table" or stores[session.id] == nil then
    return false
  end
  stores[session.id] = nil
  events.emit("remote_loaded", { session = session.id })
  return true
end

---Read the review comments of a pull request session and keep them.
---
--- The call runs in the background. A failure reaches the user as one
--- notification, because the review itself works without the remote comments.
--- A fetch that stops at the limit also gives one warning, because the
--- newest comments are missing.
---@param session codeview.Session Session of a pull request.
---@param opts? { repo?: string, number?: integer, max?: integer, dir?: string, host?: string, silent?: boolean }
---@param cb? fun(comments: codeview.remote.Comment[]?, err: codeview.Error?)
---@return boolean started False without a pull request.
function M.load(session, opts, cb)
  opts = opts or {}
  local info = require("codeview.pr").current(session)
  local repo = opts.repo or (info and info.repo) or ""
  local number = opts.number or (info and info.number) or nil
  local host = opts.host or gh.host(info and info.url)
  if repo == "" or type(number) ~= "number" then
    local err = errors.new(errors.codes.INVALID_ARG, "the session does not review a pull request")
    if not opts.silent then
      notify.warn("cannot read the review comments: " .. tostring(err))
    end
    if cb then
      cb(nil, err)
    end
    return false
  end

  M.fetch({ repo = repo, number = number, max = opts.max, dir = opts.dir, host = host }, function(comments, err)
    if not comments then
      if not opts.silent then
        notify.warn("cannot read the review comments: " .. tostring(err))
      end
      if cb then
        cb(nil, err)
      end
      return
    end
    if comments.thread_error and not opts.silent then
      notify.warn(
        "cannot read the review threads: "
          .. tostring(comments.thread_error)
          .. ". The review shows the comments without the thread state"
      )
    end
    if comments.truncated and not opts.silent then
      notify.warn(
        string.format(
          "the pull request holds more review comments than the fetch reads. "
            .. "The review shows the oldest %d. Raise github.max_comments to read more",
          #comments
        )
      )
    end
    if session:is_active() then
      M.attach(session, comments)
    end
    if cb then
      cb(comments, nil)
    end
  end)
  return true
end

--- Decoration -------------------------------------------------------------------

---Sign text that fits the sign column: at most two cells.
---@param text string? Value of a sign option.
---@return string text Empty when the option holds no sign.
function M.sign_text(text)
  text = text or ""
  while vim.fn.strdisplaywidth(text) > 2 do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text
end

---Sign text of a remote comment.
---@return string text Empty when the option holds no sign.
function M.sign()
  return M.sign_text(config.get().comments.remote_sign)
end

---Text of the line range of a comment.
---@param comment codeview.remote.Comment
---@return string
local function range_text(comment)
  if comment.start_line == comment.end_line then
    return "L" .. comment.start_line
  end
  return string.format("L%d-%d", comment.start_line, comment.end_line)
end

---Header line of one remote comment.
---@param comment codeview.remote.Comment
---@return string
function M.header(comment)
  local text = string.format(
    "%s %s (%s)",
    comment.author ~= "" and ("@" .. comment.author) or "remote",
    range_text(comment),
    comment.side
  )
  if comment.outdated then
    text = text .. " · outdated"
  end
  return text
end

---Text of the reactions of one comment, for example `👍 2  🎉 1`.
---@param reactions codeview.remote.Reaction[]?
---@return string text Empty without a reaction.
function M.reactions_text(reactions)
  local parts = {}
  for _, kind in ipairs(M.reaction_kinds) do
    for _, reaction in ipairs(reactions or {}) do
      if reaction.content == kind.content and reaction.count > 0 then
        parts[#parts + 1] = kind.emoji .. " " .. reaction.count
      end
    end
  end
  return table.concat(parts, "  ")
end

---Text of a number of comments.
---@param count integer
---@return string
local function comment_count(count)
  return string.format("%d %s", count, count == 1 and "comment" or "comments")
end

---Header of the first comment of a thread, for example
---`@alice L12 (new) · outdated · ✓ resolved`.
---@param thread codeview.remote.Thread
---@return string
function M.thread_header(thread)
  local text = M.header(thread.root)
  if thread.resolved then
    text = text .. " · ✓ resolved"
  end
  return text
end

---Id of the first comment of a thread, as the `reply_to` field of a local
---reply holds it.
---
--- GitHub sets `in_reply_to_id` of every reply to the first comment, so the
--- id stays the same when the session holds no copy of the first comment.
---@param thread codeview.remote.Thread
---@return string id
function M.thread_key(thread)
  return M.review_id(thread.root.reply_to or thread.root.id)
end

---Thread of one session with a key of |codeview.remote.thread_key()|.
---@param session codeview.Session
---@param key string
---@return codeview.remote.Thread? thread
function M.thread_by_key(session, key)
  for _, thread in ipairs(M.threads(session)) do
    if M.thread_key(thread) == key then
      return thread
    end
  end
  return nil
end

---Name of the thread that a reply answers, for a summary.
---@param session codeview.Session
---@param key string `reply_to` field of a local reply.
---@return string text `@author` of the first comment, or `#<id>` when the session does not hold the thread.
function M.reply_target(session, key)
  local thread = M.thread_by_key(session, key)
  if thread and (thread.root.author or "") ~= "" then
    return "@" .. thread.root.author
  end
  return "#" .. key
end

---Local replies of the session to one thread, oldest first.
---@param session codeview.Session
---@param thread codeview.remote.Thread
---@return codeview.store.Comment[] replies
function M.local_replies(session, thread)
  local store = require("codeview.comments").store(session)
  local key = M.thread_key(thread)
  local out = {}
  for _, comment in ipairs(store and store.comments or {}) do
    if (comment.reply_to or "") == key then
      out[#out + 1] = comment
    end
  end
  table.sort(out, function(a, b)
    if a.created_at ~= b.created_at then
      return a.created_at < b.created_at
    end
    return a.id < b.id
  end)
  return out
end

---Report whether the user expanded a resolved thread.
---@param session codeview.Session
---@param thread codeview.remote.Thread
---@return boolean expanded
function M.is_expanded(session, thread)
  return (expanded[session.id] or {})[M.thread_key(thread)] == true
end

---Show every comment of a resolved thread, or only its header line.
---@param session codeview.Session
---@param thread codeview.remote.Thread
---@param on boolean True shows every comment.
function M.set_expanded(session, thread, on)
  expanded[session.id] = expanded[session.id] or {}
  expanded[session.id][M.thread_key(thread)] = on or nil
end

---Report whether a thread shows only its header line.
---
--- A resolved thread shows its header line, until the user expands it.
---@param session codeview.Session
---@param thread codeview.remote.Thread
---@return boolean collapsed
function M.collapsed(session, thread)
  return thread.resolved and not M.is_expanded(session, thread)
end

---Sections of the box of one thread.
---
--- The first comment of the thread takes the first section. Each reply takes
--- one more section. A body ends with the reactions of the comment. A
--- resolved thread shows one header line only, for example
--- `✓ resolved · @alice L12 (new) · 3 comments`.
---
--- A local reply to the thread is a section too, in the order of time, with
--- the header of a local comment and ` · draft` while no send took it. The
--- reply that the editor has open shows no section.
---@param session codeview.Session
---@param thread codeview.remote.Thread
---@return codeview.box.Section[] sections
function M.thread_sections(session, thread)
  local replies = M.local_replies(session, thread)
  if M.collapsed(session, thread) then
    return {
      {
        header = "✓ resolved · " .. M.header(thread.root) .. " · " .. comment_count(#thread.comments + #replies),
        header_hl = "CodeViewRemoteResolved",
      },
    }
  end
  local marks = require("codeview.marks")
  local store_mod = require("codeview.store")
  local editing = marks.editing()
  local entries = {}
  for index, comment in ipairs(thread.comments) do
    entries[#entries + 1] = {
      time = comment.created_at or 0,
      order = index,
      section = {
        header = index == 1 and M.thread_header(thread)
          or ((comment.author or "") ~= "" and ("@" .. comment.author) or "remote"),
        header_hl = "CodeViewRemoteHeader",
        body = comment.body,
        body_hl = "CodeViewRemote",
        footer = M.reactions_text(comment.reactions),
        footer_hl = "CodeViewRemoteReactions",
      },
    }
  end
  for index, reply in ipairs(replies) do
    if editing ~= reply.id then
      entries[#entries + 1] = {
        time = reply.created_at or 0,
        order = #thread.comments + index,
        section = {
          header = marks.header_text(reply) .. (store_mod.is_synced(reply) and "" or " · draft"),
          header_hl = reply.state == "resolved" and "CodeViewCommentResolved" or "CodeViewCommentHeader",
          body = reply.body,
          body_hl = "CodeViewComment",
        },
      }
    end
  end
  -- The first comment of the thread stays on top.
  table.sort(entries, function(a, b)
    if (a.order == 1) ~= (b.order == 1) then
      return a.order == 1
    end
    if a.time ~= b.time then
      return a.time < b.time
    end
    return a.order < b.order
  end)
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = entry.section
  end
  return out
end

---Boxes of the threads of one file.
---@param session codeview.Session
---@param file string Path of the file in the review.
---@return codeview.remote.Block[] blocks
function M.thread_blocks(session, file)
  local out = {}
  for _, thread in ipairs(M.threads(session)) do
    if thread.file == file then
      out[#out + 1] = {
        anchor = thread,
        items = thread.comments,
        time = thread.root.created_at or 0,
        id = tostring(thread.root.id),
        sections = function()
          return M.thread_sections(session, thread)
        end,
      }
    end
  end
  return out
end

---@class codeview.remote.Source
---@field name string Name of the source, for example "remote". The overview keys its lines with it.
---@field ns integer Namespace of the extmarks of the source.
---@field list fun(session: codeview.Session): codeview.remote.Comment[] Items of a session.
---@field sign fun(): string Sign text of an item.
---@field header fun(item: codeview.remote.Comment): string Header line of an item.
---@field hl { body: string, header: string, sign: string, outdated: string, box: string, border: string } Highlight groups.
---@field section fun(count: integer): string Title of the section of the overview.
---@field who fun(item: codeview.remote.Comment): string Short text after the lines of an item in the overview.
---@field read_only string Message for a key that would change an item.
---@field blocks? fun(session: codeview.Session, file: string): codeview.remote.Block[] Boxes of one file. Without it, each item of the file is one box.

---@class codeview.remote.Block
---@field anchor { file: string, start_line: integer, end_line: integer, side: codeview.linemap.Side, outdated: boolean?, anchored: boolean? } Lines of the box.
---@field items table[] Items that the box holds.
---@field time number Time of the first item, in seconds since the epoch.
---@field id string Id for the order of two boxes of the same time.
---@field sections fun(): codeview.box.Section[] Sections of the box.

---Sources of read-only items, in the order of the overview.
---
--- The comments of GitHub come first. |codeview.remote.register()| adds a
--- source.
---@type codeview.remote.Source[]
M.sources = {
  {
    name = "remote",
    ns = M.ns,
    list = function(session)
      return M.list(session)
    end,
    sign = function()
      return M.sign()
    end,
    header = function(item)
      return M.header(item)
    end,
    hl = {
      body = "CodeViewRemote",
      header = "CodeViewRemoteHeader",
      sign = "CodeViewRemoteSign",
      outdated = "CodeViewRemoteOutdated",
      box = "CodeViewRemoteBox",
      border = "CodeViewRemoteBorder",
    },
    section = function(count)
      return string.format("%d remote %s", count, count == 1 and "comment" or "comments")
    end,
    who = function(item)
      return (item.author or "") ~= "" and ("@" .. item.author) or ""
    end,
    read_only = "the review comments of GitHub are read-only",
    blocks = function(session, file)
      return M.thread_blocks(session, file)
    end,
  },
}

---Add a source of read-only items, or replace the source with the same name.
---@param source codeview.remote.Source
function M.register(source)
  for index, held in ipairs(M.sources) do
    if held.name == source.name then
      M.sources[index] = source
      return
    end
  end
  M.sources[#M.sources + 1] = source
end

---Source with a name.
---@param name string?
---@return codeview.remote.Source? source
function M.source(name)
  for _, source in ipairs(M.sources) do
    if source.name == name then
      return source
    end
  end
  return nil
end

---Find the lines of an outdated item in the file of a view.
---
--- An item that the call finds gets the lines of the current file and counts
--- as anchored from then on. The `hunk` of a comment of GitHub holds the last
--- lines of its `diff_hunk`. The `hunk` of a pr-agent suggestion holds its
--- `existing_code`.
---@param view codeview.view.State
---@param comment codeview.remote.Comment
local function relocate(view, comment)
  if comment.anchored ~= false or not comment.hunk or type(view.diff) ~= "table" then
    return
  end
  local lines = comment.side == "old" and view.diff.old_lines or view.diff.new_lines
  local last = M.locate(comment.hunk, lines or {})
  if not last then
    return
  end
  local span = comment.end_line - comment.start_line
  comment.end_line = last
  comment.start_line = math.max(last - span, 1)
  comment.anchored = true
end

---Boxes of the items of one source in one file.
---@param session codeview.Session
---@param source codeview.remote.Source
---@param items codeview.remote.Comment[] Items of the file.
---@param file string Path of the file in the review.
---@return codeview.remote.Block[] blocks
local function blocks_of(session, source, items, file)
  if source.blocks then
    return source.blocks(session, file)
  end
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = {
      anchor = item,
      items = { item },
      time = item.created_at or 0,
      id = tostring(item.id),
      sections = function()
        return {
          { header = source.header(item), header_hl = source.hl.header, body = item.body, body_hl = source.hl.body },
        }
      end,
    }
  end
  return out
end

---Collect the items of one source on the file that a view shows.
---
--- The call first looks for the lines of each outdated item in the current
--- file. Each box that the render holds a row for gives one entry for
--- |codeview.stack|.
---@param view codeview.view.State
---@param source codeview.remote.Source
---@param display "virtual"|"float"
---@return codeview.stack.Entry[] entries
---@return integer count Number of items that the view shows.
---@return integer hidden Number of items that the render holds no row for.
function M.collect(view, source, display)
  local out, count, hidden = {}, 0, 0
  local items = {}
  for _, item in ipairs(source.list(view.session)) do
    if item.file == view.path then
      relocate(view, item)
      items[#items + 1] = item
    end
  end
  local comments_mod = require("codeview.comments")
  local cfg = config.get().comments
  for _, block in ipairs(blocks_of(view.session, source, items, view.path)) do
    local size = #block.items
    local rows, buf = {}, view.buf
    if block.anchor.anchored ~= false then
      rows, buf = comments_mod.rows(view, block.anchor)
    end
    if #rows == 0 or not api.nvim_buf_is_valid(buf) then
      hidden = hidden + size
    else
      count = count + size
      out[#out + 1] = {
        buf = buf,
        rows = rows,
        side = block.anchor.side,
        ns = source.ns,
        priority = 190,
        sign = source.sign(),
        sign_hl = block.anchor.outdated and source.hl.outdated or source.hl.sign,
        box = display == "virtual" and function(width)
          return box.lines({
            sections = block.sections(),
            box_hl = source.hl.box,
            border_hl = source.hl.border,
            border = cfg.border,
            width = width,
          })
        end or nil,
        time = block.time,
        id = block.id,
      }
    end
  end
  return out, count, hidden
end

---Draw the read-only items of every source on the file that a view shows.
---
--- |codeview.stack| draws every box of the view, the local comments too.
---@param view? codeview.view.State View to decorate. The open file by default.
---@return integer count Number of items that the view shows.
---@return integer hidden Number of items that the render holds no row for.
function M.decorate(view)
  view = view or require("codeview.view").current()
  if not view or not api.nvim_buf_is_valid(view.buf) then
    return 0, 0
  end
  local result = require("codeview.stack").decorate(view)
  return result.remote.count, result.remote.hidden
end

---Extmarks of the remote comments in one buffer.
---@param buf integer Buffer of a diff.
---@return table[] marks Result of `nvim_buf_get_extmarks()`, with details.
function M.marks(buf)
  if not api.nvim_buf_is_valid(buf) then
    return {}
  end
  return api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, { details = true })
end

-- The diff follows the comments that arrive from GitHub and the results of
-- pr-agent. Both come in after the session opens.
events.on(events.remote, function()
  M.decorate()
end)

return M
