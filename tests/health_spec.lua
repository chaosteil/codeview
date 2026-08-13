local helpers = require("tests.helpers")

---Run `:checkhealth codeview` and read the report.
---@return string
local function report()
  vim.cmd("checkhealth codeview")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text = table.concat(lines, "\n")
  vim.cmd("bwipeout!")
  return text
end

describe("codeview.health", function()
  after_each(function()
    helpers.unload()
  end)

  it("provides a check function", function()
    assert.are.equal("function", type(require("codeview.health").check))
  end)

  it("reports the Neovim version", function()
    local text = report()
    assert.is_truthy(text:find("codeview", 1, true), text)
    local v = vim.version()
    local expected = string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch)
    assert.is_truthy(text:find(expected, 1, true), text)
  end)

  it("reports the state of setup()", function()
    local text = report()
    assert.is_truthy(text:find("setup()", 1, true), text)
    assert.is_truthy(text:find("configuration is valid", 1, true), text)
  end)

  it("reports git, jj, and gh", function()
    local text = report()
    for _, tool in ipairs({ "git", "jj", "gh" }) do
      assert.is_truthy(text:find(tool, 1, true), "missing " .. tool .. " in:\n" .. text)
    end
  end)

  it("reports the version of an installed tool", function()
    local text = report()
    if vim.fn.executable("git") == 1 then
      assert.is_truthy(text:find("git version", 1, true), text)
    end
  end)
end)
