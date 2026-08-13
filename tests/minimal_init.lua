-- Minimal init for the test suite.
--
-- It downloads plenary.nvim into `.tests/site` on the first run, then puts the
-- plugin and plenary on the runtimepath. Start it with:
--   nvim --headless -u tests/minimal_init.lua ...

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local site = vim.fs.joinpath(root, ".tests", "site")
local plenary = vim.fs.joinpath(site, "pack", "deps", "start", "plenary.nvim")

if vim.fn.isdirectory(plenary) == 0 then
  vim.fn.mkdir(vim.fs.dirname(plenary), "p")
  io.stderr:write("codeview: cloning plenary.nvim into " .. plenary .. "\n")
  local out = vim.fn.system({
    "git",
    "clone",
    "--depth",
    "1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary,
  })
  if vim.v.shell_error ~= 0 then
    io.stderr:write("codeview: cannot clone plenary.nvim\n" .. out .. "\n")
    vim.cmd("cquit 1")
  end
end

vim.opt.packpath:prepend(site)
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(plenary)

-- The specs load their helpers with `require("tests.helpers")`.
package.path = table.concat({ vim.fs.joinpath(root, "?.lua"), package.path }, ";")

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.g.mapleader = " "

vim.cmd("runtime! plugin/plenary.vim")
