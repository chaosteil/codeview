-- Entry point of the plugin. Keep this file small: it runs at startup.
-- All work happens in `lua/codeview/`, which loads on demand.

if vim.g.loaded_codeview then
  return
end

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify("codeview needs Neovim 0.11 or later", vim.log.levels.ERROR)
  return
end

vim.g.loaded_codeview = 1

-- `vim.g.codeview` holds the options for users who do not call `setup()`.
if type(vim.g.codeview) == "table" then
  require("codeview").setup(vim.g.codeview)
end

vim.api.nvim_create_user_command("CodeView", function(opts)
  require("codeview.command").run(opts)
end, {
  nargs = "*",
  bang = true,
  -- A Lua completion behaves like `customlist`: it filters the names itself.
  complete = function(lead)
    return vim.startswith("pr", lead) and { "pr" } or {}
  end,
  desc = "Review a commit, a range, a jj revset, or a pull request (:CodeView pr <number>)",
})

vim.api.nvim_create_user_command("CodeViewClose", function()
  require("codeview.command").close()
end, {
  desc = "Close the review session",
})

vim.api.nvim_create_user_command("CodeViewFiles", function()
  require("codeview.command").files()
end, {
  desc = "Open or close the changed-files sidebar",
})

vim.api.nvim_create_user_command("CodeViewComments", function()
  require("codeview.command").overview()
end, {
  desc = "Open or close the comment overview sidebar",
})

vim.api.nvim_create_user_command("CodeViewExport", function(opts)
  require("codeview.command").export(opts)
end, {
  nargs = "?",
  bang = true,
  -- A Lua completion behaves like `customlist`: it filters the names itself.
  complete = function(lead)
    local names = {}
    for _, name in ipairs({ "+", "*", '"', "a", "b", "c", "z" }) do
      if vim.startswith(name, lead) then
        names[#names + 1] = name
      end
    end
    return names
  end,
  desc = "Render the comments of the session as markdown (:CodeViewExport [register])",
})

vim.api.nvim_create_user_command("CodeViewSubmit", function(opts)
  require("codeview.command").submit(opts)
end, {
  nargs = "?",
  bang = true,
  -- A Lua completion behaves like `customlist`: it filters the names itself.
  complete = function(lead)
    local names = {}
    for _, name in ipairs({ "comment", "approve", "request-changes" }) do
      if vim.startswith(name, lead) then
        names[#names + 1] = name
      end
    end
    return names
  end,
  desc = "Send the comments of the session to the pull request (:CodeViewSubmit [event])",
})
