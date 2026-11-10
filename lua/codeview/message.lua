---@brief The documents of the review, as files of the review.
---
--- The module holds one document per commit, and one document for the pull
--- request of a pull request session. A range holds commits, and a commit
--- holds a message that says why the change exists. This module gives every
--- commit a file of its own, so the sidebar lists them above the code, with
--- the subject of each one. The reviewer opens a commit like a file and
--- comments on its message.
---
--- One commit document holds the header of the commit, its message, and the
--- files that the commit changes. It holds no diff: every row is a context row
--- of the new side. A comment therefore anchors to it through the same line
--- map as a comment on code. The commit of such a comment is the commit of
--- the document.
---
--- The pull request document reads the same way. It holds the title, the
--- author, the branches, the state, the link, the description, and the
--- commits. A comment on it is an overall comment on the pull request.
---
--- The path of a commit document is `codeview://commit/<id>`, and the path of
--- the pull request document is `codeview://pr/<number>`. The text is no
--- relative path, so it names no file of the repository and it collides with
--- none.
---
--- A pull request review also holds one document per pr-agent result of
--- |codeview.agent|: review, describe, and ask. Their paths are
--- `codeview://agent/<tool>`. A comment on such a document stays local.
---
--- A message is markdown text, and so is a text of pr-agent. Every document
--- therefore holds valid markdown, without an indent in front of these texts,
--- and its buffer takes the markdown filetype.

local errors = require("codeview.error")
local tree = require("codeview.tree")

local M = {}

---Start of the path of every commit document.
---@type string
M.prefix = "codeview://commit/"

---Path of the group node that holds the commits in the tree.
---@type string
M.group_path = "codeview://commits"

---Start of the path of the pull request document.
---@type string
M.pr_prefix = "codeview://pr/"

---Path of the group node that holds the pull request document in the tree.
---@type string
M.pr_group_path = "codeview://pull-request"

---Name of the group node of the pull request document.
---@type string
M.pr_group_label = "Pull request"

---Status of a commit document in the file list.
---@type string
M.status = "message"

---Path of the document of one commit.
---@param id string Full commit id.
---@return string
function M.path_of(id)
  return M.prefix .. id
end

---Path of the document of one pull request.
---@param number integer Number of the pull request.
---@return string
function M.pr_path(number)
  return M.pr_prefix .. tostring(math.floor(number))
end

---Report whether a path names the pull request document.
---@param path string?
---@return boolean
function M.is_pr(path)
  return type(path) == "string" and vim.startswith(path, M.pr_prefix)
end

---Report whether a path names a document of the review: a commit, the pull request, or a pr-agent result.
---@param path string?
---@return boolean
function M.is(path)
  if type(path) ~= "string" then
    return false
  end
  return vim.startswith(path, M.prefix) or vim.startswith(path, M.pr_prefix) or vim.startswith(path, M.agent_prefix)
end

---Commit id of a document path.
---@param path string
---@return string? id Nil for a path of another file.
function M.commit_id(path)
  if type(path) ~= "string" or not vim.startswith(path, M.prefix) then
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

---Name of the pull request document for the user.
---@param info codeview.pr.Info
---@return string
function M.pr_label(info)
  local title = vim.trim(info.title or "")
  if title == "" then
    return string.format("#%d", info.number)
  end
  return string.format("#%d %s", info.number, title)
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
  if M.is_pr(path) then
    if session and session.pr then
      return require("codeview.pr").label(session.pr)
    end
    return "PR " .. path:sub(#M.pr_prefix + 1)
  end
  if M.is_agent(path) then
    return M.agent_label(M.agent_tool(path) --[[@as string]])
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
--- The newest commit reads first, and the oldest commit is at the bottom, as
--- in the log of jj or git.
---@param commits codeview.vcs.Commit[] Commits of the session, newest first.
---@return codeview.vcs.FileChange[]
function M.entries(commits)
  local out = {}
  local count = #commits
  for _, commit in ipairs(commits) do
    out[#out + 1] = {
      path = M.path_of(commit.id),
      status = M.status,
      virtual = true,
      label = M.label(commit),
      group = M.group_label(count),
      group_path = M.group_path,
      order = 3,
      commit = commit,
    }
  end
  return out
end

---File record of the pull request document, for the file list.
---@param info codeview.pr.Info
---@return codeview.vcs.FileChange
function M.pr_entry(info)
  return {
    path = M.pr_path(info.number),
    status = M.status,
    virtual = true,
    label = M.pr_label(info),
    group = M.pr_group_label,
    group_path = M.pr_group_path,
    order = 1,
  }
end

--- Document ---------------------------------------------------------------

---Filetype of the buffer of a document.
---@type string
M.filetype = "markdown"

---Indent of a list in a document.
---
--- Markdown reads a line with this indent as an indented code block. The file
--- list and the commit list then show their lines as they are.
---@type string
local list_indent = "    "

---Lines of the header and the message of a commit.
---
--- The message keeps no indent, so the lines are valid markdown.
---@param commit codeview.vcs.Commit
---@return string[] lines
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
  lines[#lines + 1] = commit.subject or ""
  local body = vim.trim(commit.body or "")
  if body ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
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
    local text = string.format("%s%s  %s", list_indent, tree.mark(file.status), file.path)
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
--- as they are, without hunks and without a fold of the unchanged rows. It
--- also carries the markdown filetype for the buffer.
---@param commit codeview.vcs.Commit
---@param files codeview.vcs.FileChange[] Files that the commit changes.
---@return codeview.diff.File
local function document(commit, files)
  local lines = message_lines(commit)
  vim.list_extend(lines, file_lines(files))
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
    filetype = M.filetype,
    commit = commit,
    files = files,
  }
end

---Lines of the pull request document.
---@param info codeview.pr.Info
---@param commits codeview.vcs.Commit[] Commits of the session, newest first.
---@return string[] lines
local function pr_lines(info, commits)
  local lines = {}
  local title = vim.trim(info.title or "")
  if title == "" then
    lines[#lines + 1] = string.format("Pull request #%d", info.number)
  else
    lines[#lines + 1] = string.format("Pull request #%d: %s", info.number, title)
  end

  local head = info.cross and (info.head_repo .. ":" .. info.head_ref) or info.head_ref
  local author = vim.trim(info.author or "")
  lines[#lines + 1] =
    string.format("%s wants to merge %s into %s", author == "" and "someone" or author, head, info.base_ref)

  local state = (info.state or ""):lower()
  if info.draft then
    state = state .. ", draft"
  end
  lines[#lines + 1] = "State: " .. state

  local url = vim.trim(info.url or "")
  if url ~= "" then
    lines[#lines + 1] = "Link:  " .. url
  end

  lines[#lines + 1] = ""
  local body = (info.body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  body = vim.trim(body)
  if body == "" then
    lines[#lines + 1] = "The pull request has no description."
  else
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  end

  lines[#lines + 1] = ""
  local count = #(commits or {})
  if count == 0 then
    lines[#lines + 1] = "The pull request holds no commit."
    return lines
  end
  lines[#lines + 1] = string.format("%d %s:", count, count == 1 and "commit" or "commits")
  lines[#lines + 1] = ""
  -- The newest commit reads first, as in the sidebar.
  for _, commit in ipairs(commits) do
    lines[#lines + 1] = list_indent .. M.label(commit)
  end
  return lines
end

---Diff record of the pull request document, for the renderer and the view.
---@param info codeview.pr.Info
---@param commits codeview.vcs.Commit[] Commits of the session, newest first.
---@return codeview.diff.File
local function pr_document(info, commits)
  local lines = pr_lines(info, commits)
  return {
    path = M.pr_path(info.number),
    old_path = M.pr_path(info.number),
    status = M.status,
    old_rev = nil,
    new_rev = info.head_sha,
    old_lines = {},
    new_lines = lines,
    hunks = {},
    binary = false,
    limited = false,
    line_count = #lines,
    max_lines = 0,
    context = 0,
    message = true,
    filetype = M.filetype,
    files = {},
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

---Build the document of the pull request.
---
--- The document reads from the session alone, so the call answers at once in
--- both forms.
---@param session codeview.Session
---@param _file codeview.vcs.FileChange Entry of the pull request in the file list. The document reads from the session.
---@param cb? fun(diff: codeview.diff.File?, err: codeview.Error?)
---@return codeview.diff.File? diff
---@return codeview.Error? err
function M.for_pr(session, _file, cb)
  local info = session and session.pr
  if not info then
    local err = errors.new(errors.codes.NOT_FOUND, "the session reviews no pull request")
    if cb then
      cb(nil, err)
      return nil, nil
    end
    return nil, err
  end

  local built = pr_document(info, session.commits)
  if cb then
    cb(built, nil)
    return nil, nil
  end
  return built, nil
end

--- Agent documents ----------------------------------------------------------

---Start of the path of every document of a pr-agent result.
---@type string
M.agent_prefix = "codeview://agent/"

---Path of the group node that holds the pr-agent documents in the tree.
---@type string
M.agent_group_path = "codeview://agent"

---Name of the group node of the pr-agent documents.
---@type string
M.agent_group_label = "Agent"

---Tools of pr-agent that get a document, in the order of the sidebar.
---@type string[]
M.agent_tools = { "review", "describe", "ask" }

---Path of the document of one pr-agent tool.
---@param tool string Name of the tool, for example "review".
---@return string
function M.agent_path(tool)
  return M.agent_prefix .. tool
end

---Report whether a path names a pr-agent document.
---@param path string?
---@return boolean
function M.is_agent(path)
  return type(path) == "string" and vim.startswith(path, M.agent_prefix)
end

---Tool of a pr-agent document path.
---@param path string
---@return string? tool Nil for a path of another file.
function M.agent_tool(path)
  if not M.is_agent(path) then
    return nil
  end
  return path:sub(#M.agent_prefix + 1)
end

---Name of a pr-agent document for the user.
---@param tool string
---@return string
function M.agent_label(tool)
  return "pr-agent " .. tool
end

---File records of the pr-agent documents, for the file list.
---
--- A tool without a result gets no document. The group sits between the pull
--- request document and the commits.
---@param results codeview.agent.Results? Results of the pull request.
---@return codeview.vcs.FileChange[]
function M.agent_entries(results)
  local out = {}
  if type(results) ~= "table" then
    return out
  end
  for _, tool in ipairs(M.agent_tools) do
    if results[tool] then
      out[#out + 1] = {
        path = M.agent_path(tool),
        status = M.status,
        virtual = true,
        label = tool:sub(1, 1):upper() .. tool:sub(2),
        group = M.agent_group_label,
        group_path = M.agent_group_path,
        order = 2,
      }
    end
  end
  return out
end

---Text of a JSON value of pr-agent.
---@param value any
---@return string
local function text_of(value)
  if type(value) == "string" then
    return vim.trim(value)
  end
  if value == nil then
    return ""
  end
  if type(value) == "table" then
    return vim.json.encode(value)
  end
  return tostring(value)
end

---Label of a field of a review: `estimated_effort_to_review_[1-5]` gives
---`Estimated effort to review`.
---@param key string
---@return string
local function field_label(key)
  local words = vim.trim((key:gsub("_%[1%-5%]$", ""):gsub("_", " ")))
  return words:sub(1, 1):upper() .. words:sub(2)
end

---Add a text of pr-agent to the lines of a document.
---
--- pr-agent writes markdown, so the text keeps no indent.
---@param lines string[] Lines of the document, in place.
---@param text string
local function add_text(lines, text)
  vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
end

---Lines of a review result: one line per field, then the key issues.
---@param data table JSON of pr-agent.
---@return string[] lines
local function review_lines(data)
  local lines = {}
  local review = type(data) == "table" and type(data.review) == "table" and data.review or {}
  local keys = vim.tbl_keys(review)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = review[key]
    if key ~= "key_issues_to_review" and type(value) ~= "table" then
      lines[#lines + 1] = string.format("%s: %s", field_label(key), text_of(value))
    end
  end
  local issues = type(review.key_issues_to_review) == "table" and review.key_issues_to_review or {}
  if #issues > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Key issues:"
    for _, issue in ipairs(issues) do
      local first, last = tonumber(issue.start_line), tonumber(issue.end_line)
      local where = text_of(issue.relevant_file)
      if first and last and first ~= last then
        where = string.format("%s:%d-%d", where, first, last)
      elseif first then
        where = string.format("%s:%d", where, first)
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format("%s  %s", text_of(issue.issue_header), where)
      add_text(lines, text_of(issue.issue_content))
    end
  end
  if #lines == 0 then
    lines[1] = "The review holds no field."
  end
  return lines
end

---New title of a describe result.
---@param data table JSON of pr-agent.
---@return string title Empty without a title.
function M.describe_title(data)
  return type(data) == "table" and text_of(data.title) or ""
end

---New body of a describe result: the `description`, then a list of the
---files of `pr_files`.
---@param data table JSON of pr-agent.
---@return string body
function M.describe_body(data)
  if type(data) ~= "table" then
    return ""
  end
  local parts = {}
  local description = text_of(data.description)
  if description ~= "" then
    parts[#parts + 1] = description
  end
  local files = type(data.pr_files) == "table" and data.pr_files or {}
  if #files > 0 then
    local list = { "### Files", "" }
    for _, file in ipairs(files) do
      local label = text_of(file.label)
      list[#list + 1] = string.format(
        "- `%s`%s: %s",
        text_of(file.filename),
        label ~= "" and (" (" .. label .. ")") or "",
        text_of(file.changes_title)
      )
      for _, line in ipairs(vim.split(text_of(file.changes_summary), "\n", { plain = true })) do
        local item = vim.trim(line):gsub("^%- ", "")
        if item ~= "" then
          list[#list + 1] = "  - " .. item
        end
      end
    end
    parts[#parts + 1] = table.concat(list, "\n")
  end
  return table.concat(parts, "\n\n")
end

---Lines of a describe result: the new title, then the new body.
---@param data table JSON of pr-agent.
---@return string[] lines
local function describe_lines(data)
  local lines = { "Title: " .. M.describe_title(data), "" }
  local body = M.describe_body(data)
  if body == "" then
    lines[#lines + 1] = "The result holds no body."
  else
    add_text(lines, body)
  end
  return lines
end

---Lines of the questions and the answers, newest first.
---@param data table List of `{ question, answer, head_sha, at }`.
---@return string[] lines
local function ask_lines(data)
  local lines = {}
  for index, entry in ipairs(type(data) == "table" and data or {}) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "Q: " .. text_of(entry.question)
    lines[#lines + 1] = string.format("   at %s, head %s", text_of(entry.at), text_of(entry.head_sha):sub(1, 7))
    lines[#lines + 1] = ""
    add_text(lines, text_of(entry.answer))
  end
  if #lines == 0 then
    lines[1] = "No question yet."
  end
  return lines
end

---Lines of the document of one pr-agent result.
---
--- A result of an older head says so in the first line.
---@param tool string
---@param record codeview.agent.Record
---@param info codeview.pr.Info
---@return string[] lines
local function agent_lines(tool, record, info)
  local lines = {}
  local head = tostring(info.head_sha or "")
  local ran = tostring(record.head_sha or "")
  if head ~= "" and ran ~= head then
    lines[#lines + 1] =
      string.format("Outdated: pr-agent ran on %s, the head is now %s.", ran:sub(1, 7), head:sub(1, 7))
  end
  lines[#lines + 1] = string.format("pr-agent %s of #%d", tool, info.number)
  lines[#lines + 1] = string.format("Model: %s", text_of(record.model))
  lines[#lines + 1] = string.format("Run:   %s, head %s", text_of(record.finished_at), ran:sub(1, 7))
  lines[#lines + 1] = ""
  local body
  if tool == "review" then
    body = review_lines(record.data)
  elseif tool == "describe" then
    body = describe_lines(record.data)
  else
    body = ask_lines(record.data)
  end
  vim.list_extend(lines, body)
  return lines
end

---Build the document of one pr-agent result.
---
--- The document reads from the results that |codeview.agent| holds, so the
--- call answers at once in both forms.
---@param session codeview.Session
---@param file codeview.vcs.FileChange Entry of the document in the file list.
---@param cb? fun(diff: codeview.diff.File?, err: codeview.Error?)
---@return codeview.diff.File? diff
---@return codeview.Error? err
function M.for_agent(session, file, cb)
  local info = session and session.pr
  local tool = M.agent_tool(file.path)
  local results = info and require("codeview.agent").get(info)
  local record = results and tool and results[tool]
  if not record then
    local err = errors.new(errors.codes.NOT_FOUND, "no pr-agent result for " .. tostring(file.path))
    if cb then
      cb(nil, err)
      return nil, nil
    end
    return nil, err
  end
  local lines = agent_lines(tool, record, info)
  ---@type codeview.diff.File
  local built = {
    path = file.path,
    old_path = file.path,
    status = M.status,
    old_rev = nil,
    new_rev = record.head_sha,
    old_lines = {},
    new_lines = lines,
    hunks = {},
    binary = false,
    limited = false,
    line_count = #lines,
    max_lines = 0,
    context = 0,
    message = true,
    filetype = M.filetype,
    files = {},
  }
  if cb then
    cb(built, nil)
    return nil, nil
  end
  return built, nil
end

---Build the document of one virtual entry.
---
--- The pull request document, the pr-agent documents, and the commit
--- documents take the same call, so the view needs no branch.
---@param session codeview.Session
---@param file codeview.vcs.FileChange Entry of the document in the file list.
---@param cb? fun(diff: codeview.diff.File?, err: codeview.Error?)
---@return codeview.diff.File? diff
---@return codeview.Error? err
function M.for_file(session, file, cb)
  if M.is_pr(file.path) then
    return M.for_pr(session, file, cb)
  end
  if M.is_agent(file.path) then
    return M.for_agent(session, file, cb)
  end
  return M.for_commit(session, file, cb)
end

return M
