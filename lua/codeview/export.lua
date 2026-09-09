---@brief Export the comments of a session as markdown.
---
--- The export renders the comments of |codeview.store| as one markdown text.
--- The text goes to a scratch buffer and to a register, so a reviewer pastes
--- the review into a chat window or into a pull request description.
---
--- The default template is plain markdown:
---
--- >markdown
---     # codeview review: main..@
---
---     A code review of this change produced the comments below. Each comment
---     names its lines, its side of the diff (old or new), and the commit that
---     holds the lines. Make the change that each comment asks for. Skip only
---     a comment that is marked resolved.
---
---     - range: `9b2688a5..ec056be0`
---     - commits: 2
---     - comments: 3 on 2 files, 1 resolved
---
---     ## call.lua
---
---     ### L1 · new · ec056be0
---
---     the first note
---
---     ### L2-3 · old · 9b2688a5 · resolved
---
---     two lines
--- <
---
--- The `export.prompt` option replaces the text under the title.
---
--- Every comment holds its line range, its side, and the commit that the lines
--- come from. A reader locates the code with those three values alone, without
--- the plugin.
---
--- The files come in the order of the changed-files sidebar, so the export
--- reads like a walk through the review. A file with comments that the range
--- does not change any more comes last, with a note.
---
--- The `export.template` option replaces the default template. The function
--- gets the session and the collected data, and returns the text: >lua
---
---     require("codeview").setup({
---       export = {
---         template = function(session, data)
---           return ("%d comments on %s"):format(data.count, session:label())
---         end,
---       },
---     })
--- <

local comments_mod = require("codeview.comments")
local config = require("codeview.config")
local errors = require("codeview.error")
local panel = require("codeview.panel")
local session_mod = require("codeview.session")
local tree = require("codeview.tree")
local util = require("codeview.util")

local api = vim.api
local fn = vim.fn

local before = util.comment_before

local M = {}

---@class codeview.export.File
---@field path string Path of the file, relative to the repository root.
---@field status codeview.vcs.Status Status of the file in the range.
---@field changed boolean True while the range changes the file.
---@field comments codeview.store.Comment[] Comments of the file, by line.

---@class codeview.export.Data
---@field session codeview.Session Session that holds the comments.
---@field store codeview.store.Store Comment store of the session.
---@field spec string Text that names the range.
---@field range string Resolved range, with short revision ids.
---@field repo string Absolute path of the repository root.
---@field prompt string Text under the title, from the `export.prompt` option. Empty for no prompt.
---@field files codeview.export.File[] Files with comments, in sidebar order.
---@field comments codeview.store.Comment[] Every comment, in the order of the render.
---@field count integer Number of comments.
---@field resolved integer Number of resolved comments.

---@class codeview.export.Opts
---@field session codeview.Session? Session to export. The session that runs by default.
---@field register string|false? Register for the text. False writes no register.
---@field buffer boolean? False skips the scratch buffer.
---@field focus boolean? False keeps the cursor outside the scratch buffer.
---@field notify boolean? False silences the report of the call.

---@class codeview.export.Result
---@field text string Markdown of the comments.
---@field count integer Number of comments in the text.
---@field register string? Register that holds the text. Nil without a register.
---@field buf integer? Scratch buffer with the text.
---@field win integer? Window of the scratch buffer.

---Report a message of the export.
---@param message string
---@param level integer? A `vim.log.levels` value. INFO by default.
local function notify(message, level)
  vim.notify("codeview: " .. message, level or vim.log.levels.INFO)
end

--- Data ------------------------------------------------------------------------

---Short form of a revision id.
---@type fun(rev: string?): string
M.short = util.short

---Text of the resolved range of a session.
---@param session codeview.Session
---@return string
local function range_text(session)
  local range = session.range or {}
  if range.from then
    return M.short(range.from) .. ".." .. M.short(range.to)
  end
  return M.short(range.to)
end

---Collect the comments of a session, grouped by file.
---
--- The files come in the order of the changed-files sidebar. A file with
--- comments that the range does not change any more comes after them, by name.
---@param session? codeview.Session Session to read. The session that runs by default.
---@return codeview.export.Data? data
---@return codeview.Error? err
function M.data(session)
  session = session or session_mod.current()
  if not session or not session:is_active() then
    return nil, errors.new(errors.codes.INVALID_ARG, "no review session")
  end
  local store, err = comments_mod.store(session)
  if not store then
    return nil, err
  end

  ---@type table<string, codeview.store.Comment[]>
  local by_file = {}
  local resolved = 0
  for _, comment in ipairs(store.comments) do
    by_file[comment.file] = by_file[comment.file] or {}
    local list = by_file[comment.file]
    list[#list + 1] = comment
    resolved = resolved + (comment.state == "resolved" and 1 or 0)
  end
  for _, list in pairs(by_file) do
    table.sort(list, before)
  end

  ---@type codeview.export.File[]
  local files = {}
  ---@type table<string, boolean>
  local taken = {}
  for _, index in ipairs(tree.order(session.files)) do
    local file = session:file(index)
    if file and by_file[file.path] and not taken[file.path] then
      taken[file.path] = true
      files[#files + 1] = {
        path = file.path,
        status = file.status or "unknown",
        changed = true,
        comments = by_file[file.path],
      }
    end
  end

  local rest = {}
  for path in pairs(by_file) do
    if not taken[path] then
      rest[#rest + 1] = path
    end
  end
  table.sort(rest)
  for _, path in ipairs(rest) do
    files[#files + 1] = { path = path, status = "unknown", changed = false, comments = by_file[path] }
  end

  local ordered = {}
  for _, file in ipairs(files) do
    vim.list_extend(ordered, file.comments)
  end

  return {
    session = session,
    store = store,
    spec = session:label(),
    range = range_text(session),
    repo = session.repo.root,
    prompt = config.get().export.prompt,
    files = files,
    comments = ordered,
    count = #ordered,
    resolved = resolved,
  },
    nil
end

--- Default template ------------------------------------------------------------

---Text of the line range of a comment.
---@param comment codeview.store.Comment
---@return string
local function lines_text(comment)
  if comment.start_line == comment.end_line then
    return "L" .. comment.start_line
  end
  return string.format("L%d-%d", comment.start_line, comment.end_line)
end

---Header line of one comment: the lines, the side, the commit, and the state.
---@param comment codeview.store.Comment
---@return string
local function locator(comment)
  local parts = { lines_text(comment), comment.side }
  local rev = M.short(comment.commit)
  if rev ~= "" then
    parts[#parts + 1] = rev
  end
  if comment.state == "resolved" then
    parts[#parts + 1] = "resolved"
  end
  return table.concat(parts, " · ")
end

---Count line of the header.
---@param data codeview.export.Data
---@return string
local function counts(data)
  if data.count == 0 then
    return "- comments: 0"
  end
  local text = string.format("- comments: %d on %d %s", data.count, #data.files, #data.files == 1 and "file" or "files")
  if data.resolved > 0 then
    text = text .. string.format(", %d resolved", data.resolved)
  end
  return text
end

---Render the collected data with the built-in template.
---@param data codeview.export.Data
---@return string text Markdown that ends with one newline.
function M.markdown(data)
  local out = {
    "# codeview review: " .. data.spec,
    "",
  }

  if data.prompt ~= "" then
    vim.list_extend(out, vim.split(data.prompt, "\n", { plain = true }))
    out[#out + 1] = ""
  end

  out[#out + 1] = "- range: `" .. data.range .. "`"
  out[#out + 1] = string.format("- commits: %d", #data.session.commits)
  out[#out + 1] = counts(data)

  if data.count == 0 then
    out[#out + 1] = ""
    out[#out + 1] = "No comments."
    return table.concat(out, "\n") .. "\n"
  end

  for _, file in ipairs(data.files) do
    out[#out + 1] = ""
    local name = require("codeview.message").display(file.path, data.session)
    out[#out + 1] = "## " .. name .. (file.changed and "" or " (outside the range)")
    for _, comment in ipairs(file.comments) do
      out[#out + 1] = ""
      out[#out + 1] = "### " .. locator(comment)
      out[#out + 1] = ""
      for _, line in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
        out[#out + 1] = line
      end
    end
  end

  return table.concat(out, "\n") .. "\n"
end

--- Render ----------------------------------------------------------------------

---Render the comments with the template of the configuration.
---
--- The `export.template` option holds the renderer. The call falls back to
--- |codeview.export.markdown()| when the option holds no function, when the
--- function throws, or when it gives a value that is not a string.
---@param data codeview.export.Data
---@return string text
local function apply_template(data)
  local template = config.get().export.template
  if type(template) ~= "function" then
    return M.markdown(data)
  end
  local ok, text = pcall(template, data.session, data)
  if not ok then
    notify("the export template failed: " .. tostring(text), vim.log.levels.WARN)
    return M.markdown(data)
  end
  if type(text) ~= "string" then
    notify("the export template gave " .. type(text) .. ", not a string", vim.log.levels.WARN)
    return M.markdown(data)
  end
  return text
end

---Render the comments of a session as markdown.
---@param opts? codeview.export.Opts Only `session` matters here.
---@return string? text Nil when no session runs.
---@return codeview.Error? err
function M.render(opts)
  opts = opts or {}
  local data, err = M.data(opts.session)
  if not data then
    return nil, err
  end
  return apply_template(data), nil
end

--- Buffer ----------------------------------------------------------------------

---Lines of a text, without the empty line of a trailing newline.
---@param text string
---@return string[]
local function to_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

---Window that a split of the export can take.
---@return integer? win Nil when the tab page holds panels only.
local function host_window()
  local current = api.nvim_get_current_win()
  local wins = { current }
  vim.list_extend(wins, api.nvim_tabpage_list_wins(0))
  for _, win in ipairs(wins) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == "" and not panel.is_panel_win(win) then
      return win
    end
  end
  return nil
end

---Show a text in a scratch buffer below the current window.
---
--- The buffer is read-only and holds markdown. A second export of the same
--- session takes the name of the first one, so the tab page keeps one export
--- buffer. The buffer and the window belong to the session, so
--- |:Codeview-close| removes them.
---@param session codeview.Session Session of the export.
---@param text string Markdown of the export.
---@param opts? { focus?: boolean }
---@return integer buf
---@return integer? win Nil when no window opens.
function M.open(session, text, opts)
  opts = opts or {}
  local name = string.format("codeview://%d/export.md", session.id)
  for _, held in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(held) and api.nvim_buf_get_name(held) == name then
      session:remove_buffer(held)
      pcall(api.nvim_buf_delete, held, { force = true })
    end
  end

  local lines = to_lines(text)
  local buf = session:add_buffer(api.nvim_create_buf(false, true))
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  pcall(api.nvim_buf_set_name, buf, name)

  for _, lhs in ipairs(config.keys(config.get().keymaps.close)) do
    vim.keymap.set("n", lhs, function()
      local win = fn.bufwinid(buf)
      if win ~= -1 then
        pcall(api.nvim_win_close, win, true)
      end
    end, { buffer = buf, nowait = true, silent = true, desc = "codeview: close the export" })
  end

  local host = host_window()
  local height = math.max(math.min(#lines + 1, 20), 5)
  local ok, win = pcall(api.nvim_open_win, buf, opts.focus ~= false, {
    split = "below",
    win = host,
    height = height,
  })
  if not ok then
    return buf, nil
  end
  session:add_window(win)
  vim.wo[win][0].wrap = true
  vim.wo[win][0].number = false
  vim.wo[win][0].relativenumber = false
  vim.wo[win][0].signcolumn = "no"
  return buf, win
end

--- Register --------------------------------------------------------------------

---True while a text names one register.
---@param name string
---@return boolean
local function is_register(name)
  return #name == 1 and name:match('^[0-9a-zA-Z"+*.%-]$') ~= nil
end

---Write a text into a register.
---
--- The text is a block of lines, so the register is linewise. A register that
--- the environment does not hold gives false and no error value. `+` and `*`
--- need a clipboard tool or a `g:clipboard` provider. Neovim writes the
--- clipboard registers without an error when no provider runs, so the call
--- asks for the provider itself.
---@param name string Name of the register.
---@param text string
---@return boolean ok
local function to_register(name, text)
  if (name == "+" or name == "*") and fn.has("clipboard") == 0 and vim.g.clipboard == nil then
    return false
  end
  local ok = pcall(fn.setreg, name, text, "l")
  return ok
end

--- Command ---------------------------------------------------------------------

---Export the comments of a session.
---
--- The call renders the markdown, writes it into the register of the
--- `export.register` option, and shows it in a scratch buffer. A text that is
--- not a register name writes no register and gives a warning.
---@param opts? codeview.export.Opts
---@return codeview.export.Result? result Nil after an error.
---@return codeview.Error? err
function M.run(opts)
  opts = opts or {}
  local data, err = M.data(opts.session)
  if not data then
    return nil, err
  end
  local text = apply_template(data)

  ---@type codeview.export.Result
  local result = { text = text, count = data.count }

  local register = opts.register
  if register == nil then
    register = config.get().export.register
  end
  if type(register) == "string" and register ~= "" then
    if not is_register(register) then
      if opts.notify ~= false then
        notify("not a register name: " .. register, vim.log.levels.WARN)
      end
    elseif to_register(register, text) then
      result.register = register
    elseif opts.notify ~= false then
      notify("cannot write the register " .. register, vim.log.levels.WARN)
    end
  end

  if opts.buffer ~= false then
    result.buf, result.win = M.open(data.session, text, { focus = opts.focus })
  end

  if opts.notify ~= false then
    local message = string.format("%d %s", data.count, data.count == 1 and "comment" or "comments")
    if result.register then
      message = message .. " in the register " .. result.register
    end
    notify(message)
  end
  return result, nil
end

return M
