---@brief The diff of one file.
---
--- The module reads the two sides of a changed file from the backend and runs
--- |vim.diff()| on them. The result holds the lines of both sides and the list
--- of hunks. It holds no window and no buffer, so the tests read it without a
--- user interface.
---
--- The hunks hold only the changed lines. |vim.diff()| runs with a context
--- length of 0, so it keeps each change region separate. A larger context
--- length makes it merge two near changes and report the unchanged lines
--- between them as changed. The `diff.context` option stays in the result as
--- `context`, because the renderer adds the context lines itself.
---
--- A file with a NUL byte on one side is binary. The result then holds no
--- hunks, and the renderer shows a note.
---
--- The display runs the histogram algorithm, which reads better. `algorithm`
--- and `indent_heuristic` select the settings of git instead. |codeview.submit|
--- needs them, because GitHub accepts only the lines of the diff of git.
---
--- Two limits keep a large file fast. |codeview.diff.algorithm()| selects the
--- algorithm from the size of the two sides. `max_lines` stops the comparison
--- of a file that holds more lines than the reader wants to see. The result
--- then holds no hunk and the field `limited`, and the renderer shows a note.

local config = require("codeview.config")
local errors = require("codeview.error")

local M = {}

---@class codeview.diff.Hunk
---@field index integer Position of the hunk in the list, from 1.
---@field old_start integer Value of |vim.diff()|. With `old_count == 0` it is the line before the insert.
---@field old_count integer Number of old lines that the hunk removes.
---@field new_start integer Value of |vim.diff()|. With `new_count == 0` it is the line before the insert.
---@field new_count integer Number of new lines that the hunk adds.
---@field old_first integer First old line of the change. With `old_count == 0` it is the line after the insert point.
---@field new_first integer First new line of the change. With `new_count == 0` it is the line after the insert point.

---@class codeview.diff.File
---@field path string Path in the new revision. For a deletion it is the old path.
---@field old_path string Path in the old revision.
---@field status codeview.vcs.Status Status of the file in the range.
---@field old_rev string? Revision of the old side. Nil for an added file.
---@field new_rev string? Revision of the new side. Nil for a deleted file.
---@field old_lines string[] Lines of the old side, without the line breaks.
---@field new_lines string[] Lines of the new side, without the line breaks.
---@field hunks codeview.diff.Hunk[] Hunks, in file order.
---@field binary boolean True when one side holds a NUL byte.
---@field limited boolean True when the two sides hold more lines than `max_lines`.
---@field line_count integer Number of lines of the two sides together.
---@field max_lines integer Limit that applied. 0 when no limit applied.
---@field context integer Context length for the renderer.
---@field message boolean? True for the commit message document, which holds no diff.

---@class codeview.diff.Opts
---@field context integer? Context length. The `diff.context` option by default.
---@field algorithm string? Algorithm of |vim.diff()|. |codeview.diff.algorithm()| by default.
---@field indent_heuristic boolean? True moves a change to the line that the indent suggests. False by default.
---@field max_lines integer? Highest number of lines of the two sides together. 0 removes the limit. The `diff.max_lines` option by default.

---Highest number of lines of one side for the histogram algorithm.
---@type integer
M.histogram_limit = 4000

---Split file content into lines.
---
--- The call drops the empty element after a final line break, so that a file
--- with a final break and a file without one give the same line count.
---@param content string? Content of a file.
---@return string[] lines
function M.split(content)
  if not content or content == "" then
    return {}
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

---Report whether content is binary.
---@param content string? Content of a file.
---@return boolean
function M.is_binary(content)
  return type(content) == "string" and content:find("\0", 1, true) ~= nil
end

---Algorithm of |vim.diff()| for two sides of a given size.
---
--- The histogram algorithm reads better, so a file of a normal size takes it.
--- Its cost grows with the square of the number of hunks: a file of 16000
--- lines that changes every second line costs 1300 ms, against 2 ms for the
--- myers algorithm. A large file therefore takes myers, the algorithm of git.
---@param old integer Number of lines of the old side.
---@param new integer Number of lines of the new side.
---@return string algorithm Name for the `algorithm` field of |vim.diff()|.
function M.algorithm(old, new)
  if math.max(old, new) > M.histogram_limit then
    return "myers"
  end
  return "histogram"
end

---Revisions of the two sides of a changed file.
---
--- An added file has no old side, and a deleted file has no new side. A range
--- without a base has no old side at all, because the base is the state before
--- the first commit.
---@param session codeview.Session Session that owns the file.
---@param file codeview.vcs.FileChange File of the session.
---@return string? old_rev Revision of the old side.
---@return string? new_rev Revision of the new side.
function M.revisions(session, file)
  local old_rev = session.range.from
  local new_rev = session.range.to
  if file.status == "added" then
    old_rev = nil
  end
  if file.status == "deleted" then
    new_rev = nil
  end
  return old_rev, new_rev
end

---Paths of the two sides of a changed file.
---@param file codeview.vcs.FileChange File of the session.
---@return string old_path Path in the old revision.
---@return string new_path Path in the new revision.
function M.paths(file)
  return file.old_path or file.path, file.path
end

---Compare two contents.
---@param old_text string? Content of the old side.
---@param new_text string? Content of the new side.
---@param opts? codeview.diff.Opts
---@return codeview.diff.File diff Path, status, and revisions hold their empty values.
function M.compute(old_text, new_text, opts)
  opts = opts or {}
  local cfg = config.get().diff
  local context = opts.context or cfg.context
  local max_lines = opts.max_lines or cfg.max_lines
  local binary = M.is_binary(old_text) or M.is_binary(new_text)

  local old_lines = binary and {} or M.split(old_text)
  local new_lines = binary and {} or M.split(new_text)

  ---@type codeview.diff.File
  local out = {
    path = "",
    old_path = "",
    status = "modified",
    old_rev = nil,
    new_rev = nil,
    old_lines = old_lines,
    new_lines = new_lines,
    hunks = {},
    binary = binary,
    limited = false,
    line_count = #old_lines + #new_lines,
    max_lines = 0,
    context = context,
  }
  if binary then
    return out
  end

  -- The comparison of a file above the limit costs more than the reader wants
  -- to wait. The lines go away with it, because nothing shows them.
  if max_lines > 0 and out.line_count > max_lines then
    out.limited = true
    out.max_lines = max_lines
    out.old_lines, out.new_lines = {}, {}
    return out
  end

  -- A context length above 0 merges two near changes into one hunk and counts
  -- the unchanged lines between them as changed.
  local indices = vim.diff(old_text or "", new_text or "", {
    result_type = "indices",
    ctxlen = 0,
    algorithm = opts.algorithm or M.algorithm(#old_lines, #new_lines),
    indent_heuristic = opts.indent_heuristic == true,
  }) --[[@as integer[][] ]]

  for index, hunk in ipairs(indices or {}) do
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
    out.hunks[index] = {
      index = index,
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      old_first = old_count > 0 and old_start or old_start + 1,
      new_first = new_count > 0 and new_start or new_start + 1,
    }
  end
  return out
end

---Read both sides of a file.
---@param repo codeview.vcs.Repo
---@param old_rev string?
---@param old_path string
---@param new_rev string?
---@param new_path string
---@param cb? fun(old: string?, new: string?, err: codeview.Error?)
---@return string? old
---@return string? new
---@return codeview.Error? err
local function read_sides(repo, old_rev, old_path, new_rev, new_path, cb)
  if not cb then
    local old, old_err = repo:file_content(old_rev, old_path)
    if not old then
      return nil, nil, old_err
    end
    local new, new_err = repo:file_content(new_rev, new_path)
    if not new then
      return nil, nil, new_err
    end
    return old, new, nil
  end

  -- Both reads run at the same time. The join keeps the first error.
  local left, right, failed
  local waiting = 2
  local function finish()
    waiting = waiting - 1
    if waiting > 0 then
      return
    end
    if failed then
      cb(nil, nil, failed)
      return
    end
    cb(left, right, nil)
  end

  repo:file_content(old_rev, old_path, function(content, err)
    left, failed = content, failed or err
    finish()
  end)
  repo:file_content(new_rev, new_path, function(content, err)
    right, failed = content, failed or err
    finish()
  end)
  return nil, nil, nil
end

---Build the diff of one changed file of a session.
---
--- Without a callback the call blocks and returns `diff, err`. With a callback
--- it returns at once and calls `cb(diff, err)`.
---@param session codeview.Session Session that owns the file.
---@param file codeview.vcs.FileChange File of the session.
---@param opts? codeview.diff.Opts
---@param cb? fun(diff: codeview.diff.File?, err: codeview.Error?) Callback for the async form.
---@return codeview.diff.File? diff
---@return codeview.Error? err
function M.for_file(session, file, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  if type(session) ~= "table" or type(session.repo) ~= "table" then
    local err = errors.new(errors.codes.INVALID_ARG, "the first argument must be a session")
    if cb then
      cb(nil, err)
      return nil, nil
    end
    return nil, err
  end
  if type(file) ~= "table" or type(file.path) ~= "string" then
    local err = errors.new(errors.codes.INVALID_ARG, "the second argument must be a changed file")
    if cb then
      cb(nil, err)
      return nil, nil
    end
    return nil, err
  end

  local old_rev, new_rev = M.revisions(session, file)
  local old_path, new_path = M.paths(file)

  ---@param old string
  ---@param new string
  ---@return codeview.diff.File
  local function build(old, new)
    local out = M.compute(old, new, opts)
    out.path = file.path
    out.old_path = old_path
    out.status = file.status
    out.old_rev = old_rev
    out.new_rev = new_rev
    return out
  end

  if not cb then
    local old, new, err = read_sides(session.repo, old_rev, old_path, new_rev, new_path)
    if not old or not new then
      return nil, err
    end
    return build(old, new), nil
  end

  read_sides(session.repo, old_rev, old_path, new_rev, new_path, function(old, new, err)
    if not old or not new then
      cb(nil, err)
      return
    end
    cb(build(old, new), nil)
  end)
  return nil, nil
end

---Report whether a diff holds no change.
---@param diff codeview.diff.File
---@return boolean
function M.is_empty(diff)
  return not diff.binary and not diff.limited and #diff.hunks == 0
end

---Text that says why a diff shows no line.
---@param diff codeview.diff.File
---@return string message
function M.limit_message(diff)
  return string.format("The diff holds %d lines. The limit diff.max_lines is %d.", diff.line_count, diff.max_lines)
end

---Number of added lines and removed lines of a diff.
---@param diff codeview.diff.File
---@return integer added
---@return integer removed
function M.stat(diff)
  local added, removed = 0, 0
  for _, hunk in ipairs(diff.hunks) do
    added = added + hunk.new_count
    removed = removed + hunk.old_count
  end
  return added, removed
end

return M
