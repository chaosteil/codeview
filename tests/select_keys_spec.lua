-- The comment keys act on the selected box under the cursor, without a
-- picker.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview comment keys on the selection", function()
  local fixture = fixtures.git_comments()
  local comments, config, editor, remote, select, session_mod, view
  ---@type string
  local dir
  ---@type codeview.Session?
  local opened
  ---Calls of `gh.graphql`.
  ---@type { query: string, variables: table }[]
  local graphql_calls
  ---Calls of `vim.ui.select`.
  ---@type integer
  local pickers
  ---@type { msg: string, level: integer }[]
  local seen
  local real_notify, real_select, real_confirm

  ---Open a review session for the fixture range.
  ---@return codeview.Session
  local function open_session()
    if opened then
      return opened
    end
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Add one local comment on the new side of call.lua.
  ---@param line integer
  ---@param fields? table
  ---@return codeview.store.Comment
  local function add_comment(line, fields)
    return assert(comments.create(
      open_session(),
      vim.tbl_extend("force", {
        file = "call.lua",
        start_line = line,
        end_line = line,
        side = "new",
        commit = fixture.ids.change,
        body = "a note on line " .. line,
      }, fields or {})
    ))
  end

  ---Comment of GitHub on the new line 2 of call.lua.
  ---@param fields? table
  ---@return codeview.remote.Comment
  local function remote_comment(fields)
    return vim.tbl_extend("force", {
      id = 501,
      node_id = "PRRC_501",
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      commit = fixture.ids.change,
      author = "grace",
      body = "this line needs a test",
      url = "https://github.com/ada/demo/pull/12#discussion_r501",
      created_at = 0,
      outdated = false,
      reactions = {},
      can_update = false,
      can_delete = false,
      thread = {
        id = "PRRT_1",
        resolved = false,
        resolved_by = "",
        can_resolve = true,
        can_unresolve = false,
        can_reply = true,
      },
    }, fields or {})
  end

  ---Open the diff of call.lua, with the cursor on one new line.
  ---@param line integer
  ---@return codeview.view.State
  local function open_diff(line)
    local review = open_session()
    local state = assert(view.open(review, assert(review:index_of("call.lua"))))
    api.nvim_set_current_win(state.win)
    api.nvim_win_set_cursor(state.win, { assert(state.map:buf_row(line, "new")), 0 })
    select.follow(state)
    return state
  end

  ---Press keys in the window that has the focus. `<leader>` takes the
  ---leader of the test run.
  ---@param lhs string
  local function press(lhs)
    local text = lhs:gsub("<leader>", vim.g.mapleader or "\\")
    api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "x", false)
  end

  ---Text of the open editor.
  ---@return string
  local function editor_text()
    local state = assert(editor.current())
    return table.concat(api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  end

  before_each(function()
    helpers.unload()
    dir = fixtures.tempdir("codeview-select-keys")
    config = require("codeview.config")
    assert(config.setup({ commit_message = false, quit = "never", comments = { dir = dir, start_insert = false } }))
    comments = require("codeview.comments")
    editor = require("codeview.editor")
    remote = require("codeview.remote")
    select = require("codeview.select")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    graphql_calls, pickers, seen = {}, 0, {}
    require("codeview.gh").graphql = function(query, variables, _, cb) ---@diagnostic disable-line: duplicate-set-field
      graphql_calls[#graphql_calls + 1] = { query = query, variables = variables }
      vim.schedule(function()
        cb({}, nil)
      end)
    end
    remote.load = function() ---@diagnostic disable-line: duplicate-set-field
      return true
    end
    require("codeview.pr").current = function() ---@diagnostic disable-line: duplicate-set-field
      return { repo = "ada/demo", number = 12, url = "https://github.com/ada/demo/pull/12" }
    end
    real_select, real_confirm, real_notify = vim.ui.select, vim.fn.confirm, vim.notify
    vim.ui.select = function() ---@diagnostic disable-line: duplicate-set-field
      pickers = pickers + 1
    end
    vim.fn.confirm = function() ---@diagnostic disable-line: duplicate-set-field
      return 1
    end
    vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = { msg = tostring(msg), level = level }
    end
  end)

  after_each(function()
    vim.ui.select, vim.fn.confirm, vim.notify = real_select, real_confirm, real_notify
    editor.cancel()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    require("codeview.events").clear()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  it("edits the selected one of two comments on a line, without a picker", function()
    add_comment(2, { body = "first box" })
    local second = add_comment(2, { body = "second box" })
    local state = open_diff(2)
    assert.is_true(select.set(open_session(), { kind = "local", id = second.id, file = "call.lua" }))
    press("<leader>ce")
    assert.are.equal(0, pickers)
    assert.are.equal("second box", editor_text())
    editor.cancel()

    press("i")
    assert.are.equal(0, pickers)
    assert.are.equal("second box", editor_text())
    assert.are.equal(state.buf, api.nvim_win_get_buf(state.win))
  end)

  it("deletes the selected comment", function()
    local first = add_comment(2, { body = "first box" })
    local second = add_comment(2, { body = "second box" })
    open_diff(2)
    select.set(open_session(), { kind = "local", id = second.id, file = "call.lua" })
    press("<leader>cd")
    local store = assert(comments.store(open_session()))
    assert.is_nil(store:get(second.id))
    assert.is_truthy(store:get(first.id))
  end)

  it("resolves the selected thread, and not the local comment of the line", function()
    remote.attach(open_session(), { remote_comment() })
    local mine = add_comment(2, { created_at = 10 })
    open_diff(2)
    -- The thread is older, so it is the first box of the row.
    assert.are.equal("thread", assert(select.get(open_session())).kind)
    press("<leader>cr")
    vim.wait(50, function()
      return #graphql_calls > 0
    end, 10)
    assert.are.equal(1, #graphql_calls)
    assert.are.same({ id = "PRRT_1" }, graphql_calls[1].variables)
    assert.are.equal("open", assert(comments.store(open_session())):get(mine.id).state)
  end)

  it("edits the selected comment of your own in a thread", function()
    remote.attach(open_session(), {
      remote_comment(),
      remote_comment({
        id = 502,
        reply_to = 501,
        created_at = 1,
        author = "ada",
        body = "my answer",
        can_update = true,
      }),
      remote_comment({ id = 503, reply_to = 501, created_at = 2, author = "ada", body = "my note", can_update = true }),
    })
    local state = open_diff(2)
    select.step_in_thread(state, 1)
    select.step_in_thread(state, 1)
    press("<leader>ce")
    assert.are.equal(0, pickers)
    assert.are.equal("my note", editor_text())
  end)

  it("replies to the selected thread", function()
    remote.attach(open_session(), {
      remote_comment(),
      remote_comment({ id = 601, start_line = 2, end_line = 2, author = "alan", created_at = 5 }),
    })
    open_diff(2)
    local key = assert(select.get(open_session())).id
    press("r")
    assert.are.equal(0, pickers)
    local state = assert(editor.current())
    api.nvim_buf_set_lines(state.buf, 0, -1, false, { "a reply" })
    assert.is_true(editor.submit())
    assert.are.equal(key, assert(comments.store(open_session())).comments[1].reply_to)
  end)

  it("shows only the selected box with K", function()
    add_comment(2, { body = "first box" })
    local second = add_comment(2, { body = "second box" })
    open_diff(2)
    select.set(open_session(), { kind = "local", id = second.id, file = "call.lua" })
    press("K")
    local text
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(win).relative ~= "" then
        text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), "\n")
        pcall(api.nvim_win_close, win, true)
      end
    end
    assert.is_not_nil(text)
    assert.is_truthy((text:find("second box", 1, true)))
    assert.is_nil((text:find("first box", 1, true)))
  end)

  it("edits the selected draft reply of a thread with i", function()
    remote.attach(open_session(), { remote_comment() })
    add_comment(2, { reply_to = "501", body = "a draft", created_at = 5 })
    local state = open_diff(2)
    select.step_in_thread(state, 1)
    press("i")
    assert.are.equal("a draft", editor_text())
  end)

  it("reports that an item of pr-agent is read-only", function()
    require("codeview.agent").items = function() ---@diagnostic disable-line: duplicate-set-field
      return {
        {
          id = "improve:1",
          kind = "suggestion",
          file = "call.lua",
          start_line = 2,
          end_line = 2,
          side = "new",
          author = "",
          label = "possible issue",
          body = "Use the next number.",
          outdated = false,
          anchored = true,
        },
      }
    end
    open_diff(2)
    assert.are.equal("agent", assert(select.get(open_session())).kind)
    press("<leader>ce")
    assert.is_nil(editor.current())
    local warned = false
    for _, entry in ipairs(seen) do
      warned = warned or entry.msg:find("read-only", 1, true) ~= nil
    end
    assert.is_true(warned)
  end)
end)
