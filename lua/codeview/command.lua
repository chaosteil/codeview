---@brief The `:CodeView` and `:CodeViewClose` commands.
---
--- `:CodeView <rev>` reviews one commit. `:CodeView <rev>..<rev>` reviews a
--- range. `:CodeView` without an argument opens the commit picker, and
--- `:CodeView!` opens the picker in the range mode.
---
--- The command file in `plugin/` registers the commands. It calls this module
--- only when a command runs.

local errors = require("codeview.error")
local picker = require("codeview.picker")
local session = require("codeview.session")
local vcs = require("codeview.vcs")

local api = vim.api

local M = {}

---@class codeview.command.Args
---@field action "review"|"pick" What the argument asks for.
---@field range codeview.vcs.RangeSpec? Revision argument of a review action.
---@field mode "single"|"range"? Number of picks of a pick action.

---@class codeview.command.RunOpts
---@field args string? Text after the command name.
---@field bang boolean? True after `:CodeView!`.
---@field dir string? Directory for the repository detection.
---@field on_open fun(session: codeview.Session?, err: codeview.Error?)? Handler of the answer.

---Report an error to the user.
---@param err codeview.Error
local function report(err)
  vim.notify("codeview: " .. tostring(err), vim.log.levels.ERROR)
end

---Handle the answer of an open call.
---@param review codeview.Session?
---@param err codeview.Error?
local function opened(review, err)
  if err then
    report(err)
    return
  end
  -- No session and no error: the user closed the picker.
  if review then
    api.nvim_echo({ { "codeview: " .. review:summary() } }, false, {})
  end
end

---Read the arguments of `:CodeView`.
---
--- The text goes to the backend as it is, because a backend can accept more
--- than one revision name. Only the form of the range is read here.
---@param args string? Text after the command name.
---@param bang boolean? True after `:CodeView!`.
---@return codeview.command.Args? parsed
---@return codeview.Error? err
function M.parse(args, bang)
  if args ~= nil and type(args) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "arguments must be a string, got " .. type(args))
  end

  local text = vim.trim(args or "")
  if text == "" then
    return { action = "pick", mode = bang and "range" or "single" }, nil
  end

  local range, err = vcs.parse_range(text)
  if not range then
    return nil, err
  end
  return { action = "review", range = range }, nil
end

---Run `:CodeView`.
---
--- The argument table comes from the user command. `dir` and `on_open` are
--- extra fields for callers inside the plugin: `dir` sets the directory of the
--- repository detection, and `on_open` replaces the default report.
---@param opts? codeview.command.RunOpts
function M.run(opts)
  opts = opts or {}
  local parsed, err = M.parse(opts.args, opts.bang)
  if not parsed then
    report(err --[[@as codeview.Error]])
    return
  end

  if parsed.action == "pick" then
    picker.pick({ mode = parsed.mode, dir = opts.dir }, opts.on_open or opened)
    return
  end
  session.open(parsed.range, { dir = opts.dir }, opts.on_open or opened)
end

---Run `:CodeViewClose`.
function M.close()
  if not session.close() then
    vim.notify("codeview: no review session", vim.log.levels.WARN)
  end
end

return M
