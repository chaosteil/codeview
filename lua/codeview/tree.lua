---@brief The file tree of a session.
---
--- The module turns the flat file list of the backend into a tree of
--- directory nodes and file nodes. The tree is data only. The sidebar renders
--- it, and the tests read it without a window.
---
--- A chain of directories with one child each becomes one node, like
--- neo-tree. The path `lua/codeview/vcs/git.lua` alone gives one directory
--- node `lua/codeview/vcs` and one file node `git.lua`.
---
--- The children of a node come in one order: directories first, then files,
--- both by name. |codeview.tree.order()| gives the same order as a flat list
--- of positions, for the next-file and previous-file keys.
---
--- The module also holds the status mark of each file status. The sidebar and
--- the commit documents of |codeview.message| show the same marks.
---
--- A caller can give the number of comments of each path. Every node then
--- holds the number of comments of the files below it. The sidebar shows a
--- comment mark from it.

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
  message = "",
  unknown = "?",
}

---Status mark of one status.
---@param status codeview.vcs.Status? Status of a file. An unknown status gives the mark of `unknown`.
---@return string mark
function M.mark(status)
  return M.marks[status] or M.marks.unknown
end

---Order of the statuses of a directory node.
---@type codeview.vcs.Status[]
local STATUS_ORDER = {
  "added",
  "modified",
  "deleted",
  "renamed",
  "copied",
  "typechanged",
  "unmerged",
  "unknown",
}

---@class codeview.tree.Node
---@field kind "dir"|"file" Kind of the node.
---@field name string Name in the sidebar. A collapsed chain holds separators.
---@field path string Path from the root of the repository.
---@field depth integer Depth in the tree, from 0.
---@field children codeview.tree.Node[] Children of a directory node.
---@field parent codeview.tree.Node? Parent node. Nil for the root.
---@field expanded boolean True while a directory node shows its children.
---@field statuses codeview.vcs.Status[] Statuses of the files of the node.
---@field comments integer Number of comments of the files of the node. See |codeview.tree.Opts|.
---@field file codeview.vcs.FileChange? Changed file of a file node.
---@field index integer? Position of the file in the file list of the session.
---@field virtual boolean? True for a file that the repository does not hold, like the commit message.
---@field order integer? Position among the virtual nodes. See |codeview.vcs.FileChange|.

---Split a path into its directory and its name.
---@param path string
---@return string dir Directory without the last separator, or an empty text.
---@return string name
local function split(path)
  local dir, name = path:match("^(.*)/([^/]*)$")
  if not dir then
    return "", path
  end
  return dir, name
end

---Compare two nodes: directories first, then names.
---@param a codeview.tree.Node
---@param b codeview.tree.Node
---@return boolean
local function before(a, b)
  -- The commit message reads before the code that it describes.
  if (a.virtual or false) ~= (b.virtual or false) then
    return a.virtual == true
  end
  -- A virtual node takes its place from its order. The pull request reads
  -- before the commits.
  if a.virtual and b.virtual and (a.order or 0) ~= (b.order or 0) then
    return (a.order or 0) < (b.order or 0)
  end
  -- Virtual files of one group keep the order of the list. The commits keep
  -- the order of the log, not the order of their names.
  if a.virtual and b.virtual and a.kind == "file" and b.kind == "file" then
    return (a.index or 0) < (b.index or 0)
  end
  if a.kind ~= b.kind then
    return a.kind == "dir"
  end
  return a.name < b.name
end

---Make a directory node.
---@param name string
---@param path string
---@return codeview.tree.Node
local function dir_node(name, path)
  return {
    kind = "dir",
    name = name,
    path = path,
    depth = 0,
    children = {},
    expanded = true,
    statuses = {},
    comments = 0,
  }
end

---Node that holds the virtual files of one group.
---
--- The group node reads like a directory, but it names no directory of the
--- repository. The commits of a range sit under one such node.
---@param root codeview.tree.Node
---@param dirs table<string, codeview.tree.Node> Nodes by path.
---@param file codeview.vcs.FileChange
---@return codeview.tree.Node
local function group_node(root, dirs, file)
  local path = file.group_path or file.group --[[@as string]]
  local node = dirs[path]
  if node then
    return node
  end
  node = dir_node(file.group --[[@as string]], path)
  node.virtual = true
  node.order = file.order
  root.children[#root.children + 1] = node
  dirs[path] = node
  return node
end

---Sort the children of every directory node.
---@param node codeview.tree.Node
local function sort(node)
  table.sort(node.children, before)
  for _, child in ipairs(node.children) do
    if child.kind == "dir" then
      sort(child)
    end
  end
end

---Merge a chain of directories with one child each.
---@param node codeview.tree.Node Directory node. The root keeps its name.
---@param is_root boolean
local function collapse(node, is_root)
  for _, child in ipairs(node.children) do
    if child.kind == "dir" then
      collapse(child, false)
    end
  end
  if is_root then
    return
  end
  while #node.children == 1 and node.children[1].kind == "dir" do
    local only = node.children[1]
    node.name = node.name .. "/" .. only.name
    node.path = only.path
    node.children = only.children
  end
end

---Set the depth, the parent, the statuses, and the comment count of every node.
---@param node codeview.tree.Node
---@param depth integer
---@param expanded table<string, boolean> Expanded state per directory path.
local function finish(node, depth, expanded)
  node.depth = depth
  ---@type table<string, boolean>
  local seen = {}
  local comments = 0
  for _, child in ipairs(node.children) do
    child.parent = node
    finish(child, depth + 1, expanded)
    for _, status in ipairs(child.statuses) do
      seen[status] = true
    end
    comments = comments + child.comments
  end
  if node.kind == "dir" then
    node.expanded = expanded[node.path] ~= false
    node.comments = comments
    node.statuses = {}
    for _, status in ipairs(STATUS_ORDER) do
      if seen[status] then
        node.statuses[#node.statuses + 1] = status
      end
    end
  end
end

---@class codeview.tree.Opts
---@field expanded table<string, boolean>? Expanded state per directory path. Every directory is expanded by default.
---@field comments table<string, integer>? Number of comments per file path. A path without an entry has no comments.

---Build the tree of a file list.
---
--- The root node is not part of the render. Its children are the entries at
--- the top level of the repository.
---@param files codeview.vcs.FileChange[] Changed files of the session.
---@param opts? codeview.tree.Opts
---@return codeview.tree.Node root
function M.build(files, opts)
  opts = opts or {}
  local expanded = opts.expanded or {}
  local comments = opts.comments or {}

  local root = dir_node("", "")
  root.depth = -1

  ---@type table<string, codeview.tree.Node>
  local dirs = { [""] = root }

  ---Read a directory node, and make it with its parents when it is missing.
  ---@param path string
  ---@return codeview.tree.Node
  local function directory(path)
    local node = dirs[path]
    if node then
      return node
    end
    local parent_path, name = split(path)
    local parent = directory(parent_path)
    node = dir_node(name, path)
    parent.children[#parent.children + 1] = node
    dirs[path] = node
    return node
  end

  for index, file in ipairs(files or {}) do
    local parent
    local name
    if file.virtual then
      -- A virtual file has no path in the repository, so it takes no
      -- directory of the tree. Its group node holds it instead.
      name = file.label or file.path
      parent = file.group and group_node(root, dirs, file) or root
    else
      local parent_path
      parent_path, name = split(file.path)
      parent = directory(parent_path)
    end
    parent.children[#parent.children + 1] = {
      kind = "file",
      name = name,
      path = file.path,
      depth = 0,
      children = {},
      expanded = false,
      statuses = { file.status or "unknown" },
      comments = comments[file.path] or 0,
      file = file,
      index = index,
      virtual = file.virtual or false,
      order = file.order,
    }
  end

  collapse(root, true)
  sort(root)
  finish(root, -1, expanded)
  return root
end

---Visit every node of the tree, in the order of the sidebar.
---@param root codeview.tree.Node
---@param fn fun(node: codeview.tree.Node) Handler of one node. The root is not part of the walk.
---@param opts? { visible?: boolean } `visible = true` stops at a collapsed directory.
function M.each(root, fn, opts)
  local visible = (opts or {}).visible
  for _, child in ipairs(root.children) do
    fn(child)
    if child.kind == "dir" and (not visible or child.expanded) then
      M.each(child, fn, opts)
    end
  end
end

---Nodes that the sidebar shows, from the top.
---@param root codeview.tree.Node
---@return codeview.tree.Node[] nodes
function M.visible(root)
  local out = {}
  M.each(root, function(node)
    out[#out + 1] = node
  end, { visible = true })
  return out
end

---Directory nodes of the tree.
---@param root codeview.tree.Node
---@return codeview.tree.Node[] nodes
function M.dirs(root)
  local out = {}
  M.each(root, function(node)
    if node.kind == "dir" then
      out[#out + 1] = node
    end
  end)
  return out
end

---@class codeview.tree.OrderOpts
---@field expanded table<string, boolean>? Expanded state per directory path, as in |codeview.tree.Opts|.
---@field skip string[]? Paths of directory nodes. While such a node hides its children, the order leaves out its files.

---Positions of the files, in the order of the tree.
---
--- The order does not depend on the expanded state. The next-file key walks
--- every file of the session, in the order that the sidebar shows. A node of
--- `opts.skip` is the exception: while it hides its children, its files are
--- not part of the order.
---@param files codeview.vcs.FileChange[] Changed files of the session.
---@param opts? codeview.tree.OrderOpts
---@return integer[] order Positions in the file list of the session.
function M.order(files, opts)
  opts = opts or {}
  ---@type table<string, boolean>
  local skip = {}
  for _, path in ipairs(opts.skip or {}) do
    skip[path] = true
  end

  local out = {}
  ---@param node codeview.tree.Node
  local function walk(node)
    for _, child in ipairs(node.children) do
      if child.kind == "file" then
        out[#out + 1] = child.index
      elseif child.expanded or not skip[child.path] then
        walk(child)
      end
    end
  end
  walk(M.build(files, { expanded = opts.expanded }))
  return out
end

return M
