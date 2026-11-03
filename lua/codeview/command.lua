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
--- A word `++quit` or `++noquit` sets whether Neovim quits when the review
--- ends. Without a flag the `quit` option decides. By default Neovim quits
--- after a review that the command line of Neovim started, for example
--- `nvim -c "Codeview pr 12"`.
---
--- The command file in `plugin/` registers the command. It reads
--- `M.subcommands` for the completion, and it calls this module only when the
--- command runs.

local config = require("codeview.config")
local errors = require("codeview.error")
local export = require("codeview.export")
local notify = require("codeview.notify")
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
---@field quit boolean? True after `++quit`, false after `++noquit`. Nil without a flag.

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
  notify.error(tostring(err))
end

---Report whether Neovim starts. The commands of `-c` and `+` run before
---the VimEnter event.
---@return boolean
function M.at_startup()
  return vim.v.vim_did_enter == 0
end

---Quit Neovim. A buffer with changes stops the quit, and the error shows.
function M.quit_nvim()
  local ok, err = pcall(vim.cmd.qall)
  if not ok then
    vim.notify("codeview: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---Name of the autocommand group of the quit.
---@type string
M.quit_group = "codeview.quit"

---Quit Neovim after the last review session closes.
---
--- A second open closes the session that runs and sets the new one in the
--- same call. The check waits for the next loop, so it sees the new session,
--- and Neovim stays.
local function quit_after_review()
  api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup(M.quit_group, { clear = true }),
    pattern = "CodeViewSessionClosed",
    callback = function()
      vim.schedule(function()
        if not session.current() then
          M.quit_nvim()
        end
      end)
    end,
  })
end

---Wrap the handler of an open call, so that Neovim quits when the review
---ends. Neovim also quits when the user closes the picker. After an error
---Neovim stays, so that the message shows.
---@param done fun(session: codeview.Session?, err: codeview.Error?)
---@return fun(session: codeview.Session?, err: codeview.Error?)
local function quitting(done)
  return function(review, err)
    if review then
      quit_after_review()
    end
    done(review, err)
    if not review and not err then
      vim.schedule(M.quit_nvim)
    end
  end
end

---Handle the answer of an open call.
---
--- The call reports an error. For a session, it opens the sidebar, the
--- overview, and the hints, and it shows the summary of the session.
--- |:Codeview| and |codeview.review()| both use it.
---@param review codeview.Session?
---@param err codeview.Error?
function M.opened(review, err)
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
  -- The main window shows the top entry of the sidebar at once: the pull
  -- request, the first commit, or the first file. A review without an entry
  -- shows nothing.
  require("codeview.view").next(review, function(_, view_err)
    if view_err and view_err.code ~= errors.codes.NOT_FOUND then
      report(view_err)
    end
  end)
end

---Open a review the way `:Codeview {rev}` does.
---
--- The call opens the session in the async form, and returns at once. The
--- answer goes to |codeview.command.opened()|, or to `on_open`.
---@param spec string Revision argument.
---@param opts? { dir?: string, export_file?: string }
---@param on_open? fun(session: codeview.Session?, err: codeview.Error?) Handler of the answer.
function M.review(spec, opts, on_open)
  opts = opts or {}
  session.open(spec, { dir = opts.dir, export_file = opts.export_file }, on_open or M.opened)
end

---Make the panels of a reopened session match the record.
---
--- The `auto_open` options can open a panel that was closed, or keep closed a
--- panel that was open. The call opens and closes the panels as the record
--- says, and gives the sidebar its expanded directories again.
---@param review codeview.Session
---@param record codeview.session.Last
local function restore_panels(review, record)
  if record.sidebar and not sidebar.is_open() then
    local _, err = sidebar.open({ session = review })
    if err then
      report(err)
    end
  elseif not record.sidebar and sidebar.is_open() then
    sidebar.close()
  end
  local bar = sidebar.get()
  if record.expanded and bar and bar.session == review then
    bar.expanded = vim.deepcopy(record.expanded)
    bar:render()
  end

  if record.overview and not overview.is_open() then
    local _, err = overview.open({ session = review })
    if err then
      report(err)
    end
  elseif not record.overview and overview.is_open() then
    overview.close()
  end
end

---Bring back the file, the line, the style, and the panels of a record.
---@param review codeview.Session Session that opened again.
---@param record codeview.session.Last
---@param finish fun() Runs after the restore.
local function restore(review, record, finish)
  local view = require("codeview.view")
  if not record.path then
    restore_panels(review, record)
    finish()
    return
  end
  local index = review:index_of(record.path)
  if not index then
    notify.info("the range does not change " .. record.path .. " any more")
    restore_panels(review, record)
    finish()
    return
  end
  view.open(review, index, {}, function(state, err)
    if not state then
      report(err --[[@as codeview.Error]])
    else
      if record.style and view.style() ~= record.style then
        view.set_style(record.style)
      end
      if record.line then
        view.go_to_line(record.line, "new")
      end
    end
    restore_panels(review, record)
    finish()
  end)
end

---Run `:Codeview reopen`.
---
--- The command opens the session that closed last again, in the async form.
--- It then opens the file of that session on the same line, sets the diff
--- style, and opens the sidebar and the overview as they were. See
--- |codeview.session.last()|.
---
--- Without a record, or while a session runs, the command gives a warning
--- and does nothing.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Runs after the restore.
function M.reopen(cb)
  local record = session.last()
  if not record then
    notify.warn("no closed session")
    return
  end
  if session.is_active() then
    notify.warn("a session is open, close it first")
    return
  end

  ---@param review codeview.Session?
  ---@param err codeview.Error?
  local function on_open(review, err)
    M.opened(review, err)
    if not review then
      if cb then
        cb(nil, err)
      end
      return
    end
    restore(review, record --[[@as codeview.session.Last]], function()
      if cb then
        cb(review, nil)
      end
    end)
  end

  if record.pr then
    local opts = record.pr.opts
    require("codeview.pr").open(
      record.pr.number,
      { dir = opts.dir or record.dir, repo = opts.repo, remote = opts.remote },
      on_open
    )
    return
  end
  session.open(record.input, { dir = record.dir, export_file = record.export_file }, on_open)
end

---Read the arguments of `:Codeview` without the flags.
---@param text string Trimmed text after the command name.
---@param bang boolean?
---@return codeview.command.Args? parsed
---@return codeview.Error? err
local function parse_text(text, bang)
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
---
--- The flags `++quit` and `++noquit` can stand anywhere in the text. A
--- subcommand takes no flag.
---@param args string? Text after the command name.
---@param bang boolean? True after `:Codeview!`.
---@return codeview.command.Args? parsed
---@return codeview.Error? err
function M.parse(args, bang)
  if args ~= nil and type(args) ~= "string" then
    return nil, errors.new(errors.codes.INVALID_ARG, "arguments must be a string, got " .. type(args))
  end

  -- A flag is a word that starts with `++`. A revision does not start so. The
  -- space in front lets the pattern find a flag at the start of the text.
  local flags = {}
  local rest = (" " .. (args or "")):gsub("%f[%S]%+%+(%S*)", function(name)
    flags[#flags + 1] = name
    return ""
  end)
  local text = vim.trim(rest)
  local quit = nil ---@type boolean?
  for _, name in ipairs(flags) do
    if name == "quit" or name == "noquit" then
      quit = name == "quit"
    else
      return nil, errors.new(errors.codes.INVALID_ARG, "unknown flag ++" .. name .. ": use ++quit or ++noquit")
    end
  end

  local parsed, err = parse_text(text, bang)
  if not parsed then
    return nil, err
  end
  if quit ~= nil and parsed.action == "subcommand" then
    return nil, errors.new(errors.codes.INVALID_ARG, "++quit and ++noquit do not apply to a subcommand")
  end
  parsed.quit = quit
  return parsed, nil
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

  local quit = parsed.quit
  if quit == nil then
    quit = config.get().quit == "startup" and M.at_startup()
  end
  local done = opts.on_open or M.opened
  if quit then
    done = quitting(done)
  elseif parsed.quit == false then
    -- `++noquit` also stops the quit of a review that runs.
    pcall(api.nvim_del_augroup_by_name, M.quit_group)
  end

  if parsed.action == "pick" then
    picker.pick({ mode = parsed.mode, dir = opts.dir }, done)
    return
  end

  if parsed.action == "pr" then
    local pr = require("codeview.pr")
    local title = parsed.number and ("PR #" .. parsed.number) or "the pull request of the branch"
    local view = require("codeview.loading").open({ title = title, steps = pr.steps })
    pr.open(parsed.number, { dir = opts.dir, progress = view }, function(review, open_err)
      if not open_err then
        view:close()
      elseif view:visible() then
        -- The view shows the error. A message on top of it can stop Neovim
        -- at the hit-enter prompt, and then the view does not draw.
        if quit then
          view.hint = "q quits Neovim"
          view.on_close = M.quit_nvim
        end
        view:fail(open_err)
        if opts.on_open then
          opts.on_open(review, open_err)
        end
        return
      end
      done(review, open_err)
    end)
    return
  end
  -- The text goes to the backend, not the parsed form. A jj revset must reach
  -- jj without a split on the dots.
  M.review(parsed.text --[[@as string]], { dir = opts.dir }, done)
end

---Run `:Codeview close`.
function M.close()
  if not session.close() then
    notify.warn("no review session")
  end
end

---Run `:Codeview back`.
---
--- The command takes the async form, like the back key, so a reload of the
--- review does not block the editor. See |codeview.view.back()|.
function M.back()
  require("codeview.view").back(nil, function() end)
end

---Run `:Codeview refresh`.
---
--- The command reads the review again from the repository. It takes the async
--- form, like the refresh key, so the read does not block the editor. See
--- |codeview.view.refresh()|.
function M.refresh()
  require("codeview.view").refresh(nil, function() end)
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
  reopen = {
    run = function()
      M.reopen()
    end,
    desc = "Open the session that closed last again, on the same file and line",
  },
  submit = {
    run = M.submit,
    args = { "comment", "approve", "request-changes" },
    desc = "Send the comments of the session to the pull request",
  },
}

return M
