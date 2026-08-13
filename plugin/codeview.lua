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
