---@brief The highlight groups of codeview.
---
--- Every group links to a standard group, with `default = true`. A user
--- keeps control: an own `:highlight` command, or a link in a colorscheme,
--- wins over the default link.
---
--- The links go away when a colorscheme runs `:highlight clear`. The module
--- sets them again on the |ColorScheme| event.

local api = vim.api

local M = {}

---Group of codeview, and the standard group behind it.
---@type table<string, string>
M.links = {
  CodeViewTitle = "Title",
  CodeViewCount = "Comment",
  CodeViewHint = "Comment",
  CodeViewDir = "Directory",
  CodeViewIndent = "NonText",
  CodeViewCurrent = "CursorLine",
  CodeViewMarker = "Special",
  CodeViewDiffAdd = "DiffAdd",
  CodeViewDiffDelete = "DiffDelete",
  CodeViewDiffText = "DiffText",
  CodeViewDiffHunk = "Title",
  CodeViewDiffFold = "Folded",
  CodeViewDiffFiller = "NonText",
  CodeViewDiffNumber = "LineNr",
  CodeViewDiffMessage = "Comment",
  CodeViewComment = "Comment",
  CodeViewCommentHeader = "Title",
  CodeViewCommentSign = "Special",
  CodeViewAdded = "Added",
  CodeViewModified = "Changed",
  CodeViewDeleted = "Removed",
  CodeViewRenamed = "Special",
  CodeViewCopied = "Special",
  CodeViewTypechanged = "WarningMsg",
  CodeViewUnmerged = "ErrorMsg",
  CodeViewUnknown = "Comment",
}

---Group of each file status.
---@type table<codeview.vcs.Status, string>
M.status = {
  added = "CodeViewAdded",
  modified = "CodeViewModified",
  deleted = "CodeViewDeleted",
  renamed = "CodeViewRenamed",
  copied = "CodeViewCopied",
  typechanged = "CodeViewTypechanged",
  unmerged = "CodeViewUnmerged",
  unknown = "CodeViewUnknown",
}

---Define every group.
function M.apply()
  for group, target in pairs(M.links) do
    api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

---Define the groups and keep them across a colorscheme change.
---
--- A second call replaces the autocmd of the first call, because the group is
--- cleared. The call is cheap, so every entry point can run it.
function M.setup()
  M.apply()
  local group = api.nvim_create_augroup("codeview.highlight", { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Set the codeview highlight links again",
    callback = M.apply,
  })
end

---Group of one file status.
---@param status codeview.vcs.Status? Status of a changed file.
---@return string group
function M.for_status(status)
  return M.status[status] or M.status.unknown
end

return M
