---@brief A side panel window.
---
--- A panel is a vertical split at the left or the right edge of the tab page.
--- It shows a scratch buffer that a render function fills. The panel knows
--- nothing about the content: the caller gives a title, a side, a width, a
--- render function, and a keymap table.
---
--- The render function returns one |codeview.panel.Line| per buffer line. A
--- line holds its text, an optional highlight group for the whole line,
--- optional highlights for parts of the text, and optional data. The panel
--- keeps the data, so a keymap can read the value of the line under the
--- cursor with |codeview.Panel:cursor_data()|.
---
--- The changed-files sidebar and the comment overview both use this module.
---
--- Cleanup is exact. |codeview.Panel:close()| deletes the autocmd group, the
--- window, and the buffer of the panel. A window that the user closes, or a
--- buffer that another call deletes, runs the same path.

local api = vim.api

local M = {}

---Namespace of the panel highlights.
---@type integer
M.ns = api.nvim_create_namespace("codeview.panel")

---Window options of every panel.
---@type table<string, any>
local WIN_OPTIONS = {
  winfixwidth = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  foldenable = false,
  wrap = false,
  spell = false,
  list = false,
  cursorline = true,
  cursorlineopt = "line",
  colorcolumn = "",
  statuscolumn = "",
}

---Buffer options of every panel.
---@type table<string, any>
local BUF_OPTIONS = {
  buftype = "nofile",
  bufhidden = "hide",
  swapfile = false,
  buflisted = false,
  undolevels = -1,
}

---Number of panels that this Neovim made.
---@type integer
local counter = 0

---@class codeview.panel.Mark
---@field hl string Highlight group.
---@field from integer Start column, in bytes, from 0.
---@field to integer? End column, in bytes. The end of the line by default.

---@class codeview.panel.Line
---@field text string Text of the line.
---@field hl string? Highlight group of the whole line.
---@field marks codeview.panel.Mark[]? Highlights of parts of the text.
---@field data any? Value that belongs to the line.

---@class codeview.panel.Builder
---@field add fun(chunk: string?, hl?: string) Append a part of the text.
---@field text fun(): string Text of the line up to here.
---@field build fun(opts?: { hl?: string, data?: any }): codeview.panel.Line Line of the parts.

---Collect the text and the highlights of one line.
---
--- Every panel builds its lines from parts, so the builder counts the columns
--- of each part. The changed-files sidebar and the comment overview both use
--- it.
---@return codeview.panel.Builder
function M.builder()
  local text = ""
  ---@type codeview.panel.Mark[]
  local marks = {}
  return {
    add = function(chunk, hl)
      if not chunk or chunk == "" then
        return
      end
      local from = #text
      text = text .. chunk
      if hl then
        marks[#marks + 1] = { hl = hl, from = from, to = #text }
      end
    end,
    text = function()
      return text
    end,
    build = function(opts)
      opts = opts or {}
      return { text = text, marks = marks, hl = opts.hl, data = opts.data }
    end,
  }
end

---@class codeview.panel.Opts
---@field title string Name of the panel. It names the buffer too.
---@field render fun(panel: codeview.Panel): codeview.panel.Line[] Content of the buffer.
---@field keymaps table<string, false|fun(panel: codeview.Panel)>? Normal mode maps of the buffer.
---@field position "left"|"right"? Side of the tab page. "left" by default.
---@field width integer? Width in columns. 40 by default.
---@field filetype string? Filetype of the buffer. "codeview" by default.
---@field on_close fun(panel: codeview.Panel)? Handler that runs after the close.

---@class codeview.Panel
---@field id integer Number of the panel. It counts from 1.
---@field title string Name of the panel.
---@field position "left"|"right" Side of the tab page.
---@field width integer Width in columns.
---@field filetype string Filetype of the buffer.
---@field private render_fn fun(panel: codeview.Panel): codeview.panel.Line[]
---@field private keymaps table<string, false|fun(panel: codeview.Panel)>
---@field private on_close fun(panel: codeview.Panel)?
---@field private buf integer? Buffer of the panel, while it is open.
---@field private win integer? Window of the panel, while it is open.
---@field private group integer? Autocmd group of the panel.
---@field private rendered codeview.panel.Line[] Lines of the last render.
---@field private closing boolean Guard against a close inside a close.
local Panel = {}
Panel.__index = Panel

---Build a panel. The window opens with |codeview.Panel:open()|.
---@param opts codeview.panel.Opts
---@return codeview.Panel
function M.new(opts)
  vim.validate("opts", opts, "table")
  vim.validate("opts.title", opts.title, "string")
  vim.validate("opts.render", opts.render, "callable")
  vim.validate("opts.keymaps", opts.keymaps, "table", true)
  vim.validate("opts.width", opts.width, "number", true)
  vim.validate("opts.on_close", opts.on_close, "callable", true)

  counter = counter + 1
  return setmetatable({
    id = counter,
    title = opts.title,
    position = opts.position == "right" and "right" or "left",
    width = opts.width or 40,
    filetype = opts.filetype or "codeview",
    render_fn = opts.render,
    keymaps = opts.keymaps or {},
    on_close = opts.on_close,
    rendered = {},
    closing = false,
  }, Panel)
end

---Report whether a window belongs to a panel.
---@param win integer Window handle.
---@return boolean
function M.is_panel_win(win)
  if not api.nvim_win_is_valid(win) then
    return false
  end
  local ok, value = pcall(api.nvim_win_get_var, win, "codeview_panel")
  return ok and value == true
end

--- Buffer and window ----------------------------------------------------------

---Set the buffer-local keymaps of the panel.
---@param self codeview.Panel
local function set_keymaps(self)
  for lhs, action in pairs(self.keymaps) do
    if action and lhs ~= "" then
      vim.keymap.set("n", lhs, function()
        action(self)
      end, { buffer = self.buf, nowait = true, silent = true, desc = "codeview: " .. self.title })
    end
  end
end

---Make the buffer of the panel.
---@param self codeview.Panel
local function make_buf(self)
  self.buf = api.nvim_create_buf(false, true)
  for name, value in pairs(BUF_OPTIONS) do
    vim.bo[self.buf][name] = value
  end
  vim.bo[self.buf].filetype = self.filetype
  pcall(api.nvim_buf_set_name, self.buf, string.format("codeview://%d/%s", self.id, self.title))
  set_keymaps(self)
end

---Watch the window and the buffer of the panel.
---@param self codeview.Panel
local function watch(self)
  self.group = api.nvim_create_augroup("codeview.panel." .. self.id, { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    pattern = tostring(self.win),
    desc = "Close the codeview panel with its window",
    callback = function()
      self:close()
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = self.group,
    buffer = self.buf,
    desc = "Close the codeview panel with its buffer",
    callback = function()
      self.buf = nil
      self:close()
    end,
  })
end

---Report whether the panel window is open.
---@return boolean
function Panel:is_open()
  return self.win ~= nil and api.nvim_win_is_valid(self.win)
end

---Window of the panel.
---@return integer? win Nil while the panel is closed.
function Panel:window()
  return self:is_open() and self.win or nil
end

---Buffer of the panel.
---@return integer? buf Nil while the panel is closed.
function Panel:buffer()
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    return self.buf
  end
  return nil
end

---Open the panel and render it.
---@param opts? { focus?: boolean } `focus = true` puts the cursor in the panel.
---@return integer win Window of the panel.
function Panel:open(opts)
  opts = opts or {}
  if self:is_open() then
    self:render()
    if opts.focus then
      self:focus()
    end
    return self.win --[[@as integer]]
  end

  if not self:buffer() then
    make_buf(self)
  end
  -- A new window makes Neovim equalize the tab page, which takes the width
  -- that another panel holds. The call keeps every panel at its width.
  self.win = require("codeview.layout").keep(function()
    return api.nvim_open_win(self.buf --[[@as integer]], opts.focus == true, {
      split = self.position,
      win = -1, -- -1 splits the tab page, so the window keeps the full height.
      width = self.width,
    })
  end)
  api.nvim_win_set_var(self.win, "codeview_panel", true)
  for name, value in pairs(WIN_OPTIONS) do
    vim.wo[self.win][0][name] = value
  end
  vim.wo[self.win][0].winfixbuf = true
  api.nvim_win_set_width(self.win, self.width)

  watch(self)
  self:render()
  return self.win
end

---Close the panel.
---
--- The call deletes the autocmd group, the window, and the buffer.
---@return boolean closed False when the panel was closed already.
function Panel:close()
  if self.closing then
    return false
  end
  if not self.win and not self.buf then
    return false
  end
  self.closing = true

  if self.group then
    pcall(api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end

  local win, buf = self.win, self.buf
  self.win, self.buf = nil, nil
  self.rendered = {}

  if win and api.nvim_win_is_valid(win) then
    require("codeview.layout").keep(function()
      -- The call fails on the last window of the last tab page. Keep that one.
      pcall(api.nvim_win_close, win, true)
    end)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end

  self.closing = false
  if self.on_close then
    pcall(self.on_close, self)
  end
  return true
end

---Open the panel when it is closed, and close it when it is open.
---@param opts? { focus?: boolean }
---@return boolean open State after the call.
function Panel:toggle(opts)
  if self:is_open() then
    self:close()
    return false
  end
  self:open(opts)
  return true
end

---Put the cursor in the panel window.
---@return boolean moved False when the panel is closed.
function Panel:focus()
  if not self:is_open() then
    return false
  end
  api.nvim_set_current_win(self.win --[[@as integer]])
  return true
end

--- Content --------------------------------------------------------------------

---Write the marks of one line.
---@param buf integer
---@param row integer Line, from 0.
---@param line codeview.panel.Line
local function set_marks(buf, row, line)
  local width = #line.text
  if line.hl then
    api.nvim_buf_set_extmark(buf, M.ns, row, 0, { line_hl_group = line.hl })
  end
  for _, mark in ipairs(line.marks or {}) do
    local from = math.max(mark.from or 0, 0)
    local to = math.min(mark.to or width, width)
    if from < to then
      api.nvim_buf_set_extmark(buf, M.ns, row, from, { end_col = to, hl_group = mark.hl })
    end
  end
end

---Render the panel again.
---
--- The call keeps the cursor on its line, when the new content is long
--- enough. A line break inside the text of a line becomes a space, because
--- one line of the render is one line of the buffer.
---@return boolean rendered False while the panel has no buffer.
function Panel:render()
  local buf = self:buffer()
  if not buf then
    return false
  end

  local lines = self.render_fn(self) or {}
  self.rendered = lines

  local text = {}
  for index, line in ipairs(lines) do
    line.text = (line.text or ""):gsub("[\r\n]", " ")
    text[index] = line.text
  end

  vim.bo[buf].modifiable = true
  local ok, err = pcall(api.nvim_buf_set_lines, buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if not ok then
    error(err, 0)
  end

  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for index, line in ipairs(lines) do
    set_marks(buf, index - 1, line)
  end

  if self:is_open() then
    local row = api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
    self:set_cursor(row)
  end
  return true
end

---Text of the rendered lines.
---@return string[]
function Panel:lines()
  local out = {}
  for index, line in ipairs(self.rendered) do
    out[index] = line.text or ""
  end
  return out
end

---Number of rendered lines.
---@return integer
function Panel:line_count()
  return #self.rendered
end

---Data of one line.
---@param lnum integer Line, from 1.
---@return any? data Nil when the line has no data.
function Panel:data(lnum)
  local line = self.rendered[lnum]
  return line and line.data or nil
end

---Data of the line under the cursor.
---@return any? data
---@return integer? lnum Line of the cursor, from 1.
function Panel:cursor_data()
  if not self:is_open() then
    return nil, nil
  end
  local lnum = api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
  return self:data(lnum), lnum
end

---Find the first line whose data matches.
---@param match fun(data: any, lnum: integer): boolean
---@return integer? lnum Line, from 1. Nil when no line matches.
function Panel:find(match)
  for lnum, line in ipairs(self.rendered) do
    if line.data ~= nil and match(line.data, lnum) then
      return lnum
    end
  end
  return nil
end

---Move the cursor to one line.
---
--- The call clamps the line number to the line count of the panel.
---@param lnum integer Line, from 1.
---@return boolean moved False when the panel is closed or empty.
function Panel:set_cursor(lnum)
  if not self:is_open() or #self.rendered == 0 then
    return false
  end
  local row = math.min(math.max(lnum, 1), #self.rendered)
  pcall(api.nvim_win_set_cursor, self.win --[[@as integer]], { row, 0 })
  return true
end

return M
