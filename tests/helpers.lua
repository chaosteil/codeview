-- Shared helpers for the test suite.

local M = {}

---Absolute path of the repository root.
---@type string
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

---Drop the cached modules of the plugin, so that the next `require` reloads them.
function M.unload()
  for name, _ in pairs(package.loaded) do
    if name == "codeview" or name:match("^codeview%.") then
      package.loaded[name] = nil
    end
  end
end

---Reload the plugin with the default configuration.
---@return table codeview
function M.fresh()
  M.unload()
  return require("codeview")
end

---Run Lua code in a separate Neovim process with an empty configuration.
---
--- The process loads only this plugin. Startup plugins run, so the code sees
--- the same state as a user with a clean Neovim.
---@param lua string Lua code. Print the result to stdout.
---@param pre? string Lua code that runs before the startup plugins.
---@return vim.SystemCompleted
function M.clean_nvim(lua, pre)
  local cmd = {
    vim.v.progpath,
    "--headless",
    "-u",
    "NORC", -- NORC skips the user config but keeps 'loadplugins' on.
    "-i",
    "NONE",
    "--cmd",
    "set runtimepath^=" .. vim.fn.escape(M.root, " \\"),
  }
  if pre then
    vim.list_extend(cmd, { "--cmd", "lua " .. pre })
  end
  vim.list_extend(cmd, { "-c", "lua " .. lua, "-c", "quit" })
  local res = vim.system(cmd, { text = true }):wait(30000)
  -- A headless `print()` writes to stderr. Give the specs one text to match.
  res.output = (res.stdout or "") .. (res.stderr or "")
  return res
end

---Highlight captures at a position of a buffer, with the injected languages.
---
--- The treesitter highlighter parses only the rows that a window draws. A
--- headless test draws no row. Before Neovim 0.13,
--- `vim.treesitter.get_captures_at_pos()` then finds no capture of an
--- injected language, for example the code span of markdown. The call parses
--- the whole buffer with its injections first.
---@param buf integer
---@param row integer Row from 0.
---@param col integer Column from 0.
---@return table[] captures Empty when the buffer has no highlighter.
function M.captures_at(buf, row, col)
  local highlighter = vim.treesitter.highlighter.active[buf]
  if highlighter then
    highlighter.tree:parse(true)
  end
  return vim.treesitter.get_captures_at_pos(buf, row, col)
end

return M
