-- The menu of the selected comment: the entries of each kind of box, and
-- the actions behind them.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.menu", function()
  local fixture = fixtures.git_comments()
  local comments, config, editor, menu, remote, select, session_mod, view
  ---@type string
  local dir
  ---@type codeview.Session?
  local opened
  ---Prompts and labels of each picker of a test, in order.
  ---@type { prompt: string, labels: string[] }[]
  local pickers
  ---Label of the entry that the stub picks, or a function of the list.
  ---@type (string|fun(items: any[]): any)?
  local pick
  ---Calls of `submit.send`.
  ---@type table[]
  local sends

  ---Picker for `menu.open()`. It records the labels and picks an entry.
  ---@param items any[]
  ---@param opts table
  ---@param on_choice fun(item: any?)
  local function picker(items, opts, on_choice)
    local labels = {}
    for _, item in ipairs(items) do
      labels[#labels + 1] = opts.format_item(item)
    end
    pickers[#pickers + 1] = { prompt = opts.prompt, labels = labels }
    if type(pick) == "function" then
      on_choice(pick(items))
      return
    end
    for index, label in ipairs(labels) do
      if label == pick then
        on_choice(items[index])
        return
      end
    end
    on_choice(nil)
  end

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

  ---Make the fixture a review of a pull request.
  local function as_pull_request()
    require("codeview.pr").current = function() ---@diagnostic disable-line: duplicate-set-field
      return { repo = "ada/demo", number = 12, url = "https://github.com/ada/demo/pull/12" }
    end
  end

  ---Open the diff of call.lua, with the cursor on one new line and the box
  ---under it selected.
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

  ---Labels of the last picker.
  ---@return string[]
  local function labels()
    return assert(pickers[#pickers]).labels
  end

  ---Write a body into the editor and save it.
  ---@param body string
  local function write_comment(body)
    local state = assert(editor.current())
    api.nvim_buf_set_lines(state.buf, 0, -1, false, { body })
    assert.is_true(editor.submit())
  end

  before_each(function()
    helpers.unload()
    dir = fixtures.tempdir("codeview-menu")
    config = require("codeview.config")
    -- The editor starts in normal mode. A deferred insert mode of one test
    -- closes the float of the next test.
    assert(config.setup({ commit_message = false, quit = "never", comments = { dir = dir, start_insert = false } }))
    comments = require("codeview.comments")
    editor = require("codeview.editor")
    menu = require("codeview.menu")
    remote = require("codeview.remote")
    select = require("codeview.select")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    pickers, pick, sends = {}, nil, {}
    require("codeview.submit").send = function(opts) ---@diagnostic disable-line: duplicate-set-field
      sends[#sends + 1] = opts
    end
    require("codeview.remote").load = function() ---@diagnostic disable-line: duplicate-set-field
      return true
    end
  end)

  after_each(function()
    editor.cancel()
    require("codeview.overview").close()
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

  describe("a local comment", function()
    it("lists the actions of a local review", function()
      add_comment(2)
      local state = open_diff(2)
      assert.is_true(menu.open({ view = state, select = picker }))
      assert.are.equal("codeview: comment L2 (new)", pickers[1].prompt)
      assert.are.same({
        "Edit the comment",
        "Delete the comment",
        "Resolve the comment",
        "Add another comment on these lines",
        "Show in a float",
      }, labels())
    end)

    it("sends the comment to the pull request", function()
      as_pull_request()
      local comment = add_comment(2)
      local state = open_diff(2)
      pick = "Send the comment to the pull request now"
      assert.is_true(menu.open({ view = state, select = picker }))
      assert.are.same({ { session = open_session(), id = comment.id } }, sends)
    end)

    it("names the edit and the delete on GitHub of a sent comment", function()
      as_pull_request()
      local comment = add_comment(2)
      local store = assert(comments.store(open_session()))
      assert(store:mark_synced(comment.id, { time = 100, remote_id = "1000000001" }))
      local state = open_diff(2)
      menu.open({ view = state, select = picker })
      assert.are.same({
        "Edit the comment (also on GitHub)",
        "Delete the comment (also on GitHub)",
        "Resolve the comment",
        "Add another comment on these lines",
        "Show in a float",
      }, labels())
    end)

    it("resolves the comment", function()
      local comment = add_comment(2)
      local state = open_diff(2)
      pick = "Resolve the comment"
      menu.open({ view = state, select = picker })
      assert.are.equal("resolved", assert(comments.store(open_session())):get(comment.id).state)
    end)

    it("adds another comment on the lines of the comment", function()
      add_comment(1)
      local state = open_diff(1)
      -- The cursor leaves the comment, and the menu keeps the selection.
      local selection = assert(select.get(open_session()))
      api.nvim_win_set_cursor(state.win, { assert(state.map:buf_row(4, "new")), 0 })
      pick = "Add another comment on these lines"
      menu.open({ view = state, selection = selection, select = picker })
      write_comment("one more note")
      local found = assert(comments.store(open_session())):at("call.lua", "new", 1)
      assert.are.equal(2, #found)
    end)

    it("shows only the selected box in the float", function()
      add_comment(2, { body = "first box" })
      add_comment(2, { body = "second box" })
      local state = open_diff(2)
      pick = "Show in a float"
      menu.open({ view = state, select = picker })
      local float
      for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_config(win).relative ~= "" then
          float = win
        end
      end
      assert.is_not_nil(float)
      local text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(float), 0, -1, false), "\n")
      local store = assert(comments.store(open_session()))
      local selection = assert(select.get(open_session()))
      local selected = assert(store:get(selection.id))
      local other = selected.body == "first box" and "second box" or "first box"
      assert.is_truthy((text:find(selected.body, 1, true)))
      assert.is_nil((text:find(other, 1, true)))
      pcall(api.nvim_win_close, float, true)
    end)
  end)

  describe("a thread of GitHub", function()
    it("lists the actions of the thread and of its first comment", function()
      remote.attach(open_session(), { remote_comment() })
      local state = open_diff(2)
      menu.open({ view = state, select = picker })
      assert.is_truthy(pickers[1].prompt:find("@grace", 1, true))
      assert.are.same({
        "Reply (draft)",
        "Reply and send now",
        "Resolve the thread",
        "Add or remove a reaction",
        "Open in the browser",
        "Show in a float",
      }, labels())
    end)

    it("edits and deletes a selected comment of your own", function()
      remote.attach(open_session(), {
        remote_comment(),
        remote_comment({
          id = 502,
          node_id = "PRRC_502",
          reply_to = 501,
          created_at = 1,
          author = "ada",
          can_update = true,
          can_delete = true,
        }),
      })
      local state = open_diff(2)
      select.step_in_thread(state, 1)
      menu.open({ view = state, select = picker })
      assert.are.same({
        "Reply (draft)",
        "Reply and send now",
        "Resolve the thread",
        "Edit this comment on GitHub",
        "Delete this comment on GitHub",
        "Add or remove a reaction",
        "Open in the browser",
        "Show in a float",
      }, labels())
    end)

    it("lists the actions of a resolved thread", function()
      remote.attach(open_session(), {
        remote_comment({
          thread = {
            id = "PRRT_1",
            resolved = true,
            resolved_by = "ada",
            can_resolve = false,
            can_unresolve = true,
            can_reply = false,
          },
        }),
      })
      local state = open_diff(2)
      menu.open({ view = state, select = picker })
      assert.are.same({
        "Reopen the thread",
        "Show the comments of the thread",
        "Open in the browser",
        "Show in a float",
      }, labels())
    end)

    it("writes a reply and sends it at once", function()
      as_pull_request()
      remote.attach(open_session(), { remote_comment() })
      local state = open_diff(2)
      pick = "Reply and send now"
      menu.open({ view = state, select = picker })
      assert.is_truthy(vim.wo[assert(editor.current()).win].winbar ~= nil)
      write_comment("a reply")
      local store = assert(comments.store(open_session()))
      local reply = assert(store.comments[1])
      assert.are.equal("501", reply.reply_to)
      assert.are.same({ { session = open_session(), id = reply.id } }, sends)
    end)

    it("writes a draft reply that waits for a send", function()
      as_pull_request()
      remote.attach(open_session(), { remote_comment() })
      local state = open_diff(2)
      pick = "Reply (draft)"
      menu.open({ view = state, select = picker })
      write_comment("a draft")
      assert.are.equal(1, #assert(comments.store(open_session())).comments)
      assert.are.same({}, sends)
    end)

    it("lists the actions of a selected draft reply", function()
      as_pull_request()
      remote.attach(open_session(), { remote_comment() })
      add_comment(2, { reply_to = "501", body = "a draft", created_at = 5 })
      local state = open_diff(2)
      select.step_in_thread(state, 1)
      menu.open({ view = state, select = picker })
      assert.are.same({
        "Reply (draft)",
        "Reply and send now",
        "Resolve the thread",
        "Edit the reply",
        "Delete the reply",
        "Send the reply now",
        "Show in a float",
      }, labels())
    end)
  end)

  it("lists the actions of an item of pr-agent", function()
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
    local state = open_diff(2)
    pick = "Adopt as a comment"
    menu.open({ view = state, select = picker })
    assert.are.same({ "Adopt as a comment", "Show in a float" }, labels())
    local store = assert(comments.store(open_session()))
    assert.are.equal(1, #store.comments)
  end)

  it("asks for the box when the selection is not under the cursor", function()
    add_comment(2, { body = "first box" })
    add_comment(2, { body = "second box" })
    local state = open_diff(2)
    select.clear(open_session())
    pick = function(items)
      return items[2]
    end
    menu.open({ view = state, select = picker })
    assert.are.equal("codeview: which comment?", pickers[1].prompt)
    assert.are.equal(2, #pickers[1].labels)
    assert.are.equal(2, #pickers)
  end)

  it("reports a line without a comment", function()
    add_comment(1)
    local state = open_diff(4)
    assert.is_false(menu.open({ view = state, select = picker }))
    assert.are.same({}, pickers)
  end)

  it("opens from the comment overview", function()
    local comment = add_comment(2)
    local overview = assert(require("codeview.overview").open({ session = open_session() }))
    assert.is_true(overview:go_to(comment.id))
    assert.is_true(overview:menu({ select = picker }))
    -- The overview has no diff view, so the menu has no float and no new
    -- comment on the same lines.
    assert.are.same({ "Edit the comment", "Delete the comment", "Resolve the comment" }, labels())
  end)

  it("maps the menu key in the diff view", function()
    local state = open_diff(2)
    local found = vim.fn.maparg(vim.g.mapleader and (vim.g.mapleader .. "cm") or "\\cm", "n", false, true)
    assert.are.equal(state.buf, api.nvim_get_current_buf())
    assert.are.equal("codeview: open the menu of the selected comment", found.desc)
  end)
end)
