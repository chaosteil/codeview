-- Audit of the documentation against the code.
--
-- A stranger installs the plugin from the README and the help file. Every
-- command, option, keymap, and public call must therefore appear in both.

local helpers = require("tests.helpers")

describe("codeview documentation", function()
  local codeview, config

  ---Read one file of the repository.
  ---@param name string Path from the root of the repository.
  ---@return string text
  local function read(name)
    local handle = assert(io.open(vim.fs.joinpath(helpers.root, name), "r"), "no file " .. name)
    local text = handle:read("*a")
    handle:close()
    return text
  end

  local vimdoc = read("doc/codeview.txt")
  local readme = read("README.md")

  ---Report the names that a text does not hold.
  ---@param text string
  ---@param names string[]
  ---@return string[] missing
  local function missing_from(text, names)
    local out = {}
    for _, name in ipairs(names) do
      if not text:find(name, 1, true) then
        out[#out + 1] = name
      end
    end
    table.sort(out)
    return out
  end

  ---Every option path of the defaults, for example "diff.max_lines".
  ---@param value table
  ---@param prefix string
  ---@param out string[]
  ---@return string[] paths
  local function option_paths(value, prefix, out)
    for key, entry in pairs(value) do
      local name = prefix == "" and tostring(key) or prefix .. "." .. tostring(key)
      out[#out + 1] = name
      if type(entry) == "table" and not vim.islist(entry) and prefix ~= "keymaps" then
        option_paths(entry, name, out)
      end
    end
    return out
  end

  before_each(function()
    helpers.unload()
    codeview = require("codeview")
    config = require("codeview.config")
  end)

  after_each(function()
    helpers.unload()
  end)

  it("names every user command", function()
    -- The test harness starts Neovim without the startup plugins, so the file
    -- that defines the commands runs here.
    vim.cmd.source(vim.fs.joinpath(helpers.root, "plugin", "codeview.lua"))
    local names = {}
    for _, command in ipairs(vim.fn.getcompletion("CodeView", "command")) do
      names[#names + 1] = ":" .. command
    end
    assert.is_true(#names >= 6, "the plugin defines the commands")
    assert.are.same({}, missing_from(vimdoc, names))
    assert.are.same({}, missing_from(readme, names))
  end)

  it("holds every user command in the lazy.nvim example of the README", function()
    -- A command that the `cmd` list does not hold gets no stub of the plugin
    -- manager. The command then does not exist before another one loads the
    -- plugin.
    vim.cmd.source(vim.fs.joinpath(helpers.root, "plugin", "codeview.lua"))
    local block = assert(readme:match("cmd = (%b{})"), "the README holds a cmd list")
    local names = {}
    for _, command in ipairs(vim.fn.getcompletion("CodeView", "command")) do
      names[#names + 1] = '"' .. command .. '"'
    end
    assert.is_true(#names >= 6, "the plugin defines the commands")
    assert.are.same({}, missing_from(block, names))
  end)

  it("names every configuration option", function()
    local paths = option_paths(config.defaults, "", {})
    -- The help file and the README both hold the defaults as one block, so
    -- the leaf name of an option answers for its path.
    local leaves = {}
    for _, path in ipairs(paths) do
      leaves[#leaves + 1] = path:match("[^.]+$")
    end
    assert.are.same({}, missing_from(vimdoc, leaves))
    assert.are.same({}, missing_from(readme, leaves))
  end)

  it("names every keymap action and its default keys", function()
    local names = {}
    for action, value in pairs(config.defaults.keymaps) do
      names[#names + 1] = action
      for _, lhs in ipairs(config.keys(value)) do
        names[#names + 1] = lhs
      end
    end
    assert.are.same({}, missing_from(vimdoc, names))
  end)

  it("gives a help tag to every public call", function()
    local names = {}
    for name, value in pairs(codeview) do
      if type(value) == "function" then
        names[#names + 1] = "*codeview." .. name .. "()*"
      end
    end
    assert.is_true(#names >= 30, "the plugin has a public API")
    assert.are.same({}, missing_from(vimdoc, names))
  end)

  it("names every User event", function()
    local names = {
      "CodeViewSessionOpened",
      "CodeViewSessionRefreshed",
      "CodeViewSessionClosed",
      "CodeViewFileOpened",
      "CodeViewCommentAdded",
      "CodeViewCommentChanged",
      "CodeViewCommentDeleted",
      "CodeViewReviewSubmitted",
    }
    assert.are.same({}, missing_from(vimdoc, names))
    -- The events must exist in the code too, not only in the help file.
    local sources = ""
    for name, _ in vim.fs.dir(vim.fs.joinpath(helpers.root, "lua", "codeview")) do
      if name:match("%.lua$") then
        sources = sources .. read(vim.fs.joinpath("lua", "codeview", name))
      end
    end
    assert.are.same({}, missing_from(sources, names))
  end)

  it("names every highlight group of the plugin", function()
    local names = {}
    for group in pairs(require("codeview.highlight").links) do
      names[#names + 1] = group
    end
    assert.is_true(#names >= 10, "the plugin defines highlight groups")
    assert.are.same({}, missing_from(vimdoc, names))
  end)

  it("holds the version of the plugin in the changelog", function()
    local changelog = read("CHANGELOG.md")
    assert.is_truthy(changelog:find("## " .. codeview.version, 1, true), "the changelog holds " .. codeview.version)
  end)

  it("ends the help file with a modeline", function()
    assert.is_truthy(vimdoc:find("vim:tw=78:ts=8:noet:ft=help:norl:", 1, true))
  end)
end)
