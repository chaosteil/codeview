---@brief The comment editor: one floating window with a markdown buffer.
---
--- The diff buffers of a review are read-only. The editor holds the only
--- modifiable buffer of the comment flow: the reviewer types here, and the
--- text goes to the comment store, never into a diff buffer and never into a
--- file of the repository.
---
--- `:w` saves the comment. `q` and `<Esc><Esc>` discard it. A close of the
--- window discards it too. An empty body counts as a discard, so a save of an
--- empty buffer writes nothing.
---
--- One editor is open at a time. A second |codeview.editor.open()| discards
--- the editor that is open.

local config = require("codeview.config")

local api = vim.api

local M = {}

---Filetype of the editor buffer.
---@type string
M.filetype = "markdown"

---@class codeview.editor.Opts
---@field title string? Text of the window border. "Comment" by default.
---@field text string? Body to edit. Empty for a new comment.
---@field on_save fun(body: string) Handler of a save. The body is trimmed.
---@field on_cancel fun()? Handler of a discard.

---@class codeview.editor.State
---@field buf integer Buffer of the editor.
---@field win integer Window of the editor.
---@field group integer? Autocmd group of the editor.
---@field on_save fun(body: string)
---@field on_cancel fun()?
---@field done boolean True after a save or a discard.

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
--- the group, and autocmds do not nest, so the window close of this call sends
--- no `WinClosed` event. The group would stay behind after every `:w`.
---@param editor codeview.editor.State
local function unmount(editor)
  if state == editor then
    state = nil
  end
  if editor.group then
    pcall(api.nvim_del_augroup_by_id, editor.group)
    editor.group = nil
  end
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

---Size and position of the editor window.
---@return vim.api.keyset.win_config
local function window_config()
  local cfg = config.get().comments
  local width = math.max(math.min(cfg.width, vim.o.columns - 4), 20)
  local height = math.max(math.min(cfg.height, vim.o.lines - 6), 3)
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
---@param buf integer
local function set_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true, desc = "codeview: comment editor" }
  vim.keymap.set("n", "q", M.cancel, opts)
  vim.keymap.set("n", "<Esc><Esc>", M.cancel, opts)
  vim.keymap.set("n", "ZZ", M.submit, opts)
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
  vim.validate("opts.on_cancel", opts.on_cancel, "callable", true)
  vim.validate("opts.title", opts.title, "string", true)
  vim.validate("opts.text", opts.text, "string", true)

  M.cancel()
  counter = counter + 1

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

  local win_config = window_config()
  win_config.title = " " .. (opts.title or "Comment") .. " "
  win_config.footer = " :w saves · q discards "
  win_config.footer_pos = "right"
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

  ---@type codeview.editor.State
  local editor = {
    buf = buf,
    win = win,
    on_save = opts.on_save,
    on_cancel = opts.on_cancel,
    done = false,
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
  return buf, win
end

return M
