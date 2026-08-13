---@brief Configuration defaults, merge, and validation for codeview.
---
--- Every option has a concrete default value. No default is `nil`, so the
--- defaults table is the full list of valid keys. `setup()` rejects unknown
--- keys with this table.

local fs = vim.fs
local fn = vim.fn

local M = {}

---@class codeview.Config
---@field backend "auto"|"git"|"jj" Which VCS backend to use. "auto" detects the repo type.
---@field diff codeview.Config.Diff Diff view options.
---@field sidebar codeview.Config.Sidebar Changed-files sidebar options.
---@field comments codeview.Config.Comments Comment editor and storage options.
---@field export codeview.Config.Export Export options.
---@field keymaps table<string, string|string[]|false> Buffer-local keymaps. A list holds more than one key for one action. Set an entry to false to disable it.
---@field log_level integer Minimum level for notifications. Use a `vim.log.levels` value.

---@class codeview.Config.Diff
---@field style "inline"|"split" Default diff style. "inline" is a unified diff, "split" is side by side.
---@field context integer Number of unchanged lines kept around each hunk.
---@field max_lines integer Diffs above this line count need a manual confirmation.
---@field word_diff boolean Highlight the changed words inside a modified line.

---@class codeview.Config.Sidebar
---@field position "left"|"right" Side of the tab page for the sidebar.
---@field width integer Width of the sidebar in columns.
---@field auto_open boolean Open the sidebar when a session starts.
---@field icons codeview.Config.Sidebar.Icons Text icons of the file tree.

---@class codeview.Config.Sidebar.Icons
---@field expanded string Icon of a directory that shows its children.
---@field collapsed string Icon of a directory that hides its children.
---@field file string Icon of a file. It keeps the names in one column.
---@field guide string Indent guide of one tree level.
---@field current string Marker of the file that the diff view shows.

---@class codeview.Config.Comments
---@field dir string Directory for the session files. One subdirectory per repo.
---@field display "virtual"|"float" How to show a comment body in the diff.
---@field sign string Sign text for a commented line.
---@field border string Border of the comment editor and of the comment float.
---@field width integer Width of the comment editor, in columns.
---@field height integer Height of the comment editor, in lines.

---@class codeview.Config.Export
---@field register string Register that receives the exported markdown.
---@field template fun(session: table): string|false Custom renderer. False uses the built-in renderer.

---Default configuration.
---@type codeview.Config
M.defaults = {
  backend = "auto",
  diff = {
    style = "inline",
    context = 3,
    max_lines = 20000,
    word_diff = true,
  },
  sidebar = {
    position = "left",
    width = 40,
    auto_open = true,
    icons = {
      expanded = "▾",
      collapsed = "▸",
      file = " ",
      guide = "│",
      current = "▸",
    },
  },
  comments = {
    dir = fs.joinpath(fn.stdpath("config") --[[@as string]], "review"),
    display = "virtual",
    sign = "▌",
    border = "rounded",
    width = 72,
    height = 10,
  },
  export = {
    register = "+",
    template = false,
  },
  keymaps = {
    open_file = "<CR>",
    toggle_node = "<Tab>",
    expand_all = "zR",
    collapse_all = "zM",
    next_file = "]f",
    prev_file = "[f",
    next_hunk = "]h",
    prev_hunk = "[h",
    expand_context = "za",
    toggle_style = "<leader>ct",
    comment = "<leader>cc",
    -- The diff buffer is read-only, so the insert keys are free. They open the
    -- comment editor instead. Visual `i` stays free, because `vi(` must work.
    comment_insert = { "i", "a", "o", "O" },
    comment_visual = { "I", "A", "c" },
    edit_comment = "<leader>ce",
    delete_comment = "<leader>cd",
    show_comment = "K",
    close = "q",
  },
  log_level = vim.log.levels.WARN,
}

---Active configuration. It holds the defaults until `setup()` runs.
---@type codeview.Config
M.options = vim.deepcopy(M.defaults)

---@param list string[]
---@return fun(value: any): boolean, string
local function one_of(list)
  local message = table.concat(
    vim.tbl_map(function(item)
      return string.format("%q", item)
    end, list),
    ", "
  )
  return function(value)
    return type(value) == "string" and vim.tbl_contains(list, value)
  end,
    "one of " .. message
end

---@param value any
---@return boolean
local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

---Report whether a value names one key, a list of keys, or no key.
---@param value any
---@return boolean
local function keys_value(value)
  if value == false or type(value) == "string" then
    return true
  end
  if not vim.islist(value) then
    return false
  end
  for _, lhs in ipairs(value) do
    if type(lhs) ~= "string" then
      return false
    end
  end
  return true
end

---Report the keys that are not in the defaults.
---@param opts table
---@param defaults table
---@param path string
---@param unknown string[]
local function collect_unknown(opts, defaults, path, unknown)
  for key, value in pairs(opts) do
    local name = path == "" and tostring(key) or path .. "." .. tostring(key)
    local default = defaults[key]
    if default == nil then
      unknown[#unknown + 1] = name
    elseif type(default) == "table" and type(value) == "table" and not vim.islist(default) then
      -- A list default is one value, for example a list of keys. Its entries
      -- are not options.
      collect_unknown(value, default, name, unknown)
    end
  end
end

---Validate a user option table.
---@param opts table User options, already merged with the defaults.
---@return string? err Message of the first problem, or nil when the table is valid.
function M.validate(opts)
  local ok, err = pcall(function()
    vim.validate("backend", opts.backend, one_of({ "auto", "git", "jj" }))

    vim.validate("diff", opts.diff, "table")
    vim.validate("diff.style", opts.diff.style, one_of({ "inline", "split" }))
    vim.validate("diff.context", opts.diff.context, positive_integer, "positive integer")
    vim.validate("diff.max_lines", opts.diff.max_lines, positive_integer, "positive integer")
    vim.validate("diff.word_diff", opts.diff.word_diff, "boolean")

    vim.validate("sidebar", opts.sidebar, "table")
    vim.validate("sidebar.position", opts.sidebar.position, one_of({ "left", "right" }))
    vim.validate("sidebar.width", opts.sidebar.width, positive_integer, "positive integer")
    vim.validate("sidebar.auto_open", opts.sidebar.auto_open, "boolean")
    vim.validate("sidebar.icons", opts.sidebar.icons, "table")
    for name, icon in pairs(opts.sidebar.icons) do
      vim.validate("sidebar.icons." .. tostring(name), icon, "string")
    end

    vim.validate("comments", opts.comments, "table")
    vim.validate("comments.dir", opts.comments.dir, "string")
    vim.validate("comments.display", opts.comments.display, one_of({ "virtual", "float" }))
    vim.validate("comments.sign", opts.comments.sign, "string")
    vim.validate("comments.border", opts.comments.border, "string")
    vim.validate("comments.width", opts.comments.width, positive_integer, "positive integer")
    vim.validate("comments.height", opts.comments.height, positive_integer, "positive integer")

    vim.validate("export", opts.export, "table")
    vim.validate("export.register", opts.export.register, "string")
    vim.validate("export.template", opts.export.template, function(value)
      return value == false or type(value) == "function"
    end, "function or false")

    vim.validate("keymaps", opts.keymaps, "table")
    for action, lhs in pairs(opts.keymaps) do
      vim.validate("keymaps." .. tostring(action), lhs, keys_value, "string, list of strings, or false")
    end

    vim.validate("log_level", opts.log_level, "number")
  end)
  if ok then
    return nil
  end
  -- `error()` prefixes the message with the source position. Drop it.
  local message = tostring(err)
  return (message:gsub("^[^%s]-:%d+:%s*", ""))
end

---Merge user options into a copy of the defaults.
---@param opts? table
---@return codeview.Config
function M.merge(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- A keymap option is one value, not a table of options. A list from the user
  -- replaces the default list, entry by entry.
  local keymaps = opts and opts.keymaps
  if type(keymaps) == "table" then
    for action, lhs in pairs(keymaps) do
      merged.keymaps[action] = vim.deepcopy(lhs)
    end
  end
  return merged
end

---Merge, validate, and store the configuration.
---@param opts? table User options.
---@return codeview.Config? config The merged configuration, or nil after an error.
---@return string? err The reason why the options are invalid.
function M.setup(opts)
  -- Check the type before the default, because `false` is not a valid table.
  if opts ~= nil and type(opts) ~= "table" then
    return nil, "codeview.setup: expected table, got " .. type(opts)
  end
  opts = opts or {}

  local unknown = {}
  collect_unknown(opts, M.defaults, "", unknown)
  if #unknown > 0 then
    table.sort(unknown)
    return nil, "unknown option: " .. table.concat(unknown, ", ")
  end

  local merged = M.merge(opts)
  local err = M.validate(merged)
  if err then
    return nil, err
  end

  merged.comments.dir = fs.normalize(merged.comments.dir)
  M.options = merged
  return M.options, nil
end

---Read the active configuration.
---@return codeview.Config
function M.get()
  return M.options
end

---Read one keymap option as a list of keys.
---
--- An option holds one key, a list of keys, or false. The call gives the keys
--- of the action, and an empty list for an action that the user disabled.
---@param value string|string[]|false|nil Value of one `keymaps` entry.
---@return string[] keys
function M.keys(value)
  if type(value) == "string" then
    return value ~= "" and { value } or {}
  end
  if type(value) ~= "table" then
    return {}
  end
  local out = {}
  for _, lhs in ipairs(value) do
    if type(lhs) == "string" and lhs ~= "" then
      out[#out + 1] = lhs
    end
  end
  return out
end

---Reset the configuration to the defaults.
function M.reset()
  M.options = vim.deepcopy(M.defaults)
end

---Directory that holds the comment files of one repository.
---
--- The slug keeps the directory readable. The digest keeps it unique, because
--- the slug alone maps different roots to the same name, for example "/a/b.c"
--- and "/a/b/c".
---@param repo_root string Absolute path of the repository root.
---@return string dir
function M.store_dir(repo_root)
  local normalized = fs.normalize(repo_root)
  local slug = normalized:gsub("[^%w%-_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if slug == "" then
    slug = "repo"
  end
  return fs.joinpath(M.options.comments.dir, slug .. "-" .. fn.sha256(normalized):sub(1, 8))
end

return M
