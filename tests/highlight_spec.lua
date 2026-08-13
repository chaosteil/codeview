local helpers = require("tests.helpers")

local api = vim.api

---Link of a highlight group.
---@param name string
---@return string? target
local function link_of(name)
  local ok, value = pcall(api.nvim_get_hl, 0, { name = name })
  if not ok then
    return nil
  end
  return value.link
end

describe("codeview.highlight", function()
  local highlight

  before_each(function()
    helpers.unload()
    highlight = require("codeview.highlight")
  end)

  after_each(function()
    pcall(api.nvim_del_augroup_by_name, "codeview.highlight")
    helpers.unload()
  end)

  it("links every group to a standard group", function()
    highlight.apply()
    assert.are.equal("Added", link_of("CodeViewAdded"))
    assert.are.equal("Changed", link_of("CodeViewModified"))
    assert.are.equal("Removed", link_of("CodeViewDeleted"))
    assert.are.equal("Special", link_of("CodeViewRenamed"))
    assert.are.equal("Title", link_of("CodeViewTitle"))
    assert.are.equal("Directory", link_of("CodeViewDir"))
  end)

  it("names a group for every status", function()
    for status, group in pairs(highlight.status) do
      assert.are.equal(group, highlight.for_status(status))
      assert.is_truthy(highlight.links[group], group .. " has no link")
    end
    assert.are.equal("CodeViewUnknown", highlight.for_status(nil))
    assert.are.equal("CodeViewUnknown", highlight.for_status("no-such-status"))
  end)

  it("keeps a link that the user set", function()
    -- The group stays on "String" for the rest of the file. No other test
    -- reads it.
    api.nvim_set_hl(0, "CodeViewCopied", { link = "String" })
    highlight.apply()
    assert.are.equal("String", link_of("CodeViewCopied"))
  end)

  it("sets the links again on a colorscheme change", function()
    highlight.setup()
    assert.are.equal(1, #api.nvim_get_autocmds({ group = "codeview.highlight", event = "ColorScheme" }))

    api.nvim_exec_autocmds("ColorScheme", { modeline = false })
    assert.are.equal("Added", link_of("CodeViewAdded"))
    assert.are.equal("Title", link_of("CodeViewTitle"))
  end)

  it("keeps one autocmd after a second setup", function()
    highlight.setup()
    highlight.setup()
    assert.are.equal(1, #api.nvim_get_autocmds({ group = "codeview.highlight" }))
  end)
end)
