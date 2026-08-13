---@brief Send the comments of a session to a GitHub pull request.
---
--- `:CodeViewSubmit` posts every comment of the session that no submit sent
--- yet. The comments go out as one review, with `POST /pulls/<n>/reviews`, so
--- the pull request shows one entry with all the lines, and not one entry per
--- comment.
---
--- The post is always explicit. The call shows a summary first: the number of
--- comments, the event, and every comment that the diff of the pull request
--- does not hold. Nothing reaches GitHub before the user confirms that
--- summary. No autocommand, no save, and no keymap posts by itself.
---
--- The position of a comment comes from a line map of the diff. The map runs
--- with the diff settings of git, because GitHub accepts only the lines of the
--- diff of git. It answers whether the pull request diff holds a line of a
--- side:
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
--- `synced_at` and `review_id` per comment, and a comment gets them only after
--- the API confirms the post. A failed post writes nothing, so a second
--- submit sends the same comments again and nothing is lost.

local diff_mod = require("codeview.diff")
local errors = require("codeview.error")
local events = require("codeview.events")
local gh = require("codeview.gh")
local inline = require("codeview.inline")
local linemap = require("codeview.linemap")
local session_mod = require("codeview.session")
local store_mod = require("codeview.store")

local api = vim.api

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
--- The value decides which lines a comment can reach. It is the context length
--- of the GitHub diff, not the `diff.context` option of the plugin.
---@type integer
M.context = 3

---Settings of the diff that the position mapping runs on.
---
--- GitHub validates every position against the diff of git, and git runs the
--- myers algorithm with the indent heuristic. The display of the review runs
--- the histogram algorithm, which reads better but puts some changes on other
--- lines. A position of that diff can name a line that the diff of git does
--- not hold, and the API then rejects the whole review. The map and the
--- coverage of a submit take the settings of git for that reason.
---
--- `max_lines = 0` removes the line limit of the display. A comment on a large
--- file must map, whether the reader rendered that diff or not.
---@type codeview.diff.Opts
M.diff_opts = { algorithm = "myers", indent_heuristic = true, max_lines = 0 }

---@class codeview.submit.Position
---@field path string Path of the file in the pull request.
---@field side "LEFT"|"RIGHT" Side of the diff that holds the last line.
---@field line integer Last line of the comment, in the file of that side.
---@field start_line integer? First line of a comment over more than one line.
---@field start_side "LEFT"|"RIGHT"? Side of the first line. It is `side`.

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

---Report a message of the submit flow.
---@param message string
---@param level integer? A `vim.log.levels` value. INFO by default.
local function notify(message, level)
  vim.notify("codeview: " .. message, level or vim.log.levels.INFO)
end

---Text of an error, with every line that the server sent.
---
--- |codeview.Error| shows one line. GitHub answers a bad position with more
--- than one line, and every line names a comment that it did not take, so the
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

---Return a value in the sync form, or send it to the callback.
---@generic T
---@param cb? fun(value: T?, err: codeview.Error?)
---@param value any?
---@param err codeview.Error?
---@return any?, codeview.Error?
local function done(cb, value, err)
  if not cb then
    return value, err
  end
  vim.schedule(function()
    cb(value, err)
  end)
  return nil, nil
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

---Side of the review API of a side of the diff.
---@param side codeview.linemap.Side
---@return "LEFT"|"RIGHT"
function M.api_side(side)
  return side == "old" and "LEFT" or "RIGHT"
end

---@class codeview.submit.Block
---@field from integer First line of the block, in the file of the side.
---@field to integer Last line of the block, in the file of the side.

---@class codeview.submit.Coverage
---@field old codeview.submit.Block[] Blocks of the old side, in file order.
---@field new codeview.submit.Block[] Blocks of the new side, in file order.

---Blocks of one side that the diff of the pull request holds.
---
--- GitHub shows `M.context` unchanged lines around each change. Two changes
--- that are near each other give one block, and the lines between them stay in
--- the diff. A line outside every block is not in the diff, and the review API
--- rejects a comment on it.
---@param diff codeview.diff.File Diff of one file, with the hunks of the file.
---@param ctx integer Number of unchanged lines around a change.
---@param side codeview.linemap.Side Side of the diff.
---@return codeview.submit.Block[] blocks
local function blocks_of(diff, ctx, side)
  local total = #(side == "old" and diff.old_lines or diff.new_lines)
  local out = {}
  for _, hunk in ipairs(diff.hunks or {}) do
    local start = side == "old" and hunk.old_start or hunk.new_start
    local count = side == "old" and hunk.old_count or hunk.new_count
    -- A hunk without a line of this side sits between two lines of it, so the
    -- context starts one line later.
    local first = count > 0 and start or start + 1
    local last = count > 0 and start + count - 1 or start
    local from = math.max(first - ctx, 1)
    local to = math.min(last + ctx, total)
    if to >= from then
      local previous = out[#out]
      -- Two blocks without a line between them are one block of the diff.
      if previous and from <= previous.to + 1 then
        previous.to = math.max(previous.to, to)
      else
        out[#out + 1] = { from = from, to = to }
      end
    end
  end
  return out
end

---Lines that the diff of the pull request holds, per side.
---
--- The blocks come from the hunks and not from the render of the review. The
--- render keeps a section of one line, because a filler row costs as much
--- screen space as the line itself. GitHub leaves that line out, so a comment
--- on it needs a report and not a post.
---@param diff codeview.diff.File Diff of one file.
---@param ctx integer? Number of unchanged lines around a change. |codeview.submit|.context by default.
---@return codeview.submit.Coverage coverage
function M.coverage(diff, ctx)
  local length = math.max(math.floor(tonumber(ctx) or M.context), 0)
  if type(diff) ~= "table" then
    return { old = {}, new = {} }
  end
  return { old = blocks_of(diff, length, "old"), new = blocks_of(diff, length, "new") }
end

---Number of the block that holds one line.
---@param coverage codeview.submit.Coverage? Blocks of the diff.
---@param side codeview.linemap.Side Side of the line.
---@param line integer Line in the file of the side.
---@return integer? index Nil without a coverage, or when no block holds the line.
function M.block_of(coverage, side, line)
  if type(coverage) ~= "table" then
    return nil
  end
  for index, block in ipairs(coverage[side] or {}) do
    if line >= block.from and line <= block.to then
      return index
    end
  end
  return nil
end

---Map one comment onto the diff of its file.
---
--- The map comes from the render of the diff, with the context length of
--- GitHub. A line that the map does not hold is outside the diff of the pull
--- request, and the API rejects a comment on it.
---
--- The render shows one line more than GitHub around a short hidden section,
--- so the call also asks the coverage of the file. Without a coverage the call
--- takes the render alone.
---@param map codeview.LineMap Map of the diff of the file.
---@param comment codeview.store.Comment Comment of the session.
---@param coverage codeview.submit.Coverage? Blocks that the diff of the pull request holds.
---@return codeview.submit.Position? position Nil when the diff does not hold the lines.
---@return string? reason One line that says why the comment does not map.
function M.position(map, comment, coverage)
  if not linemap.is(map) then
    return nil, "the file has no diff"
  end
  local side = comment.side == "old" and "old" or "new"

  ---Reason of a line that the diff does not hold.
  ---@param line integer
  ---@return string
  local function gone(line)
    return string.format("the diff of the pull request does not hold %s line %d", side, line)
  end

  local last_row = map:buf_row(comment.end_line, side)
  local last_block = M.block_of(coverage, side, comment.end_line)
  if not last_row or (coverage and not last_block) then
    return nil, gone(comment.end_line)
  end
  if comment.start_line < comment.end_line then
    local first_row = map:buf_row(comment.start_line, side)
    local first_block = M.block_of(coverage, side, comment.start_line)
    if not first_row or (coverage and not first_block) then
      return nil, gone(comment.start_line)
    end
    if first_block ~= last_block then
      return nil, "the diff of the pull request breaks the line range"
    end
    for row = first_row, last_row do
      -- A filler row stands for a section that the diff does not show, so the
      -- line range is not one block of the diff.
      if map:kind(row) == "filler" then
        return nil, "the diff of the pull request breaks the line range"
      end
    end
  end

  local api_side = M.api_side(side)
  ---@type codeview.submit.Position
  local position = { path = comment.file, side = api_side, line = comment.end_line }
  if comment.start_line < comment.end_line then
    position.start_line = comment.start_line
    position.start_side = api_side
  end
  return position, nil
end

---Order two comments of one file: by line, then by side, then by age.
---@param a codeview.store.Comment
---@param b codeview.store.Comment
---@return boolean
local function before(a, b)
  if a.start_line ~= b.start_line then
    return a.start_line < b.start_line
  end
  if a.side ~= b.side then
    return a.side == "old"
  end
  if a.created_at ~= b.created_at then
    return a.created_at < b.created_at
  end
  return a.id < b.id
end

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

---@class codeview.submit.FileDiff
---@field map codeview.LineMap Map of the render of the diff.
---@field coverage codeview.submit.Coverage Blocks that the diff of the pull request holds.

---Line map and coverage of the diff of one file of the session.
---@param session codeview.Session
---@param file codeview.vcs.FileChange
---@param cb? fun(entry: codeview.submit.FileDiff?, reason: string?)
---@return codeview.submit.FileDiff? entry
---@return string? reason One line that says why the file has no map.
local function map_of(session, file, cb)
  local opts = vim.tbl_extend("force", { context = M.context }, M.diff_opts)

  ---@param diff codeview.diff.File?
  ---@param err codeview.Error?
  ---@return codeview.submit.FileDiff?, string?
  local function build(diff, err)
    if not diff then
      return nil, "cannot read the diff of the file: " .. tostring(err)
    end
    if diff.binary then
      return nil, "the file is binary, so the diff holds no line"
    end
    return { map = inline.build(diff, opts).map, coverage = M.coverage(diff, M.context) }, nil
  end

  if not cb then
    return build(diff_mod.for_file(session, file, opts))
  end
  diff_mod.for_file(session, file, opts, function(diff, err)
    cb(build(diff, err))
  end)
  return nil, nil
end

--- Plan --------------------------------------------------------------------

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

  local session = opts.session or session_mod.current()
  if not session or not session:is_active() then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "no review session"))
  end
  local info = require("codeview.pr").current(session)
  if not info then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the session does not review a pull request"))
  end
  if info.repo == "" then
    return done(cb, nil, errors.new(errors.codes.NOT_FOUND, "the pull request has no repository"))
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
  local store, store_err = require("codeview.comments").store(session)
  if not store then
    return done(cb, nil, store_err)
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
    skipped = {},
    synced = synced,
    total = #store.comments,
  }

  local by_file, paths = group(store:unsynced())

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
      local position, reason = M.position(entry.map, comment, entry.coverage)
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
    if not file then
      skip_file(path, "the pull request does not change this file")
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
      keep(map_of(session, file))
      return
    end
    map_of(session, file, function(entry, reason)
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
      comment_count(#plan.entries),
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
--- GitHub rejects a review without a body for the comment event and for the
--- request-changes event, so a plan without a body takes the fallback text.
---@param plan codeview.submit.Plan
---@return string body
function M.body(plan)
  local text = vim.trim(plan.body or "")
  if text == "" and M.needs_body[plan.event] then
    return M.fallback_body
  end
  return text
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

--- Post --------------------------------------------------------------------

---Id of a review of the answer of GitHub.
---@param review table?
---@return string id Empty when the answer holds no id.
local function review_id(review)
  local id = type(review) == "table" and review.id or nil
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
  local opts = {
    method = "POST",
    -- `--input -` sends the request body from standard input, so the nested
    -- comment list keeps its shape. `--field` cannot hold a list of objects.
    input = "-",
    stdin = vim.json.encode(M.payload(plan)),
    cwd = plan.dir,
  }
  return gh.api(path, opts, cb)
end

---Mark the comments of a plan as sent, and write the session file.
---
--- The call runs only after GitHub confirmed the post. A write error leaves
--- the comments marked in memory and reports the problem, because the review
--- is on GitHub already.
---@param plan codeview.submit.Plan
---@param review table? Answer of GitHub.
---@return integer count Number of comments that the call marked.
---@return codeview.Error? err Error of the write of the session file.
function M.apply(plan, review)
  local id = review_id(review)
  local time = os.time()
  local count = 0
  for _, entry in ipairs(plan.entries) do
    local comment = plan.store:mark_synced(entry.comment.id, { time = time, review_id = id })
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
    prompt = string.format("codeview: submit %s to PR #%d as", comment_count(#plan.entries), plan.pr.number),
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
      comment_count(#plan.entries),
      plan.pr.number,
      plan.event
    ),
  }, function(choice)
    cb(choice == "submit")
  end)
end

--- Command -----------------------------------------------------------------

---Send the comments of a session to the pull request.
---
--- The call collects the comments, asks for the event and for the text of the
--- review, shows the summary, and posts only after the user confirms it. A
--- failed post marks nothing, so every comment stays in the session file.
---@param opts? codeview.submit.Opts
---@param cb? fun(result: codeview.submit.Result?, err: codeview.Error?) Handler of the answer.
function M.run(opts, cb)
  opts = opts or {}
  local loud = opts.notify ~= false

  ---@param result codeview.submit.Result?
  ---@param err codeview.Error?
  local function finish(result, err)
    if err and loud then
      notify(M.error_text(err), vim.log.levels.ERROR)
    end
    if cb then
      cb(result, err)
    end
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
    notify(table.concat(lines, "\n"), vim.log.levels.WARN)
  end

  ---@param plan codeview.submit.Plan
  local function send(plan)
    M.post(plan, function(review, err)
      if not review then
        -- Nothing is marked, so every comment stays local and a later submit
        -- sends it again. The comments that do not map stay local too, and the
        -- report names them next to the error.
        report_skipped(plan)
        finish(nil, err)
        return
      end
      local count, save_err = M.apply(plan, review)
      if save_err and loud then
        notify(
          "the review is on GitHub, but the session file did not change: "
            .. tostring(save_err)
            .. ". Do not submit again",
          vim.log.levels.ERROR
        )
      end
      local url = type(review.html_url) == "string" and review.html_url or ""
      if loud then
        local message = string.format("%s went to PR #%d", comment_count(count), plan.pr.number)
        notify(url ~= "" and (message .. ": " .. url) or message)
      end
      report_skipped(plan)
      finish({ posted = count, skipped = #plan.skipped, cancelled = false, review = review, url = url }, nil)
    end)
  end

  M.plan(opts, function(plan, err)
    if not plan then
      finish(nil, err)
      return
    end
    if #plan.entries == 0 then
      if loud then
        local reason = "no comment to submit"
        if #plan.skipped > 0 then
          reason = "no comment maps to the diff of the pull request"
        elseif plan.synced > 0 then
          reason = "every comment went to the pull request already"
        end
        notify(reason)
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
            notify("the submit was cancelled. Nothing went to GitHub")
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
      ask_body(plan, with_body)
    end

    if opts.event then
      with_event(M.normalize_event(opts.event))
      return
    end
    ask_event(plan, with_event)
  end)
end

return M
