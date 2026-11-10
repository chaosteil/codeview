---@brief The highlight groups of codeview.
---
--- Every group links to a standard group, with `default = true`. A user
--- keeps control: an own `:highlight` command, or a link in a colorscheme,
--- wins over the default link.
---
--- The row groups and the word groups of a diff, and the box groups of the
--- comments, are the exceptions. The module computes their colors from the
--- colorscheme, so they carry no link and no `default`.
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
  CodeViewRemoteResolved = "DiagnosticOk",
  CodeViewRemoteReactions = "Comment",
  CodeViewAgent = "Comment",
  CodeViewAgentHeader = "DiagnosticHint",
  CodeViewAgentSign = "DiagnosticHint",
  CodeViewLoadingDone = "DiagnosticOk",
  CodeViewLoadingFailed = "DiagnosticError",
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

---@class codeview.highlight.BoxSource
---@field tint string Standard group that gives the color of the background.
---@field border string Group of the frame of the box.

---Groups of the background of a comment box in the diff, and the standard
--- groups they derive from. |codeview.highlight.apply_comment_boxes()|
--- defines them and their border groups, so they are not part of
--- |codeview.highlight.links|.
---@type table<string, codeview.highlight.BoxSource>
M.comment_boxes = {
  CodeViewCommentBox = { tint = "DiagnosticInfo", border = "CodeViewCommentBorder" },
  CodeViewRemoteBox = { tint = "Comment", border = "CodeViewRemoteBorder" },
  CodeViewAgentBox = { tint = "DiagnosticHint", border = "CodeViewAgentBorder" },
}

---Define every group.
function M.apply()
  for group, target in pairs(M.links) do
    api.nvim_set_hl(0, group, { link = target, default = true })
  end
  M.apply_diff_rows()
  M.apply_diff_words()
  M.apply_comment_boxes()
end

---Most links that the call follows from one group. It stops a loop of links.
---@type integer
local MAX_LINKS = 20

---Global definition of one group, after its links.
---
--- The call follows the links itself. With `link = false`, `nvim_get_hl()`
--- reads the 'winhighlight' of the current window after the window shows
--- once. In the inline comment editor, `Normal` then gives the color of
--- the comment box, and each new tint goes on top of the last one.
---@param name string
---@return table? hl Nil when the group does not exist.
local function resolve(name)
  for _ = 0, MAX_LINKS do
    local ok, hl = pcall(api.nvim_get_hl, 0, { name = name })
    if not ok or type(hl) ~= "table" then
      return nil
    end
    if not hl.link then
      return hl
    end
    name = hl.link
  end
  return nil
end

---Background of one group, or nil when the group carries none.
---@param name string
---@return integer? bg
local function background_of(name)
  local hl = resolve(name)
  return hl and hl.bg
end

---Foreground of one group, or nil when the group carries none.
---@param name string
---@return integer? fg
local function foreground_of(name)
  local hl = resolve(name)
  return hl and hl.fg
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

---Smallest contrast ratio between the frame of a comment box and the box.
---
--- WCAG 2.1 asks for 3:1 for the parts of a user interface, see
--- https://www.w3.org/WAI/WCAG21/Understanding/non-text-contrast.html.
---@type number
M.min_frame_contrast = 3

---Relative luminance of a color, as WCAG 2.1 gives it.
---@param color integer 24-bit color.
---@return number luminance From 0 for black to 1 for white.
local function luminance(color)
  local out = 0
  for index, shift in ipairs({ 16, 8, 0 }) do
    local value = bit.band(bit.rshift(color, shift), 0xff) / 255
    local linear = value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
    out = out + ({ 0.2126, 0.7152, 0.0722 })[index] * linear
  end
  return out
end

---Contrast ratio of two colors, as WCAG 2.1 gives it.
---@param a integer 24-bit color.
---@param b integer 24-bit color.
---@return number ratio From 1 for two equal colors to 21 for black and white.
function M.contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
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

---Colors of the boxes of the comments in the diff.
---
--- A comment box takes a light tint of a color on the background of
--- `Normal`, so the comment stands out from the code around it. The box of a
--- local comment takes 15 percent of the foreground of `DiagnosticInfo`,
--- which is blue in most colorschemes. The box of a GitHub comment takes 15
--- percent of the foreground of `Comment`, a grey, so the two kinds of
--- comment look different. The box of a pr-agent item takes 15 percent of
--- the foreground of `DiagnosticHint`. The box groups carry no foreground, so
--- the text keeps the color of its own group.
---
--- The border group of a box takes the foreground of `FloatBorder` on the
--- background of the box. When `FloatBorder` has no foreground, or when its
--- contrast with the box is less than |codeview.highlight.min_frame_contrast|,
--- the border takes the color of the tint. A dark `FloatBorder` on a dark box
--- then does not hide the frame.
---
--- A transparent colorscheme gives no background to `Normal`. The tint then
--- goes on the background of `NormalFloat`. When `NormalFloat` has no
--- background too, the tint goes on black for a dark 'background' and on
--- white for a light one. The box then has a color on the background of the
--- terminal.
---
--- When the colorscheme gives no foreground to the tint, the box links to
--- `NormalFloat` and the border links to `FloatBorder`.
---
--- The groups carry no `default`, like the row groups. Their value follows a
--- colorscheme, so the call computes it again on each run. To give them your
--- own colors, set them from your own |ColorScheme| autocmd.
function M.apply_comment_boxes()
  local base = background_of("Normal")
    or background_of("NormalFloat")
    or (vim.o.background == "light" and 0xffffff or 0x000000)
  local line = foreground_of("FloatBorder")
  for group, source in pairs(M.comment_boxes) do
    local tint = foreground_of(source.tint)
    if base and tint then
      local bg = blend(tint, base, 0.15)
      local frame = line
      if not frame or M.contrast(frame, bg) < M.min_frame_contrast then
        frame = tint
      end
      api.nvim_set_hl(0, group, { bg = bg })
      api.nvim_set_hl(0, source.border, { fg = frame, bg = bg })
    else
      api.nvim_set_hl(0, group, { link = "NormalFloat" })
      api.nvim_set_hl(0, source.border, { link = "FloatBorder" })
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
