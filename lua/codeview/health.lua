---@brief Health report for `:checkhealth codeview`.

local health = vim.health

local M = {}

---Minimum Neovim version. The plugin uses the 0.11 form of `vim.validate()`.
---@type integer[]
local MIN_NVIM = { 0, 11, 0 }

---@class codeview.health.Tool
---@field name string Name of the executable.
---@field args string[] Arguments that print the version.
---@field required boolean The plugin does not work without a required tool.
---@field purpose string What the plugin does with the tool.

---@type codeview.health.Tool[]
local TOOLS = {
  { name = "git", args = { "--version" }, required = true, purpose = "the git backend" },
  { name = "jj", args = { "--version" }, required = false, purpose = "the jj backend" },
  { name = "gh", args = { "--version" }, required = false, purpose = "GitHub pull request review" },
}

---Read the first output line of a command.
---@param cmd string[]
---@return string? line
---@return string? err
local function first_line(cmd)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(5000)
  end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    return nil, vim.trim((res.stderr or "") ~= "" and res.stderr or ("exit code " .. tostring(res.code)))
  end
  local out = vim.trim(res.stdout or "")
  return vim.split(out, "\n", { plain = true })[1], nil
end

---@return boolean ok
---@return string version
local function nvim_version()
  local v = vim.version()
  local current = { v.major, v.minor, v.patch }
  local text = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  for i = 1, 3 do
    if current[i] > MIN_NVIM[i] then
      return true, text
    end
    if current[i] < MIN_NVIM[i] then
      return false, text
    end
  end
  return true, text
end

---@param tool codeview.health.Tool
local function check_tool(tool)
  if vim.fn.executable(tool.name) ~= 1 then
    local message = string.format("%s: not found in $PATH (needed for %s)", tool.name, tool.purpose)
    if tool.required then
      health.error(message, { "Install " .. tool.name .. " and add it to $PATH." })
    else
      health.warn(message, { "Install " .. tool.name .. " to use " .. tool.purpose .. "." })
    end
    return
  end

  local cmd = vim.list_extend({ tool.name }, tool.args)
  local line, err = first_line(cmd)
  if not line then
    health.warn(string.format("%s: found, but the version call failed (%s)", tool.name, err or "unknown error"))
    return
  end
  health.ok(string.format("%s: %s", tool.name, line))
end

---Report the state of the plugin and of its external tools.
function M.check()
  health.start("codeview")

  local ok, version = nvim_version()
  local wanted = table.concat(MIN_NVIM, ".")
  if ok then
    health.ok(string.format("Neovim %s (minimum %s)", version, wanted))
  else
    health.error(
      string.format("Neovim %s is too old (minimum %s)", version, wanted),
      { "Update Neovim to " .. wanted .. " or later." }
    )
  end

  local codeview = require("codeview")
  health.info(string.format("codeview %s", codeview.version))
  if codeview.did_setup then
    health.ok("setup() ran")
  else
    health.info("setup() did not run. The plugin uses the default configuration.")
  end

  local err = require("codeview.config").validate(require("codeview.config").get())
  if err then
    health.error("invalid configuration: " .. err)
  else
    health.ok("configuration is valid")
  end

  health.start("codeview: external tools")
  for _, tool in ipairs(TOOLS) do
    check_tool(tool)
  end
end

return M
