---@brief The comment store: one markdown file per review session.
---
--- The store holds every comment of one session. It lives in the directory of
--- |codeview.config.store_dir()|, which is one subdirectory per repository.
--- The file name is a short hash of the repository root and the resolved
--- range. As a result, a second review of the same range finds the same file
--- without a scan of the directory.
---
--- The file is markdown:
---
--- >
---     ---
---     version: 1
---     key: 4f1c0a2b8d3e5f60
---     repo: /home/ada/code/codeview
---     range: aaaa1111..bbbb2222
---     spec: main..@
---     created_at: 2026-08-12T09:00:00Z
---     updated_at: 2026-08-12T09:30:00Z
---     ---
---
---     # codeview review: main..@
---
---     ## codeview-comment 68a1c2f30b7a01
---
---     - file: lua/codeview/store.lua
---     - start_line: 12
---     - end_line: 14
---     - side: new
---     - commit: bbbb2222
---     - state: open
---     - synced_at:
---     - review_id:
---     - created_at: 2026-08-12T09:10:00Z
---     - updated_at: 2026-08-12T09:10:00Z
---
---     The body of the comment.
--- <
---
--- The frontmatter holds the session data. Each comment is one section: a
--- heading with the id, a field block, and a markdown body. |M.decode()| reads
--- the format back without loss. A body line that looks like a section heading
--- keeps a backslash in the file, and the parser removes it again.
---
--- |codeview.store.Store:save()| writes the file atomically: it writes a
--- temporary file in the same directory and renames it over the target. A
--- failed write leaves the file of the last save in place.

local config = require("codeview.config")
local errors = require("codeview.error")

local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local M = {}

---Format version of the file.
---@type integer
M.version = 1

---Text of a comment heading, before the id.
---@type string
M.marker = "## codeview-comment "

---@alias codeview.store.State
---| "open" # The comment waits for an answer.
---| "resolved" # The reviewer marked the comment as done.

---@class codeview.store.Comment
---@field id string Id of the comment. It is unique inside one session file.
---@field file string Path of the file, relative to the repository root.
---@field start_line integer First line of the range, from 1.
---@field end_line integer Last line of the range. For a range of one line, it equals the start line.
---@field side codeview.linemap.Side Side of the diff that holds the lines.
---@field commit string Revision that the lines come from. Empty when unknown.
---@field state codeview.store.State State of the comment.
---@field synced_at integer Time of the post to the review host, in seconds since the epoch. 0 while the comment is local.
---@field review_id string Id of the review that holds the comment on the host. Empty while the comment is local.
---@field created_at integer Time of the first save, in seconds since the epoch.
---@field updated_at integer Time of the last change, in seconds since the epoch.
---@field body string Markdown text of the comment.

---@class codeview.store.Store
---@field key string Session key. It names the file.
---@field path string Absolute path of the session file.
---@field repo string Absolute path of the repository root.
---@field range string Resolved range. The key comes from it.
---@field spec string Text of the range, as the user wrote it.
---@field version integer Format version of the file.
---@field created_at integer Time of the first save, in seconds since the epoch.
---@field updated_at integer Time of the last save, in seconds since the epoch.
---@field comments codeview.store.Comment[] Comments of the session, oldest first.
local Store = {}
Store.__index = Store

---Fields of a comment section, and the type of each field.
---@type table<string, "string"|"integer"|"time">
local FIELDS = {
  file = "string",
  start_line = "integer",
  end_line = "integer",
  side = "string",
  commit = "string",
  state = "string",
  synced_at = "time",
  review_id = "string",
  created_at = "time",
  updated_at = "time",
}

---Order of the fields in the file.
---@type string[]
local FIELD_ORDER = {
  "file",
  "start_line",
  "end_line",
  "side",
  "commit",
  "state",
  "synced_at",
  "review_id",
  "created_at",
  "updated_at",
}

---Number of ids that this Neovim made.
---
--- It makes two ids from the same second different.
---@type integer
local counter = 0

--- Time ------------------------------------------------------------------------

---Days between 1970-01-01 and one date, in the proleptic Gregorian calendar.
---@param y integer
---@param m integer
---@param d integer
---@return integer days
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

---Format a time as an ISO 8601 timestamp in UTC.
---@param time integer? Seconds since the epoch. The current time by default.
---@return string text
function M.to_iso(time)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", time or os.time()) --[[@as string]]
end

---Read an ISO 8601 timestamp in UTC.
---@param text string?
---@return integer? time Seconds since the epoch. Nil for text of another form.
function M.from_iso(text)
  if type(text) ~= "string" then
    return nil
  end
  local y, m, d, hh, mm, ss = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z?$")
  if not y then
    return nil
  end
  local days =
    days_from_civil(tonumber(y) --[[@as integer]], tonumber(m) --[[@as integer]], tonumber(d) --[[@as integer]])
  return days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
end

--- Keys ------------------------------------------------------------------------

---Text of a resolved range.
---
--- The key comes from this text, so it must name the same commits after a
--- reopen. A range table gives the resolved ids, not the text of the user.
---@param range string|codeview.vcs.Range Resolved range, or its text.
---@return string text
function M.range_id(range)
  if type(range) == "string" then
    return vim.trim(range)
  end
  if type(range) ~= "table" or type(range.to) ~= "string" then
    return ""
  end
  if range.from then
    return range.from .. ".." .. range.to
  end
  return range.to
end

---Session key of one repository and one range.
---
--- The key is stable: the same root and the same resolved range always give
--- the same text.
---@param repo_root string Absolute path of the repository root.
---@param range string|codeview.vcs.Range Resolved range.
---@return string key
function M.key(repo_root, range)
  local root = fs.normalize(repo_root or "")
  return fn.sha256(root .. "\n" .. M.range_id(range)):sub(1, 16)
end

---Path of the session file of one repository and one range.
---@param repo_root string Absolute path of the repository root.
---@param range string|codeview.vcs.Range Resolved range.
---@return string path
function M.path(repo_root, range)
  return fs.joinpath(config.store_dir(repo_root), M.key(repo_root, range) .. ".md")
end

---Build an id for a new comment.
---@return string id
function M.new_id()
  counter = (counter + 1) % 0x10000
  return string.format("%08x%04x", os.time() % 0x100000000, counter)
end

--- Encode ----------------------------------------------------------------------

---Text of one field value, on one line.
---@param value any
---@return string
local function flat(value)
  return (tostring(value or ""):gsub("[\r\n]+", " "))
end

---Text of a time field.
---
--- A time of 0 means "not set", for example the sync time of a comment
--- that no submit sent yet. It writes an empty value, and |M.from_iso()| reads
--- it back as 0.
---@param value any Seconds since the epoch.
---@return string text
local function time_text(value)
  local time = math.floor(tonumber(value) or 0)
  if time <= 0 then
    return ""
  end
  return M.to_iso(time)
end

---Escape a body line that reads as a section heading.
---@param line string
---@return string
local function escape(line)
  if line:sub(1, 1) == "\\" or vim.startswith(line, M.marker) then
    return "\\" .. line
  end
  return line
end

---Read an escaped body line.
---@param line string
---@return string
local function unescape(line)
  if line:sub(1, 1) == "\\" then
    return line:sub(2)
  end
  return line
end

---Remove the empty lines at both ends of a list.
---@param lines string[]
---@return string[]
local function trim_lines(lines)
  local first, last = 1, #lines
  while first <= last and vim.trim(lines[first]) == "" do
    first = first + 1
  end
  while last >= first and vim.trim(lines[last]) == "" do
    last = last - 1
  end
  return vim.list_slice(lines, first, last)
end

---Render a store as the text of its file.
---@param store codeview.store.Store
---@return string text
function M.encode(store)
  local out = {
    "---",
    "version: " .. tostring(store.version or M.version),
    "key: " .. flat(store.key),
    "repo: " .. flat(store.repo),
    "range: " .. flat(store.range),
    "spec: " .. flat(store.spec),
    "created_at: " .. M.to_iso(store.created_at),
    "updated_at: " .. M.to_iso(store.updated_at),
    "---",
    "",
    "# codeview review: " .. flat(store.spec ~= "" and store.spec or store.range),
  }

  for _, comment in ipairs(store.comments) do
    out[#out + 1] = ""
    out[#out + 1] = M.marker .. comment.id
    out[#out + 1] = ""
    for _, name in ipairs(FIELD_ORDER) do
      local value = comment[name]
      if FIELDS[name] == "time" then
        value = time_text(value)
      end
      -- A field without a value keeps no trailing space, so that the file
      -- holds no whitespace at the end of a line.
      out[#out + 1] = vim.trim("- " .. name .. ": " .. flat(value))
    end
    out[#out + 1] = ""
    for _, line in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
      out[#out + 1] = escape(line)
    end
  end

  return table.concat(out, "\n") .. "\n"
end

--- Decode ----------------------------------------------------------------------

---Read one comment section.
---@param id string
---@param lines string[] Lines of the section, without the heading.
---@return codeview.store.Comment
local function decode_comment(id, lines)
  ---@type codeview.store.Comment
  local comment = {
    id = id,
    file = "",
    start_line = 1,
    end_line = 1,
    side = "new",
    commit = "",
    state = "open",
    synced_at = 0,
    review_id = "",
    created_at = 0,
    updated_at = 0,
    body = "",
  }

  local at = 1
  while lines[at] and vim.trim(lines[at]) == "" do
    at = at + 1
  end
  while lines[at] do
    local name, value = lines[at]:match("^%-%s+([%w_]+):%s*(.-)%s*$")
    if not name or not FIELDS[name] then
      break
    end
    local kind = FIELDS[name]
    if kind == "integer" then
      comment[name] = tonumber(value) or comment[name]
    elseif kind == "time" then
      comment[name] = M.from_iso(value) or comment[name]
    else
      comment[name] = value
    end
    at = at + 1
  end

  comment.body = table.concat(vim.tbl_map(unescape, trim_lines(vim.list_slice(lines, at, #lines))), "\n")
  comment.start_line = math.max(math.floor(comment.start_line), 1)
  comment.end_line = math.max(math.floor(comment.end_line), comment.start_line)
  comment.side = comment.side == "old" and "old" or "new"
  comment.state = comment.state == "resolved" and "resolved" or "open"
  comment.synced_at = math.max(math.floor(comment.synced_at), 0)
  return comment
end

---Read the text of a session file.
---@param text string Content of the file.
---@return codeview.store.Store? store Nil when the text is not a session file.
---@return codeview.Error? err
function M.decode(text)
  if type(text) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the text must be a string, got " .. type(text))
  end

  local lines = vim.split(text, "\n", { plain = true })
  if vim.trim(lines[1] or "") ~= "---" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the file has no codeview frontmatter")
  end

  local meta = {}
  local at = 2
  while lines[at] and vim.trim(lines[at]) ~= "---" do
    local name, value = lines[at]:match("^([%w_]+):%s*(.-)%s*$")
    if name then
      meta[name] = value
    end
    at = at + 1
  end
  if not lines[at] then
    return nil, errors.new(errors.codes.INVALID_ARG, "the frontmatter has no end")
  end
  at = at + 1

  local store = M.new({
    key = meta.key,
    repo = meta.repo,
    range = meta.range,
    spec = meta.spec,
    version = tonumber(meta.version) or M.version,
    created_at = M.from_iso(meta.created_at),
    updated_at = M.from_iso(meta.updated_at),
  })

  local id, section = nil, {}
  ---Keep the section that ended.
  local function flush()
    if id then
      store.comments[#store.comments + 1] = decode_comment(id, section)
    end
    id, section = nil, {}
  end

  while lines[at] do
    local line = lines[at]
    local found = line:match("^## codeview%-comment ([%w%-_%.]+)%s*$")
    if found then
      flush()
      id = found
    elseif id then
      section[#section + 1] = line
    end
    at = at + 1
  end
  flush()

  return store, nil
end

--- Files -----------------------------------------------------------------------

---Read a file as one text.
---@param path string
---@return string? text
---@return codeview.Error? err
local function read_file(path)
  local handle, open_err = io.open(path, "rb")
  if not handle then
    return nil, errors.new(errors.codes.NOT_FOUND, "cannot read " .. path .. ": " .. tostring(open_err))
  end
  local text = handle:read("*a")
  handle:close()
  return text or "", nil
end

---Write a text to a file, without a partial result.
---
--- The call writes a temporary file in the directory of the target and renames
--- it. A rename inside one directory is atomic, so a reader sees the old file
--- or the new file, never a half file.
---@param path string
---@param text string
---@return boolean ok
---@return codeview.Error? err
local function write_atomic(path, text)
  local dir = fs.dirname(path)
  if fn.isdirectory(dir) == 0 then
    local made = pcall(fn.mkdir, dir, "p")
    if not made or fn.isdirectory(dir) == 0 then
      return false, errors.new(errors.codes.COMMAND_FAILED, "cannot make the directory " .. dir)
    end
  end

  local tmp = string.format("%s.%d.tmp", path, uv.os_getpid())
  local handle, open_err = io.open(tmp, "wb")
  if not handle then
    return false, errors.new(errors.codes.COMMAND_FAILED, "cannot write " .. tmp .. ": " .. tostring(open_err))
  end
  local written, write_err = handle:write(text)
  handle:close()
  if not written then
    os.remove(tmp)
    return false, errors.new(errors.codes.COMMAND_FAILED, "cannot write " .. tmp .. ": " .. tostring(write_err))
  end

  local ok, rename_err = uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, errors.new(errors.codes.COMMAND_FAILED, "cannot replace " .. path .. ": " .. tostring(rename_err))
  end
  return true, nil
end

--- Store -----------------------------------------------------------------------

---Build an empty store.
---@param opts? { key?: string, path?: string, repo?: string, range?: string|codeview.vcs.Range, spec?: string, version?: integer, created_at?: integer, updated_at?: integer }
---@return codeview.store.Store
function M.new(opts)
  opts = opts or {}
  local repo = opts.repo or ""
  local range = M.range_id(opts.range or "")
  local now = os.time()
  return setmetatable({
    key = opts.key or M.key(repo, range),
    path = opts.path or "",
    repo = repo,
    range = range,
    spec = opts.spec or range,
    version = opts.version or M.version,
    created_at = opts.created_at or now,
    updated_at = opts.updated_at or now,
    comments = {},
  }, Store)
end

---Report whether a value is a store of this module.
---@param value any
---@return boolean
function M.is(value)
  return type(value) == "table" and getmetatable(value) == Store
end

---Read the session file of one repository and one range.
---
--- A range without a file gives an empty store, not an error. The first save
--- writes the file.
---@param opts { repo: string, range: string|codeview.vcs.Range, spec?: string, path?: string }
---@return codeview.store.Store? store Nil after a read error.
---@return codeview.Error? err
function M.load(opts)
  if type(opts) ~= "table" or type(opts.repo) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the call needs a repository root")
  end
  local range = M.range_id(opts.range or "")
  local path = opts.path or M.path(opts.repo, range)

  if not uv.fs_stat(path) then
    local store = M.new({ repo = opts.repo, range = range, spec = opts.spec, path = path })
    return store, nil
  end

  local text, read_err = read_file(path)
  if not text then
    return nil, read_err
  end
  local store, decode_err = M.decode(text)
  if not store then
    return nil, decode_err
  end
  store.path = path
  store.repo = opts.repo
  store.range = range ~= "" and range or store.range
  store.spec = opts.spec or store.spec
  store.key = M.key(store.repo, store.range)
  return store, nil
end

---Read the session file of a review session.
---
--- The key comes from the resolved range. A session with a `store_key` field
--- names its file itself. A pull request review builds the key from the
--- number of the pull request and its head commit. A new push then writes its
--- own file.
---@param session codeview.Session
---@return codeview.store.Store? store
---@return codeview.Error? err
function M.for_session(session)
  if type(session) ~= "table" or type(session.repo) ~= "table" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the call needs a review session")
  end
  local key = type(session.store_key) == "string" and vim.trim(session.store_key) or ""
  return M.load({
    repo = session.repo.root,
    range = key ~= "" and key or session.range,
    spec = session.spec,
  })
end

---Number of comments in the store.
---@return integer count
function Store:count()
  return #self.comments
end

---Read one comment by its id.
---@param id string
---@return codeview.store.Comment? comment
---@return integer? index Position in the comment list.
function Store:get(id)
  for index, comment in ipairs(self.comments) do
    if comment.id == id then
      return comment, index
    end
  end
  return nil, nil
end

---Comments of one file.
---@param file string Path of the file in the review.
---@param opts? { side?: codeview.linemap.Side } Keep one side only.
---@return codeview.store.Comment[] comments
function Store:for_file(file, opts)
  opts = opts or {}
  local out = {}
  for _, comment in ipairs(self.comments) do
    if comment.file == file and (not opts.side or comment.side == opts.side) then
      out[#out + 1] = comment
    end
  end
  return out
end

---Comments that cover one line of a file.
---@param file string Path of the file in the review.
---@param side codeview.linemap.Side Side that holds the line.
---@param line integer Line in the file, from 1.
---@return codeview.store.Comment[] comments
function Store:at(file, side, line)
  local out = {}
  for _, comment in ipairs(self.comments) do
    if comment.file == file and comment.side == side and comment.start_line <= line and line <= comment.end_line then
      out[#out + 1] = comment
    end
  end
  return out
end

---Check the fields of a new comment.
---@param fields table
---@return codeview.store.Comment? comment
---@return codeview.Error? err
local function build_comment(fields)
  if type(fields) ~= "table" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the comment must be a table, got " .. type(fields))
  end
  if type(fields.file) ~= "string" or fields.file == "" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the comment needs a file")
  end
  if type(fields.body) ~= "string" or vim.trim(fields.body) == "" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the comment needs a body")
  end
  local side = fields.side == "old" and "old" or "new"
  local start_line = math.max(math.floor(tonumber(fields.start_line) or 1), 1)
  local end_line = math.max(math.floor(tonumber(fields.end_line) or start_line), start_line)
  local now = os.time()

  ---@type codeview.store.Comment
  return {
    id = type(fields.id) == "string" and fields.id or M.new_id(),
    file = fields.file,
    start_line = start_line,
    end_line = end_line,
    side = side,
    commit = type(fields.commit) == "string" and fields.commit or "",
    state = fields.state == "resolved" and "resolved" or "open",
    synced_at = math.max(math.floor(tonumber(fields.synced_at) or 0), 0),
    review_id = type(fields.review_id) == "string" and fields.review_id or "",
    created_at = tonumber(fields.created_at) or now,
    updated_at = tonumber(fields.updated_at) or now,
    body = vim.trim(fields.body),
  },
    nil
end

---Add one comment.
---
--- The call does not write the file. Call |codeview.store.Store:save()| after
--- it.
---@param fields codeview.store.Comment|table Fields of the comment. An id is optional.
---@return codeview.store.Comment? comment
---@return codeview.Error? err
function Store:add(fields)
  local comment, err = build_comment(fields)
  if not comment then
    return nil, err
  end
  while self:get(comment.id) do
    comment.id = M.new_id()
  end
  self.comments[#self.comments + 1] = comment
  return comment, nil
end

---Change the fields of one comment.
---
--- A new body clears the sync mark of the comment. The text on the review host
--- is the text of the last submit, so the comment needs a new submit.
---@param id string Id of the comment.
---@param fields table Fields to set. `body`, `state`, and the anchor fields.
---@return codeview.store.Comment? comment
---@return codeview.Error? err
function Store:update(id, fields)
  local comment = self:get(id)
  if not comment then
    return nil, errors.new(errors.codes.NOT_FOUND, "no comment with the id " .. tostring(id))
  end
  if type(fields) ~= "table" then
    return nil, errors.new(errors.codes.INVALID_ARG, "the fields must be a table, got " .. type(fields))
  end
  if fields.body ~= nil then
    if type(fields.body) ~= "string" or vim.trim(fields.body) == "" then
      return nil, errors.new(errors.codes.INVALID_ARG, "the comment needs a body")
    end
    local body = vim.trim(fields.body)
    -- A submit sent the held text, not this one. The comment loses the sync
    -- mark, so that the next submit sends the new text. `review_id` stays as
    -- the record of the review that took the comment first.
    if body ~= comment.body then
      comment.synced_at = 0
    end
    comment.body = body
  end
  if fields.state ~= nil then
    comment.state = fields.state == "resolved" and "resolved" or "open"
  end
  if type(fields.file) == "string" and fields.file ~= "" then
    comment.file = fields.file
  end
  if fields.side ~= nil then
    comment.side = fields.side == "old" and "old" or "new"
  end
  local start_line = tonumber(fields.start_line)
  if start_line then
    comment.start_line = math.max(math.floor(start_line), 1)
    comment.end_line = math.max(comment.end_line, comment.start_line)
  end
  local end_line = tonumber(fields.end_line)
  if end_line then
    comment.end_line = math.max(math.floor(end_line), comment.start_line)
  end
  if type(fields.commit) == "string" then
    comment.commit = fields.commit
  end
  comment.updated_at = os.time()
  return comment, nil
end

---Report whether a comment went to the review host already.
---@param comment codeview.store.Comment
---@return boolean synced
function M.is_synced(comment)
  return type(comment) == "table" and (tonumber(comment.synced_at) or 0) > 0
end

---Mark one comment as sent to the review host.
---
--- |codeview.submit| calls this after the API confirms the post. The call does
--- not touch `updated_at`, because a sync is not an edit of the text.
---
--- The call does not write the file. Call |codeview.store.Store:save()| after
--- it.
---@param id string Id of the comment.
---@param opts? { time?: integer, review_id?: string|integer } `time` is the sync time. The current time by default.
---@return codeview.store.Comment? comment
---@return codeview.Error? err
function Store:mark_synced(id, opts)
  opts = opts or {}
  local comment = self:get(id)
  if not comment then
    return nil, errors.new(errors.codes.NOT_FOUND, "no comment with the id " .. tostring(id))
  end
  comment.synced_at = math.max(math.floor(tonumber(opts.time) or os.time()), 1)
  if opts.review_id ~= nil then
    comment.review_id = tostring(opts.review_id)
  end
  return comment, nil
end

---Comments that no submit sent to the review host yet.
---@return codeview.store.Comment[] comments In the order of the file.
function Store:unsynced()
  local out = {}
  for _, comment in ipairs(self.comments) do
    if not M.is_synced(comment) then
      out[#out + 1] = comment
    end
  end
  return out
end

---Delete one comment.
---@param id string Id of the comment.
---@return codeview.store.Comment? comment The comment that the call removed.
function Store:remove(id)
  local comment, index = self:get(id)
  if not comment then
    return nil
  end
  table.remove(self.comments, index --[[@as integer]])
  return comment
end

---Write the session file.
---
--- The call makes the directory of the file when it is missing, and writes the
--- file atomically.
---@return boolean ok False after an error.
---@return codeview.Error? err
function Store:save()
  if self.path == "" then
    return false, errors.new(errors.codes.INVALID_ARG, "the store has no path")
  end
  self.updated_at = os.time()
  return write_atomic(self.path, M.encode(self))
end

---Delete the session file.
---@return boolean removed False when the file was gone already.
function Store:delete_file()
  if self.path == "" or not uv.fs_stat(self.path) then
    return false
  end
  return os.remove(self.path) == true
end

return M
