-- The key hint row of a session.
--
-- The row shows the keys of the window that has the cursor. It holds the keys
-- that a reader does not guess, so `i` and `<CR>` stay out of it.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.hints", function()
  local fixture = fixtures.git_comments()
  local config, hints, overview, session_mod, sidebar, view
  ---@type codeview.Session?
  local opened
  ---@type string?
  local store_dir

  ---Open a session on the fixture range.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return review
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    store_dir = fixtures.tempdir("codeview-hints")
    assert(config.setup({ commit_message = false, comments = { dir = store_dir } }))
    hints = require("codeview.hints")
    overview = require("codeview.overview")
    session_mod = require("codeview.session")
    sidebar = require("codeview.sidebar")
    view = require("codeview.view")
  end)

  after_each(function()
    hints.close()
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

  it("opens one row of one line under the windows", function()
    local session = open_session()
    assert.is_true(hints.open({ session = session }))
    local row = assert(hints.get())
    assert.are.equal(1, api.nvim_win_get_height(row.win))
    assert.is_false(vim.bo[row.buf].modifiable)
  end)

  it("shows the keys of the window that has the cursor", function()
    local session = open_session()
    hints.open({ session = session })

    local bar = assert(sidebar.open({ session = session }))
    api.nvim_set_current_win(bar.panel:window())
    hints.refresh()
    local text = assert(hints.text())
    assert.is_truthy(text:find("next file", 1, true), text)
    assert.is_truthy(text:find("]f", 1, true), text)

    local state = assert(view.open(session, 1))
    api.nvim_set_current_win(state.win)
    hints.refresh()
    local diff_text = assert(hints.text())
    assert.is_truthy(diff_text:find("next hunk", 1, true), diff_text)
    assert.is_truthy(diff_text:find("]h", 1, true), diff_text)
  end)

  it("leaves the keys that the window shows out", function()
    local session = open_session()
    hints.open({ session = session })
    local state = assert(view.open(session, 1))
    api.nvim_set_current_win(state.win)
    hints.refresh()

    local text = assert(hints.text())
    -- The insert keys and <CR> come naturally, so they take no space here.
    for _, key in ipairs({ " i ", " o ", "<CR>" }) do
      assert.is_nil(text:find(key, 1, true), "the row holds " .. key .. ": " .. text)
    end
  end)

  it("takes the keys of the user", function()
    assert(config.setup({
      commit_message = false,
      comments = { dir = store_dir },
      keymaps = { toggle_style = "gs" },
    }))
    local session = open_session()
    hints.open({ session = session })
    local state = assert(view.open(session, 1))
    api.nvim_set_current_win(state.win)
    hints.refresh()

    assert.is_truthy(assert(hints.text()):find("gs style", 1, true), hints.text())
  end)

  it("takes an action list of the user", function()
    assert(config.setup({
      commit_message = false,
      comments = { dir = store_dir },
      hints = { actions = { view = { { action = "close", text = "leave" } } } },
    }))
    local session = open_session()
    hints.open({ session = session })
    local state = assert(view.open(session, 1))
    api.nvim_set_current_win(state.win)
    hints.refresh()

    local text = assert(hints.text())
    assert.is_truthy(text:find("leave", 1, true), text)
    assert.is_nil(text:find("next hunk", 1, true), text)
  end)

  it("opens no row when the option is off", function()
    assert(config.setup({ commit_message = false, comments = { dir = store_dir }, hints = { enabled = false } }))
    local session = open_session()
    assert.is_false(hints.open({ session = session }))
    assert.is_false(hints.is_open())
    assert.is_nil(hints.text())
  end)

  it("closes with the session", function()
    local session = open_session()
    hints.open({ session = session })
    assert.is_true(hints.is_open())

    session:close()
    opened = nil
    assert.is_false(hints.is_open())
  end)

  it("leaves no window behind", function()
    local before = #api.nvim_tabpage_list_wins(0)
    local session = open_session()
    hints.open({ session = session })
    assert.are.equal(before + 1, #api.nvim_tabpage_list_wins(0))
    hints.close()
    assert.are.equal(before, #api.nvim_tabpage_list_wins(0))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
