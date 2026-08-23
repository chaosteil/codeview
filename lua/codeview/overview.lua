---@brief The comment overview sidebar.
---
--- The overview shows every comment of the session in one panel. It groups the
--- comments under the file that holds them, in the same tree as the
--- changed-files sidebar: directory nodes, file nodes, and indent guides. A
--- comment is a child of its file node. Every node shows the number of
--- comments below it.
---
--- One comment line holds the line range, the side, the commit, and the first
--- line of the body. The sign of the line reports the state: the open sign of
--- the `comments.sign` option, or the resolved sign of the
--- `comments.resolved_sign` option.
---
--- `<CR>` on a comment opens the diff of the file and moves the cursor to the
--- anchor of the comment. A collapsed section that hides the line shows its
--- lines again.
---
--- The keys for edit, delete, and resolve act on the comment under the cursor.
--- Each of them writes the session file and sends an event of
--- |codeview.events|, so the diff view draws its extmarks again at once.
---
--- The overview uses |codeview.panel| for the window and |codeview.tree| for
--- the tree, like the changed-files sidebar. The plugin keeps one overview. It
--- belongs to the session that runs, and it closes with that session.

local comments_mod = require("codeview.comments")
local config = require("codeview.config")
local errors = require("codeview.error")
local message = require("codeview.message")
local events = require("codeview.events")
local highlight = require("codeview.highlight")
local panel = require("codeview.panel")
local session_mod = require("codeview.session")
local store_mod = require("codeview.store")
local tree = require("codeview.tree")
local util = require("codeview.util")
local view = require("codeview.view")

local api = vim.api
local fn = vim.fn

local before = util.comment_before

local M = {}

---@class codeview.overview.Item
---@field kind "dir"|"file"|"comment"|"remote-file"|"remote" Kind of the line.
---@field path string Path of the file, or of the directory. A remote line prefixes it with `remote:`.
---@field node codeview.tree.Node? Tree node of a directory line or a file line.
---@field comment codeview.store.Comment? Comment of a comment line.
---@field remote codeview.remote.Comment? Comment of a remote line.
---@field count integer Number of comments below the line.
---@field resolved integer Number of resolved comments below the line.
---@field expanded boolean? True while a directory or a file shows its children.
---@field missing boolean? True for a file that the range does not change.

---@class codeview.Overview
---@field session codeview.Session Session that the overview shows.
---@field panel codeview.Panel Window of the overview.
---@field tree codeview.tree.Node Root of the tree of the last render.
---@field current string? Path of the file that the diff view shows.
---@field expanded table<string, boolean> Expanded state per directory and per file.
---@field private autocmds integer[] Autocmds that close with the overview.
---@field private subscriptions integer[] Event handlers that close with the overview.
local Overview = {}
Overview.__index = Overview

---Overview that runs now.
---@type codeview.Overview?
local current = nil

--- Comments ---------------------------------------------------------------

---Comments of the session, by file.
---@param self codeview.Overview
---@return table<string, codeview.store.Comment[]> by_file
---@return string[] files Paths of the files that hold a comment.
local function group(self)
  local store = comments_mod.store(self.session)
  ---@type table<string, codeview.store.Comment[]>
  local by_file = {}
  local files = {}
  for _, comment in ipairs(store and store.comments or {}) do
    if not by_file[comment.file] then
      by_file[comment.file] = {}
      files[#files + 1] = comment.file
    end
    local list = by_file[comment.file]
    list[#list + 1] = comment
  end
  for _, list in pairs(by_file) do
    table.sort(list, before)
  end
  table.sort(files)
  return by_file, files
end

---Number of comments below one node.
---@param node codeview.tree.Node
---@param by_file table<string, codeview.store.Comment[]>
---@return integer count
---@return integer resolved
local function count_of(node, by_file)
  if node.kind == "file" then
    local count, resolved = 0, 0
    for _, comment in ipairs(by_file[node.path] or {}) do
      count = count + 1
      resolved = resolved + (comment.state == "resolved" and 1 or 0)
    end
    return count, resolved
  end
  local count, resolved = 0, 0
  for _, child in ipairs(node.children) do
    local child_count, child_resolved = count_of(child, by_file)
    count, resolved = count + child_count, resolved + child_resolved
  end
  return count, resolved
end

--- Lines ------------------------------------------------------------------

---Cut a text to a number of screen cells.
---@param text string
---@param width integer Number of cells.
---@return string
local function fit(text, width)
  if width <= 0 then
    return ""
  end
  if fn.strdisplaywidth(text) <= width then
    return text
  end
  local out = fn.strcharpart(text, 0, width)
  while fn.strchars(out) > 0 and fn.strdisplaywidth(out) > width - 1 do
    out = fn.strcharpart(out, 0, fn.strchars(out) - 1)
  end
  return out .. "…"
end

---Short form of a commit id.
---@param rev string?
---@return string
local function short(rev)
  rev = rev or ""
  if #rev >= 12 and rev:match("^%x+$") then
    return rev:sub(1, 7)
  end
  return rev
end

---Text of the line range of a comment.
---@param comment codeview.store.Comment
---@return string
local function range_text(comment)
  if comment.start_line == comment.end_line then
    return "L" .. comment.start_line
  end
  return string.format("L%d-%d", comment.start_line, comment.end_line)
end

---First line of the body of a comment.
---@param comment codeview.store.Comment
---@return string
local function preview_text(comment)
  for _, line in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
    local text = vim.trim(line)
    if text ~= "" then
      return text
    end
  end
  return ""
end

---Count of the comments of a session.
---@param count integer
---@param resolved integer
---@return string
local function counts(count, resolved)
  if count == 0 then
    return "no comments"
  end
  local text = string.format("%d %s", count, count == 1 and "comment" or "comments")
  if resolved > 0 then
    text = text .. string.format(", %d resolved", resolved)
  end
  return text
end

---Build the line of one directory node or file node.
---@param item codeview.overview.Item
---@param is_current boolean True for the file that the diff view shows.
---@return codeview.panel.Line
local function node_line(item, is_current)
  local icons = config.get().sidebar.icons
  local node = item.node --[[@as codeview.tree.Node]]
  local line = panel.builder()

  line.add(is_current and icons.current .. " " or "  ", is_current and "CodeViewMarker" or nil)
  line.add(string.rep(icons.guide .. " ", node.depth), "CodeViewIndent")

  local group_name = node.kind == "dir" and "CodeViewDir" or nil
  line.add(item.expanded and icons.expanded or icons.collapsed, group_name)
  line.add(" ")
  -- A file that the range does not change any more keeps its comments, but the
  -- jump key cannot open it. The dim name reports that.
  line.add(node.name, item.missing and "CodeViewHint" or group_name)
  line.add(" " .. tostring(item.count), "CodeViewCount")

  return line.build({ hl = is_current and node.kind == "file" and "CodeViewCurrent" or nil, data = item })
end

---Build the line of one comment.
---@param item codeview.overview.Item
---@param depth integer Depth of the line in the tree.
---@param width integer Width of the panel, in columns.
---@return codeview.panel.Line
local function comment_line(item, depth, width)
  local icons = config.get().sidebar.icons
  local comment = item.comment --[[@as codeview.store.Comment]]
  local resolved = comment.state == "resolved"
  local line = panel.builder()

  line.add("  ")
  line.add(string.rep(icons.guide .. " ", depth), "CodeViewIndent")

  local sign = comments_mod.sign(comment)
  if sign ~= "" then
    line.add(sign .. " ", comments_mod.sign_group(comment))
  end
  line.add(range_text(comment), resolved and "CodeViewComment" or "CodeViewCommentHeader")
  line.add(" " .. comment.side, "CodeViewHint")
  local rev = short(comment.commit)
  if rev ~= "" then
    line.add(" " .. rev, "CodeViewCount")
  end
  if store_mod.is_synced(comment) then
    line.add(" synced", "CodeViewCount")
  end

  local preview = preview_text(comment)
  if preview ~= "" then
    line.add(" " .. fit(preview, width - fn.strdisplaywidth(line.text()) - 1))
  end

  return line.build({ hl = resolved and "CodeViewComment" or nil, data = item })
end

---Key of the expanded state of a file of the remote section.
---@param path string Path of the file.
---@return string
local function remote_key(path)
  return "remote:" .. path
end

---Comments of the pull request of the session, by file.
---@param self codeview.Overview
---@return table<string, codeview.remote.Comment[]> by_file
---@return string[] files Paths of the files that hold a remote comment.
---@return integer count Number of remote comments.
local function remote_group(self)
  ---@type table<string, codeview.remote.Comment[]>
  local by_file = {}
  local files, count = {}, 0
  for _, comment in ipairs(require("codeview.remote").list(self.session)) do
    if not by_file[comment.file] then
      by_file[comment.file] = {}
      files[#files + 1] = comment.file
    end
    local list = by_file[comment.file]
    list[#list + 1] = comment
    count = count + 1
  end
  for _, list in pairs(by_file) do
    table.sort(list, function(a, b)
      if a.start_line ~= b.start_line then
        return a.start_line < b.start_line
      end
      return a.id < b.id
    end)
  end
  table.sort(files)
  return by_file, files, count
end

---Build the line of one file of the remote section.
---@param path string Path of the file.
---@param count integer Number of remote comments of the file.
---@param expanded boolean
---@return codeview.panel.Line
local function remote_file_line(path, count, expanded)
  local icons = config.get().sidebar.icons
  local line = panel.builder()
  line.add("  ")
  line.add(icons.guide .. " ", "CodeViewIndent")
  line.add(expanded and icons.expanded or icons.collapsed)
  line.add(" ")
  line.add(path)
  line.add(" " .. tostring(count), "CodeViewCount")
  return line.build({
    data = { kind = "remote-file", path = remote_key(path), count = count, resolved = 0, expanded = expanded },
  })
end

---Build the line of one remote comment.
---@param comment codeview.remote.Comment
---@param width integer Width of the panel, in columns.
---@return codeview.panel.Line
local function remote_comment_line(comment, width)
  local remote_mod = require("codeview.remote")
  local icons = config.get().sidebar.icons
  local line = panel.builder()

  line.add("  ")
  line.add(string.rep(icons.guide .. " ", 2), "CodeViewIndent")
  local sign = remote_mod.sign()
  if sign ~= "" then
    line.add(sign .. " ", comment.outdated and "CodeViewRemoteOutdated" or "CodeViewRemoteSign")
  end
  line.add(range_text(comment), "CodeViewRemoteHeader")
  line.add(" " .. comment.side, "CodeViewHint")
  if comment.author ~= "" then
    line.add(" @" .. comment.author, "CodeViewCount")
  end
  if comment.outdated then
    line.add(" outdated", "CodeViewRemoteOutdated")
  end

  local preview = preview_text(comment)
  if preview ~= "" then
    line.add(" " .. fit(preview, width - fn.strdisplaywidth(line.text()) - 1))
  end

  ---@type codeview.overview.Item
  local item = {
    kind = "remote",
    path = remote_key(comment.file),
    remote = comment,
    count = 1,
    resolved = 0,
  }
  return line.build({ hl = "CodeViewRemote", data = item })
end

---Build the lines of the comments that the pull request holds.
---
--- The section comes after the local comments, because it is read-only: the
--- reviewer works in the local section and reads this one.
---@param self codeview.Overview
---@param lines codeview.panel.Line[] Lines of the render, in place.
---@return integer count Number of remote comments.
local function render_remote(self, lines)
  local by_file, files, count = remote_group(self)
  if count == 0 then
    return 0
  end

  lines[#lines + 1] = { text = "" }
  lines[#lines + 1] = {
    text = string.format("%d remote %s", count, count == 1 and "comment" or "comments"),
    hl = "CodeViewRemoteHeader",
  }
  for _, path in ipairs(files) do
    local list = by_file[path]
    local expanded = self.expanded[remote_key(path)] ~= false
    lines[#lines + 1] = remote_file_line(path, #list, expanded)
    if expanded then
      for _, comment in ipairs(list) do
        lines[#lines + 1] = remote_comment_line(comment, self.panel.width)
      end
    end
  end
  return count
end

---Build every line of the overview.
---
--- The call builds the tree again. A new comment, a refresh of the session,
--- and a change of the expanded state then all reach the window.
---@param self codeview.Overview
---@return codeview.panel.Line[]
local function render_lines(self)
  local by_file, files = group(self)

  ---@type codeview.vcs.FileChange[]
  local changed = {}
  ---@type table<string, boolean>
  local missing = {}
  for index, path in ipairs(files) do
    local file = self.session:index_of(path)
    local held = file and assert(self.session:file(file)) or nil
    changed[index] = {
      path = path,
      status = held and held.status or "unknown",
      virtual = (held and held.virtual) or message.is(path),
      label = (held and held.label) or (message.is(path) and message.display(path, self.session) or nil),
      group = held and held.group or nil,
      group_path = held and held.group_path or nil,
    }
    missing[path] = file == nil
  end

  self.tree = tree.build(changed, { expanded = self.expanded })
  local total, resolved = count_of(self.tree, by_file)

  ---@type codeview.panel.Line[]
  local lines = {
    { text = self.session:label(), hl = "CodeViewTitle" },
    { text = counts(total, resolved), hl = "CodeViewCount" },
    { text = "" },
  }
  if total == 0 then
    lines[#lines + 1] = { text = "  no comments", hl = "CodeViewHint" }
    render_remote(self, lines)
    return lines
  end

  for _, node in ipairs(tree.visible(self.tree)) do
    local count, done = count_of(node, by_file)
    ---@type codeview.overview.Item
    local item = {
      kind = node.kind,
      path = node.path,
      node = node,
      count = count,
      resolved = done,
      expanded = self.expanded[node.path] ~= false,
      missing = node.kind == "file" and missing[node.path] or false,
    }
    lines[#lines + 1] = node_line(item, node.kind == "file" and node.path == self.current)

    if node.kind == "file" and item.expanded then
      for _, comment in ipairs(by_file[node.path] or {}) do
        lines[#lines + 1] = comment_line({
          kind = "comment",
          path = node.path,
          comment = comment,
          count = 1,
          resolved = comment.state == "resolved" and 1 or 0,
        }, node.depth + 1, self.panel.width)
      end
    end
  end
  render_remote(self, lines)
  return lines
end

--- Overview ---------------------------------------------------------------

---Report an error of an action of the overview.
---@param err codeview.Error|string
local function report(err)
  vim.notify("codeview: " .. tostring(err), vim.log.levels.INFO)
end

---Render the overview again.
---@return boolean rendered
function Overview:render()
  return self.panel:render()
end

---Report whether the window of the overview is open.
---@return boolean
function Overview:is_open()
  return self.panel:is_open()
end

---Put the cursor in the overview.
---@return boolean moved
function Overview:focus()
  return self.panel:focus()
end

---Comments of the session, in the order of the render.
---@return codeview.store.Comment[] comments
function Overview:comments()
  local out = {}
  for lnum = 1, self.panel:line_count() do
    local item = self.panel:data(lnum)
    if type(item) == "table" and item.kind == "comment" then
      out[#out + 1] = item.comment
    end
  end
  return out
end

---Item of the line under the cursor.
---@return codeview.overview.Item? item Nil on a header line.
function Overview:cursor_item()
  local data = self.panel:cursor_data()
  if type(data) == "table" and data.kind then
    return data
  end
  return nil
end

---Comment of the line under the cursor.
---
--- On a file line the call takes the first comment of the file.
---@return codeview.store.Comment? comment Nil without a comment on the line.
function Overview:cursor_comment()
  local item = self:cursor_item()
  if not item then
    return nil
  end
  if item.comment then
    return item.comment
  end
  if item.kind == "file" then
    local by_file = group(self)
    return (by_file[item.path] or {})[1]
  end
  return nil
end

---Remote comments of the session, in the order of the render.
---@return codeview.remote.Comment[] comments
function Overview:remote()
  local out = {}
  for lnum = 1, self.panel:line_count() do
    local item = self.panel:data(lnum)
    if type(item) == "table" and item.kind == "remote" then
      out[#out + 1] = item.remote
    end
  end
  return out
end

---Remote comment of the line under the cursor.
---@return codeview.remote.Comment? comment Nil outside the remote section.
function Overview:cursor_remote()
  local item = self:cursor_item()
  if not item then
    return nil
  end
  if item.remote then
    return item.remote
  end
  if item.kind == "remote-file" then
    local by_file = remote_group(self)
    return (by_file[item.path:gsub("^remote:", "")] or {})[1]
  end
  return nil
end

---Report that a remote comment does not change.
---@param self codeview.Overview
---@return boolean remote True when the cursor is on a line of the remote section.
local function read_only(self)
  local item = self:cursor_item()
  if item and (item.kind == "remote" or item.kind == "remote-file") then
    report("the review comments of GitHub are read-only")
    return true
  end
  return false
end

---Move the cursor to the line of one comment.
---@param id string Id of the comment.
---@return boolean moved False when the overview hides the comment.
function Overview:go_to(id)
  local lnum = self.panel:find(function(item)
    return item.kind == "comment" and item.comment.id == id
  end)
  if not lnum then
    return false
  end
  return self.panel:set_cursor(lnum)
end

---Open the diff of one comment and move the cursor to its anchor.
---
--- A diff that the `diff.max_lines` limit stopped reads again, without the
--- limit. A cursor that cannot reach the anchor gives an error to the callback,
--- or a message without one.
---@param comment codeview.store.Comment|codeview.remote.Comment Comment to show.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return boolean started False when the range does not change the file.
function Overview:jump(comment, cb)
  local index = self.session:index_of(comment.file)
  if not index then
    local err = errors.new(errors.codes.NOT_FOUND, "the range does not change " .. comment.file)
    if cb then
      cb(nil, err)
    else
      report(err)
    end
    return false
  end

  ---@param state codeview.view.State?
  ---@param err codeview.Error?
  local function place(state, err)
    if state and not view.go_to_line(comment.start_line, comment.side, { focus = true }) then
      err = errors.new(
        errors.codes.NOT_FOUND,
        string.format("the diff of %s holds no line %d", comment.file, comment.start_line)
      )
    end
    if err and not cb then
      report(err)
    end
    if cb then
      cb(state, err)
    end
  end

  -- A diff that the `diff.max_lines` limit stopped holds the note rows only,
  -- and no row of the comment. The forced read renders the file, so the cursor
  -- reaches the anchor.
  ---@param state codeview.view.State?
  ---@param err codeview.Error?
  local function arrive(state, err)
    if state and state.diff.limited then
      view.open(self.session, index, { force = true }, place)
      return
    end
    place(state, err)
  end

  -- The path, and not the index, tells whether the diff shows the file. A
  -- refresh of the session can move a file to another position in the list.
  local state = view.current()
  if state and state.session == self.session and state.path == comment.file then
    arrive(state, nil)
    return true
  end
  view.open(self.session, index, arrive)
  return true
end

---Act on the line under the cursor.
---
--- A comment line opens its anchor in the diff view. A file line opens the
--- first comment of the file. A directory line changes its expanded state. A
--- line of the remote section works in the same way, with the comments of the
--- pull request.
---
--- The return value reports the start of the action only. The result of the
--- jump arrives at the callback, because the diff loads without a block.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return boolean acted False on a header line.
function Overview:open_cursor(cb)
  local item = self:cursor_item()
  if not item then
    return false
  end
  if item.kind == "dir" or item.kind == "remote-file" then
    return self:toggle_node(item)
  end
  local comment = item.kind == "remote" and self:cursor_remote() or self:cursor_comment()
  if not comment then
    return false
  end
  return self:jump(comment, cb)
end

---Change the expanded state of a directory node or a file node.
---
--- On a comment line the call acts on the file of the comment.
---@param item? codeview.overview.Item Item of the action. The item under the cursor by default.
---@return boolean toggled False without a node.
function Overview:toggle_node(item)
  item = item or self:cursor_item()
  if not item then
    return false
  end
  local path = item.path
  if item.kind == "dir" and path == "" then
    return false
  end
  -- A path without an entry is expanded, so the toggle answers false for it.
  self.expanded[path] = self.expanded[path] == false
  self:render()
  local lnum = self.panel:find(function(other)
    return other.kind ~= "comment" and other.kind ~= "remote" and other.path == path
  end)
  if lnum then
    self.panel:set_cursor(lnum)
  end
  return true
end

---Show the comments of every file.
function Overview:expand_all()
  self.expanded = {}
  self:render()
end

---Hide the children of every directory and of every file.
function Overview:collapse_all()
  tree.each(self.tree, function(node)
    self.expanded[node.path] = false
  end)
  local _, files = remote_group(self)
  for _, path in ipairs(files) do
    self.expanded[remote_key(path)] = false
  end
  self:render()
end

---Open the editor for the comment under the cursor.
---@return boolean opened False without a comment on the line.
function Overview:edit()
  if read_only(self) then
    return false
  end
  local comment = self:cursor_comment()
  if not comment then
    report("no comment on this line")
    return false
  end
  return comments_mod.edit({ id = comment.id, session = self.session })
end

---Delete the comment under the cursor.
---@param opts? { confirm?: boolean } `confirm = false` skips the question.
---@return boolean removed False when no comment went away.
function Overview:remove(opts)
  if read_only(self) then
    return false
  end
  local comment = self:cursor_comment()
  if not comment then
    report("no comment on this line")
    return false
  end
  return comments_mod.remove({
    id = comment.id,
    session = self.session,
    confirm = (opts or {}).confirm,
  })
end

---Change the state of the comment under the cursor.
---@param state? codeview.store.State State to set. The other state by default.
---@return codeview.store.Comment? comment The comment after the change.
function Overview:set_state(state)
  if read_only(self) then
    return nil
  end
  local comment = self:cursor_comment()
  if not comment then
    report("no comment on this line")
    return nil
  end
  return comments_mod.set_state({ id = comment.id, state = state, session = self.session })
end

---Close the overview. The session stays open.
---@return boolean closed
function Overview:close()
  for _, id in ipairs(self.autocmds) do
    pcall(api.nvim_del_autocmd, id)
  end
  self.autocmds = {}
  for _, id in ipairs(self.subscriptions) do
    events.off(id)
  end
  self.subscriptions = {}
  if current == self then
    current = nil
  end
  return self.panel:close()
end

--- Module -----------------------------------------------------------------

---Keymaps of the overview buffer.
---@param overview codeview.Overview
---@return table<string, codeview.panel.Keymap>
local function keymaps(overview)
  local keys = config.get().keymaps
  ---@type table<string, codeview.panel.Keymap>
  local maps = {}

  ---@param value string|string[]|false Key of the configuration. False disables the map.
  ---@param action fun()
  ---@param desc string Text of the action, for `:map` and its readers.
  local function add(value, action, desc)
    for _, lhs in ipairs(config.keys(value)) do
      maps[lhs] = { fn = action, desc = desc }
    end
  end

  add(keys.open_file, function()
    overview:open_cursor()
  end, "open the comment under the cursor in the diff")
  add(keys.toggle_node, function()
    overview:toggle_node()
  end, "show or hide the comments of the file")
  add(keys.expand_all, function()
    overview:expand_all()
  end, "show the comments of every file")
  add(keys.collapse_all, function()
    overview:collapse_all()
  end, "hide the comments of every file")
  add(keys.edit_comment, function()
    overview:edit()
  end, "edit the comment under the cursor")
  add(keys.delete_comment, function()
    overview:remove()
  end, "delete the comment under the cursor")
  add(keys.resolve_comment, function()
    overview:set_state()
  end, "resolve the comment under the cursor, or open it again")
  add(keys.toggle_overview, function()
    overview:close()
  end, "close the comment overview")
  add(keys.close, function()
    overview:close()
  end, "close the comment overview")
  return maps
end

---Watch the events of the session and of the comments.
---@param overview codeview.Overview
local function watch(overview)
  local group_id = overview.session:augroup()
  overview.autocmds[#overview.autocmds + 1] = api.nvim_create_autocmd("User", {
    group = group_id,
    pattern = "CodeViewFileOpened",
    desc = "Mark the open file in the codeview comment overview",
    callback = function(event)
      if event.data and event.data.session == overview.session.id then
        overview.current = event.data.path
        overview:render()
      end
    end,
  })
  overview.autocmds[#overview.autocmds + 1] = api.nvim_create_autocmd("User", {
    group = group_id,
    pattern = "CodeViewSessionRefreshed",
    desc = "Render the codeview comment overview again",
    callback = function(event)
      if event.data and event.data.id == overview.session.id then
        overview:render()
      end
    end,
  })
  overview.subscriptions[#overview.subscriptions + 1] = events.on(events.comment, function(data)
    if data.session == nil or data.session == overview.session.id then
      overview:render()
    end
  end)
  -- The comments of a pull request arrive after the session opens. The remote
  -- section shows them as soon as the answer is there.
  overview.subscriptions[#overview.subscriptions + 1] = events.on(events.remote, function(data)
    if data.session == nil or data.session == overview.session.id then
      overview:render()
    end
  end)
  overview.session:on_close(function()
    overview:close()
  end)
end

---Open the comment overview.
---
--- Without a session the call takes the session that runs. An overview of
--- another session closes first.
---@param opts? { session?: codeview.Session, focus?: boolean }
---@return codeview.Overview? overview Nil when no session runs.
---@return codeview.Error? err
function M.open(opts)
  opts = opts or {}
  local session = opts.session or session_mod.current()
  if not session or not session:is_active() then
    return nil, errors.new(errors.codes.INVALID_ARG, "no review session")
  end

  if current and current.session ~= session then
    current:close()
  end

  if not current then
    highlight.setup()
    local cfg = config.get().overview
    local overview = setmetatable({
      session = session,
      current = nil,
      expanded = {},
      tree = tree.build({}),
      autocmds = {},
      subscriptions = {},
    }, Overview)
    overview.panel = panel.new({
      title = "comments",
      filetype = "codeview-comments",
      position = cfg.position,
      width = cfg.width,
      render = function()
        return render_lines(overview)
      end,
      keymaps = keymaps(overview),
    })
    local state = view.current()
    if state and state.session == session then
      overview.current = state.path
    end
    current = overview
    watch(overview)
  end

  local overview = current --[[@as codeview.Overview]]
  local win = overview.panel:open({ focus = opts.focus })
  session:add_window(win)
  local buf = overview.panel:buffer()
  if buf then
    session:add_buffer(buf)
  end
  return overview, nil
end

---Read the overview that runs.
---@return codeview.Overview? overview
function M.get()
  return current
end

---Report whether the overview window is open.
---@return boolean
function M.is_open()
  return current ~= nil and current:is_open()
end

---Close the overview. The session stays open.
---@return boolean closed False when no overview is open.
function M.close()
  if not current then
    return false
  end
  return current:close()
end

---Render the overview again.
---@return boolean rendered False when no overview is open.
function M.refresh()
  if not current then
    return false
  end
  return current:render()
end

---Close the overview when it is open, and open it when it is closed.
---@param opts? { session?: codeview.Session, focus?: boolean }
---@return boolean open State after the call.
function M.toggle(opts)
  if M.is_open() then
    M.close()
    return false
  end
  return M.open(opts) ~= nil
end

return M
