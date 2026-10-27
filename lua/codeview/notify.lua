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

local M = {}

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

return M
