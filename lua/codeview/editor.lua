---@brief The comment editor: one floating window with a markdown buffer.
---
--- The diff buffers of a review are read-only. The editor holds the only
--- modifiable buffer of the comment flow. The reviewer types here. The text
--- goes to the comment store, never into a diff buffer and never into a file
--- of the repository.
---
--- `:w` saves the comment. The `editor_cancel` keys discard it, and a close of
--- the window discards it too. An empty body counts as a discard, so a save of
--- an empty buffer writes nothing.
---
--- One editor is open at a time. A second |codeview.editor.open()| discards
--- the editor that is open.

local config = require("codeview.config")

local api = vim.api

local M = {}

---Filetype of the editor buffer.
---@type string
M.filetype = "markdown"

---@class codeview.editor.Anchor
---@field win integer Window that shows the diff.
---@field buf integer Buffer of the diff.
---@field row integer Row of the buffer, from 1. The editor opens under this row.

---@class codeview.editor.Opts
---@field title string? Text of the window border. "Comment" by default.
---@field text string? Body to edit. Empty for a new comment.
---@field on_save fun(body: string) Handler of a save. The call trims the body.
---@field on_send fun(body: string)? Handler of the send key. Without it the key reports that the comment has no pull request.
---@field on_cancel fun()? Handler of a discard.
---@field anchor codeview.editor.Anchor? Row that the inline style opens under.

---@class codeview.editor.State
---@field buf integer Buffer of the editor.
---@field win integer Window of the editor.
---@field group integer? Autocmd group of the editor.
---@field on_save fun(body: string)
---@field on_send fun(body: string)?
---@field on_cancel fun()?
---@field done boolean True after a save or a discard.
---@field style codeview.editor.Style Style that the editor opened with.
---@field anchor codeview.editor.Anchor? Anchor of the inline style.
---@field spacer integer? Extmark that holds the space of the inline editor.
---@field insert boolean True when the editor asked for insert mode.

---@alias codeview.editor.Style "inline"|"float"

---Namespace of the spacer of the inline editor.
---@type integer
local ns = api.nvim_create_namespace("codeview.editor")

---Editor that is open.
---@type codeview.editor.State?
local state = nil

---Number of editors that this Neovim made. It names the buffer.
---@type integer
local counter = 0

---Read the editor that is open.
---@return codeview.editor.State? state Nil when no editor is open.
function M.current()
  if state and (not api.nvim_buf_is_valid(state.buf) or not api.nvim_win_is_valid(state.win)) then
    state = nil
  end
  return state
end

---Report whether an editor is open.
---@return boolean
function M.is_open()
  return M.current() ~= nil
end

---Text of the editor buffer.
---@return string? body Nil when no editor is open.
function M.body()
  local editor = M.current()
  if not editor then
    return nil
  end
  return vim.trim(table.concat(api.nvim_buf_get_lines(editor.buf, 0, -1, false), "\n"))
end

---Close the window and the buffer of an editor.
---
--- The autocmd group goes first. A save runs from the `BufWriteCmd` autocmd of
--- the group. Autocmds do not nest, so the window close of this call sends no
--- `WinClosed` event. Without this order, the group stays behind after every
--- `:w`.
---@param editor codeview.editor.State
local function unmount(editor)
  if state == editor then
    state = nil
  end
  if editor.group then
    pcall(api.nvim_del_augroup_by_id, editor.group)
    editor.group = nil
  end
  M.clear_spacer(editor)
  if api.nvim_win_is_valid(editor.win) then
    pcall(api.nvim_win_close, editor.win, true)
  end
  if api.nvim_buf_is_valid(editor.buf) then
    vim.bo[editor.buf].modified = false
    pcall(api.nvim_buf_delete, editor.buf, { force = true })
  end
end

---Discard the comment and close the editor.
---@return boolean closed False when no editor is open.
function M.cancel()
  local editor = M.current()
  if not editor then
    return false
  end
  editor.done = true
  local on_cancel = editor.on_cancel
  unmount(editor)
  if on_cancel then
    on_cancel()
  end
  return true
end

---Save the comment and close the editor.
---
--- An empty body discards the comment, because a comment without text says
--- nothing.
---@return boolean saved False when the editor is closed or the body is empty.
function M.submit()
  local editor = M.current()
  if not editor then
    return false
  end
  local body = M.body() or ""
  if body == "" then
    M.cancel()
    return false
  end
  editor.done = true
  local on_save = editor.on_save
  unmount(editor)
  on_save(body)
  return true
end

---Save the comment and send it to the pull request.
---
--- The key posts the one comment of the editor. An editor without a send
--- handler belongs to a local review, so the key reports that and keeps the
--- editor open. An empty body stays open too, because there is nothing to
--- send.
---@return boolean sent False when no editor is open, the editor has no send handler, or the body is empty.
function M.send()
  local editor = M.current()
  if not editor then
    return false
  end
  if not editor.on_send then
    vim.notify("codeview: this comment has no pull request to go to", vim.log.levels.WARN)
    return false
  end
  local body = M.body() or ""
  if body == "" then
    vim.notify("codeview: the comment is empty", vim.log.levels.WARN)
    return false
  end
  editor.done = true
  local on_send = editor.on_send
  unmount(editor)
  on_send(body)
  return true
end

---Remove the space that the inline editor holds in the diff buffer.
---
--- The spacer is an extmark with virtual lines. It adds no line to the buffer,
--- so the line count and the line map of the diff stay as they were.
---@param editor codeview.editor.State
function M.clear_spacer(editor)
  if not editor.spacer or not editor.anchor then
    return
  end
  if api.nvim_buf_is_valid(editor.anchor.buf) then
    pcall(api.nvim_buf_del_extmark, editor.anchor.buf, ns, editor.spacer)
  end
  editor.spacer = nil
end

---Report whether an anchor still points at a live window and buffer.
---@param anchor codeview.editor.Anchor?
---@return boolean
local function anchored(anchor)
  return anchor ~= nil
    and api.nvim_win_is_valid(anchor.win)
    and api.nvim_buf_is_valid(anchor.buf)
    and anchor.row >= 1
    and anchor.row <= api.nvim_buf_line_count(anchor.buf)
end

---Height of the editor window.
---@return integer
local function editor_height()
  local cfg = config.get().comments
  return math.max(math.min(cfg.height, vim.o.lines - 6), 3)
end

---Open the space that the inline editor sits in.
---
--- Without the spacer the window covers the lines under the anchor. The
--- virtual lines push them down instead, so the reviewer keeps the whole diff
--- in sight while the editor is open.
---@param anchor codeview.editor.Anchor
---@param height integer
---@return integer? id Extmark of the spacer.
local function open_spacer(anchor, height)
  local lines = {}
  for _ = 1, height do
    lines[#lines + 1] = { { "", "NormalFloat" } }
  end
  local ok, id = pcall(api.nvim_buf_set_extmark, anchor.buf, ns, anchor.row - 1, 0, {
    virt_lines = lines,
  })
  return ok and id or nil
end

---Size and position of the editor window.
---@param style codeview.editor.Style
---@param anchor codeview.editor.Anchor? Anchor of the inline style.
---@return vim.api.keyset.win_config
local function window_config(style, anchor)
  local cfg = config.get().comments
  local height = editor_height()
  if style == "inline" and anchor then
    -- The window sits on the virtual lines of the spacer, which start one
    -- screen row under the anchor row.
    local width = math.max(api.nvim_win_get_width(anchor.win) - 1, 20)
    return {
      relative = "win",
      win = anchor.win,
      bufpos = { anchor.row - 1, 0 },
      row = 1,
      col = 0,
      width = width,
      height = height,
      style = "minimal",
      border = "none",
      zindex = 45,
    }
  end
  local width = math.max(math.min(cfg.width, vim.o.columns - 4), 20)
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = "minimal",
    border = cfg.border,
  }
end

---Set the buffer-local keymaps of the editor.
---
--- `:w` also saves. It runs from the `BufWriteCmd` autocmd, not from a map, so
--- the write of a modified buffer never leaves the comment behind.
---@param buf integer
local function set_keymaps(buf)
  local keys = config.get().keymaps
  local opts = { buffer = buf, nowait = true, silent = true, desc = "codeview: comment editor" }
  for _, lhs in ipairs(config.keys(keys.editor_cancel)) do
    vim.keymap.set("n", lhs, M.cancel, opts)
  end
  for _, lhs in ipairs(config.keys(keys.editor_save)) do
    vim.keymap.set("n", lhs, M.submit, opts)
  end
  -- The map exists on every editor, with or without a handler, so that the
  -- audit of the keymaps sees it.
  for _, lhs in ipairs(config.keys(keys.editor_send)) do
    vim.keymap.set("n", lhs, M.send, opts)
  end
end

---Open the comment editor.
---
--- The call replaces an editor that is open. It returns the handles of the
--- new buffer and window, so a test can write into the buffer.
---@param opts codeview.editor.Opts
---@return integer buf Buffer of the editor.
---@return integer win Window of the editor.
function M.open(opts)
  vim.validate("opts", opts, "table")
  vim.validate("opts.on_save", opts.on_save, "callable")
  vim.validate("opts.on_send", opts.on_send, "callable", true)
  vim.validate("opts.on_cancel", opts.on_cancel, "callable", true)
  vim.validate("opts.title", opts.title, "string", true)
  vim.validate("opts.text", opts.text, "string", true)
  vim.validate("opts.anchor", opts.anchor, "table", true)

  M.cancel()
  counter = counter + 1

  local cfg = config.get().comments
  -- The inline style needs a row to sit under. An editor that opens from the
  -- overview has no diff row, so it falls back to the float.
  local anchor = anchored(opts.anchor) and opts.anchor or nil
  local style = (cfg.editor == "inline" and anchor) and "inline" or "float"

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = M.filetype
  vim.bo[buf].modifiable = true
  pcall(api.nvim_buf_set_name, buf, string.format("codeview://comment/%d", counter))
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.text or "", "\n", { plain = true }))
  vim.bo[buf].modified = false

  local spacer = nil
  if style == "inline" then
    spacer = open_spacer(anchor, editor_height())
  end

  local win_config = window_config(style, anchor)
  local hints = require("codeview.hints")
  local cancel = config.keys(config.get().keymaps.editor_cancel)[1]
  local send = opts.on_send and config.keys(config.get().keymaps.editor_send)[1] or nil
  local parts = { ":w saves" }
  if cancel then
    parts[#parts + 1] = hints.key_text(cancel) .. " discards"
  end
  if send then
    parts[#parts + 1] = hints.key_text(send) .. " sends"
  end
  local hint = table.concat(parts, " · ")
  if style == "float" then
    -- A border carries the title. The inline style has none, so its hint goes
    -- into the winbar, where it reads as part of the row.
    win_config.title = " " .. (opts.title or "Comment") .. " "
    win_config.footer = " " .. hint .. " "
    win_config.footer_pos = "right"
  end
  local ok, win = pcall(api.nvim_open_win, buf, true, win_config)
  if not ok then
    -- The border, the title, or the footer is not available. Try without them.
    win_config.title, win_config.footer, win_config.footer_pos = nil, nil, nil
    win = api.nvim_open_win(buf, true, win_config)
  end

  vim.wo[win][0].wrap = true
  vim.wo[win][0].linebreak = true
  vim.wo[win][0].number = false
  vim.wo[win][0].signcolumn = "no"
  vim.wo[win][0].spell = false
  vim.wo[win][0].cursorline = false
  if style == "inline" then
    vim.wo[win][0].winhighlight = "Normal:NormalFloat"
    local bar = " " .. (opts.title or "Comment") .. " · " .. hint
    vim.wo[win][0].winbar = "%#Comment#" .. bar:gsub("%%", "%%%%")
  end

  ---@type codeview.editor.State
  local editor = {
    buf = buf,
    win = win,
    on_save = opts.on_save,
    on_send = opts.on_send,
    on_cancel = opts.on_cancel,
    done = false,
    style = style,
    anchor = anchor,
    spacer = spacer,
    insert = cfg.start_insert,
  }
  state = editor

  set_keymaps(buf)

  local group = api.nvim_create_augroup("codeview.editor." .. counter, { clear = true })
  editor.group = group
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    desc = "Save the codeview comment of the editor",
    callback = function()
      M.submit()
      return true
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    desc = "Discard the codeview comment when the editor window closes",
    callback = function()
      if not editor.done then
        editor.done = true
        if state == editor then
          state = nil
        end
        vim.schedule(function()
          if api.nvim_buf_is_valid(buf) then
            vim.bo[buf].modified = false
            pcall(api.nvim_buf_delete, buf, { force = true })
          end
          if editor.on_cancel then
            editor.on_cancel()
          end
        end)
      end
      editor.group = nil
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })

  -- The cursor starts at the end of the text, so a reopen continues the note.
  local last = api.nvim_buf_line_count(buf)
  pcall(api.nvim_win_set_cursor, win, { last, #(api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or "") })

  -- The reviewer opened the editor to type, so the editor starts in insert
  -- mode, after the last character of the text.
  if cfg.start_insert then
    vim.cmd("startinsert!")
  end
  return buf, win
end

return M
