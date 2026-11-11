---@brief One way to show a message of codeview to the user.
---
--- Every message goes through |codeview.notify.notify()|. The call puts
--- "codeview: " in front of the text, drops a message below the `log_level`
--- option, and calls |vim.notify()|. The call reads `vim.notify` at the time
--- of the call, so a replacement of `vim.notify` gets every message.
---
--- `config.lua` and `plugin/codeview.lua` call |vim.notify()| themselves,
--- because they run before the configuration exists. `events.lua` does too,
--- because it loads no other module.
---
--- A message of background work, for example the check of a pull request,
--- goes through |codeview.notify.background()|. It never goes to the command
--- line, so it never shows the hit-enter prompt.

local api = vim.api
local fn = vim.fn

local M = {}

---Milliseconds before a popup of |codeview.notify.background()| closes.
---@type { info: integer, warn: integer }
M.popup_ms = { info = 3000, warn = 5000 }

---@class codeview.notify.Popup
---@field win integer Window of the popup.
---@field height integer Rows of the popup, without the border.

---Open popups, from the top down.
---@type codeview.notify.Popup[]
local popups = {}

---Show one message, when its level is at or above the `log_level` option.
---@param message string Text of the message, without the "codeview: " prefix.
---@param level integer? A `vim.log.levels` value. INFO by default.
function M.notify(message, level)
  level = level or vim.log.levels.INFO
  if level < require("codeview.config").get().log_level then
    return
  end
  vim.notify("codeview: " .. message, level)
end

---Show an error message.
---@param message string
function M.error(message)
  M.notify(message, vim.log.levels.ERROR)
end

---Show a warning.
---@param message string
function M.warn(message)
  M.notify(message, vim.log.levels.WARN)
end

---Show a message for information.
---@param message string
function M.info(message)
  M.notify(message, vim.log.levels.INFO)
end

---Report whether `vim.notify` is the function of Neovim. A notification
---plugin, for example nvim-notify, replaces it.
---@return boolean default
function M.default_notify()
  local info = debug.getinfo(vim.notify, "S")
  local source = info and info.source or ""
  return source:find("vim/_", 1, true) ~= nil and source:find("editor", 1, true) ~= nil
end

---Put the open popups below each other in the top-right corner.
local function stack()
  local row = 0
  for _, popup in ipairs(popups) do
    if api.nvim_win_is_valid(popup.win) then
      api.nvim_win_set_config(popup.win, { relative = "editor", anchor = "NE", row = row, col = vim.o.columns })
      row = row + popup.height + 2
    end
  end
end

---Close one popup, and move the others up.
---@param popup codeview.notify.Popup
local function close(popup)
  for index, open in ipairs(popups) do
    if open == popup then
      table.remove(popups, index)
      break
    end
  end
  if api.nvim_win_is_valid(popup.win) then
    pcall(api.nvim_win_close, popup.win, true)
  end
  stack()
end

---Open a popup in the top-right corner. It takes no focus, and it closes
---by itself after the time of |codeview.notify.popup_ms|.
---@param text string
---@param level integer A `vim.log.levels` value.
---@return codeview.notify.Popup? popup Nil when Neovim cannot open the window.
function M.popup(text, level)
  local lines = vim.split(text, "\n", { plain = true })
  local most = math.max(vim.o.columns - 4, 1)
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, fn.strdisplaywidth(line))
  end
  width = math.min(width, most)
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(fn.strdisplaywidth(line) / width))
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ok, win = pcall(api.nvim_open_win, buf, false, {
    relative = "editor",
    anchor = "NE",
    row = 0,
    col = vim.o.columns,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
  if not ok then
    pcall(api.nvim_buf_delete, buf, { force = true })
    return nil
  end
  vim.wo[win][0].wrap = true
  local border = "FloatBorder"
  if level >= vim.log.levels.ERROR then
    border = "DiagnosticError"
  elseif level >= vim.log.levels.WARN then
    border = "DiagnosticWarn"
  end
  vim.wo[win][0].winhighlight = "FloatBorder:" .. border
  ---@type codeview.notify.Popup
  local popup = { win = win, height = height }
  popups[#popups + 1] = popup
  stack()
  local ms = level >= vim.log.levels.WARN and M.popup_ms.warn or M.popup_ms.info
  vim.defer_fn(function()
    close(popup)
  end, ms)
  return popup
end

---Show a message of background work, when its level is at or above the
---`log_level` option.
---
--- When a plugin replaced `vim.notify`, the message goes to it. Else the
--- call shows a popup in the top-right corner. The message never goes to the
--- command line, so it never shows the hit-enter prompt.
---@param message string Text of the message, without the "codeview: " prefix.
---@param level integer? A `vim.log.levels` value. INFO by default.
function M.background(message, level)
  level = level or vim.log.levels.INFO
  if level < require("codeview.config").get().log_level then
    return
  end
  local text = "codeview: " .. message
  if not M.default_notify() then
    vim.notify(text, level)
    return
  end
  if vim.in_fast_event() then
    vim.schedule(function()
      M.popup(text, level)
    end)
    return
  end
  M.popup(text, level)
end

---Popups that are open now.
---@return integer[] wins Windows of the popups, from the top down.
function M.popups()
  local wins = {}
  for _, popup in ipairs(popups) do
    if api.nvim_win_is_valid(popup.win) then
      wins[#wins + 1] = popup.win
    end
  end
  return wins
end

return M
