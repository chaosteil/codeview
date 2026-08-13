---@brief The commits of the range, as files of the review.
---
--- A range holds commits, and a commit holds a message that says why the
--- change exists. This module gives every commit a file of its own, so the
--- sidebar lists them above the code, with the subject of each one. The
--- reviewer opens a commit like a file and comments on its message.
---
--- One commit document holds the header of the commit, its message, and the
--- files that the commit changes. It holds no diff: every row is a context row
--- of the new side, so a comment anchors to it through the same line map as a
--- comment on code. The commit of such a comment is the commit of the
--- document.
---
--- The path of a document is `codeview://commit/<id>`. The text is no relative
--- path, so it names no file of the repository and it collides with none.

local errors = require("codeview.error")

local M = {}

---Start of the path of every commit document.
---@type string
M.prefix = "codeview://commit/"

---Path of the group node that holds the commits in the tree.
---@type string
M.group_path = "codeview://commits"

---Status of a commit document in the file list.
---@type string
M.status = "message"

---Path of the document of one commit.
---@param id string Full commit id.
---@return string
function M.path_of(id)
  return M.prefix .. id
end

---Report whether a path names a commit document.
---@param path string?
---@return boolean
function M.is(path)
  return type(path) == "string" and path:sub(1, #M.prefix) == M.prefix
end

---Commit id of a document path.
---@param path string
---@return string? id Nil for a path of another file.
function M.commit_id(path)
  if not M.is(path) then
    return nil
  end
  return path:sub(#M.prefix + 1)
end

---Name of the group node for the user.
---@param count integer Number of commits.
---@return string
function M.group_label(count)
  return count == 1 and "Commit" or "Commits"
end

---Commit record of a session by its id.
---@param session codeview.Session
---@param id string?
---@return codeview.vcs.Commit? commit
function M.commit_of(session, id)
  for _, commit in ipairs(session and session.commits or {}) do
    if commit.id == id then
      return commit
    end
  end
  return nil
end

---Name of a commit document for the user.
---
--- The name holds the short id and the subject, so the sidebar reads like a
--- log. A commit without a subject takes its id alone.
---@param commit codeview.vcs.Commit
---@return string
function M.label(commit)
  local subject = vim.trim(commit.subject or "")
  local id = commit.short_id or commit.id:sub(1, 8)
  if subject == "" then
    return id
  end
  return id .. " " .. subject
end

---Name of a path for the user.
---
--- The sidebar, the comment overview, and the export send every path here, so
--- that a document reads as a name and not as an internal path.
---@param path string
---@param session codeview.Session?
---@return string
function M.display(path, session)
  if not M.is(path) then
    return path
  end
  local id = M.commit_id(path) --[[@as string]]
  local commit = M.commit_of(session, id)
  if commit then
    return M.label(commit)
  end
  return id:sub(1, 8)
end

---File records of the commits of a session, for the file list.
---
--- The commits read from the oldest to the newest, the order that the work
--- happened in.
---@param commits codeview.vcs.Commit[] Commits of the session, newest first.
---@return codeview.vcs.FileChange[]
function M.entries(commits)
  local out = {}
  local count = #commits
  for index = count, 1, -1 do
    local commit = commits[index]
    out[#out + 1] = {
      path = M.path_of(commit.id),
      status = M.status,
      virtual = true,
      label = M.label(commit),
      group = M.group_label(count),
      group_path = M.group_path,
      commit = commit,
    }
  end
  return out
end

--- Document ---------------------------------------------------------------

---Status mark of one changed file, for the file list of a commit.
---@param status codeview.vcs.Status?
---@return string
local function mark_of(status)
  local marks = require("codeview.sidebar").marks
  return marks[status] or marks.unknown
end

---Lines of the header and the message of a commit.
---@param commit codeview.vcs.Commit
---@return string[]
local function message_lines(commit)
  local lines = {
    string.format("commit %s", commit.id),
    string.format("Author: %s <%s>", commit.author, commit.author_email),
    string.format("Date:   %s", commit.date),
  }
  if commit.change_id then
    table.insert(lines, 2, string.format("change %s", commit.change_id))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "    " .. (commit.subject or "")
  local body = vim.trim(commit.body or "")
  if body ~= "" then
    lines[#lines + 1] = ""
    for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
      lines[#lines + 1] = line == "" and "" or ("    " .. line)
    end
  end
  return lines
end

---Lines of the file list of a commit.
---@param files codeview.vcs.FileChange[] Files that the commit changes.
---@return string[]
local function file_lines(files)
  local lines = { "" }
  if #files == 0 then
    lines[#lines + 1] = "This commit changes no file."
    return lines
  end
  lines[#lines + 1] = string.format("%d changed %s:", #files, #files == 1 and "file" or "files")
  lines[#lines + 1] = ""
  for _, file in ipairs(files) do
    local text = string.format("    %s  %s", mark_of(file.status), file.path)
    if file.old_path then
      text = text .. " ← " .. file.old_path
    end
    lines[#lines + 1] = text
  end
  return lines
end

---Range of one commit: the commit against its first parent.
---@param commit codeview.vcs.Commit
---@return codeview.vcs.Range
local function range_of(commit)
  return { from = commit.parents and commit.parents[1] or nil, to = commit.id }
end

---Diff record of a commit document, for the renderer and the view.
---
--- The record carries `message = true`, so that the renderer writes the lines
--- as they are, without hunks and without a fold of the unchanged rows.
---@param commit codeview.vcs.Commit
---@param files codeview.vcs.FileChange[] Files that the commit changes.
---@return codeview.diff.File
local function document(commit, files)
  local lines = message_lines(commit)
  for _, text in ipairs(file_lines(files)) do
    lines[#lines + 1] = text
  end
  return {
    path = M.path_of(commit.id),
    old_path = M.path_of(commit.id),
    status = M.status,
    old_rev = nil,
    new_rev = commit.id,
    old_lines = {},
    new_lines = lines,
    hunks = {},
    binary = false,
    limited = false,
    line_count = #lines,
    max_lines = 0,
    context = 0,
    message = true,
    commit = commit,
    files = files,
  }
end

---Build the document of one commit.
---
--- The call reads the files of the commit from the backend. Without a
--- callback it blocks and returns `diff, err`. With a callback it returns at
--- once and calls `cb(diff, err)`.
---@param session codeview.Session
---@param file codeview.vcs.FileChange Entry of the commit in the file list.
---@param cb? fun(diff: codeview.diff.File?, err: codeview.Error?)
---@return codeview.diff.File? diff
---@return codeview.Error? err
function M.for_commit(session, file, cb)
  local commit = file.commit or M.commit_of(session, M.commit_id(file.path))
  if not commit then
    local err = errors.new(errors.codes.NOT_FOUND, "the range holds no commit " .. tostring(file.path))
    if cb then
      cb(nil, err)
      return nil, nil
    end
    return nil, err
  end

  local range = range_of(commit)
  if not cb then
    local files = session.repo:changed_files(range)
    return document(commit, files or {}), nil
  end
  session.repo:changed_files(range, function(files)
    -- A commit whose files do not read still shows its message. The list then
    -- reports no file, which is better than no document at all.
    cb(document(commit, files or {}), nil)
  end)
  return nil, nil
end

return M
