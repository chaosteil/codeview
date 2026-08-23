---@brief The commit picker.
---
--- The picker reads the log of the repository and shows it with
--- |vim.ui.select()|. One pick opens a session for one commit. Two picks open
--- a session for the range between them, with both commits in the range.
---
--- Every pick function takes a callback. The callback gets `nil, nil` when the
--- user cancels the picker.

local errors = require("codeview.error")
local session = require("codeview.session")
local vcs = require("codeview.vcs")

local M = {}

---Number of commits in the list, when the caller sets no limit.
---@type integer
M.limit = 100

---@class codeview.picker.Opts
---@field repo codeview.vcs.Repo? Repository handle. Without it the picker detects one.
---@field dir string? Directory for the detection. The current directory by default.
---@field backend "auto"|"git"|"jj"? Backend for the detection. The configuration value by default.
---@field limit integer? Number of commits in the list.
---@field revs string[]? Revisions for the log. The head revision by default.
---@field prompt string? Prompt of the first list.
---@field mode "single"|"range"? Number of picks. "single" by default.
---@field select fun(items: any[], opts: table, on_choice: fun(item: any?, index: integer?))? Selector. |vim.ui.select()| by default.

--- Dates ----------------------------------------------------------------------

---Seconds between the local time zone and UTC at one time.
---@param time integer Seconds since the epoch.
---@return integer offset
local function utc_offset(time)
  local utc = os.date("!*t", time)
  utc.isdst = false
  return time - os.time(utc)
end

---Read an ISO 8601 timestamp.
---@param text string Timestamp, for example "2024-01-02T10:00:00+01:00".
---@return integer? time Seconds since the epoch. Nil when the text has another form.
function M.parse_date(text)
  if type(text) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute, second, rest =
    text:match("^%s*(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
  if not year then
    return nil
  end

  local as_local = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = tonumber(second),
    isdst = false,
  })
  if not as_local then
    return nil
  end
  local time = as_local + utc_offset(as_local)

  local sign, offset_hour, offset_minute = rest:match("([+-])(%d%d):?(%d%d)%s*$")
  if sign then
    local offset = tonumber(offset_hour) * 3600 + tonumber(offset_minute) * 60
    time = sign == "-" and time + offset or time - offset
  end
  return math.floor(time)
end

---@type { limit: integer, seconds: integer, unit: string }[]
local UNITS = {
  { limit = 60, seconds = 1, unit = "second" },
  { limit = 3600, seconds = 60, unit = "minute" },
  { limit = 86400, seconds = 3600, unit = "hour" },
  { limit = 2592000, seconds = 86400, unit = "day" },
  { limit = 31536000, seconds = 2592000, unit = "month" },
}

---Render the age of a timestamp as text.
---@param time integer Seconds since the epoch.
---@param now? integer Time to compare against. The current time by default.
---@return string age For example "3 days ago".
function M.relative_date(time, now)
  local diff = (now or os.time()) - time
  if diff < 45 then
    return "just now"
  end
  for _, unit in ipairs(UNITS) do
    if diff < unit.limit then
      local count = math.floor(diff / unit.seconds)
      return string.format("%d %s%s ago", count, unit.unit, count == 1 and "" or "s")
    end
  end
  local years = math.floor(diff / 31536000)
  return string.format("%d year%s ago", years, years == 1 and "" or "s")
end

--- Entries ---------------------------------------------------------------------

---Render one commit as a list entry: short id, subject, and relative date.
---@param commit codeview.vcs.Commit
---@param now? integer Time to compare the date against.
---@return string entry
function M.format_commit(commit, now)
  local time = M.parse_date(commit.date)
  local age = time and M.relative_date(time, now) or commit.date
  return string.format("%-9s %s  (%s)", commit.short_id, commit.subject, age)
end

---Show a list of commits and report the pick.
---@param commits codeview.vcs.Commit[]
---@param opts codeview.picker.Opts
---@param cb fun(commit: codeview.vcs.Commit?, index: integer?) Nil commit means cancel.
function M.select_commit(commits, opts, cb)
  local choose = opts.select or vim.ui.select
  local now = os.time()
  choose(commits, {
    prompt = opts.prompt or "Commit to review",
    kind = "codeview.commit",
    format_item = function(commit)
      return M.format_commit(commit, now)
    end,
  }, function(commit, index)
    if not commit then
      cb(nil, nil)
      return
    end
    -- A selector can report the item without its position.
    if not index then
      for position, item in ipairs(commits) do
        if item.id == commit.id then
          index = position
          break
        end
      end
    end
    cb(commit, index)
  end)
end

---Operator that names the parent of a commit, per backend.
---
--- The label of a range must stay valid input for `:CodeView`. git writes the
--- parent of a commit as `<rev>^`, jj writes it as `<rev>-`.
---@type table<string, string>
local PARENT = {
  git = "^",
  jj = "-",
}

---Build the range of two picks.
---
--- Both picks belong to the review. The base is the parent of the older
--- commit, so that the range holds the older commit too. A first commit has no
--- parent. The base is then nil, which means the state before the first
--- commit.
---@param first codeview.vcs.Commit Older commit of the two picks.
---@param last codeview.vcs.Commit Newer commit of the two picks.
---@param repo? codeview.vcs.Repo Repository of the commits. It decides the syntax of the label.
---@return codeview.vcs.RangeSpec spec
function M.build_range(first, last, repo)
  local base = (first.parents or {})[1]
  if first.id == last.id then
    return { kind = "single", to = last.id, spec = last.short_id }
  end
  if not base then
    return { kind = "explicit", to = last.id, spec = last.short_id }
  end
  local parent = PARENT[repo and repo.backend or "git"] or PARENT.git
  return {
    kind = "range",
    from = base,
    to = last.id,
    spec = first.short_id .. parent .. ".." .. last.short_id,
  }
end

---Commits of a list that have one commit as an ancestor.
---
--- The log is in date order, so a newer commit can sit on another branch. A
--- range needs the first pick as an ancestor of the last pick. This call walks
--- the parent ids of the list and keeps the descendants of `first`. `first`
--- itself is part of the answer.
---@param commits codeview.vcs.Commit[] Commits of the log, newest first.
---@param first codeview.vcs.Commit Older end of the range.
---@return codeview.vcs.Commit[] descendants Commits in the order of the list.
function M.descendants(commits, first)
  local by_id = {}
  for _, commit in ipairs(commits) do
    by_id[commit.id] = commit
  end

  ---@type table<string, boolean>
  local known = {}

  ---Report whether a path of parents leads from a commit to the first pick.
  ---@param id string
  ---@return boolean
  local function reaches(id)
    if known[id] ~= nil then
      return known[id]
    end
    if id == first.id then
      known[id] = true
      return true
    end
    -- The false value also stops a walk that meets the same commit again.
    known[id] = false
    local commit = by_id[id]
    if not commit then
      return false
    end
    for _, parent in ipairs(commit.parents or {}) do
      if reaches(parent) then
        known[id] = true
        return true
      end
    end
    return false
  end

  local out = {}
  for _, commit in ipairs(commits) do
    if reaches(commit.id) then
      out[#out + 1] = commit
    end
  end
  return out
end

--- Pick flows ------------------------------------------------------------------

---Read the log of the repository.
---@param opts codeview.picker.Opts
---@param cb fun(repo: codeview.vcs.Repo?, commits: codeview.vcs.Commit[]?, err: codeview.Error?)
local function load_commits(opts, cb)
  ---@param repo codeview.vcs.Repo
  local function with_repo(repo)
    repo:log({ limit = opts.limit or M.limit, revs = opts.revs }, function(commits, err)
      if not commits then
        cb(nil, nil, err)
        return
      end
      if #commits == 0 then
        cb(nil, nil, errors.new(errors.codes.NOT_FOUND, "the repository has no commits"))
        return
      end
      cb(repo, commits, nil)
    end)
  end

  if opts.repo then
    with_repo(opts.repo)
    return
  end
  vcs.detect(opts.dir, { backend = opts.backend }, function(repo, err)
    if not repo then
      cb(nil, nil, err)
      return
    end
    with_repo(repo)
  end)
end

---Pick one commit and open a session for it.
---@param opts? codeview.picker.Opts
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Nil session and nil error mean cancel.
function M.pick_single(opts, cb)
  opts = opts or {}
  cb = cb or function() end
  load_commits(opts, function(repo, commits, err)
    if not commits then
      cb(nil, err)
      return
    end
    M.select_commit(commits, {
      prompt = opts.prompt or "Commit to review",
      select = opts.select,
    }, function(commit)
      if not commit then
        cb(nil, nil)
        return
      end
      session.open({ kind = "single", to = commit.id, spec = commit.short_id }, { repo = repo }, cb)
    end)
  end)
end

---Pick a range in two steps and open a session for it.
---
--- The first pick is the older end of the range. The second list holds only
--- the descendants of the first pick, because a commit on another branch
--- drops the first pick from the range. Both picks belong to the range.
---@param opts? codeview.picker.Opts
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Nil session and nil error mean cancel.
function M.pick_range(opts, cb)
  opts = opts or {}
  cb = cb or function() end
  load_commits(opts, function(repo, commits, err)
    if not commits then
      cb(nil, err)
      return
    end
    M.select_commit(commits, {
      prompt = opts.prompt or "First commit of the range",
      select = opts.select,
    }, function(first)
      if not first then
        cb(nil, nil)
        return
      end
      local later = M.descendants(commits, first)
      M.select_commit(later, {
        prompt = "Last commit of the range",
        select = opts.select,
      }, function(last)
        if not last then
          cb(nil, nil)
          return
        end
        local in_range = vim.iter(later):any(function(commit)
          return commit.id == last.id
        end)
        if not in_range then
          cb(nil, errors.new(errors.codes.INVALID_ARG, first.short_id .. " is not an ancestor of " .. last.short_id))
          return
        end
        session.open(M.build_range(first, last, repo), { repo = repo }, cb)
      end)
    end)
  end)
end

---Open the picker.
---@param opts? codeview.picker.Opts `mode = "range"` asks for two picks.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Nil session and nil error mean cancel.
function M.pick(opts, cb)
  opts = opts or {}
  if opts.mode == "range" then
    M.pick_range(opts, cb)
    return
  end
  M.pick_single(opts, cb)
end

return M
