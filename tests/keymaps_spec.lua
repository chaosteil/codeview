-- Audit of the default keymaps.
--
-- Every action of the `keymaps` option must reach a buffer, take a key of the
-- user, and go away when the user sets the action to false. The test walks all
-- four surfaces that hold maps: the sidebar, the diff view, the comment
-- overview, and the comment editor.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview keymaps", function()
  local fixture = fixtures.git_comments()
  local config, editor, export, overview, session_mod, sidebar, view
  ---@type codeview.Session?
  local opened
  ---@type string?
  local store_dir

  ---Action of every keymap, with the surfaces that hold it.
  ---
  --- "n" and "x" name the mode of the map. The audit fails when the defaults
  --- hold an action that this table does not name, so a new keymap needs a
  --- line here and a line in the documentation.
  ---@type table<string, { surface: string, mode: string }[]>
  local ACTIONS = {
    open_file = { { surface = "sidebar", mode = "n" }, { surface = "overview", mode = "n" } },
    toggle_node = { { surface = "sidebar", mode = "n" }, { surface = "overview", mode = "n" } },
    expand_all = {
      { surface = "sidebar", mode = "n" },
      { surface = "overview", mode = "n" },
      { surface = "view", mode = "n" },
    },
    collapse_all = {
      { surface = "sidebar", mode = "n" },
      { surface = "overview", mode = "n" },
      { surface = "view", mode = "n" },
    },
    next_file = { { surface = "sidebar", mode = "n" }, { surface = "view", mode = "n" } },
    prev_file = { { surface = "sidebar", mode = "n" }, { surface = "view", mode = "n" } },
    next_hunk = { { surface = "view", mode = "n" } },
    prev_hunk = { { surface = "view", mode = "n" } },
    expand_context = { { surface = "view", mode = "n" } },
    -- The load key maps on a diff above the `diff.max_lines` limit only.
    load_diff = { { surface = "view", mode = "n" } },
    toggle_style = { { surface = "sidebar", mode = "n" }, { surface = "view", mode = "n" } },
    edit_file = { { surface = "sidebar", mode = "n" }, { surface = "view", mode = "n" } },
    -- The back key sits on the file that the edit key opened.
    back = { { surface = "file", mode = "n" } },
    comment = { { surface = "view", mode = "n" }, { surface = "view", mode = "x" } },
    comment_insert = { { surface = "view", mode = "n" } },
    comment_add = { { surface = "view", mode = "n" } },
    comment_visual = { { surface = "view", mode = "x" } },
    edit_comment = { { surface = "view", mode = "n" }, { surface = "overview", mode = "n" } },
    delete_comment = { { surface = "view", mode = "n" }, { surface = "overview", mode = "n" } },
    resolve_comment = { { surface = "view", mode = "n" }, { surface = "overview", mode = "n" } },
    show_comment = { { surface = "view", mode = "n" } },
    toggle_overview = {
      { surface = "sidebar", mode = "n" },
      { surface = "view", mode = "n" },
      { surface = "overview", mode = "n" },
    },
    -- The export keys act on the whole review, so they sit in the overview.
    export = { { surface = "overview", mode = "n" } },
    copy_comments = { { surface = "overview", mode = "n" } },
    editor_save = { { surface = "editor", mode = "n" } },
    editor_cancel = { { surface = "editor", mode = "n" } },
    close = {
      { surface = "sidebar", mode = "n" },
      { surface = "view", mode = "n" },
      { surface = "overview", mode = "n" },
      { surface = "export", mode = "n" },
    },
  }

  ---Open a session for the range of the fixture.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Buffer of one surface of an open session.
  ---@param review codeview.Session
  ---@param name string
  ---@return integer buf
  local function buffer_of(review, name)
    if name == "sidebar" then
      return assert(assert(sidebar.open({ session = review })).panel:buffer())
    end
    if name == "overview" then
      return assert(assert(overview.open({ session = review })).panel:buffer())
    end
    if name == "view" then
      return assert(view.open(review, 1)).buf
    end
    if name == "file" then
      assert(view.open(review, 1))
      assert(require("codeview.view").edit(), "the edit key opened no file")
      return api.nvim_get_current_buf()
    end
    if name == "editor" then
      return (editor.open({ on_save = function() end }))
    end
    if name == "export" then
      return assert(assert(export.run({ session = review, notify = false })).buf)
    end
    error("unknown surface " .. name)
  end

  ---Text of one key, after the leader and the termcodes.
  ---
  --- `vim.keymap.set()` resolves `<leader>` and the termcodes, so the map of
  --- the buffer holds another text than the option. One form answers for both.
  ---@param lhs string
  ---@return string
  local function normal(lhs)
    local text = (lhs:gsub("<[lL]eader>", vim.g.mapleader or "\\"))
    return vim.fn.keytrans(api.nvim_replace_termcodes(text, true, true, true))
  end

  ---Keys that codeview maps in one buffer, in one mode.
  ---@param buf integer
  ---@param mode string
  ---@return table<string, boolean>
  local function mapped(buf, mode)
    local out = {}
    for _, map in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
      if type(map.desc) == "string" and map.desc:find("^codeview: ") then
        out[normal(map.lhs)] = true
      end
    end
    return out
  end

  ---Keys of every surface of a session.
  ---
  --- The editor comes last, because its window is a float and a split of a
  --- float fails.
  ---@param review codeview.Session
  ---@return table<string, table<string, table<string, boolean>>>
  local function surface_keys(review)
    local out = {}
    for _, name in ipairs({ "view", "file", "sidebar", "overview", "export", "editor" }) do
      local buf = buffer_of(review, name)
      out[name] = { n = mapped(buf, "n"), x = mapped(buf, "x") }
    end
    return out
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    editor = require("codeview.editor")
    export = require("codeview.export")
    overview = require("codeview.overview")
    session_mod = require("codeview.session")
    sidebar = require("codeview.sidebar")
    view = require("codeview.view")
    store_dir = fixtures.tempdir("codeview-keymaps")
    -- The load key maps on a diff above the line limit only. A limit of one
    -- line makes every diff of the fixture such a diff.
    config.setup({ commit_message = false, comments = { dir = store_dir }, diff = { max_lines = 1 } })
  end)

  after_each(function()
    editor.cancel()
    view.close()
    sidebar.close()
    overview.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    if store_dir then
      vim.fn.delete(store_dir, "rf")
    end
    store_dir = nil
    config.reset()
    helpers.unload()
  end)

  it("names every default action in the audit", function()
    local missing = {}
    for action in pairs(config.defaults.keymaps) do
      if not ACTIONS[action] then
        missing[#missing + 1] = action
      end
    end
    table.sort(missing)
    assert.are.same({}, missing)
  end)

  it("maps every default key in its surface", function()
    local keys = surface_keys(open_session())

    for action, surfaces in pairs(ACTIONS) do
      for _, surface in ipairs(surfaces) do
        for _, lhs in ipairs(config.keys(config.defaults.keymaps[action])) do
          assert.is_true(
            keys[surface.surface][surface.mode][normal(lhs)] == true,
            string.format("%s maps %s for %s in the mode %s", surface.surface, lhs, action, surface.mode)
          )
        end
      end
    end
  end)

  it("takes a key of the user for every action", function()
    -- One key of the user per action. The lower case letters and the upper
    -- case letters together hold 52 actions.
    local letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    ---@type table<string, string>
    local custom = {}
    local index = 0
    for action in pairs(config.defaults.keymaps) do
      index = index + 1
      custom[action] = "," .. letters:sub(index, index)
    end
    assert.is_true(index <= #letters, "the audit needs one letter per action")
    config.setup({ commit_message = false, comments = { dir = store_dir }, diff = { max_lines = 1 }, keymaps = custom })

    local keys = surface_keys(open_session())
    for action, surfaces in pairs(ACTIONS) do
      for _, surface in ipairs(surfaces) do
        assert.is_true(
          keys[surface.surface][surface.mode][custom[action]] == true,
          string.format("%s maps %s for %s", surface.surface, custom[action], action)
        )
      end
    end
  end)

  it("drops every map that the user sets to false", function()
    ---@type table<string, false>
    local off = {}
    for action in pairs(config.defaults.keymaps) do
      off[action] = false
    end
    config.setup({ commit_message = false, comments = { dir = store_dir }, diff = { max_lines = 1 }, keymaps = off })

    local keys = surface_keys(open_session())
    for name, modes in pairs(keys) do
      for mode, out in pairs(modes) do
        assert.are.same({}, out, name .. " holds no map of codeview in the mode " .. mode)
      end
    end
  end)

  it("removes the fixture", function()
    fixture.cleanup()
  end)
end)
