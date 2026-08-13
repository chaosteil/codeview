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
  desc = "Review a commit, a range, or a jj revset (:CodeView <rev>), or pick from the log",
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
