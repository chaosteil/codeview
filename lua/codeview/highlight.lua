---@brief The highlight groups of codeview.
---
--- Every group links to a standard group, with `default = true`. A user
--- keeps control: an own `:highlight` command, or a link in a colorscheme,
--- wins over the default link.
---
--- The row groups and the word groups of a diff are the exceptions. The
--- module computes their colors from the colorscheme, so they carry no link
--- and no `default`.
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

---@class codeview.highlight.WordSource
---@field row string Standard group that gives the background of the row.
---@field color string Standard group that gives the diff color.

---Groups of the changed words of a line, and the standard groups they
--- derive from. |codeview.highlight.apply_diff_words()| defines them, so
--- they are not part of |codeview.highlight.links|.
---@type table<string, codeview.highlight.WordSource>
M.diff_words = {
  CodeViewDiffTextAdd = { row = "DiffAdd", color = "Added" },
  CodeViewDiffTextDelete = { row = "DiffDelete", color = "Removed" },
}

---Define every group.
function M.apply()
  for group, target in pairs(M.links) do
    api.nvim_set_hl(0, group, { link = target, default = true })
  end
  M.apply_diff_rows()
  M.apply_diff_words()
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

---Foreground of one group, or nil when the group carries none.
---@param name string
---@return integer? fg
local function foreground_of(name)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or type(hl) ~= "table" then
    return nil
  end
  return hl.fg
end

---Mix of two colors, as a 24-bit integer.
---@param fg integer First color.
---@param bg integer Second color.
---@param weight number Part of the first color, from 0 to 1.
---@return integer color
local function blend(fg, bg, weight)
  local out = 0
  -- One pass per channel: red at bit 16, green at bit 8, blue at bit 0.
  for _, shift in ipairs({ 16, 8, 0 }) do
    local f = bit.band(bit.rshift(fg, shift), 0xff)
    local b = bit.band(bit.rshift(bg, shift), 0xff)
    out = out + bit.lshift(math.floor(f * weight + b * (1 - weight) + 0.5), shift)
  end
  return out
end

---Colors of the added rows and the removed rows.
---
--- A whole-row highlight with a foreground color hides the syntax colors of
--- the code. With `diff.syntax` on, the row groups take the background of
--- `DiffAdd` and `DiffDelete` and carry no foreground. The code keeps the
--- colors of its language, and the background still says added or removed.
---
--- The groups take the plain link when the option is off. They also take it
--- when the colorscheme puts no background on `DiffAdd` or `DiffDelete`,
--- because a row without color says nothing.
---
--- The two groups carry no `default`, unlike every other group of the module.
--- Their value follows an option and a colorscheme, so the call computes it
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

---Colors of the changed words of a pair of lines.
---
--- A changed word takes the color of its own side: green in an added line,
--- red in a removed line. The group puts a quarter of the color of `Added` or
--- `Removed` on the background of the row, so the word stands out from the
--- rest of the row and still names the side. It carries no foreground, so the
--- code keeps the colors of its language.
---
--- The group links to `CodeViewDiffText` when the colorscheme gives no
--- background to the row or no foreground to the color. The shared group is
--- then the fallback, with the colors of the user or of the colorscheme.
---
--- The two groups carry no `default`, like the row groups. Their value follows
--- a colorscheme, so the call computes it again on each run. To give them your
--- own colors, set them from your own |ColorScheme| autocmd.
function M.apply_diff_words()
  for group, source in pairs(M.diff_words) do
    local bg = background_of(source.row)
    local fg = foreground_of(source.color)
    if bg and fg then
      api.nvim_set_hl(0, group, { bg = blend(fg, bg, 0.25) })
    else
      api.nvim_set_hl(0, group, { link = "CodeViewDiffText" })
    end
  end
end

---Define the groups and keep them across a colorscheme change.
---
--- A second call replaces the autocmd of the first call, because
--- `clear = true` removes the old one. The call is cheap, so every entry point
--- can run it.
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
