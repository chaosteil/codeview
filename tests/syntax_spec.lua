-- Syntax highlights inside a diff.
--
-- The diff buffer holds two revisions with a marker column, so treesitter
-- cannot attach to it. The module parses each side as a whole file and copies
-- the captures into the buffer. The tests read the extmarks of its namespace.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.syntax", function()
  local fixture = fixtures.git_comments()
  local config, highlight, inline, session_mod, syntax, view
  ---@type codeview.Session?
  local opened

  ---Open a session on the fixture range.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return review
  end

  ---Open the diff of the Lua file of the fixture.
  ---@param session codeview.Session
  ---@return codeview.view.State
  local function open_lua(session)
    local index = assert(session:index_of("call.lua"), "no call.lua in the fixture")
    return assert(view.open(session, index))
  end

  ---Marks of the syntax namespace of a buffer.
  ---@param buf integer
  ---@return table[]
  local function marks_of(buf)
    return api.nvim_buf_get_extmarks(buf, syntax.ns, 0, -1, { details = true })
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    assert(config.setup({ commit_message = false }))
    highlight = require("codeview.highlight")
    inline = require("codeview.inline")
    session_mod = require("codeview.session")
    syntax = require("codeview.syntax")
    view = require("codeview.view")
  end)

  after_each(function()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    config.reset()
    helpers.unload()
  end)

  describe("the language", function()
    it("reads the language of a path", function()
      assert.are.equal("lua", syntax.language("lua/codeview/init.lua"))
    end)

    it("answers nothing for a path without a parser", function()
      assert.is_nil(syntax.language("notes.unknown-extension"))
      assert.is_nil(syntax.language(""))
    end)
  end)

  describe("the highlights", function()
    it("writes the captures of the code into the diff", function()
      local session = open_session()
      local state = open_lua(session)
      local marks = marks_of(state.buf)
      assert.is_true(#marks > 0, "no syntax marks in the diff")

      ---@type table<string, boolean>
      local groups = {}
      for _, mark in ipairs(marks) do
        groups[mark[4].hl_group] = true
      end
      -- The file of the fixture holds a call, so the query captures one.
      assert.is_true(groups["@function.call"] or groups["@variable"] or groups["@keyword"], vim.inspect(groups))
    end)

    it("shifts every capture by the marker column", function()
      local session = open_session()
      local state = open_lua(session)
      for _, mark in ipairs(marks_of(state.buf)) do
        -- No capture sits on the marker itself.
        assert.is_true(mark[3] >= #inline.markers.context, "a mark covers the marker column")
      end
    end)

    it("keeps the text of the diff", function()
      local session = open_session()
      local state = open_lua(session)
      local before = api.nvim_buf_get_lines(state.buf, 0, -1, false)
      syntax.apply(state.buf, state.diff, state.map, { offset = 1 })
      assert.are.same(before, api.nvim_buf_get_lines(state.buf, 0, -1, false))
      assert.is_false(vim.bo[state.buf].modifiable)
    end)

    it("writes nothing when the option is off", function()
      assert(config.setup({ commit_message = false, diff = { syntax = false } }))
      local session = open_session()
      local state = open_lua(session)
      assert.are.equal(0, #marks_of(state.buf))
    end)

    it("writes nothing for a commit document", function()
      assert(config.setup({}))
      local session = open_session()
      local message = require("codeview.message")
      local index = assert(session:index_of(message.path_of(session.commits[1].id)))
      local state = assert(view.open(session, index))
      assert.are.equal(0, #marks_of(state.buf))
    end)
  end)

  describe("the row colors", function()
    it("keeps the background of the diff and drops the foreground", function()
      vim.cmd("highlight DiffAdd guibg=#123456 guifg=#abcdef")
      vim.cmd("highlight DiffDelete guibg=#654321 guifg=#fedcba")
      highlight.apply()

      for group in pairs(highlight.diff_rows) do
        local hl = api.nvim_get_hl(0, { name = group, link = false })
        assert.is_nil(hl.fg, group .. " keeps a foreground")
        assert.is_truthy(hl.bg, group .. " has no background")
      end
    end)

    it("keeps the link when the option is off", function()
      assert(config.setup({ diff = { syntax = false } }))
      highlight.apply()
      for group, target in pairs(highlight.diff_rows) do
        local hl = api.nvim_get_hl(0, { name = group })
        assert.are.equal(target, hl.link)
      end
    end)
  end)

  describe("the word colors", function()
    it("mixes the diff color into the row background", function()
      vim.cmd("highlight DiffAdd guibg=#000000")
      vim.cmd("highlight DiffDelete guibg=#000000")
      vim.cmd("highlight Added guifg=#ff0000")
      vim.cmd("highlight Removed guifg=#0000ff")
      highlight.apply()

      -- A quarter of 255 is 63.75, which rounds to 64, or 0x40.
      local add = api.nvim_get_hl(0, { name = "CodeViewDiffTextAdd", link = false })
      assert.are.equal(0x400000, add.bg)
      assert.is_nil(add.fg)
      local removed = api.nvim_get_hl(0, { name = "CodeViewDiffTextDelete", link = false })
      assert.are.equal(0x000040, removed.bg)
      assert.is_nil(removed.fg)
    end)

    it("links to the shared group when a color is missing", function()
      vim.cmd("highlight Added guifg=NONE")
      vim.cmd("highlight Removed guifg=NONE")
      highlight.apply()
      for group in pairs(highlight.diff_words) do
        local hl = api.nvim_get_hl(0, { name = group })
        assert.are.equal("CodeViewDiffText", hl.link)
      end
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
