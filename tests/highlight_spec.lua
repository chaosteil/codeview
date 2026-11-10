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

  it("computes the contrast ratio of two colors", function()
    assert.are.equal(21, highlight.contrast(0x000000, 0xffffff))
    assert.are.equal(1, highlight.contrast(0x123456, 0x123456))
    assert.are.equal(highlight.contrast(0x1d1d1d, 0x011d24), highlight.contrast(0x011d24, 0x1d1d1d))
    assert.is_true(highlight.contrast(0x1d1d1d, 0x011d24) < highlight.min_frame_contrast)
  end)

  it("keeps one autocmd after a second setup", function()
    highlight.setup()
    highlight.setup()
    assert.are.equal(1, #api.nvim_get_autocmds({ group = "codeview.highlight" }))
  end)

  describe("comment boxes on a transparent colorscheme", function()
    local saved

    before_each(function()
      saved = {
        Normal = api.nvim_get_hl(0, { name = "Normal" }),
        NormalFloat = api.nvim_get_hl(0, { name = "NormalFloat" }),
        FloatBorder = api.nvim_get_hl(0, { name = "FloatBorder" }),
        DiagnosticInfo = api.nvim_get_hl(0, { name = "DiagnosticInfo" }),
        background = vim.o.background,
      }
    end)

    ---Set the groups of a transparent colorscheme: a foreground, no background.
    ---
    --- A change of 'background' sets the default colors again, so the tests
    --- call this after the change.
    local function transparent()
      api.nvim_set_hl(0, "Normal", { fg = 0xeeeeee })
      api.nvim_set_hl(0, "NormalFloat", { fg = 0xeeeeee })
      api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x0000ff })
    end

    after_each(function()
      for _, name in ipairs({ "Normal", "NormalFloat", "FloatBorder", "DiagnosticInfo" }) do
        api.nvim_set_hl(0, name, saved[name])
      end
      vim.o.background = saved.background
    end)

    it("tints black for a dark background", function()
      vim.o.background = "dark"
      transparent()
      highlight.apply_comment_boxes()
      local box = api.nvim_get_hl(0, { name = "CodeViewCommentBox" })
      -- 15 percent of 0xff on 0x00 is 0x26.
      assert.are.equal(0x000026, box.bg)
      assert.are.equal(box.bg, api.nvim_get_hl(0, { name = "CodeViewCommentBorder" }).bg)
    end)

    it("tints white for a light background", function()
      vim.o.background = "light"
      transparent()
      highlight.apply_comment_boxes()
      local box = api.nvim_get_hl(0, { name = "CodeViewCommentBox" })
      -- 85 percent of 0xff on red and green, all of it on blue.
      assert.are.equal(0xd9d9ff, box.bg)
    end)

    it("tints the background of NormalFloat when it has one", function()
      transparent()
      api.nvim_set_hl(0, "NormalFloat", { bg = 0x101010 })
      highlight.apply_comment_boxes()
      local box = api.nvim_get_hl(0, { name = "CodeViewCommentBox" })
      -- 0x10 * 0.85 + 0xff * 0.15 = 51.85, so blue is 0x34. Red and green are 0x0e.
      assert.are.equal(0x0e0e34, box.bg)
    end)

    it("gives the frame the tint when FloatBorder hides on the box", function()
      vim.o.background = "dark"
      transparent()
      -- A near-black border, like the one of pierre. The box is 0x000026.
      api.nvim_set_hl(0, "FloatBorder", { fg = 0x1d1d1d })
      highlight.apply_comment_boxes()
      local border = api.nvim_get_hl(0, { name = "CodeViewCommentBorder" })
      assert.are.equal(0x0000ff, border.fg)
      assert.are.equal(0x000026, border.bg)
    end)

    it("keeps a FloatBorder that stands out from the box", function()
      vim.o.background = "dark"
      transparent()
      api.nvim_set_hl(0, "FloatBorder", { fg = 0xcccccc })
      highlight.apply_comment_boxes()
      assert.are.equal(0xcccccc, api.nvim_get_hl(0, { name = "CodeViewCommentBorder" }).fg)
    end)

    it("gives the same colors from a window that maps Normal to the box", function()
      transparent()
      highlight.apply_comment_boxes()
      local first = api.nvim_get_hl(0, { name = "CodeViewCommentBox" })

      -- The inline comment editor maps Normal to the box group. After the
      -- window shows once, `link = false` reads that map.
      local buf = api.nvim_create_buf(false, true)
      local win = api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 20, height = 2 })
      vim.wo[win][0].winhighlight = "Normal:CodeViewCommentBox,FloatBorder:CodeViewCommentBorder"
      vim.cmd.redraw()
      highlight.apply_comment_boxes()
      highlight.apply_comment_boxes()
      local again = api.nvim_get_hl(0, { name = "CodeViewCommentBox" })
      api.nvim_win_close(win, true)

      assert.are.equal(0x000026, first.bg)
      assert.are.equal(first.bg, again.bg)
    end)
  end)
end)
