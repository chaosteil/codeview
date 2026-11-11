---@brief A side panel window.
---
--- A panel is a vertical split at the left or the right edge of the tab page.
--- It shows a scratch buffer that a render function fills. The panel knows
--- nothing about the content: the caller gives a title, a side, a width, a
--- render function, and a keymap table. Each entry of the keymap table holds
--- the action of the key and the text of the action. The text becomes the
--- description of the map, so `:map` names each key of the panel.
---
--- The render function returns one |codeview.panel.Line| per buffer line. A
--- line holds its text, an optional highlight group for the whole line,
--- optional highlights for parts of the text, and optional data. The panel
--- keeps the data, so a keymap can read the value of the line under the
--- cursor with |codeview.Panel:cursor_data()|.
---
--- A line can also hold marks for the right edge of the window. They are
--- virtual text, not part of the buffer text, and Neovim draws them at the
--- right edge also over a long text. |codeview.panel.builder()| cuts the text
--- to the width of the window, so that the marks do not cover it. A panel
--- with `fit = true` renders again when the width of its text area changes.
---
--- The changed-files sidebar and the comment overview both use this module.
--- |codeview.panel.singleton()| gives both of them the same lifecycle: one
--- panel at a time, the handlers of its events, and the close with the
--- session.
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
---@field right [string, string?][]? Parts of the marks at the right edge of the window, as `{ text, hl }`. They are not part of the text.
---@field data any? Value that belongs to the line.

---@class codeview.panel.BuildOpts
---@field hl string? Highlight group of the whole line.
---@field data any? Value that belongs to the line.
---@field width integer? Number of screen columns of the text area. A text that does not fit before the marks of the right edge gets cut. Without a width, the text stays as it is.

---@class codeview.panel.Builder
---@field add fun(chunk: string?, hl?: string) Append a part of the text.
---@field add_right fun(chunk: string?, hl?: string) Append a part of the marks at the right edge.
---@field text fun(): string Text of the line up to here.
---@field build fun(opts?: codeview.panel.BuildOpts): codeview.panel.Line Line of the parts.

---Marker at the end of a text that |codeview.panel.cut()| shortens.
---@type string
M.ELLIPSIS = "…"

---Cut a text to a number of screen columns.
---
--- A text that is wider than the limit loses its end, and the marker
--- |codeview.panel.ELLIPSIS| takes the last columns. The call counts screen
--- columns, so a wide character or an icon counts with its real width.
---@param text string
---@param width integer Number of screen columns.
---@return string
function M.cut(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local room = width - vim.fn.strdisplaywidth(M.ELLIPSIS)
  if room < 0 then
    return ""
  end
  local out, used = {}, 0
  for _, char in ipairs(vim.fn.split(text, [[\zs]])) do
    local size = vim.fn.strdisplaywidth(char)
    if used + size > room then
      break
    end
    out[#out + 1] = char
    used = used + size
  end
  return table.concat(out) .. M.ELLIPSIS
end

---Cut the text of a line and keep its highlights in the shorter text.
---
--- A highlight that covers the cut also covers the marker of the cut. A
--- highlight after the cut goes away.
---@param text string
---@param marks codeview.panel.Mark[]
---@param width integer Number of screen columns.
---@return string text
---@return codeview.panel.Mark[] marks
local function cut_line(text, marks, width)
  local short = M.cut(text, width)
  if short == text then
    return text, marks
  end
  local kept = #short - (short:sub(-#M.ELLIPSIS) == M.ELLIPSIS and #M.ELLIPSIS or 0)
  local out = {}
  for _, mark in ipairs(marks) do
    if mark.from < kept then
      local to = mark.to or #text
      out[#out + 1] = { hl = mark.hl, from = mark.from, to = to > kept and #short or to }
    end
  end
  return short, out
end

---Collect the text and the highlights of one line.
---
--- Every panel builds its lines from parts, so the builder counts the columns
--- of each part. The changed-files sidebar and the comment overview both use
--- it.
---
--- The parts of |codeview.panel.Builder.add_right()| go to the right edge of
--- the window. With a width, the build cuts the text so that it ends one
--- column before these parts.
---@return codeview.panel.Builder
function M.builder()
  local text = ""
  ---@type codeview.panel.Mark[]
  local marks = {}
  ---@type [string, string?][]
  local right = {}
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
    add_right = function(chunk, hl)
      if not chunk or chunk == "" then
        return
      end
      right[#right + 1] = { chunk, hl }
    end,
    text = function()
      return text
    end,
    build = function(opts)
      opts = opts or {}
      local out, out_marks = text, marks
      if opts.width then
        local room = opts.width
        if #right > 0 then
          local size = 0
          for _, chunk in ipairs(right) do
            size = size + vim.fn.strdisplaywidth(chunk[1])
          end
          -- One blank column keeps the text apart from the marks.
          room = room - size - 1
        end
        out, out_marks = cut_line(text, marks, room)
      end
      return { text = out, marks = out_marks, right = #right > 0 and right or nil, hl = opts.hl, data = opts.data }
    end,
  }
end

---@class codeview.panel.Keymap
---@field fn fun(panel: codeview.Panel) Action of the key.
---@field desc string Text of the action, for `:map` and its readers.

---@class codeview.panel.Opts
---@field title string Name of the panel. It names the buffer too.
---@field render fun(panel: codeview.Panel): codeview.panel.Line[] Content of the buffer.
---@field keymaps table<string, false|codeview.panel.Keymap>? Normal mode maps of the buffer.
---@field position "left"|"right"? Side of the tab page. "left" by default.
---@field width integer? Width in columns. 40 by default.
---@field filetype string? Filetype of the buffer. "codeview" by default.
---@field on_close fun(panel: codeview.Panel)? Handler that runs after the close.
---@field same fun(a: any, b: any): boolean? Report whether the data of two lines names the same item. A render keeps the cursor on that item.
---@field fit boolean? Render again when the text area of the window gets wider or narrower. The render function reads the width with |codeview.Panel:text_width()|.

---@class codeview.Panel
---@field id integer Number of the panel. It counts from 1.
---@field title string Name of the panel.
---@field position "left"|"right" Side of the tab page.
---@field width integer Width in columns.
---@field filetype string Filetype of the buffer.
---@field private render_fn fun(panel: codeview.Panel): codeview.panel.Line[]
---@field private keymaps table<string, false|codeview.panel.Keymap>
---@field private on_close fun(panel: codeview.Panel)?
---@field private same fun(a: any, b: any): boolean?
---@field private fit boolean
---@field private rendered_width integer? Width of the text area at the last render.
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
  vim.validate("opts.same", opts.same, "callable", true)
  vim.validate("opts.fit", opts.fit, "boolean", true)

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
    same = opts.same,
    fit = opts.fit == true,
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
  return vim.w[win].codeview_panel == true
end

--- Buffer and window ----------------------------------------------------------

---Set the buffer-local keymaps of the panel.
---@param self codeview.Panel
local function set_keymaps(self)
  for lhs, map in pairs(self.keymaps) do
    if map and lhs ~= "" then
      vim.keymap.set("n", lhs, function()
        map.fn(self)
      end, { buffer = self.buf, nowait = true, silent = true, desc = "codeview: " .. map.desc })
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
  if not self.fit then
    return
  end
  -- A resize of any window can change the width of the panel. These options
  -- change the width of the columns left of the text.
  local function refit()
    if self:is_open() and self:text_width() ~= self.rendered_width then
      self:render()
    end
  end
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.group,
    desc = "Render the codeview panel again for its new width",
    callback = refit,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = self.group,
    pattern = { "number", "relativenumber", "numberwidth", "signcolumn", "foldcolumn", "statuscolumn" },
    desc = "Render the codeview panel again for its new text width",
    callback = refit,
  })
end

---Report whether the panel window is open.
---@return boolean
function Panel:is_open()
  return self.win ~= nil and api.nvim_win_is_valid(self.win)
end

---Number of screen columns of the text area of the panel window.
---
--- The number leaves out the columns left of the text, for example the line
--- numbers and the sign column.
---@return integer width The width of the configuration while the panel is closed.
function Panel:text_width()
  if not self:is_open() then
    return self.width
  end
  local info = vim.fn.getwininfo(self.win)[1]
  return math.max(info.width - info.textoff, 0)
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

---Set one normal mode map of the panel, or remove it.
---
--- The map goes into the buffer at once when the panel is open, and into
--- each later buffer of the panel.
---@param lhs string Key of the map.
---@param map false|codeview.panel.Keymap False removes the map.
function Panel:set_keymap(lhs, map)
  self.keymaps[lhs] = map
  local buf = self:buffer()
  if not buf or lhs == "" then
    return
  end
  if map then
    vim.keymap.set("n", lhs, function()
      map.fn(self)
    end, { buffer = buf, nowait = true, silent = true, desc = "codeview: " .. map.desc })
  else
    require("codeview.config").unmap(buf, lhs)
  end
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
  vim.w[self.win].codeview_panel = true
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
  self.rendered_width = nil

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
  if line.right then
    -- "combine" keeps the background of the line under the marks, for
    -- example the background of 'cursorline'.
    api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
      virt_text = line.right,
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
  end
end

---Render the panel again.
---
--- The call keeps the cursor on its item: the new line whose data the `same`
--- function of the panel matches with the data of the old line. Without a
--- match the cursor keeps its line number, when the new content is long
--- enough. A line break inside the text of a line becomes a space, because
--- one line of the render is one line of the buffer.
---@return boolean rendered False while the panel has no buffer.
function Panel:render()
  local buf = self:buffer()
  if not buf then
    return false
  end

  local row, before = nil, nil
  if self:is_open() then
    row = api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
    before = self:data(row)
  end

  self.rendered_width = self:text_width()
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

  if row and self:is_open() then
    local found = nil
    if before ~= nil and self.same then
      found = self:find(function(data)
        return self.same(before, data) == true
      end)
    end
    self:set_cursor(found or row)
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

--- Lifecycle --------------------------------------------------------------------

---@class codeview.panel.Owner
---@field session codeview.Session Session that the panel shows.
---@field panel codeview.Panel Window of the owner.
---@field autocmds integer[] Autocmds that close with the panel.
---@field subscriptions integer[] Handlers of |codeview.events| that close with the panel.

---@class codeview.panel.SingletonOpts
---@field make fun(session: codeview.Session, on_close: fun(panel: codeview.Panel)): codeview.panel.Owner Build the owner of a new panel. It passes `on_close` to |codeview.panel.new()|.

---@class codeview.panel.OpenOpts
---@field session codeview.Session? Session of the panel. The session that runs by default.
---@field focus boolean? True puts the cursor in the panel.

---@class codeview.panel.Singleton
---@field open fun(opts?: codeview.panel.OpenOpts): codeview.panel.Owner?, codeview.Error?
---@field get fun(): codeview.panel.Owner?
---@field is_open fun(): boolean
---@field close fun(): boolean
---@field refresh fun(): boolean
---@field toggle fun(opts?: codeview.panel.OpenOpts): boolean

---Lifecycle of a panel kind that the plugin shows once.
---
--- The helper keeps the owner that runs. An open for another session closes
--- that owner first. The owner closes with its session, and the session drops
--- the window, the buffer, and the close handler of the owner again. A close
--- of the panel window, for example with `:q`, deletes the autocmds and the
--- event handlers of the owner, and it clears the owner that runs.
---@param opts codeview.panel.SingletonOpts
---@return codeview.panel.Singleton
function M.singleton(opts)
  vim.validate("opts", opts, "table")
  vim.validate("opts.make", opts.make, "callable")

  ---@type codeview.panel.Singleton
  local life = {}

  ---Owner that runs now.
  ---@type codeview.panel.Owner?
  local current = nil

  ---Keep the window and the buffer of the owner that runs, as the session
  ---holds them.
  ---@type fun(win: integer, buf: integer?)
  local track = function() end

  ---Build the owner of a new panel.
  ---@param session codeview.Session
  ---@return codeview.panel.Owner owner
  ---@return fun(win: integer, buf: integer?) track Keep the handles that the session holds.
  local function build(session)
    ---@type codeview.panel.Owner
    local owner
    ---@type integer?, integer?
    local win, buf

    ---Close the panel with the session.
    local function stop()
      owner.panel:close()
    end

    ---Drop every handle of the owner. The panel runs this after its close.
    local function release()
      for _, id in ipairs(owner.autocmds) do
        pcall(api.nvim_del_autocmd, id)
      end
      owner.autocmds = {}
      local events = require("codeview.events")
      for _, id in ipairs(owner.subscriptions) do
        events.off(id)
      end
      owner.subscriptions = {}
      session:off_close(stop)
      if win then
        session:remove_window(win)
      end
      if buf then
        session:remove_buffer(buf)
      end
      if current == owner then
        current = nil
      end
    end

    owner = opts.make(session, release)
    session:on_close(stop)
    return owner, function(new_win, new_buf)
      win, buf = new_win, new_buf
    end
  end

  ---Open the panel.
  ---
  --- Without a session the call takes the session that runs.
  ---@param open_opts? codeview.panel.OpenOpts
  ---@return codeview.panel.Owner? owner Nil when no session runs.
  ---@return codeview.Error? err
  function life.open(open_opts)
    open_opts = open_opts or {}
    local session = open_opts.session or require("codeview.session").current()
    if not session or not session:is_active() then
      local errors = require("codeview.error")
      return nil, errors.new(errors.codes.INVALID_ARG, "no review session")
    end

    if current and current.session ~= session then
      life.close()
    end
    if not current then
      current, track = build(session)
    end

    local owner = current --[[@as codeview.panel.Owner]]
    local win = owner.panel:open({ focus = open_opts.focus })
    session:add_window(win)
    local buf = owner.panel:buffer()
    if buf then
      session:add_buffer(buf)
    end
    track(win, buf)
    return owner, nil
  end

  ---Read the owner that runs.
  ---@return codeview.panel.Owner? owner
  function life.get()
    return current
  end

  ---Report whether the panel window is open.
  ---@return boolean
  function life.is_open()
    return current ~= nil and current.panel:is_open()
  end

  ---Close the panel. The session stays open.
  ---@return boolean closed False when no panel is open.
  function life.close()
    if not current then
      return false
    end
    return current.panel:close()
  end

  ---Render the panel again.
  ---@return boolean rendered False when no panel is open.
  function life.refresh()
    if not current then
      return false
    end
    return current.panel:render()
  end

  ---Close the panel when it is open, and open it when it is closed.
  ---@param open_opts? codeview.panel.OpenOpts
  ---@return boolean open State after the call.
  function life.toggle(open_opts)
    if life.is_open() then
      life.close()
      return false
    end
    return life.open(open_opts) ~= nil
  end

  return life
end

return M
