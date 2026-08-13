---@brief codeview — review commits and ranges of commits inside Neovim.
---
--- The public API of the plugin. Later milestones add the session, sidebar,
--- diff, and comment functions to this table.

local config = require("codeview.config")

local M = {}

---Plugin version.
---@type string
M.version = "0.1.0-dev"

---True after a successful `setup()` call.
---@type boolean
M.did_setup = false

---Configure the plugin.
---
--- The plugin also works without this call. Every option then holds its
--- default value.
---@param opts? table User options. See |codeview-config|.
---@return codeview.Config? config The active configuration, or nil after an error.
---@return string? err The reason why the options are invalid.
function M.setup(opts)
  local merged, err = config.setup(opts)
  if err then
    vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    return nil, err
  end
  M.did_setup = true
  return merged, nil
end

---Read the active configuration.
---@return codeview.Config
function M.config()
  return config.get()
end

---Open a review session.
---
--- The argument is user text (`a`, `a..b`, `a...b`) or a range table. Without
--- a callback the call blocks. The command `:CodeView` calls this function.
---@param spec string|codeview.vcs.Range|codeview.vcs.RangeSpec Revision argument.
---@param opts? codeview.session.OpenOpts
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session
---@return codeview.Error? err
function M.open(spec, opts, cb)
  return require("codeview.session").open(spec, opts, cb)
end

---Open the commit picker.
---@param opts? codeview.picker.Opts `mode = "range"` asks for two picks.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Nil session and nil error mean cancel.
function M.pick(opts, cb)
  require("codeview.picker").pick(opts, cb)
end

---Read the session that runs.
---@return codeview.Session? session Nil when no session runs.
function M.session()
  return require("codeview.session").current()
end

---Close the session that runs.
---@return boolean closed False when no session runs.
function M.close()
  return require("codeview.session").close()
end

---Run the health check of the plugin.
---
--- The same report comes from `:checkhealth codeview`.
function M.health()
  vim.cmd.checkhealth("codeview")
end

return M
