---@brief The review comments that a pull request already holds.
---
--- A pull request review starts with the comments of the other reviewers. This
--- module reads them with `gh api`, maps every comment to a file and a line,
--- and shows them in the diff next to the local anchors.
---
--- A remote comment is read-only. It lives on GitHub, not in the session file
--- of |codeview.store|, so the edit keys and the delete key do not touch it.
--- The extmarks use their own namespace, so the two kinds of comment never
--- overwrite each other.
---
--- A comment that a submit of this session sent lives twice: on GitHub and in
--- the session file. The module drops the copy of GitHub, so the review shows
--- the local comment alone, with its sync mark.
---
--- GitHub reports the position of a comment in three ways, and the mapping
--- takes the first one that answers:
---
--- 1. `line` and `start_line`: the lines of the newest version of the diff.
--- 2. `original_line` and `original_start_line`: the lines of the version that
---    the author wrote the comment on. A comment that a later push moved holds
---    these fields only, and the display marks it as outdated.
--- 3. The last line of `diff_hunk`: the hunk that GitHub sends with every
---    comment ends at the commented line.
---
--- `side` is LEFT for the old side of the diff and RIGHT for the new side.

local config = require("codeview.config")
local errors = require("codeview.error")
local events = require("codeview.events")
local gh = require("codeview.gh")
local highlight = require("codeview.highlight")
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
---@field reply_to integer? Id of the comment that this one answers.

---Comments of each open session, by session id.
---@type table<integer, codeview.remote.Comment[]>
local stores = {}

--- Mapping ---------------------------------------------------------------------

---Side of the diff of a GitHub `side` field.
---@param text string? LEFT or RIGHT.
---@return codeview.linemap.Side side
function M.side(text)
  return tostring(text or ""):upper() == "LEFT" and "old" or "new"
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

---Anchor of one comment of the GitHub API.
---@param entry table Entry of `GET /repos/{owner}/{repo}/pulls/{n}/comments`.
---@return codeview.remote.Anchor? anchor Nil when the entry holds no position.
function M.anchor(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local side = M.side(entry.side)

  local last = tonumber(entry.line)
  local first = tonumber(entry.start_line)
  local outdated = false
  if not last then
    last = tonumber(entry.original_line)
    first = tonumber(entry.original_start_line)
    outdated = last ~= nil
  end
  if not last then
    last = M.hunk_line(entry.diff_hunk, side)
    outdated = last ~= nil
  end
  if not last then
    return nil
  end

  first = first or last
  if first > last then
    first, last = last, first
  end
  return {
    start_line = math.max(math.floor(first), 1),
    end_line = math.max(math.floor(last), 1),
    side = side,
    outdated = outdated,
  }
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
        reply_to = reply and math.floor(reply),
      }
    end
  end
  return out
end

--- Fetch -----------------------------------------------------------------------

---Read the review comments of one pull request.
---
--- `dir` names the directory that `gh` runs in. It decides the host that `gh`
--- talks to, so a GitHub Enterprise repository needs it.
---@param opts { repo: string, number: integer, max?: integer, dir?: string } `repo` is `owner/name`.
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
  local api_opts = { max = opts.max or config.get().github.max_comments, cwd = opts.dir }

  if not cb then
    local entries, err = gh.api_list(path, api_opts)
    if not entries then
      return nil, err
    end
    return M.parse(entries), nil
  end

  gh.api_list(path, api_opts, function(entries, err)
    if not entries then
      cb(nil, err)
      return
    end
    cb(M.parse(entries), nil)
  end)
  return nil, nil
end

--- Store ------------------------------------------------------------------------

---Report whether a remote comment is the copy of a local comment.
---
--- A submit sends a local comment to the pull request and marks it as synced.
--- The comment then lives twice: in the session file and in the answer of the
--- review comments endpoint. The two copies hold the same file, the same
--- lines, the same side, and the same text. With a review id on both sides,
--- the two ids must be equal too.
---@param comment codeview.store.Comment Comment of the session file.
---@param entry codeview.remote.Comment Comment of GitHub.
---@return boolean same
function M.same(comment, entry)
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

---Comments that cover one line of a file.
---@param session codeview.Session
---@param file string Path of the file in the review.
---@param side codeview.linemap.Side Side that holds the line.
---@param line integer Line in the file, from 1.
---@return codeview.remote.Comment[] comments
function M.at(session, file, side, line)
  local out = {}
  for _, comment in ipairs(M.for_file(session, file)) do
    if comment.side == side and comment.start_line <= line and line <= comment.end_line then
      out[#out + 1] = comment
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
---@param session codeview.Session Session of a pull request.
---@param opts? { repo?: string, number?: integer, max?: integer, dir?: string, silent?: boolean }
---@param cb? fun(comments: codeview.remote.Comment[]?, err: codeview.Error?)
---@return boolean started False without a pull request.
function M.load(session, opts, cb)
  opts = opts or {}
  local info = require("codeview.pr").current(session)
  local repo = opts.repo or (info and info.repo) or ""
  local number = opts.number or (info and info.number) or nil
  if repo == "" or type(number) ~= "number" then
    local err = errors.new(errors.codes.INVALID_ARG, "the session does not review a pull request")
    if not opts.silent then
      vim.notify("codeview: cannot read the review comments: " .. tostring(err), vim.log.levels.WARN)
    end
    if cb then
      cb(nil, err)
    end
    return false
  end

  M.fetch({ repo = repo, number = number, max = opts.max, dir = opts.dir }, function(comments, err)
    if not comments then
      if not opts.silent then
        vim.notify("codeview: cannot read the review comments: " .. tostring(err), vim.log.levels.WARN)
      end
      if cb then
        cb(nil, err)
      end
      return
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

---Sign text of a remote comment.
---@return string text Empty when the option holds no sign.
function M.sign()
  local text = config.get().comments.remote_sign or ""
  while vim.fn.strdisplaywidth(text) > 2 do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text
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
  if comment.reply_to then
    text = text .. " · reply"
  end
  if comment.outdated then
    text = text .. " · outdated"
  end
  return text .. " · read-only"
end

---Virtual lines of one remote comment.
---@param comment codeview.remote.Comment
---@return string[][][] lines Chunks of every virtual line.
local function virt_lines(comment)
  local prefix = M.sign() .. " "
  local out = { { { prefix .. M.header(comment), "CodeViewRemoteHeader" } } }
  for _, line in ipairs(vim.split(comment.body, "\n", { plain = true })) do
    out[#out + 1] = { { prefix .. line, "CodeViewRemote" } }
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

---Place the marks of one remote comment.
---@param view codeview.view.State
---@param comment codeview.remote.Comment
---@param display "virtual"|"float"
---@return boolean placed False when the render hides the lines of the comment.
local function place(view, comment, display)
  local comments_mod = require("codeview.comments")
  local rows, buf = comments_mod.rows(view, comment)
  if #rows == 0 or not api.nvim_buf_is_valid(buf) then
    return false
  end

  local sign = M.sign()
  for _, row in ipairs(rows) do
    local opts = {
      sign_text = sign ~= "" and sign or nil,
      sign_hl_group = comment.outdated and "CodeViewRemoteOutdated" or "CodeViewRemoteSign",
      priority = 190,
    }
    if display == "virtual" and row == rows[#rows] then
      opts.virt_lines = virt_lines(comment)
      opts.virt_lines_above = false
    end
    local ok = pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, opts)
    if not ok then
      opts.sign_text, opts.sign_hl_group = nil, nil
      pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, opts)
    end
    local other = opts.virt_lines and comments_mod.mirror(view, comment.side) or nil
    if other then
      pcall(api.nvim_buf_set_extmark, other, M.ns, row - 1, 0, {
        virt_lines = blank_lines(#opts.virt_lines),
        virt_lines_above = false,
        priority = 190,
      })
    end
  end
  return true
end

---Draw the remote comments of the file that a view shows.
---
--- The call only writes extmarks, in the namespace of this module. The local
--- comments of |codeview.comments| keep their own marks.
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

  local display = config.get().comments.display
  local count, hidden = 0, 0
  for _, comment in ipairs(M.for_file(view.session, view.path)) do
    if place(view, comment, display) then
      count = count + 1
    else
      hidden = hidden + 1
    end
  end
  return count, hidden
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

-- The diff follows the comments that arrive from GitHub. The fetch runs after
-- the session opens, so the marks come in when the answer is there.
events.on(events.remote, function()
  M.decorate()
end)

return M
