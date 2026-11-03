---@brief The loading view of a review that opens.
---
--- A pull request review needs the network before it can show a diff. The
--- open call asks gh for the pull request and fetches its commits. Without a
--- view, the reader looks at an empty window for this time, and an error
--- arrives as one message on that empty window.
---
--- The loading view is a float in the middle of the editor. It shows the title
--- of the review and one line per step of the open call. A spinner turns on
--- the step that runs, and a check mark stands on each step that ended. The
--- view closes before the review windows open.
---
--- After an error, the view stays. It marks the step that failed and shows the
--- error. The cursor goes into the view, and `q` or `<Esc>` closes it. The
--- view is then the report of the error, so `:Codeview pr` sends no message
--- for it.
---
--- The view does not take the cursor while the steps run, so the reader can
--- keep on with the window under it.

local config = require("codeview.config")
local highlight = require("codeview.highlight")

local api = vim.api
local uv = vim.uv

local M = {}

---Namespace of the highlights of the view.
---@type integer
M.ns = api.nvim_create_namespace("codeview.loading")

---Filetype of the buffer of the view.
---@type string
M.filetype = "codeview-loading"

---Frames of the spinner.
---@type string[]
M.frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---Time of one frame of the spinner, in milliseconds.
---@type integer
M.frame_ms = 100

---Mark of a step that did not start yet.
---@type string
M.pending_mark = "·"

---Mark of a step that ended.
---@type string
M.done_mark = "✓"

---Mark of the step that failed.
---@type string
M.failed_mark = "✗"

---Default last line of the view after an error.
---@type string
M.close_hint = "q closes this window"

---One step of the open call.
---@class codeview.loading.Step
---@field key string Name of the step, for |codeview.loading.View:start()|.
---@field text string Text of the step line, for the reader.

---State of one step line.
---@alias codeview.loading.State "pending"|"running"|"done"|"failed"

---A loading view.
---@class codeview.loading.View
---@field title string First line of the view.
---@field steps codeview.loading.Step[]
---@field states table<string, codeview.loading.State> State of each step, by key.
---@field error string? Text of the error, after a failure.
---@field frame integer Frame of the spinner, from 1.
---@field buf integer?
---@field win integer?
---@field timer uv.uv_timer_t?
---@field closed boolean
---@field hint string Last line of the view after an error. It names the close key.
---@field on_close fun()? Handler that runs after the view closes.
local View = {}
View.__index = View

---Cut a text into lines of at most `width` cells, at spaces where it can.
---@param text string
---@param width integer
---@return string[] lines
function M.wrap(text, width)
  local out = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      -- A word that is wider than a line gets cut.
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= "" then
          out[#out + 1] = line
          line = ""
        end
        out[#out + 1] = vim.fn.strcharpart(word, 0, width)
        word = vim.fn.strcharpart(word, width)
      end
      if line == "" then
        line = word
      elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
        line = line .. " " .. word
      elseif word ~= "" then
        out[#out + 1] = line
        line = word
      end
    end
    out[#out + 1] = line
  end
  return out
end

---Widest text line of the view, in cells: the width of the editor less the
---border and the padding.
---@return integer width
local function text_width()
  return math.max(vim.o.columns - 10, 16)
end

---Lines of the view and the highlight of each line part.
---@return string[] lines
---@return { line: integer, from: integer, to: integer, hl: string }[] marks Zero-based line, byte columns.
function View:lines()
  local lines = { self.title, "" }
  local marks = { { line = 0, from = 0, to = #self.title, hl = "CodeViewTitle" } }
  for _, step in ipairs(self.steps) do
    local state = self.states[step.key]
    local mark, hl = M.pending_mark, "CodeViewHint"
    if state == "running" then
      mark, hl = M.frames[self.frame], "CodeViewMarker"
    elseif state == "done" then
      mark, hl = M.done_mark, "CodeViewLoadingDone"
    elseif state == "failed" then
      mark, hl = M.failed_mark, "CodeViewLoadingFailed"
    end
    lines[#lines + 1] = mark .. " " .. step.text
    marks[#marks + 1] = { line = #lines - 1, from = 0, to = #mark, hl = hl }
    if state == "pending" then
      marks[#marks + 1] = { line = #lines - 1, from = #mark, to = #lines[#lines], hl = "CodeViewHint" }
    end
  end
  if self.error then
    lines[#lines + 1] = ""
    for _, line in ipairs(M.wrap(self.error, text_width())) do
      lines[#lines + 1] = line
      marks[#marks + 1] = { line = #lines - 1, from = 0, to = #line, hl = "CodeViewLoadingFailed" }
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = self.hint
    marks[#marks + 1] = { line = #lines - 1, from = 0, to = 1, hl = "CodeViewHintKey" }
    marks[#marks + 1] = { line = #lines - 1, from = 1, to = #lines[#lines], hl = "CodeViewHint" }
  end
  return lines, marks
end

---Size and place of the float for the lines.
---@param lines string[]
---@return vim.api.keyset.win_config
local function placement(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  -- Two cells of space on each side.
  width = math.max(math.min(width + 4, vim.o.columns - 4), 20)
  local height = math.max(math.min(#lines, vim.o.lines - 4), 1)
  return {
    relative = "editor",
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    width = width,
    height = height,
  }
end

---Write the lines into the buffer, and fit the float to them.
function View:render()
  if self.closed or not (self.buf and api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local lines, marks = self:lines()
  local padded = {}
  for i, line in ipairs(lines) do
    padded[i] = "  " .. line
  end
  vim.bo[self.buf].modifiable = true
  api.nvim_buf_set_lines(self.buf, 0, -1, false, padded)
  vim.bo[self.buf].modifiable = false
  api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
  for _, mark in ipairs(marks) do
    api.nvim_buf_set_extmark(self.buf, M.ns, mark.line, mark.from + 2, {
      end_col = mark.to + 2,
      hl_group = mark.hl,
    })
  end
  if self.win and api.nvim_win_is_valid(self.win) then
    pcall(api.nvim_win_set_config, self.win, placement(padded))
  end
end

---Report whether the float of the view shows.
---@return boolean
function View:visible()
  return not self.closed and self.win ~= nil and api.nvim_win_is_valid(self.win)
end

---Report whether a step runs.
---@return boolean
function View:running()
  for _, state in pairs(self.states) do
    if state == "running" then
      return true
    end
  end
  return false
end

---Stop the spinner.
function View:stop()
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
end

---Start the spinner, if it does not turn yet.
function View:spin()
  if self.timer or self.closed then
    return
  end
  self.timer = uv.new_timer()
  self.timer:start(
    M.frame_ms,
    M.frame_ms,
    vim.schedule_wrap(function()
      if self.closed or not self:running() then
        self:stop()
        return
      end
      self.frame = self.frame % #M.frames + 1
      self:render()
    end)
  )
end

---Set the first line of the view.
---@param text string
function View:set_title(text)
  self.title = text
  self:render()
end

---Mark a step as the step that runs. A step that ran before it ends.
---@param key string
function View:start(key)
  for name, state in pairs(self.states) do
    if state == "running" then
      self.states[name] = "done"
    end
  end
  self.states[key] = "running"
  self:render()
  self:spin()
end

---Mark a step as ended.
---@param key string
function View:finish(key)
  self.states[key] = "done"
  self:render()
end

---Show an error. The step that runs fails, and the view takes the cursor.
---@param err codeview.Error|string
function View:fail(err)
  if self.closed then
    return
  end
  for name, state in pairs(self.states) do
    if state == "running" then
      self.states[name] = "failed"
    end
  end
  self.error = tostring(err)
  self:stop()
  self:render()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_set_current_win(self.win)
  end
end

---Close the view. A second call does nothing.
function View:close()
  if self.closed then
    return
  end
  self.closed = true
  self:stop()
  if self.win and api.nvim_win_is_valid(self.win) then
    pcall(api.nvim_win_close, self.win, true)
  end
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
  if self.on_close then
    self.on_close()
  end
end

---Open a loading view.
---
--- The view shows the steps in the order of the list, all of them pending.
---@param opts { title: string, steps: codeview.loading.Step[] }
---@return codeview.loading.View view
function M.open(opts)
  highlight.setup()
  local states = {}
  for _, step in ipairs(opts.steps) do
    states[step.key] = "pending"
  end
  local view = setmetatable({
    title = opts.title,
    steps = opts.steps,
    states = states,
    frame = 1,
    closed = false,
    hint = M.close_hint,
  }, View)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = M.filetype
  view.buf = buf
  local lines = view:lines()
  local win_config = vim.tbl_extend("force", placement(lines), {
    style = "minimal",
    border = config.get().comments.border,
    focusable = true,
    zindex = 60,
  })
  local ok, win = pcall(api.nvim_open_win, buf, false, win_config)
  if ok then
    view.win = win
    -- The lines hold the height of the float. A long title gets cut, not
    -- wrapped.
    vim.wo[win][0].wrap = false
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      view:close()
    end, { buffer = buf, nowait = true, desc = "Close the codeview loading view" })
  end
  view:render()
  return view
end

return M
