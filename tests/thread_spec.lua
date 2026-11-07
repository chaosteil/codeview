local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.thread", function()
  local fixture = fixtures.git_comments()
  local comments_mod, config, editor, gh, remote, session_mod, thread, view
  ---@type codeview.Session?
  local opened
  ---@type string
  local dir
  ---Calls of `gh.api`: the path and the options.
  ---@type { path: string, opts: table }[]
  local api_calls
  ---Calls of `gh.graphql`: the query and the variables.
  ---@type { query: string, variables: table }[]
  local graphql_calls
  ---Answer of the stubs: a value, or nil and an error.
  ---@type { value: any, err: any }
  local reply
  ---Number of calls of `remote.load`.
  ---@type integer
  local loads
  ---Every notification of a test.
  ---@type { msg: string, level: integer }[]
  local seen
  local real_notify

  ---State of a thread that the user can resolve and reply to.
  ---@param fields? table
  ---@return codeview.remote.ThreadState
  local function thread_state(fields)
    return vim.tbl_extend("force", {
      id = "PRRT_1",
      resolved = false,
      resolved_by = "",
      can_resolve = true,
      can_unresolve = false,
      can_reply = true,
    }, fields or {})
  end

  ---One comment of GitHub on the new line 2 of call.lua.
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
      created_at = 10,
      outdated = false,
      reactions = {},
      can_update = false,
      can_delete = false,
      thread = thread_state(),
    }, fields or {})
  end

  ---Open the session and the diff of call.lua, with the cursor on the new
  ---line 2.
  ---@param list codeview.remote.Comment[] Comments of GitHub.
  ---@return codeview.view.State
  local function open_diff(list)
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    remote.attach(review, list)
    local state = assert(view.open(review, assert(review:index_of("call.lua"))))
    api.nvim_set_current_win(state.win)
    api.nvim_win_set_cursor(state.win, { 4, 0 })
    return state
  end

  ---Wait until the stubs answered and the threads read again.
  local function settle()
    vim.wait(100, function()
      return false
    end, 10)
  end

  ---Text of the virtual lines of the boxes of a buffer.
  ---@param buf integer
  ---@return string[]
  local function box_lines(buf)
    local out = {}
    for _, mark in ipairs(require("codeview.stack").marks(buf)) do
      for _, line in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(line) do
          text = text .. chunk[1]
        end
        out[#out + 1] = text
      end
    end
    return out
  end

  ---Messages of one level.
  ---@param level integer
  ---@return string[]
  local function said(level)
    local out = {}
    for _, entry in ipairs(seen) do
      if entry.level == level then
        out[#out + 1] = entry.msg
      end
    end
    return out
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = fixtures.tempdir("codeview-thread")
    assert(config.setup({ commit_message = false, comments = { dir = dir }, log_level = vim.log.levels.INFO }))
    comments_mod = require("codeview.comments")
    editor = require("codeview.editor")
    gh = require("codeview.gh")
    remote = require("codeview.remote")
    session_mod = require("codeview.session")
    thread = require("codeview.thread")
    view = require("codeview.view")

    api_calls, graphql_calls, loads, seen = {}, {}, 0, {}
    reply = { value = {} }
    gh.api = function(path, opts, cb) ---@diagnostic disable-line: duplicate-set-field
      api_calls[#api_calls + 1] = { path = path, opts = opts }
      vim.schedule(function()
        cb(reply.value, reply.err)
      end)
    end
    gh.graphql = function(query, variables, _, cb) ---@diagnostic disable-line: duplicate-set-field
      graphql_calls[#graphql_calls + 1] = { query = query, variables = variables }
      vim.schedule(function()
        cb(reply.value, reply.err)
      end)
    end
    remote.load = function() ---@diagnostic disable-line: duplicate-set-field
      loads = loads + 1
      return true
    end
    -- The fixture is a local review. The actions need a pull request.
    require("codeview.pr").current = function() ---@diagnostic disable-line: duplicate-set-field
      return { repo = "ada/demo", number = 12, url = "https://github.com/ada/demo/pull/12" }
    end
    real_notify = vim.notify
    vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = { msg = tostring(msg), level = level }
    end
  end)

  after_each(function()
    vim.notify = real_notify
    editor.cancel()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  describe("resolve", function()
    it("resolves the thread of a line without a local comment", function()
      open_diff({ remote_comment() })
      assert.is_nil(comments_mod.set_state())
      settle()

      assert.are.equal(1, #graphql_calls)
      assert.is_truthy(graphql_calls[1].query:find("resolveReviewThread", 1, true))
      assert.is_nil(graphql_calls[1].query:find("unresolveReviewThread", 1, true))
      assert.are.same({ id = "PRRT_1" }, graphql_calls[1].variables)
      assert.are.equal(1, loads)
    end)

    it("opens a resolved thread again", function()
      open_diff({ remote_comment({ thread = thread_state({ resolved = true, can_unresolve = true }) }) })
      assert.is_true(thread.resolve())
      settle()

      assert.are.equal(1, #graphql_calls)
      assert.is_truthy(graphql_calls[1].query:find("unresolveReviewThread", 1, true))
    end)

    it("checks the right of the user first", function()
      open_diff({ remote_comment({ thread = thread_state({ can_resolve = false }) }) })
      thread.resolve()
      settle()

      assert.are.equal(0, #graphql_calls)
      assert.is_truthy(said(vim.log.levels.WARN)[1]:find("does not let you resolve", 1, true))
    end)

    it("says that the thread state is missing", function()
      local comment = remote_comment()
      comment.thread = nil
      open_diff({ comment })
      thread.resolve()
      settle()

      assert.are.equal(0, #graphql_calls)
      assert.are.same({ "codeview: " .. remote.no_state }, said(vim.log.levels.WARN))
    end)

    it("resolves the local comment of a line that also holds a thread", function()
      open_diff({ remote_comment() })
      local store = assert(comments_mod.store(assert(opened)))
      local local_comment =
        assert(store:add({ file = "call.lua", start_line = 2, end_line = 2, side = "new", body = "mine" }))
      local changed = assert(comments_mod.set_state())
      settle()

      assert.are.equal(local_comment.id, changed.id)
      assert.are.equal("resolved", changed.state)
      assert.are.equal(0, #graphql_calls)
    end)

    it("reports a failure of GitHub once", function()
      open_diff({ remote_comment() })
      reply = { value = nil, err = require("codeview.error").new("command_failed", "gh: Something went wrong") }
      thread.resolve()
      settle()

      assert.are.equal(1, #said(vim.log.levels.ERROR))
      assert.is_truthy(said(vim.log.levels.ERROR)[1]:find("Something went wrong", 1, true))
      assert.are.equal(0, loads)
    end)
  end)

  describe("toggle", function()
    it("shows and hides the comments of a resolved thread", function()
      local state = thread_state({ resolved = true, can_unresolve = true })
      local diff = open_diff({
        remote_comment({ thread = state }),
        remote_comment({ id = 502, reply_to = 501, created_at = 20, author = "ada", body = "done", thread = state }),
      })
      assert.are.equal(2, #box_lines(diff.buf))

      assert.is_true(thread.toggle())
      local lines = box_lines(diff.buf)
      assert.are.equal(5, #lines)
      assert.is_truthy(lines[1]:find("@grace L2 (new) · ✓ resolved", 1, true), lines[1])

      assert.is_true(thread.toggle())
      assert.are.equal(2, #box_lines(diff.buf))
    end)
  end)

  describe("edit", function()
    it("sends the new text of a comment of your own at once", function()
      open_diff({ remote_comment({ can_update = true }) })
      assert.is_true(comments_mod.edit())
      local held = assert(editor.current())
      assert.are.same({ "this line needs a test" }, api.nvim_buf_get_lines(held.buf, 0, -1, false))
      api.nvim_buf_set_lines(held.buf, 0, -1, false, { "this line needs two tests" })
      assert.is_true(editor.submit())
      settle()

      assert.are.equal(1, #api_calls)
      assert.are.equal("repos/ada/demo/pulls/comments/501", api_calls[1].path)
      assert.are.equal("PATCH", api_calls[1].opts.method)
      assert.are.same({ body = "this line needs two tests" }, vim.json.decode(api_calls[1].opts.stdin))
      assert.are.equal(1, loads)
    end)

    it("changes nothing on an empty save", function()
      open_diff({ remote_comment({ can_update = true }) })
      assert.is_true(comments_mod.edit())
      api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "" })
      editor.submit()
      settle()

      assert.are.equal(0, #api_calls)
      assert.is_truthy(said(vim.log.levels.WARN)[1]:find("empty text", 1, true))
    end)

    it("asks which comment when the thread holds more than one of your own", function()
      open_diff({
        remote_comment({ can_update = true }),
        remote_comment({ id = 502, reply_to = 501, created_at = 20, body = "second", can_update = true }),
      })
      local select = vim.ui.select
      vim.ui.select = function(items, _, cb) ---@diagnostic disable-line: duplicate-set-field
        cb(items[2])
      end
      comments_mod.edit()
      vim.ui.select = select

      assert.are.same({ "second" }, api.nvim_buf_get_lines(assert(editor.current()).buf, 0, -1, false))
    end)

    it("warns on a thread without a comment of your own", function()
      open_diff({ remote_comment() })
      comments_mod.edit()
      assert.is_false(editor.is_open())
      assert.is_truthy(said(vim.log.levels.WARN)[1]:find("no comment that you can edit", 1, true))
    end)
  end)

  describe("delete", function()
    it("deletes a comment of your own on GitHub", function()
      open_diff({ remote_comment({ can_delete = true }) })
      assert.is_true(comments_mod.remove({ confirm = false }))
      settle()

      assert.are.equal(1, #api_calls)
      assert.are.equal("repos/ada/demo/pulls/comments/501", api_calls[1].path)
      assert.are.equal("DELETE", api_calls[1].opts.method)
      assert.is_true(api_calls[1].opts.allow_empty)
      assert.are.equal(1, loads)
    end)

    it("asks before the delete", function()
      open_diff({ remote_comment({ can_delete = true }) })
      local confirm = vim.fn.confirm
      vim.fn.confirm = function() ---@diagnostic disable-line: duplicate-set-field
        return 2
      end
      comments_mod.remove()
      vim.fn.confirm = confirm
      settle()

      assert.are.equal(0, #api_calls)
    end)
  end)

  describe("react", function()
    it("adds a reaction to the comment that the user picks", function()
      open_diff({
        remote_comment(),
        remote_comment({ id = 502, node_id = "PRRC_502", reply_to = 501, created_at = 20, body = "second" }),
      })
      local select = vim.ui.select
      local offered
      local answers = { 2, 4 }
      vim.ui.select = function(items, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        offered = vim.tbl_map(opts.format_item, items)
        cb(items[table.remove(answers, 1)])
      end
      assert.is_true(thread.react())
      vim.ui.select = select
      settle()

      assert.are.equal("👍 THUMBS_UP", offered[1])
      assert.are.equal(8, #offered)
      assert.are.equal(1, #graphql_calls)
      assert.is_truthy(graphql_calls[1].query:find("addReaction", 1, true))
      assert.are.same({ subject = "PRRC_502", content = "HOORAY" }, graphql_calls[1].variables)
    end)

    it("removes a reaction of your own", function()
      open_diff({ remote_comment({ reactions = { { content = "HEART", count = 1, mine = true } } }) })
      local select = vim.ui.select
      local offered
      vim.ui.select = function(items, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        offered = vim.tbl_map(opts.format_item, items)
        cb(items[6])
      end
      thread.react()
      vim.ui.select = select
      settle()

      assert.are.equal("❤️ HEART ✓", offered[6])
      assert.is_truthy(graphql_calls[1].query:find("removeReaction", 1, true))
      assert.are.same({ subject = "PRRC_501", content = "HEART" }, graphql_calls[1].variables)
    end)
  end)

  describe("open", function()
    it("opens the first comment of the thread in the browser", function()
      open_diff({ remote_comment() })
      local real_open = vim.ui.open
      local opened_url
      vim.ui.open = function(url) ---@diagnostic disable-line: duplicate-set-field
        opened_url = url
        return nil, nil
      end
      assert.is_true(thread.open())
      vim.ui.open = real_open
      assert.are.equal("https://github.com/ada/demo/pull/12#discussion_r501", opened_url)
    end)

    it("opens the file under the cursor without a thread", function()
      open_diff({})
      local real_open = vim.ui.open
      local opened_url
      vim.ui.open = function(url) ---@diagnostic disable-line: duplicate-set-field
        opened_url = url
        return nil, nil
      end
      thread.open()
      vim.ui.open = real_open
      assert.are.equal(vim.fn.expand("<cfile>"), opened_url)
    end)
  end)

  describe("show", function()
    it("shows the whole thread with the reactions", function()
      local state = thread_state({ resolved = true, can_unresolve = true })
      open_diff({
        remote_comment({ thread = state, reactions = { { content = "THUMBS_UP", count = 2, mine = false } } }),
        remote_comment({ id = 502, reply_to = 501, created_at = 20, author = "ada", body = "done", thread = state }),
      })
      local buf = assert(comments_mod.show())
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:find("### @grace L2 (new) · ✓ resolved", 1, true), text)
      assert.is_truthy(text:find("👍 2", 1, true), text)
      assert.is_truthy(text:find("### @ada\n\ndone", 1, true), text)
      assert.is_true(text:find("this line needs a test", 1, true) < text:find("done", 1, true))
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
