---@brief The language server in the diff view.
---
--- A diff buffer is no file. The inline style puts a marker column in front
--- of each line, mixes the lines of the two sides, and adds hunk headers and
--- collapsed sections. The split style adds filler rows. A language server
--- that reads such a buffer reads no valid program. This module therefore
--- attaches no client to a diff buffer.
---
--- The module loads the file of the working copy into a hidden buffer
--- instead. The language servers of the user attach to that buffer, the same
--- way as they attach to a file that the user opens. A request from the diff
--- goes to the hidden buffer, at the position of the line under the cursor.
---
--- The two texts can differ. The working copy can hold a later version of the
--- file than the side of the review, for example after a commit on top of the
--- reviewed one, or after an edit that is not in a commit. The module then
--- compares the lines of the side with the lines of the buffer. A line that
--- did not change maps to its line in the buffer. A changed line maps to no
--- line, so a request from it gets a note and no answer.
---
--- The map has two steps:
---
--- 1. The line map of the render gives the line of the side for a row. A
---    context row holds a line of both sides, so a context row of the old
---    side reaches the file through the new side too.
--- 2. The line diff between the side and the buffer gives the line of the
---    buffer. When the two texts are the same, the line stays the same.
---
--- A buffer that the module loads goes away again when the session closes.
--- A buffer that the user opened, changed, or listed stays.

local api = vim.api
local fn = vim.fn

local M = {}

---@class codeview.lsp.Source
---@field side codeview.linemap.Side Side of the diff that the source reads.
---@field path string Path of the side in the review.
---@field file string Absolute path of the file in the working copy.
---@field buf integer Buffer of the file in the working copy.
---@field lines string[] Lines of the side, without a carriage return at the end.
---@field tick integer? Change tick of the buffer at the last compare.
---@field same boolean True when the buffer holds the lines of the side.
---@field forward table<integer, integer> Line of the side to line of the buffer. Empty when `same` is true.
---@field back table<integer, integer> Line of the buffer to line of the side. Empty when `same` is true.

---@class codeview.lsp.Sources
---@field diff codeview.diff.File Diff that the sources belong to.
---@field new codeview.lsp.Source? Source of the new side.
---@field old codeview.lsp.Source? Source of the old side.

---@class codeview.lsp.Position
---@field source codeview.lsp.Source Source that holds the line.
---@field side codeview.linemap.Side Side of the line.
---@field line integer Line of the side, from 1.
---@field file_line integer Line of the buffer of the working copy, from 1.
---@field col integer Byte column in the line of the buffer, from 0.
---@field row integer Row of the diff buffer, from 1.
---@field prefix integer Bytes in front of the text of the line in the diff row.

---@class codeview.lsp.SessionState
---@field owned table<integer, { created: boolean }> Buffers that the module loaded. `created` is true when the module made the buffer.
---@field noted table<string, boolean> Files that got the note about a different working copy.

---State of each session. The keys are weak, so a closed session goes away.
---@type table<codeview.Session, codeview.lsp.SessionState>
local sessions = setmetatable({}, { __mode = "k" })

---Sources of each view. The keys are weak, so a closed view goes away.
---@type table<codeview.view.State, codeview.lsp.Sources>
local cache = setmetatable({}, { __mode = "k" })

---Release the buffers of a session. |state_of()| holds the definition.
---@type fun(session: codeview.Session)
local release

---State of a session. The first call adds the close handler.
---@param session codeview.Session
---@return codeview.lsp.SessionState
local function state_of(session)
  local entry = sessions[session]
  if not entry then
    entry = { owned = {}, noted = {} }
    sessions[session] = entry
    session:on_close(release)
  end
  return entry
end

---Remove a carriage return at the end of a line.
---
--- A file with CRLF line ends gives lines with a carriage return from the
--- backend. Neovim reads the same file with 'fileformat' "dos", and its lines
--- hold no carriage return.
---@param line string
---@return string
local function strip(line)
  if line:sub(-1) == "\r" then
    return line:sub(1, -2)
  end
  return line
end

---Absolute path of a file of the review in the working copy.
---@param session codeview.Session
---@param path string Path in the review.
---@return string file
function M.file_of(session, path)
  return vim.fs.normalize(vim.fs.joinpath(session.repo.root, path))
end

---Report whether a window shows a buffer.
---@param buf integer
---@return boolean
local function shown(buf)
  return #fn.win_findbuf(buf) > 0
end

---Load a file of the working copy into a buffer.
---
--- A buffer of the file that exists already is the answer, also with changes
--- that are not written. A new buffer stays unlisted. The load gives no swap
--- file prompt, because no window shows the buffer.
---@param session codeview.Session Session that owns the load.
---@param file string Absolute path.
---@return integer? buf Nil when the file cannot load.
---@return string? err Reason of the failure.
function M.load(session, file)
  if fn.filereadable(file) ~= 1 then
    return nil, "the working copy holds no " .. file
  end
  local existed = fn.bufexists(file) == 1
  local buf = fn.bufadd(file)
  if buf == 0 then
    return nil, "cannot make a buffer for " .. file
  end
  if api.nvim_buf_is_loaded(buf) then
    return buf, nil
  end

  local shortmess = vim.o.shortmess
  vim.o.shortmess = shortmess .. "A"
  local ok, err = pcall(fn.bufload, buf)
  vim.o.shortmess = shortmess
  if not ok or not api.nvim_buf_is_loaded(buf) then
    return nil, string.format("cannot load %s: %s", file, tostring(err))
  end
  local owner = state_of(session)
  if not owner.owned[buf] then
    owner.owned[buf] = { created = not existed }
  end
  return buf, nil
end

---Remove the buffers that the module loaded for a session.
---
--- A buffer stays when a window shows it, when it holds changes, or when it
--- is listed. Each of these says that the user works with the buffer now.
---@param session codeview.Session
release = function(session)
  local entry = sessions[session]
  sessions[session] = nil
  if not entry then
    return
  end
  for buf, owned in pairs(entry.owned) do
    if api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified and not vim.bo[buf].buflisted and not shown(buf) then
      if owned.created then
        pcall(api.nvim_buf_delete, buf, {})
      elseif api.nvim_buf_is_loaded(buf) then
        pcall(api.nvim_buf_delete, buf, { unload = true })
      end
    end
  end
end

---Report the buffers that the module loaded for a session.
---@param session codeview.Session
---@return integer[] bufs
function M.owned(session)
  local out = {}
  local entry = sessions[session]
  for buf in pairs(entry and entry.owned or {}) do
    out[#out + 1] = buf
  end
  table.sort(out)
  return out
end

---Make the source of one side of a diff.
---@param session codeview.Session
---@param side codeview.linemap.Side
---@param path string Path of the side in the review.
---@param lines string[] Lines of the side.
---@return codeview.lsp.Source? source Nil when the working copy holds no file at the path.
local function source_of(session, side, path, lines)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local file = M.file_of(session, path)
  local buf = M.load(session, file)
  if not buf then
    return nil
  end
  return {
    side = side,
    path = path,
    file = file,
    buf = buf,
    lines = vim.tbl_map(strip, lines),
    tick = nil,
    same = false,
    forward = {},
    back = {},
  }
end

---Report whether a diff holds rows that map to a file.
---
--- A binary file, a diff above the limits, and a document hold no line of a
--- file. A file of a review of files is a document of the file itself, so it
--- holds the lines of the new side.
---@param diff codeview.diff.File
---@return boolean
function M.has_lines(diff)
  if diff.binary or diff.limited then
    return false
  end
  if diff.message and not diff.plain then
    return false
  end
  return true
end

---Sources of the sides of a view.
---
--- The call loads the files of the working copy on the first call for a view.
--- A later call gives the same sources, because the diff of a view never
--- changes.
---@param view codeview.view.State
---@return codeview.lsp.Sources sources
function M.sources(view)
  local entry = cache[view]
  if entry and entry.diff == view.diff then
    return entry
  end
  local diff = view.diff
  entry = { diff = diff }
  cache[view] = entry
  if not M.has_lines(diff) then
    return entry
  end
  if diff.status ~= "deleted" then
    entry.new = source_of(view.session, "new", diff.path, diff.new_lines)
  end
  if not diff.plain and diff.status ~= "added" and diff.old_rev ~= nil then
    entry.old = source_of(view.session, "old", diff.old_path, diff.old_lines)
  end
  return entry
end

---Compare the lines of a side with the buffer of the working copy.
---
--- The call runs again only after a change of the buffer. A buffer that went
--- away loads again.
---@param session codeview.Session
---@param source codeview.lsp.Source
---@return boolean ok False when the buffer cannot load.
function M.sync(session, source)
  if not api.nvim_buf_is_valid(source.buf) or not api.nvim_buf_is_loaded(source.buf) then
    local buf = M.load(session, source.file)
    if not buf then
      return false
    end
    source.buf, source.tick = buf, nil
  end
  local tick = api.nvim_buf_get_changedtick(source.buf)
  if source.tick == tick then
    return true
  end
  source.tick = tick

  local lines = api.nvim_buf_get_lines(source.buf, 0, -1, false)
  -- An empty buffer holds one empty line. The side of an empty file holds none.
  if #lines == 1 and lines[1] == "" and #source.lines == 0 then
    lines = {}
  end
  source.forward, source.back = {}, {}
  source.same = vim.deep_equal(lines, source.lines)
  if source.same then
    return true
  end

  local function text(list)
    return #list > 0 and table.concat(list, "\n") .. "\n" or ""
  end
  local hunks = vim.diff(text(source.lines), text(lines), { result_type = "indices", algorithm = "histogram" })
  ---@cast hunks integer[][]
  local a, b = 1, 1
  ---@param last integer Last line of the side before the next change.
  local function keep(last)
    while a <= last do
      source.forward[a], source.back[b] = b, a
      a, b = a + 1, b + 1
    end
  end
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    keep(count_a == 0 and start_a or start_a - 1)
    a = count_a == 0 and start_a + 1 or start_a + count_a
    b = count_b == 0 and start_b + 1 or start_b + count_b
  end
  keep(#source.lines)
  return true
end

---Line of the working copy for a line of the side.
---@param source codeview.lsp.Source
---@param line integer Line of the side, from 1.
---@return integer? file_line Nil when the working copy changed the line.
function M.to_file(source, line)
  if source.same then
    return line <= #source.lines and line or nil
  end
  return source.forward[line]
end

---Line of the side for a line of the working copy.
---@param source codeview.lsp.Source
---@param file_line integer Line of the working copy, from 1.
---@return integer? line Nil when the side does not hold the line.
function M.from_file(source, file_line)
  if source.same then
    return file_line <= #source.lines and file_line or nil
  end
  return source.back[file_line]
end

---Bytes in front of the text of a line in a row of the diff.
---
--- The inline style puts a marker in front of a line. The split style and a
--- document put nothing in front.
---@param row_text string Text of the diff row.
---@param line_text string Text of the line of the file.
---@return integer prefix
function M.prefix(row_text, line_text)
  local width = #row_text - #line_text
  if width > 0 and row_text:sub(width + 1) == line_text then
    return width
  end
  return 0
end

---Report the note about a working copy that differs from the review, once per file.
---@param session codeview.Session
---@param source codeview.lsp.Source
---@param note fun(message: string)
local function note_once(session, source, note)
  if source.same then
    return
  end
  local entry = state_of(session)
  if entry.noted[source.file] then
    return
  end
  entry.noted[source.file] = true
  note(
    string.format(
      "the working copy of %s differs from the review. The language server reads the working copy, so only the lines that did not change answer.",
      source.path
    )
  )
end

---@class codeview.lsp.LocateOpts
---@field win integer? Window of the view. The current window by default.
---@field row integer? Row of the buffer, from 1. The cursor row by default.
---@field col integer? Byte column of the row, from 0. The cursor column by default.
---@field note fun(message: string)? Receiver of the note about a working copy that differs.

---Position in the working copy of a row of the view.
---
--- The side of the window answers first. A context row of the other side
--- answers when the side of the window holds no line in the working copy.
---@param view codeview.view.State
---@param opts? codeview.lsp.LocateOpts
---@return codeview.lsp.Position? position
---@return string? reason Reason for the user, when no position answers.
function M.locate(view, opts)
  opts = opts or {}
  local win = opts.win or api.nvim_get_current_win()
  local map, buf, first
  if view.old_win and win == view.old_win and view.old_map then
    map, buf, first = view.old_map, view.old_buf, "old"
  elseif win == view.win then
    map, buf, first = view.map, view.buf, "new"
  else
    return nil, "the cursor is not in the diff"
  end
  if not api.nvim_win_is_valid(win) or not buf or not api.nvim_buf_is_valid(buf) then
    return nil, "the cursor is not in the diff"
  end
  local cursor = api.nvim_win_get_cursor(win)
  local row = opts.row or cursor[1]
  local col = opts.col or cursor[2]

  if not M.has_lines(view.diff) then
    return nil, "this file has no lines for the language server"
  end
  local record = map:row(row)
  if not record or (not record.old and not record.new) then
    return nil, "this row holds no line of the file"
  end

  local sources = M.sources(view)
  if not sources.new and not sources.old then
    return nil, "the working copy holds no " .. view.path
  end

  local order = first == "old" and { "old", "new" } or { "new", "old" }
  for _, side in ipairs(order) do
    local line = record[side]
    local source = sources[side]
    if line and source and M.sync(view.session, source) then
      local file_line = M.to_file(source, line)
      if file_line then
        if opts.note then
          note_once(view.session, source, opts.note)
        end
        local row_text = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
        local prefix = M.prefix(row_text, source.lines[line] or "")
        local text = api.nvim_buf_get_lines(source.buf, file_line - 1, file_line, false)[1] or ""
        return {
          source = source,
          side = side,
          line = line,
          file_line = file_line,
          col = math.min(math.max(col - prefix, 0), #text),
          row = row,
          prefix = prefix,
        },
          nil
      end
    end
  end
  return nil, "the working copy does not hold this line of " .. view.path
end

---Line of the review for a line of a file of the working copy.
---
--- The new side answers first, because the working copy holds the newer
--- version of a file in most reviews.
---@param view codeview.view.State
---@param file string Absolute path of the file.
---@param file_line integer Line of the working copy, from 1.
---@return integer? line Line of the side. Nil when no side holds the line.
---@return codeview.linemap.Side? side
function M.review_line(view, file, file_line)
  local sources = M.sources(view)
  for _, side in ipairs({ "new", "old" }) do
    local source = sources[side]
    if source and M.same_file(source.file, file) and M.sync(view.session, source) then
      local line = M.from_file(source, file_line)
      if line then
        return line, side
      end
    end
  end
  return nil, nil
end

---Report whether two paths name the same file.
---
--- A language server can give the real path of a file, and the review can
--- hold a path through a symbolic link. On macOS, for example, /var is a link
--- to /private/var.
---@param a string
---@param b string
---@return boolean
function M.same_file(a, b)
  if vim.fs.normalize(a) == vim.fs.normalize(b) then
    return true
  end
  local real_a, real_b = vim.uv.fs_realpath(a), vim.uv.fs_realpath(b)
  return real_a ~= nil and real_a == real_b
end

return M
