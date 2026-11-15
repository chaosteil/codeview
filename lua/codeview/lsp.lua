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
---
--- The LSP keys of the diff run |codeview.lsp.run()|. A jump to a line of the
--- file of the view moves the cursor in the diff. A jump to another file of
--- the review opens the diff of that file. Every other jump opens the file
--- like the edit key, and the back key comes back. See |codeview-lsp|.

local config = require("codeview.config")
local notify = require("codeview.notify")

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
---@field origin codeview.view.Origin? Place of the review that a jump out of the review came from.
---@field watching boolean True after |M.attach()| made the autocmds of the session.

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

--- Requests ----------------------------------------------------------------------

---@class codeview.lsp.Action
---@field method string Method of the request.
---@field label string Name for the user.
---@field kind "jump"|"list"|"hover" What the answer does.

---Actions of the LSP keys, by the name of their `keymaps` entry.
---@type table<string, codeview.lsp.Action>
M.actions = {
  lsp_definition = { method = "textDocument/definition", label = "definition", kind = "jump" },
  lsp_declaration = { method = "textDocument/declaration", label = "declaration", kind = "jump" },
  lsp_type_definition = { method = "textDocument/typeDefinition", label = "type definition", kind = "jump" },
  lsp_implementation = { method = "textDocument/implementation", label = "implementation", kind = "jump" },
  lsp_references = { method = "textDocument/references", label = "references", kind = "list" },
  lsp_hover = { method = "textDocument/hover", label = "hover", kind = "hover" },
}

---Order of the actions for the keymaps.
---@type string[]
M.order = {
  "lsp_definition",
  "lsp_declaration",
  "lsp_type_definition",
  "lsp_implementation",
  "lsp_references",
  "lsp_hover",
}

---Number of requests of this Neovim. It names the newest request.
---@type integer
local requests = 0

---Report whether the option is on.
---@return boolean
function M.enabled()
  return config.get().lsp.enabled == true
end

---Place of the review under the cursor, for the back key.
---@param view codeview.view.State
---@return codeview.view.Origin
local function origin_of(view)
  return { path = view.path, line = require("codeview.view").cursor_line(view) }
end

---@class codeview.lsp.Answer
---@field client vim.lsp.Client
---@field result any Result of the request. Nil after an error.
---@field err table? Error of the request.

---Send one request from the cursor of the view to the language servers.
---
--- Every client of the buffer that supports the method gets the request. The
--- callback runs once, after the last answer. It does not run when the view
--- changed in the meantime, for example after a jump to another file.
---@param view codeview.view.State
---@param action codeview.lsp.Action
---@param extend fun(params: table, client: vim.lsp.Client, position: codeview.lsp.Position)? Adds fields to the parameters.
---@param cb fun(answers: codeview.lsp.Answer[], position: codeview.lsp.Position)
---@return boolean sent False with a note when no request went out.
function M.request(view, action, extend, cb)
  local position, reason = M.locate(view, { note = notify.info })
  if not position then
    notify.info(reason or "no line of the working copy here")
    return false
  end
  local source = position.source
  local clients = vim.lsp.get_clients({ bufnr = source.buf, method = action.method })
  if #clients == 0 then
    if #vim.lsp.get_clients({ bufnr = source.buf }) == 0 then
      notify.info("no language server is attached to " .. source.path)
    else
      notify.info(string.format("no language server of %s gives the %s", source.path, action.label))
    end
    return false
  end

  state_of(view.session).origin = origin_of(view)
  requests = requests + 1
  local ticket = requests
  local text = api.nvim_buf_get_lines(source.buf, position.file_line - 1, position.file_line, false)[1] or ""
  local answers = {}
  local waiting = #clients

  local function finish()
    waiting = waiting - 1
    if waiting > 0 then
      return
    end
    if ticket ~= requests or require("codeview.view").current() ~= view then
      return
    end
    cb(answers, position)
  end

  for _, client in ipairs(clients) do
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(source.buf) },
      position = {
        line = position.file_line - 1,
        character = vim.str_utfindex(text, client.offset_encoding, position.col, false),
      },
    }
    if extend then
      extend(params, client, position)
    end
    local ok = client:request(action.method, params, function(err, result)
      answers[#answers + 1] = { client = client, result = not err and result or nil, err = err }
      finish()
    end, source.buf)
    if not ok then
      finish()
    end
  end
  return true
end

---Text of one line of a file, from a loaded buffer or from the disk.
---@param file string Absolute path.
---@param line integer Line from 1.
---@return string text
local function line_text(file, line)
  if fn.bufexists(file) == 1 then
    local buf = fn.bufadd(file)
    if api.nvim_buf_is_loaded(buf) then
      return api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    end
  end
  local ok, lines = pcall(fn.readfile, file, "", line)
  return ok and lines[line] or ""
end

---Position in the file of the target of a location.
---@param location table Location or LocationLink of LSP.
---@param encoding string Position encoding of the client.
---@return string? file Absolute path.
---@return integer? line Line from 1.
---@return integer? col Byte column from 0.
local function target_of(location, encoding)
  local uri = location.targetUri or location.uri
  local range = location.targetSelectionRange or location.range
  if type(uri) ~= "string" or type(range) ~= "table" or type(range.start) ~= "table" then
    return nil, nil, nil
  end
  local file = vim.uri_to_fname(uri)
  local line = range.start.line + 1
  local text = line_text(file, line)
  local ok, col = pcall(vim.str_byteindex, text, encoding, range.start.character, false)
  return file, line, ok and col or 0
end

---Position of a file of the review in the file list.
---
--- A deleted file and a document hold no file of the working copy, so they
--- give no answer.
---@param session codeview.Session
---@param file string Absolute path.
---@return integer? index
function M.review_index(session, file)
  local target = vim.fs.normalize(file)
  local candidates = {}
  for index, entry in ipairs(session.files) do
    if not entry.virtual and entry.status ~= "deleted" then
      local full = M.file_of(session, entry.path)
      if full == target then
        return index
      end
      candidates[#candidates + 1] = { index = index, full = full }
    end
  end
  local real = vim.uv.fs_realpath(target)
  if not real then
    return nil
  end
  for _, candidate in ipairs(candidates) do
    if vim.uv.fs_realpath(candidate.full) == real then
      return candidate.index
    end
  end
  return nil
end

---Move the cursor of a view to a line of the review.
---@param view codeview.view.State
---@param line integer Line of the side.
---@param side codeview.linemap.Side
---@param col integer Byte column of the line, from 0.
---@return boolean moved
local function move(view, line, side, col)
  local view_mod = require("codeview.view")
  local row = view_mod.go_to_line(line, side, { focus = true })
  if not row then
    return false
  end
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local row_text = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local source = M.sources(view)[side]
  local prefix = M.prefix(row_text, source and source.lines[line] or "")
  pcall(api.nvim_win_set_cursor, win, { row, math.min(prefix + col, math.max(#row_text - 1, 0)) })
  return true
end

---Open a file outside the review, the same way as the edit key.
---@param view codeview.view.State
---@param file string
---@param line integer
---@param col integer
---@param origin codeview.view.Origin
local function open_file(view, file, line, col, origin)
  require("codeview.view").edit({ file = file, line = line, col = col, origin = origin, win = view.win })
end

---Go to the target of one location.
---
--- A line of the file of the view moves the cursor in the diff. A file of the
--- review opens its diff. Every other target opens like the edit key, and the
--- back key comes back.
---@param view codeview.view.State
---@param location table Location or LocationLink of LSP.
---@param encoding string Position encoding of the client.
function M.land(view, location, encoding)
  local file, line, col = target_of(location, encoding)
  if not file or not line or not col then
    notify.info("the language server gave no valid location")
    return
  end
  local origin = state_of(view.session).origin or origin_of(view)

  local review_line, side = M.review_line(view, file, line)
  if review_line and side then
    -- The jump list keeps the place, so CTRL-O comes back inside the diff.
    vim.cmd("normal! m'")
    move(view, review_line, side, col)
    return
  end

  local index = M.review_index(view.session, file)
  if index and index ~= view.index then
    require("codeview.view").open(view.session, index, { win = view.win }, function(next_view, err)
      if not next_view then
        notify.error(tostring(err))
        return
      end
      local next_line, next_side = M.review_line(next_view, file, line)
      if next_line and next_side then
        move(next_view, next_line, next_side, col)
      else
        open_file(next_view, file, line, col, origin)
      end
    end)
    return
  end

  open_file(view, file, line, col, origin)
end

---Locations of the answers, without a location that two answers hold.
---@param answers codeview.lsp.Answer[]
---@return { location: table, encoding: string }[]
local function locations_of(answers)
  local out, seen = {}, {}
  for _, answer in ipairs(answers) do
    local result = answer.result
    if type(result) == "table" then
      if result.uri or result.targetUri then
        result = { result }
      end
      for _, location in ipairs(result) do
        local uri = location.targetUri or location.uri
        local range = location.targetSelectionRange or location.range
        local key = vim.inspect({ uri, range and range.start })
        if uri and range and not seen[key] then
          seen[key] = true
          out[#out + 1] = { location = location, encoding = answer.client.offset_encoding }
        end
      end
    end
  end
  return out
end

---Put locations into the quickfix list and open it.
---@param title string
---@param found { location: table, encoding: string }[]
local function show_list(title, found)
  local items = {}
  for _, entry in ipairs(found) do
    vim.list_extend(items, vim.lsp.util.locations_to_items({ entry.location }, entry.encoding))
  end
  fn.setqflist({}, " ", { title = "codeview: " .. title, items = items })
  vim.cmd("botright copen")
end

---Show the hover answers in a float.
---@param answers codeview.lsp.Answer[]
local function show_hover(answers)
  local lines = {}
  for _, answer in ipairs(answers) do
    local result = answer.result
    if type(result) == "table" and result.contents then
      local part = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
      while #part > 0 and vim.trim(part[#part]) == "" do
        part[#part] = nil
      end
      if #part > 0 then
        if #lines > 0 then
          lines[#lines + 1] = "---"
        end
        vim.list_extend(lines, part)
      end
    end
  end
  if #lines == 0 then
    notify.info("the language server gave no hover text")
    return
  end
  vim.lsp.util.open_floating_preview(lines, "markdown", {
    focus_id = "codeview.lsp.hover",
    border = config.get().comments.border,
  })
end

---Run the action of one LSP key in the view.
---@param name string Name of the `keymaps` entry, for example "lsp_definition".
---@return boolean sent False with a note when no request went out.
function M.run(name)
  local action = M.actions[name]
  local view = require("codeview.view").current()
  if not action then
    return false
  end
  if not view then
    notify.info("no file of the review")
    return false
  end
  if action.kind == "hover" then
    return M.request(view, action, nil, function(answers)
      show_hover(answers)
    end)
  end
  local extend = nil
  if action.kind == "list" then
    extend = function(params)
      params.context = { includeDeclaration = true }
    end
  end
  return M.request(view, action, extend, function(answers)
    local found = locations_of(answers)
    if #found == 0 then
      notify.info("no " .. action.label .. " found")
      return
    end
    if action.kind == "jump" and #found == 1 then
      M.land(view, found[1].location, found[1].encoding)
      return
    end
    show_list(action.label, found)
  end)
end

--- Attach -----------------------------------------------------------------------

---Map the LSP keys in a diff buffer.
---@param session codeview.Session
---@param buf integer
function M.set_keymaps(session, buf)
  local keys = config.get().keymaps
  for _, name in ipairs(M.order) do
    for _, lhs in ipairs(config.keys(keys[name])) do
      vim.keymap.set("n", lhs, function()
        M.run(name)
      end, { buffer = buf, nowait = true, silent = true, desc = "codeview: LSP " .. M.actions[name].label })
    end
  end
  -- A jump of the quickfix list leaves the diff. The place under the cursor
  -- is the way back.
  api.nvim_create_autocmd("BufLeave", {
    group = session:augroup(),
    buffer = buf,
    desc = "Keep the place of the codeview diff for the back key",
    callback = function()
      local view = require("codeview.view").current()
      if view and view.session == session and (view.buf == buf or view.old_buf == buf) then
        state_of(session).origin = origin_of(view)
      end
    end,
  })
end

---Watch the windows of the view for a file that a jump opens there.
---@param session codeview.Session
local function watch(session)
  local entry = state_of(session)
  if entry.watching then
    return
  end
  entry.watching = true
  api.nvim_create_autocmd("BufWinEnter", {
    group = session:augroup(),
    desc = "Give the codeview window to a file that a jump opened",
    callback = function(args)
      local buf = args.buf
      local name = api.nvim_buf_get_name(buf)
      if vim.bo[buf].buftype ~= "" or name == "" or vim.startswith(name, "codeview://") then
        return
      end
      local win = api.nvim_get_current_win()
      if api.nvim_win_get_buf(win) ~= buf or not entry.origin then
        return
      end
      require("codeview.view").release_window(win, buf, entry.origin)
    end,
  })
end

---Load the files of the working copy for a view.
---
--- The view calls this after each render. The first call for a view loads the
--- files, so the language servers start while the reader reads the diff.
---@param view codeview.view.State
function M.attach(view)
  if not view.session:is_active() then
    return
  end
  M.sources(view)
  watch(view.session)
end

return M
