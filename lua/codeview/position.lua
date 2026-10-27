---@brief The map between the comments of a session and the lines of GitHub.
---
--- The review API of GitHub names a line with four fields:
---
--- - `side` is LEFT for the old side and RIGHT for the new side.
--- - `line` is the last line of the comment, in the file of `side`.
--- - `start_line` and `start_side` come with a comment over more than one
---   line.
---
--- |codeview.position.to_api()| maps a comment of the session to these fields.
--- It runs on a line map of the diff with the settings of git, because GitHub
--- accepts only the lines of the diff of git. A line that the diff does not
--- hold gives a reason and no position.
---
--- |codeview.position.from_api()| is the inverse. It maps the fields of a
--- review comment of GitHub to the side and the lines of an anchor.
---
--- The module talks to no host and changes no state.

local diff_mod = require("codeview.diff")
local inline = require("codeview.inline")
local linemap = require("codeview.linemap")

local M = {}

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
--- `linematch = 0` runs the map without the line alignment of the display,
--- because git has none.
---
--- `max_lines = 0` removes the line limit of the display. A comment on a large
--- file must map, whether the reader rendered that diff or not.
---@type codeview.diff.Opts
M.diff_opts = { algorithm = "myers", indent_heuristic = true, linematch = 0, max_lines = 0 }

---@class codeview.position.Position
---@field path string Path of the file in the pull request.
---@field side "LEFT"|"RIGHT" Side of the diff that holds the last line.
---@field line integer Last line of the comment, in the file of that side.
---@field start_line integer? First line of a comment over more than one line.
---@field start_side "LEFT"|"RIGHT"? Side of the first line. It is `side`.

---@class codeview.position.Block
---@field from integer First line of the block, in the file of the side.
---@field to integer Last line of the block, in the file of the side.

---@class codeview.position.Coverage
---@field old codeview.position.Block[] Blocks of the old side, in file order.
---@field new codeview.position.Block[] Blocks of the new side, in file order.

---@class codeview.position.FileDiff
---@field map codeview.LineMap Map of the render of the diff.
---@field coverage codeview.position.Coverage Blocks that the diff of the pull request holds.

---@class codeview.position.Anchor
---@field side codeview.linemap.Side Side that holds the lines.
---@field start_line integer First line of the range.
---@field end_line integer Last line of the range.

--- Sides ------------------------------------------------------------------------

---Side of the review API of a side of the diff.
---@param side codeview.linemap.Side
---@return "LEFT"|"RIGHT"
function M.api_side(side)
  return side == "old" and "LEFT" or "RIGHT"
end

---Side of the diff of a side of the review API.
---@param text string? LEFT or RIGHT. Every other value is the new side.
---@return codeview.linemap.Side side
function M.side(text)
  return tostring(text or ""):upper() == "LEFT" and "old" or "new"
end

--- Coverage ---------------------------------------------------------------------

---Blocks of one side that the diff of the pull request holds.
---
--- GitHub shows `M.context` unchanged lines around each change. Two changes
--- that are near each other give one block, and the lines between them stay in
--- the diff. A line outside every block is not in the diff, and the review API
--- rejects a comment on it.
---@param diff codeview.diff.File Diff of one file, with the hunks of the file.
---@param ctx integer Number of unchanged lines around a change.
---@param side codeview.linemap.Side Side of the diff.
---@return codeview.position.Block[] blocks
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
---@param ctx integer? Number of unchanged lines around a change. |codeview.position.context| by default.
---@return codeview.position.Coverage coverage
function M.coverage(diff, ctx)
  local length = math.max(math.floor(tonumber(ctx) or M.context), 0)
  if type(diff) ~= "table" then
    return { old = {}, new = {} }
  end
  return { old = blocks_of(diff, length, "old"), new = blocks_of(diff, length, "new") }
end

---Number of the block that holds one line.
---@param coverage codeview.position.Coverage? Blocks of the diff.
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

--- Mapping ----------------------------------------------------------------------

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
---@param coverage codeview.position.Coverage? Blocks that the diff of the pull request holds.
---@return codeview.position.Position? position Nil when the diff does not hold the lines.
---@return string? reason One line that says why the comment does not map.
function M.to_api(map, comment, coverage)
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
  ---@type codeview.position.Position
  local position = { path = comment.file, side = api_side, line = comment.end_line }
  if comment.start_line < comment.end_line then
    position.start_line = comment.start_line
    position.start_side = api_side
  end
  return position, nil
end

---Map the line fields of the review API to an anchor.
---
--- The inverse of |codeview.position.to_api()|. A range that starts on the
--- other side holds line numbers of two sides. One anchor holds the lines of
--- one side, so such a range keeps its last line only.
---@param fields { side?: string, line?: integer, start_line?: integer, start_side?: string } Fields of the API. `line` is required.
---@return codeview.position.Anchor? anchor Nil without a `line`.
function M.from_api(fields)
  local last = type(fields) == "table" and tonumber(fields.line) or nil
  if not last then
    return nil
  end
  local side = M.side(fields.side)
  local first = tonumber(fields.start_line)
  if first and fields.start_side and M.side(fields.start_side) ~= side then
    first = nil
  end
  first = first or last
  if first > last then
    first, last = last, first
  end
  return {
    side = side,
    start_line = math.max(math.floor(first), 1),
    end_line = math.max(math.floor(last), 1),
  }
end

---Line map and coverage of the diff of one file of a session.
---
--- The diff runs with |codeview.position.diff_opts| and the context of
--- GitHub.
---@param session codeview.Session
---@param file codeview.vcs.FileChange
---@param cb? fun(entry: codeview.position.FileDiff?, reason: string?) Callback for the async form.
---@return codeview.position.FileDiff? entry
---@return string? reason One line that says why the file has no map.
function M.map_of(session, file, cb)
  local opts = vim.tbl_extend("force", { context = M.context }, M.diff_opts)

  ---@param diff codeview.diff.File?
  ---@param err codeview.Error?
  ---@return codeview.position.FileDiff?, string?
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

return M
