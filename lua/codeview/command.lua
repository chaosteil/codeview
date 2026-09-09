---@brief The user command of codeview.
---
--- `:Codeview` drives the whole plugin. `:Codeview <rev>` reviews one commit,
--- and `:Codeview <rev>..<rev>` reviews a range. On a jj repository the
--- argument is a revset, for example `:Codeview ::@` or
--- `:Codeview trunk()..@`. `:Codeview` without an argument opens the commit
--- picker, and `:Codeview!` opens the picker in the range mode.
---
--- The first word can also name a subcommand: `pr`, or one name of
--- `M.subcommands`. That table holds the handler, the values of the argument
--- completion, and the description of every subcommand. A subcommand name
--- wins over a revision of the same name. Write such a revision as a range,
--- for example `:Codeview close^..close`.
---
--- The command file in `plugin/` registers the command. It reads
--- `M.subcommands` for the completion, and it calls this module only when the
--- command runs.

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
---@field action "review"|"pick"|"pr"|"subcommand" What the argument asks for.
---@field text string? Revision argument of a review action, or the text after the name of a subcommand.
---@field range codeview.vcs.RangeSpec? Form of the revision argument, in git terms.
---@field mode "single"|"range"? Number of picks of a pick action.
---@field number integer? Number of the pull request of a pr action. Nil for the pull request of the branch.
---@field name string? Name of the subcommand of a subcommand action.

---@class codeview.command.RunOpts
---@field args string? Text after the command name.
---@field bang boolean? True after `:Codeview!`.
---@field dir string? Directory for the repository detection.
---@field on_open fun(session: codeview.Session?, err: codeview.Error?)? Handler of the answer.

---@class codeview.command.SubOpts
---@field args string? Text after the name of the subcommand.
---@field bang boolean? True after `:Codeview!`.
---@field on_done fun(result: codeview.submit.Result?, err: codeview.Error?)? Handler of the answer of a submit.

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

---Read the arguments of `:Codeview`.
---
--- The text goes to the backend as it is. Each backend reads the revision
--- language that it knows: git reads `a`, `a..b`, and `a...b`, and jj reads a
--- revset. `parsed.range` reports the form in git terms, for a caller that
--- needs it. `parsed.text` holds the argument itself.
---
--- A first word that `M.subcommands` holds names a subcommand. The name wins
--- over a revision of the same name. `parsed.text` then holds the text after
--- the name.
---
--- `pr <number>` reviews a GitHub pull request. `pr` without a number takes
--- the pull request of the current branch.
---@param args string? Text after the command name.
---@param bang boolean? True after `:Codeview!`.
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

  -- A subcommand name wins over a revision of the same name. A revision that a
  -- subcommand names needs a range form, for example `close^..close`.
  local first = text:match("^%S+") or text
  if M.subcommands[first:lower()] then
    return { action = "subcommand", name = first:lower(), text = vim.trim(text:sub(#first + 1)) }, nil
  end

  local lower = text:lower()
  if lower == "pr" then
    return { action = "pr", text = text }, nil
  end
  local number = lower:match("^pr%s+#?(%d+)$")
  if number then
    return { action = "pr", text = text, number = tonumber(number) }, nil
  end
  if lower:match("^pr%s") then
    return nil, errors.new(errors.codes.INVALID_ARG, "the pr argument needs a number: :Codeview pr <number>")
  end

  local range, err = vcs.parse_range(text)
  if not range then
    return nil, err
  end
  return { action = "review", text = text, range = range }, nil
end

---Run `:Codeview`.
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

  if parsed.action == "subcommand" then
    local name = parsed.name or ""
    M.subcommands[name].run({ args = parsed.text, bang = opts.bang })
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

---Run `:Codeview close`.
function M.close()
  if not session.close() then
    vim.notify("codeview: no review session", vim.log.levels.WARN)
  end
end

---Run `:Codeview back`.
function M.back()
  require("codeview.view").back()
end

---Run `:Codeview refresh`.
---
--- The command reads the review again from the repository. See
--- |codeview.view.refresh()|.
function M.refresh()
  require("codeview.view").refresh()
end

---Run `:Codeview files`.
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

---Run `:Codeview comments`.
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

---Run `:Codeview export`.
---
--- The argument names the register that receives the markdown. Without an
--- argument the call takes the `export.register` option. After `!` the export
--- opens no scratch buffer.
---@param opts? codeview.command.SubOpts
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

---Run `:Codeview submit`.
---
--- The argument names the event of the review: `comment`, `approve`, or
--- `request-changes`. Without an argument the call asks for the event. After
--- `!` the review takes the default text, without a prompt.
---
--- The command shows a summary and posts only after the user confirms it.
---@param opts? codeview.command.SubOpts
function M.submit(opts)
  opts = opts or {}
  local event = vim.trim(opts.args or "")
  require("codeview.submit").run({
    event = event ~= "" and event or nil,
    body = opts.bang and "" or nil,
  }, opts.on_done)
end

---@class codeview.command.Subcommand
---@field run fun(opts?: codeview.command.SubOpts) Handler of the subcommand.
---@field args string[]? Values that the completion offers for the argument.
---@field desc string One line about the subcommand.

---The subcommands of `:Codeview`.
---
--- This table is the single source of truth. `M.run` takes the handler from
--- it, and the completion of the command takes the names and the values of
--- the argument from it. The `desc` field names the action of the subcommand,
--- for a reader of the code and for the help file. `pr` is no entry here,
--- because `M.parse` reads the number of the pull request.
---@type table<string, codeview.command.Subcommand>
M.subcommands = {
  back = { run = M.back, desc = "Go back to the review from a file of the working copy" },
  close = { run = M.close, desc = "Close the review session" },
  comments = { run = M.overview, desc = "Open or close the comment overview sidebar" },
  export = {
    run = M.export,
    args = { "+", "*", '"', "a", "b", "c", "z" },
    desc = "Render the comments of the session as markdown",
  },
  files = { run = M.files, desc = "Open or close the changed-files sidebar" },
  refresh = { run = M.refresh, desc = "Read the review again from the repository" },
  submit = {
    run = M.submit,
    args = { "comment", "approve", "request-changes" },
    desc = "Send the comments of the session to the pull request",
  },
}

return M
