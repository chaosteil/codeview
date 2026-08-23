-- Entry point of the plugin. Keep this file small: it runs at startup.
-- All work happens in `lua/codeview/`, which loads on demand.

if vim.g.loaded_codeview then
  return
end
-- The guard comes before the version check, so a second `:runtime!` does not
-- notify again.
vim.g.loaded_codeview = 1

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify("codeview needs Neovim 0.11 or later", vim.log.levels.ERROR)
  return
end

-- `vim.g.codeview` holds the options for users who do not call `setup()`.
if type(vim.g.codeview) == "table" then
  require("codeview").setup(vim.g.codeview)
end

-- One command drives the plugin. `codeview.command` holds the subcommands, so
-- the completion reads its table. The require stays inside the callbacks: the
-- module loads on the first run and on the first completion, not at startup.
vim.api.nvim_create_user_command("CodeView", function(opts)
  require("codeview.command").run(opts)
end, {
  nargs = "*",
  bang = true,
  -- A Lua completion behaves like `customlist`: it filters the names itself.
  -- It takes the word under the cursor, the whole command line, and the
  -- position of the cursor in that line.
  complete = function(lead, line, pos)
    local subcommands = require("codeview.command").subcommands
    -- Text after the name of the command, up to the cursor.
    local text = line:sub(1, pos):match("^%s*%S+%s+(.*)$") or ""
    local words = vim.split(text, "%s+", { trimempty = true })
    -- The lead is the word under the cursor, so it ends no word.
    local done = #words - (lead ~= "" and 1 or 0)
    local values = {}
    if done == 0 then
      values[#values + 1] = "pr"
      for name in pairs(subcommands) do
        values[#values + 1] = name
      end
    elseif done == 1 then
      local sub = subcommands[words[1]:lower()]
      values = sub and sub.args or {}
    end

    local names = {}
    for _, value in ipairs(values) do
      if vim.startswith(value, lead) then
        names[#names + 1] = value
      end
    end
    table.sort(names)
    return names
  end,
  desc = "Review a commit, a range, a jj revset, or a pull request, and run a subcommand of the session",
})
