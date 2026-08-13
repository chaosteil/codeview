---@brief The changed-files sidebar.
---
--- The sidebar shows the files that the range of the session changes, as a
--- tree of directories and files. Every file line holds a status mark, `A`
--- for added, `M` for modified, `D` for deleted, and `R` for renamed. A
--- directory that hides its children shows the marks of the files below it.
---
--- The header holds the range, the number of files, and the number of
--- commits.
---
--- The sidebar uses |codeview.panel| for the window and |codeview.tree| for
--- the tree. It holds the file list only, so the panel stays free for the
--- comment overview of M8.
---
--- The plugin keeps one sidebar. It belongs to the session that runs, and it
--- closes with that session.

local config = require("codeview.config")
local errors = require("codeview.error")
local highlight = require("codeview.highlight")
local panel = require("codeview.panel")
local session_mod = require("codeview.session")
local tree = require("codeview.tree")
local view = require("codeview.view")

local api = vim.api

local M = {}

---Status mark of each file status.
---@type table<codeview.vcs.Status, string>
M.marks = {
  added = "A",
  modified = "M",
  deleted = "D",
  renamed = "R",
  copied = "C",
  typechanged = "T",
  unmerged = "U",
  unknown = "?",
}

---@class codeview.Sidebar
---@field session codeview.Session Session that the sidebar shows.
---@field panel codeview.Panel Window of the sidebar.
---@field tree codeview.tree.Node Root of the tree of the last render.
---@field current integer? Position of the file that the diff view shows.
---@field expanded table<string, boolean> Expanded state per directory path.
---@field private autocmds integer[] Autocmds that close with the sidebar.
local Sidebar = {}
Sidebar.__index = Sidebar

---Sidebar that runs now.
---@type codeview.Sidebar?
local current = nil

--- Lines ------------------------------------------------------------------

---Collect the text and the highlights of one line.
---@return { add: fun(chunk: string, hl?: string), build: fun(opts?: { hl?: string, data?: any }): codeview.panel.Line }
local function builder()
  local text = ""
  ---@type codeview.panel.Mark[]
  local marks = {}
  return {
    add = function(chunk, hl)
      if not chunk or chunk == "" then
        return
      end
      local from = #text
      text = text .. chunk
      if hl then
        marks[#marks + 1] = { hl = hl, from = from, to = #text }
      end
    end,
    build = function(opts)
      opts = opts or {}
      return { text = text, marks = marks, hl = opts.hl, data = opts.data }
    end,
  }
end

---Status mark of one status.
---@param status codeview.vcs.Status?
---@return string
local function mark_of(status)
  return M.marks[status] or M.marks.unknown
end

---Text of the old path of a rename or a copy.
---
--- A file that keeps its directory shows the old name only.
---@param file codeview.vcs.FileChange
---@return string
local function old_name(file)
  local old = file.old_path --[[@as string]]
  local old_dir = old:match("^(.*)/[^/]*$") or ""
  local new_dir = file.path:match("^(.*)/[^/]*$") or ""
  if old_dir == new_dir then
    return old:match("[^/]*$") --[[@as string]]
  end
  return old
end

---Count of the files and the commits of a session.
---@param session codeview.Session
---@return string
local function counts(session)
  local files, commits = #session.files, #session.commits
  return string.format(
    "%d %s, %d %s",
    files,
    files == 1 and "file" or "files",
    commits,
    commits == 1 and "commit" or "commits"
  )
end

---Build the line of one tree node.
---@param node codeview.tree.Node
---@param is_current boolean True for the file that the diff view shows.
---@return codeview.panel.Line
local function node_line(node, is_current)
  local icons = config.get().sidebar.icons
  local line = builder()

  line.add(is_current and icons.current .. " " or "  ", is_current and "CodeViewMarker" or nil)
  line.add(string.rep(icons.guide .. " ", node.depth), "CodeViewIndent")

  if node.kind == "dir" then
    line.add(node.expanded and icons.expanded or icons.collapsed, "CodeViewDir")
    line.add(" ")
    line.add(node.name, "CodeViewDir")
    if not node.expanded then
      line.add(" ")
      for _, status in ipairs(node.statuses) do
        line.add(mark_of(status), highlight.for_status(status))
      end
    end
    return line.build({ data = node })
  end

  local file = node.file --[[@as codeview.vcs.FileChange]]
  local group = highlight.for_status(file.status)
  line.add(icons.file)
  line.add(" ")
  line.add(node.name, group)
  if file.old_path then
    line.add(" ← " .. old_name(file), "CodeViewDir")
  end
  line.add(" ")
  line.add(mark_of(file.status), group)

  return line.build({ hl = is_current and "CodeViewCurrent" or nil, data = node })
end

---Build every line of the sidebar.
---
--- The call builds the tree again, so that a refresh of the session and a
--- change of the expanded state both reach the window.
---@param self codeview.Sidebar
---@return codeview.panel.Line[]
local function render_lines(self)
  local session = self.session
  ---@type codeview.panel.Line[]
  local lines = {
    { text = session:label(), hl = "CodeViewTitle" },
    { text = counts(session), hl = "CodeViewCount" },
    { text = "" },
  }

  self.tree = tree.build(session:changed_files(), { expanded = self.expanded })
  local nodes = tree.visible(self.tree)
  if #nodes == 0 then
    lines[#lines + 1] = { text = "  no changed files", hl = "CodeViewHint" }
    return lines
  end

  for _, node in ipairs(nodes) do
    lines[#lines + 1] = node_line(node, node.kind == "file" and node.index == self.current)
  end
  return lines
end

--- Sidebar --------------------------------------------------------------------

---Report an error of an action of the sidebar.
---@param err codeview.Error
local function report(err)
  vim.notify("codeview: " .. tostring(err), vim.log.levels.INFO)
end

---Render the sidebar again.
---@return boolean rendered
function Sidebar:render()
  return self.panel:render()
end

---Report whether the window of the sidebar is open.
---@return boolean
function Sidebar:is_open()
  return self.panel:is_open()
end

---Put the cursor in the sidebar.
---@return boolean moved
function Sidebar:focus()
  return self.panel:focus()
end

---Move the cursor to the line of one path.
---@param path string Path of a file node or a directory node.
---@return boolean moved False when the sidebar hides the path.
function Sidebar:go_to(path)
  local lnum = self.panel:find(function(node)
    return node.path == path
  end)
  if not lnum then
    return false
  end
  return self.panel:set_cursor(lnum)
end

---Node of the line under the cursor.
---@return codeview.tree.Node? node Nil on a header line.
function Sidebar:cursor_node()
  local data = self.panel:cursor_data()
  if type(data) == "table" and (data.kind == "file" or data.kind == "dir") then
    return data
  end
  return nil
end

---Show every directory above one file.
---
--- The marker of the current file needs a visible line. A collapsed directory
--- above the file opens again.
---@param self codeview.Sidebar
---@param index integer Position in the file list.
local function reveal(self, index)
  ---@type codeview.tree.Node?
  local target
  tree.each(tree.build(self.session:changed_files(), { expanded = self.expanded }), function(node)
    if node.kind == "file" and node.index == index then
      target = node
    end
  end)

  local node = target and target.parent
  while node and node.path ~= "" do
    self.expanded[node.path] = nil
    node = node.parent
  end
end

---Mark one file as the file of the diff view.
---
--- The call renders the sidebar again and moves the cursor to the file. A
--- collapsed directory above the file opens.
---@param index integer? Position in the file list. Nil clears the marker.
function Sidebar:set_current(index)
  self.current = index
  if index then
    reveal(self, index)
  end
  self:render()
  if not index then
    return
  end
  local lnum = self.panel:find(function(node)
    return node.kind == "file" and node.index == index
  end)
  if lnum then
    self.panel:set_cursor(lnum)
  end
end

---Show one changed file in the diff view.
---@param index integer Position in the file list.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
function Sidebar:open_file(index, cb)
  view.open(self.session, index, cb or function(_, err)
    if err then
      report(err)
    end
  end)
end

---Act on the line under the cursor.
---
--- A file line opens the file. A directory line changes its expanded state.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
---@return boolean acted False on a header line.
function Sidebar:open_cursor(cb)
  local node = self:cursor_node()
  if not node then
    return false
  end
  if node.kind == "dir" then
    return self:toggle_node(node)
  end
  self:open_file(node.index --[[@as integer]], cb)
  return true
end

---Change the expanded state of a directory.
---
--- On a file line the call acts on the directory of the file.
---@param node? codeview.tree.Node Node of the action. The node under the cursor by default.
---@return boolean toggled False without a directory node.
function Sidebar:toggle_node(node)
  node = node or self:cursor_node()
  if not node then
    return false
  end
  local dir = node.kind == "dir" and node or node.parent
  if not dir or dir.kind ~= "dir" or dir.path == "" then
    return false
  end
  self.expanded[dir.path] = not (self.expanded[dir.path] ~= false)
  self:render()
  self:go_to(dir.path)
  return true
end

---Show the children of every directory.
function Sidebar:expand_all()
  self.expanded = {}
  self:render()
end

---Hide the children of every directory.
function Sidebar:collapse_all()
  for _, node in ipairs(tree.dirs(self.tree)) do
    self.expanded[node.path] = false
  end
  self:render()
end

---Show the next changed file.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
function Sidebar:next_file(cb)
  view.next(self.session, cb or function(_, err)
    if err then
      report(err)
    end
  end)
end

---Show the previous changed file.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?)
function Sidebar:prev_file(cb)
  view.prev(self.session, cb or function(_, err)
    if err then
      report(err)
    end
  end)
end

---Close the sidebar. The session stays open.
---@return boolean closed
function Sidebar:close()
  for _, id in ipairs(self.autocmds) do
    pcall(api.nvim_del_autocmd, id)
  end
  self.autocmds = {}
  if current == self then
    current = nil
  end
  return self.panel:close()
end

--- Module ---------------------------------------------------------------------

---Keymaps of the sidebar buffer.
---@param sidebar codeview.Sidebar
---@return table<string, fun()>
local function keymaps(sidebar)
  local keys = config.get().keymaps
  ---@type table<string, fun()>
  local maps = {}

  ---@param lhs string|false Key of the configuration. False disables the map.
  ---@param action fun()
  local function add(lhs, action)
    if type(lhs) == "string" and lhs ~= "" then
      maps[lhs] = action
    end
  end

  add(keys.open_file, function()
    sidebar:open_cursor()
  end)
  add(keys.toggle_node, function()
    sidebar:toggle_node()
  end)
  add(keys.expand_all, function()
    sidebar:expand_all()
  end)
  add(keys.collapse_all, function()
    sidebar:collapse_all()
  end)
  add(keys.next_file, function()
    sidebar:next_file()
  end)
  add(keys.prev_file, function()
    sidebar:prev_file()
  end)
  add(keys.close, function()
    sidebar.session:close()
  end)
  return maps
end

---Watch the events of the session.
---@param sidebar codeview.Sidebar
local function watch(sidebar)
  local group = sidebar.session:augroup()
  sidebar.autocmds[#sidebar.autocmds + 1] = api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeViewFileOpened",
    desc = "Mark the open file in the codeview sidebar",
    callback = function(event)
      if event.data and event.data.session == sidebar.session.id then
        sidebar:set_current(event.data.index)
      end
    end,
  })
  sidebar.autocmds[#sidebar.autocmds + 1] = api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeViewSessionRefreshed",
    desc = "Render the codeview sidebar again",
    callback = function(event)
      if event.data and event.data.id == sidebar.session.id then
        sidebar:render()
      end
    end,
  })
  sidebar.session:on_close(function()
    sidebar:close()
  end)
end

---Open the changed-files sidebar.
---
--- Without a session the call takes the session that runs. A sidebar of
--- another session closes first.
---@param opts? { session?: codeview.Session, focus?: boolean }
---@return codeview.Sidebar? sidebar Nil when no session runs.
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
    local cfg = config.get().sidebar
    local sidebar = setmetatable({
      session = session,
      current = nil,
      expanded = {},
      tree = tree.build({}),
      autocmds = {},
    }, Sidebar)
    sidebar.panel = panel.new({
      title = "files",
      filetype = "codeview-files",
      position = cfg.position,
      width = cfg.width,
      render = function()
        return render_lines(sidebar)
      end,
      keymaps = keymaps(sidebar),
    })
    current = sidebar
    watch(sidebar)
  end

  local sidebar = current --[[@as codeview.Sidebar]]
  local win = sidebar.panel:open({ focus = opts.focus })
  session:add_window(win)
  local buf = sidebar.panel:buffer()
  if buf then
    session:add_buffer(buf)
  end
  return sidebar, nil
end

---Read the sidebar that runs.
---@return codeview.Sidebar? sidebar
function M.get()
  return current
end

---Report whether the sidebar window is open.
---@return boolean
function M.is_open()
  return current ~= nil and current:is_open()
end

---Close the sidebar. The session stays open.
---@return boolean closed False when no sidebar is open.
function M.close()
  if not current then
    return false
  end
  return current:close()
end

---Render the sidebar again.
---@return boolean rendered False when no sidebar is open.
function M.refresh()
  if not current then
    return false
  end
  return current:render()
end

---Close the sidebar when it is open, and open it when it is closed.
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
