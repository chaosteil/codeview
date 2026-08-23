---@brief The key hints of a review.
---
--- A terminal tool shows the keys that it takes at the bottom of the screen.
--- This module does the same for a review session. It shows one row under the
--- windows of the session, with the keys of the window that has the cursor.
---
--- The row holds the keys that a reader does not guess. `i` writes a comment
--- and `<CR>` opens the file under the cursor, so neither reads here. A key
--- like the style toggle reads here, because nothing else names it.
---
--- The row is one window of one line, and not a float. A float covers a line
--- of the diff or the statusline. A reader who scrolls to the last line of a
--- file loses it behind the hints.
---
--- Set `hints.enabled` to false to leave the row out.

local config = require("codeview.config")

local api = vim.api

local M = {}

---Filetype of the hint buffer.
---@type string
M.filetype = "codeview-hints"

---Actions of each surface, in the order that they read.
---
--- The list holds the keys that a reader does not guess from the window. A
--- surface takes its list from the `hints.actions` option when the option
--- names it.
---@type table<string, { action: string, text: string }[]>
M.actions = {
  sidebar = {
    { action = "next_file", text = "next file" },
    { action = "toggle_node", text = "fold" },
    { action = "collapse_all", text = "fold all" },
    { action = "toggle_style", text = "style" },
    { action = "edit_file", text = "edit the file" },
    { action = "toggle_overview", text = "comments" },
    { action = "close", text = "close" },
  },
  view = {
    { action = "next_hunk", text = "next hunk" },
    { action = "next_file", text = "next file" },
    { action = "expand_context", text = "unfold" },
    { action = "toggle_style", text = "style" },
    { action = "edit_file", text = "edit the file" },
    { action = "show_comment", text = "read comment" },
    { action = "edit_comment", text = "edit comment" },
    { action = "delete_comment", text = "delete comment" },
    { action = "toggle_overview", text = "comments" },
  },
  file = {
    { action = "back", text = "back to the review" },
  },
  overview = {
    { action = "edit_comment", text = "edit" },
    { action = "delete_comment", text = "delete" },
    { action = "resolve_comment", text = "resolve" },
    { action = "toggle_overview", text = "close" },
  },
}

---Hint row of the session that runs.
---@type { buf: integer, win: integer, session: codeview.Session, group: integer, surface: string? }?
local state = nil

---Report whether a window belongs to the hint row.
---@param win integer?
---@return boolean
function M.is_hint_win(win)
  return state ~= nil and win == state.win and api.nvim_win_is_valid(win)
end

---Surface of one window of a session.
---@param win integer
---@return string? name Nil for a window that no surface owns.
local function surface_of(win)
  if not api.nvim_win_is_valid(win) then
    return nil
  end
  local sidebar = require("codeview.sidebar").get()
  if sidebar and sidebar.panel:window() == win then
    return "sidebar"
  end
  local overview = require("codeview.overview").get()
  if overview and overview.panel:window() == win then
    return "overview"
  end
  local view = require("codeview.view").current()
  if view and (view.win == win or view.old_win == win) then
    return "view"
  end
  -- The file that the edit key opened. It holds the way back.
  if vim.b[api.nvim_win_get_buf(win)].codeview_file then
    return "file"
  end
  return nil
end

---Text of one key, for the reader.
---@param lhs string
---@return string
local function key_text(lhs)
  local text = lhs:gsub("<[lL]eader>", vim.g.mapleader == " " and "<space>" or (vim.g.mapleader or "\\"))
  return text
end

---Chunks of the hint row of one surface.
---@param name string
---@return { text: string, hl: string }[] chunks
function M.chunks(name)
  local cfg = config.get()
  local actions = (cfg.hints.actions or {})[name] or M.actions[name] or {}
  local keys = cfg.keymaps

  ---@type { text: string, hl: string }[]
  local out = {}
  for _, entry in ipairs(actions) do
    local lhs = require("codeview.config").keys(keys[entry.action])[1]
    if lhs then
      if #out > 0 then
        out[#out + 1] = { text = "  ", hl = "CodeViewHint" }
      end
      out[#out + 1] = { text = key_text(lhs), hl = "CodeViewHintKey" }
      out[#out + 1] = { text = " " .. entry.text, hl = "CodeViewHint" }
    end
  end
  return out
end

---Write the chunks of a surface into the hint buffer.
---@param name string?
local function render(name)
  if not state or not api.nvim_buf_is_valid(state.buf) then
    return
  end
  local chunks = name and M.chunks(name) or {}
  local text = ""
  for _, chunk in ipairs(chunks) do
    text = text .. chunk.text
  end

  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, { " " .. text })
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified = false

  api.nvim_buf_clear_namespace(state.buf, M.ns, 0, -1)
  local col = 1
  for _, chunk in ipairs(chunks) do
    local width = #chunk.text
    if width > 0 then
      pcall(api.nvim_buf_set_extmark, state.buf, M.ns, 0, col, {
        end_col = col + width,
        hl_group = chunk.hl,
      })
    end
    col = col + width
  end
  state.surface = name
end

---Namespace of the hint highlights.
---@type integer
M.ns = api.nvim_create_namespace("codeview.hints")

---Draw the row again for the window that has the cursor.
function M.refresh()
  if not state then
    return
  end
  if not state.session:is_active() then
    M.close()
    return
  end
  local name = surface_of(api.nvim_get_current_win())
  -- A window of another buffer keeps the last surface, so the row does not
  -- blink while the cursor passes through.
  render(name or state.surface)
end

---Open the hint row of a session.
---@param opts? { session?: codeview.Session }
---@return boolean opened False when the option is off, or without a session.
function M.open(opts)
  opts = opts or {}
  local session = opts.session or require("codeview.session").current()
  if not session or not session:is_active() or not config.get().hints.enabled then
    return false
  end
  if state and state.session == session and api.nvim_win_is_valid(state.win) then
    M.refresh()
    return true
  end
  M.close()

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = M.filetype
  vim.bo[buf].modifiable = false

  local current = api.nvim_get_current_win()
  local win = api.nvim_open_win(buf, false, { split = "below", win = -1, height = 1 })
  api.nvim_win_set_var(win, "codeview_panel", true)
  vim.wo[win][0].winfixheight = true
  vim.wo[win][0].number = false
  vim.wo[win][0].relativenumber = false
  vim.wo[win][0].signcolumn = "no"
  vim.wo[win][0].cursorline = false
  vim.wo[win][0].wrap = false
  vim.wo[win][0].statusline = " "
  vim.wo[win][0].winbar = nil
  api.nvim_set_current_win(current)

  local group = api.nvim_create_augroup("codeview.hints", { clear = true })
  state = { buf = buf, win = win, session = session, group = group }
  session:add_window(win)
  session:add_buffer(buf)

  api.nvim_create_autocmd({ "WinEnter", "BufEnter", "CursorMoved" }, {
    group = group,
    desc = "Draw the codeview key hints of the window",
    callback = function()
      vim.schedule(M.refresh)
    end,
  })
  session:on_close(function()
    M.close()
  end)

  require("codeview.highlight").setup()
  M.refresh()
  return true
end

---Close the hint row.
function M.close()
  if not state then
    return
  end
  local held = state
  state = nil
  pcall(api.nvim_del_augroup_by_id, held.group)
  if api.nvim_win_is_valid(held.win) then
    pcall(api.nvim_win_close, held.win, true)
  end
  if api.nvim_buf_is_valid(held.buf) then
    pcall(api.nvim_buf_delete, held.buf, { force = true })
  end
end

---Report whether the hint row is open.
---@return boolean
function M.is_open()
  return state ~= nil and api.nvim_win_is_valid(state.win)
end

---Row that runs now, for the tests.
---@return { buf: integer, win: integer, surface: string? }?
function M.get()
  if not M.is_open() then
    return nil
  end
  return state
end

---Text of the hint row.
---@return string? text Nil while the row is closed.
function M.text()
  if not M.is_open() then
    return nil
  end
  return api.nvim_buf_get_lines(state.buf, 0, 1, false)[1]
end

return M
