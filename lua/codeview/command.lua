---@brief The user commands of codeview.
---
--- `:CodeView <rev>` reviews one commit. `:CodeView <rev>..<rev>` reviews a
--- range. On a jj repository the argument is a revset, for example
--- `:CodeView ::@` or `:CodeView trunk()..@`. `:CodeView` without an argument
--- opens the commit picker, and `:CodeView!` opens the picker in the range
--- mode.
---
--- The command file in `plugin/` registers the commands. It calls this module
--- only when a command runs.

local config = require("codeview.config")
local errors = require("codeview.error")
local export = require("codeview.export")
local overview = require("codeview.overview")
local picker = require("codeview.picker")
local session = require("codeview.session")
local sidebar = require("codeview.sidebar")
local vcs = require("codeview.vcs")

local api = vim.api

local M = {}

---@class codeview.command.Args
---@field action "review"|"pick"|"pr" What the argument asks for.
---@field text string? Revision argument of a review action, as the user wrote it.
---@field range codeview.vcs.RangeSpec? Form of the revision argument, in git terms.
---@field mode "single"|"range"? Number of picks of a pick action.
---@field number integer? Number of the pull request of a pr action. Nil for the pull request of the branch.

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
  if not review then
    return
  end
  local cfg = config.get()
  if cfg.sidebar.auto_open then
    local _, open_err = sidebar.open({ session = review })
    if open_err then
      report(open_err)
      return
    end
  end
  if cfg.overview.auto_open then
    local _, open_err = overview.open({ session = review })
    if open_err then
      report(open_err)
      return
    end
  end
  require("codeview.hints").open({ session = review })
  api.nvim_echo({ { "codeview: " .. review:summary() } }, false, {})
end

---Read the arguments of `:CodeView`.
---
--- The text goes to the backend as it is. Each backend reads the revision
--- language that it knows: git reads `a`, `a..b`, and `a...b`, and jj reads a
--- revset. `parsed.range` reports the form in git terms, for a caller that
--- needs it. `parsed.text` holds the argument itself.
---
--- `pr <number>` reviews a GitHub pull request. `pr` without a number takes
--- the pull request of the current branch.
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

  if text:lower() == "pr" then
    return { action = "pr", text = text }, nil
  end
  local number = text:lower():match("^pr%s+#?(%d+)$")
  if number then
    return { action = "pr", text = text, number = tonumber(number) }, nil
  end
  if text:lower():match("^pr%s") then
    return nil, errors.new(errors.codes.INVALID_ARG, "the pr argument needs a number: :CodeView pr <number>")
  end

  local range, err = vcs.parse_range(text)
  if not range then
    return nil, err
  end
  return { action = "review", text = text, range = range }, nil
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

  if parsed.action == "pr" then
    require("codeview.pr").open(parsed.number, { dir = opts.dir }, opts.on_open or opened)
    return
  end
  -- The text goes to the backend, not the parsed form. A jj revset must reach
  -- jj without a split on the dots.
  session.open(parsed.text --[[@as string]], { dir = opts.dir }, opts.on_open or opened)
end

---Run `:CodeViewClose`.
function M.close()
  if not session.close() then
    vim.notify("codeview: no review session", vim.log.levels.WARN)
  end
end

---Run `:CodeViewBack`.
function M.back()
  require("codeview.view").back()
end

---Run `:CodeViewFiles`.
---
--- The command closes the sidebar when it is open. Otherwise it opens the
--- sidebar and puts the cursor in it.
function M.files()
  if sidebar.is_open() then
    sidebar.close()
    return
  end
  local _, err = sidebar.open({ focus = true })
  if err then
    report(err)
  end
end

---Run `:CodeViewComments`.
---
--- The command closes the comment overview when it is open. Otherwise it opens
--- the overview and puts the cursor in it.
function M.overview()
  if overview.is_open() then
    overview.close()
    return
  end
  local _, err = overview.open({ focus = true })
  if err then
    report(err)
  end
end

---Run `:CodeViewExport`.
---
--- The argument names the register that receives the markdown. Without an
--- argument the call takes the `export.register` option. After `!` the export
--- opens no scratch buffer.
---@param opts? { args?: string, bang?: boolean }
---@return codeview.export.Result? result
function M.export(opts)
  opts = opts or {}
  local register = vim.trim(opts.args or "")
  local result, err = export.run({
    register = register ~= "" and register or nil,
    buffer = not opts.bang,
  })
  if err then
    report(err)
    return nil
  end
  return result
end

---Run `:CodeViewSubmit`.
---
--- The argument names the event of the review: `comment`, `approve`, or
--- `request-changes`. Without an argument the call asks for the event. After
--- `!` the review takes the default text, without a prompt.
---
--- The command shows a summary and posts only after the user confirms it.
---@param opts? { args?: string, bang?: boolean, on_done?: fun(result: codeview.submit.Result?, err: codeview.Error?) }
function M.submit(opts)
  opts = opts or {}
  local event = vim.trim(opts.args or "")
  require("codeview.submit").run({
    event = event ~= "" and event or nil,
    body = opts.bang and "" or nil,
  }, opts.on_done)
end

return M
