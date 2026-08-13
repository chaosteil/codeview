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
  CodeViewHintKey = "Special",
  CodeViewDir = "Directory",
  CodeViewIndent = "NonText",
  CodeViewCurrent = "CursorLine",
  CodeViewMarker = "Special",
  CodeViewDiffText = "DiffText",
  CodeViewDiffHunk = "Title",
  CodeViewDiffFold = "Folded",
  CodeViewDiffFiller = "NonText",
  CodeViewDiffNumber = "LineNr",
  CodeViewDiffMessage = "Comment",
  CodeViewComment = "Comment",
  CodeViewCommentHeader = "Title",
  CodeViewCommentSign = "Special",
  CodeViewCommentResolved = "DiagnosticOk",
  CodeViewRemote = "Comment",
  CodeViewRemoteHeader = "DiagnosticInfo",
  CodeViewRemoteSign = "DiagnosticInfo",
  CodeViewRemoteOutdated = "DiagnosticWarn",
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
  message = "CodeViewTitle",
  unknown = "CodeViewUnknown",
}

---Groups of a whole diff row that follow the `diff.syntax` option.
---
--- They are not part of |codeview.highlight.links|, because
--- |codeview.highlight.apply_diff_rows()| defines them.
---@type table<string, string>
M.diff_rows = {
  CodeViewDiffAdd = "DiffAdd",
  CodeViewDiffDelete = "DiffDelete",
}

---Define every group.
function M.apply()
  for group, target in pairs(M.links) do
    api.nvim_set_hl(0, group, { link = target, default = true })
  end
  M.apply_diff_rows()
end

---Background of one group, or nil when the group carries none.
---@param name string
---@return integer? bg
local function background_of(name)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or type(hl) ~= "table" then
    return nil
  end
  return hl.bg
end

---Colors of the added rows and the removed rows.
---
--- A whole-row highlight with a foreground color hides the syntax colors of
--- the code. With `diff.syntax` on, the row groups therefore take the
--- background of `DiffAdd` and `DiffDelete` and carry no foreground: the code
--- keeps the colors of its language, and the background still says added or
--- removed.
---
--- The groups take the plain link when the option is off, and also when the
--- colorscheme puts no background on `DiffAdd` or `DiffDelete`, because a row
--- without any color says nothing.
---
--- The two groups carry no `default`, unlike every other group of the module:
--- their value follows an option and a colorscheme, so the call computes it
--- again on each run. To give them your own colors, set them from your own
--- |ColorScheme| autocmd, which runs after this one.
function M.apply_diff_rows()
  local syntax = require("codeview.config").get().diff.syntax
  for group, target in pairs(M.diff_rows) do
    local bg = syntax and background_of(target) or nil
    if bg then
      api.nvim_set_hl(0, group, { bg = bg })
    else
      api.nvim_set_hl(0, group, { link = target })
    end
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
