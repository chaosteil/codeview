-- Edge cases of the language server in the diff view.
--
-- Each test is one case that tries to break the feature. The tests guard
-- the behavior of the edge cases, also of the bugs that they found.
--
-- A language server in the test process answers the requests. See
-- `helpers.fake_lsp()`.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

---Methods that the fake servers answer from the `answers` table.
local METHODS = {
  "textDocument/definition",
  "textDocument/declaration",
  "textDocument/typeDefinition",
  "textDocument/implementation",
  "textDocument/references",
  "textDocument/hover",
  "textDocument/rename",
  "textDocument/codeAction",
  "codeAction/resolve",
}

---Lines of the long file of the odd fixture.
---@param changed integer Line that holds another text.
---@return string content
local function long_file(changed)
  local lines = {}
  for index = 1, 60 do
    lines[index] = string.format("local v%d = %d", index, index == changed and 0 or index)
  end
  return table.concat(lines, "\n") .. "\n"
end

---Repository with files that are hard for the line map.
---
---     uni.lua          text with more than one byte per character.
---     tabs.lua         a line that starts with a tab.
---     mixed.txt        one line with CRLF in a file with LF line ends.
---     noeol.lua        no line end after the last line.
---     empty.lua        added with no content.
---     we ird [1].lua   a name with a space and brackets.
---     long.lua         60 lines with one change, so sections collapse.
---@return tests.Fixture
local function odd_fixture()
  return fixtures.git_history({
    {
      name = "base",
      files = {
        ["uni.lua"] = 'local name = "x"\nlocal é = "😀" .. name\nreturn é\n',
        ["tabs.lua"] = "local value = 1\n\treturn\tvalue\n",
        ["mixed.txt"] = "one\r\ntwo\nthree\n",
        ["noeol.lua"] = "local a = 1\nreturn a",
        ["we ird [1].lua"] = "local w = 1\nreturn w\n",
        ["long.lua"] = long_file(0),
      },
    },
    {
      name = "change",
      files = {
        ["uni.lua"] = 'local name = "y"\nlocal é = "😀" .. name\nlocal ü = "😀😀" .. name\nreturn é\n',
        ["tabs.lua"] = "local value = 2\n\treturn\tvalue\n",
        ["mixed.txt"] = "one\r\ntwo changed\nthree\n",
        ["noeol.lua"] = "local a = 2\nreturn a",
        ["empty.lua"] = "",
        ["we ird [1].lua"] = "local w = 2\nreturn w\n",
        ["long.lua"] = long_file(30),
      },
    },
  })
end

---Repository with a commit on top of the reviewed one.
---
--- The review is `one..two`. The commit `three` puts two lines in front of
--- lib.lua and changes line 8 of the review.
---@return tests.Fixture
local function stacked_fixture()
  local one = { "local M = {}", "", "function M.helper()", "  return 1", "end", "", "return M", "" }
  local two = {
    "local M = {}",
    "",
    "function M.helper()",
    "  return 2",
    "end",
    "",
    "function M.extra()",
    "  return M.helper() + 1",
    "end",
    "",
    "return M",
    "",
  }
  local three = vim.list_extend({ "-- header", "" }, two)
  three[10] = "  return M.helper() + 2"
  return fixtures.git_history({
    { name = "one", files = { ["lib.lua"] = table.concat(one, "\n") } },
    { name = "two", files = { ["lib.lua"] = table.concat(two, "\n") } },
    { name = "three", files = { ["lib.lua"] = table.concat(three, "\n") } },
  })
end

describe("codeview lsp edge cases", function()
  local config, lsp, session_mod, view
  ---@type codeview.Session?
  local opened
  ---@type string?
  local store_dir
  ---@type tests.FakeLsp[]
  local servers
  ---@type tests.Fixture[]
  local made
  ---@type string[]
  local temp_dirs
  ---@type string[]
  local messages
  local notify, ui_input, ui_select
  ---Answer of each method. A function gets the parameters.
  ---@type table<string, any>
  local answers

  ---Keep a fixture for the cleanup of the test.
  ---@param fixture tests.Fixture
  ---@return tests.Fixture
  local function keep(fixture)
    made[#made + 1] = fixture
    return fixture
  end

  ---@param fixture tests.Fixture
  ---@param path string
  ---@return string file
  local function file_of(fixture, path)
    return vim.fs.joinpath(fixture.root, path)
  end

  ---@param fixture tests.Fixture
  ---@param path string
  ---@return string uri
  local function uri_of(fixture, path)
    return helpers.real_uri(file_of(fixture, path))
  end

  ---Location in a file of a fixture.
  ---@param fixture tests.Fixture
  ---@param path string
  ---@param line integer Line from 1.
  ---@param character integer
  ---@return table location
  local function location(fixture, path, line, character)
    local position = { line = line - 1, character = character }
    return { uri = uri_of(fixture, path), range = { start = position, ["end"] = position } }
  end

  ---Text edit that replaces part of one line.
  ---@param line integer Line from 1.
  ---@param first integer
  ---@param last integer
  ---@param text string
  ---@return table edit
  local function edit(line, first, last, text)
    return {
      range = { start = { line = line - 1, character = first }, ["end"] = { line = line - 1, character = last } },
      newText = text,
    }
  end

  ---Start a fake server that answers from `answers`.
  ---@param root string
  ---@param opts? { capabilities?: table, name?: string, answers?: table<string, any> }
  ---@return tests.FakeLsp
  local function start_server(root, opts)
    opts = opts or {}
    local source = opts.answers or answers
    local handlers = {}
    for _, method in ipairs(METHODS) do
      handlers[method] = function(params)
        local answer = source[method]
        if type(answer) == "function" then
          return answer(params)
        end
        if answer == nil and method == "codeAction/resolve" then
          return params
        end
        return answer
      end
    end
    handlers["workspace/executeCommand"] = function(params, fake)
      source.executed = params
      if source.command_edit then
        fake.dispatchers.server_request("workspace/applyEdit", { edit = source.command_edit })
      end
      return vim.NIL
    end
    local server = helpers.fake_lsp({
      root = root,
      name = opts.name,
      handlers = handlers,
      capabilities = opts.capabilities,
      filetypes = { "lua", "text" },
    })
    server.attach_on_filetype()
    servers[#servers + 1] = server
    return server
  end

  ---Configure the plugin.
  ---@param opts? table Options on top of the test defaults.
  local function setup(opts)
    assert(config.setup(vim.tbl_deep_extend("force", {
      commit_message = false,
      comments = { dir = store_dir },
      sidebar = { auto_open = false },
      lsp = { enabled = true },
    }, opts or {})))
  end

  ---Open a session of a fixture.
  ---@param fixture tests.Fixture
  ---@param spec string? `base..change` by default.
  ---@return codeview.Session
  local function open_session(fixture, spec)
    local session, err =
      session_mod.open(spec or (fixture.ids.base .. ".." .. fixture.ids.change), { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(session)
    return opened
  end

  ---Open one file of the review.
  ---@param fixture tests.Fixture
  ---@param path string
  ---@param spec string? `base..change` by default.
  ---@return codeview.view.State
  local function open_file(fixture, path, spec)
    if not opened then
      open_session(fixture, spec)
    end
    local index = assert(assert(opened):index_of(path), "the review holds " .. path)
    local state = assert(view.open(assert(opened), index))
    api.nvim_set_current_win(state.win)
    return state
  end

  ---Put the cursor on a line of one side.
  ---
  --- The call fails when the view holds no row for the line. `needle` puts
  --- the cursor on the first byte of a text of the row.
  ---@param state codeview.view.State
  ---@param line integer
  ---@param side "old"|"new"?
  ---@param needle string?
  ---@return integer row
  local function put(state, line, side, needle)
    side = side or "new"
    local on_old = side == "old" and state.old_win ~= nil
    local win = on_old and state.old_win or state.win
    local map = on_old and state.old_map or state.map
    local row = map:buf_row(line, side)
    assert.is_not_nil(row, string.format("the view holds a row for line %d of the %s side", line, side))
    api.nvim_set_current_win(win)
    local col = 0
    if needle then
      local text = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), row - 1, row, false)[1]
      local found = text:find(needle, 1, true)
      assert.is_not_nil(found, "the row holds " .. needle)
      col = found - 1
    end
    api.nvim_win_set_cursor(win, { row, col })
    return row
  end

  ---Row of a line of one side. The call fails when the map holds no row.
  ---@param map codeview.LineMap
  ---@param line integer
  ---@param side "old"|"new"
  ---@return integer row
  local function row_of(map, line, side)
    local row = map:buf_row(line, side)
    assert.is_not_nil(row, string.format("the view holds a row for line %d of the %s side", line, side))
    return row
  end

  ---Text of the row of the current window, from the cursor on.
  ---@return string text
  local function at_cursor()
    local cursor = api.nvim_win_get_cursor(0)
    local text = api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    return text:sub(cursor[2] + 1)
  end

  ---Line of one side under the cursor of the current window.
  ---@param side "old"|"new"?
  ---@return integer? line
  local function cursor_line(side)
    local state = view.current()
    if not state then
      return nil
    end
    local win = api.nvim_get_current_win()
    local map = win == state.old_win and state.old_map or state.map
    local record = map:row(api.nvim_win_get_cursor(win)[1])
    return record and record[side or "new"]
  end

  ---Hidden buffer of the working copy for one side of a view.
  ---@param state codeview.view.State
  ---@param side "old"|"new"?
  ---@return integer buf
  local function source_buf(state, side)
    local source = lsp.sources(state)[side or "new"]
    assert.is_not_nil(source, "the view has a source")
    return source.buf
  end

  ---@param fn fun(): boolean
  ---@param what string
  local function wait_for(fn, what)
    assert.is_true(vim.wait(5000, fn, 10), what)
  end

  ---Last message that holds a text.
  ---@param text string
  ---@return string? message
  local function message_with(text)
    for index = #messages, 1, -1 do
      if messages[index]:find(text, 1, true) then
        return messages[index]
      end
    end
    return nil
  end

  ---Run one request and give the parameters that the server got.
  ---@param server tests.FakeLsp
  ---@param name string Name of the action, for example "lsp_definition".
  ---@param opts table? Options of `lsp.run()`.
  ---@return table params
  local function request(server, name, opts)
    local method = lsp.actions[name].method
    local before = #server.calls(method)
    assert.is_true(lsp.run(name, opts), "the request went out: " .. tostring(messages[#messages]))
    wait_for(function()
      return #server.calls(method) > before
    end, "the server got the request")
    return server.calls(method)[before + 1]
  end

  ---Floating windows of the editor.
  ---@return integer[] wins
  local function floats()
    local out = {}
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(win).relative ~= "" then
        out[#out + 1] = win
      end
    end
    return out
  end

  ---Run a git command in a fixture.
  ---@param fixture tests.Fixture
  ---@param args string[]
  local function git(fixture, args)
    local cmd = vim.list_extend({ "git" }, args)
    local res = vim.system(cmd, { cwd = fixture.dir, env = fixture.env, text = true }):wait(30000)
    assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  end

  ---Maps of the normal mode of a buffer, by key.
  ---@param buf integer
  ---@return table<string, string> desc Description of each key.
  local function maps_of(buf)
    local out = {}
    for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
      out[vim.fn.keytrans(map.lhs)] = map.desc or ""
    end
    return out
  end

  ---Diagnostics of codeview in one diff buffer, by row from 1.
  ---@param buf integer
  ---@return table<integer, vim.Diagnostic>
  local function by_row(buf)
    local out = {}
    for _, item in ipairs(vim.diagnostic.get(buf, { namespace = lsp.ns })) do
      out[item.lnum + 1] = item
    end
    return out
  end

  ---LSP diagnostic.
  ---@param first_line integer Line from 1.
  ---@param first integer
  ---@param last_line integer Line from 1.
  ---@param last integer
  ---@param message string
  ---@return table diagnostic
  local function diagnostic(first_line, first, last_line, last, message)
    return {
      range = {
        start = { line = first_line - 1, character = first },
        ["end"] = { line = last_line - 1, character = last },
      },
      severity = 1,
      message = message,
    }
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    store_dir = fixtures.tempdir("codeview-lsp-edge-store")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    answers = {}
    servers, made, temp_dirs, messages = {}, {}, {}, {}
    notify, ui_input, ui_select = vim.notify, vim.ui.input, vim.ui.select
    vim.notify = function(msg)
      messages[#messages + 1] = tostring(msg)
    end
  end)

  after_each(function()
    vim.notify, vim.ui.input, vim.ui.select = notify, ui_input, ui_select
    pcall(vim.cmd, "cclose")
    for _, win in ipairs(floats()) do
      pcall(api.nvim_win_close, win, true)
    end
    pcall(function()
      require("codeview.view").close()
    end)
    if opened then
      pcall(function()
        opened:close()
      end)
    end
    opened = nil
    pcall(function()
      require("codeview.session").close()
    end)
    for _, server in ipairs(servers) do
      server.stop()
    end
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
    -- The window stays for the next test. Its mark of a jump must not stay,
    -- because the next session takes the same id after the reload.
    vim.w.codeview_released = nil
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= "" then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
    for _, fixture in ipairs(made) do
      fixture.cleanup()
    end
    for _, dir in ipairs(temp_dirs) do
      vim.fn.delete(dir, "rf")
    end
    if store_dir then
      vim.fn.delete(store_dir, "rf")
    end
    store_dir = nil
    vim.fn.setqflist({}, "r")
    vim.o.swapfile = false
    vim.o.hidden = true
    config.reset()
    helpers.unload()
  end)

  describe("sides and styles", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
    end)

    it("sends the column of the new window of the split style with no marker", function()
      local state = open_file(fixture, "lib.lua")
      assert.are.equal("split", view.set_style("split"))
      assert.is_true(server.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 7, character = 11 }, params.position)
    end)

    it("sends a context row of the old window of the split style", function()
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "old", "helper")
      assert.are.equal(state.old_win, api.nvim_get_current_win())
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 2, character = 11 }, params.position)
    end)

    it("gives a note for a removed row of the old window of the split style", function()
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 4, "old")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("does not hold this line"))
      assert.are.same({}, server.calls("textDocument/definition"))
    end)

    it("gives a note for a filler row of the old window of the split style", function()
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      assert.is_true(server.wait(source_buf(state)))
      -- The old window holds a filler row next to an added line.
      local filler
      for row = 1, api.nvim_buf_line_count(state.old_buf) do
        if state.old_map:kind(row) == "filler" then
          filler = row
          break
        end
      end
      assert.is_not_nil(filler, "the old window holds a filler row")
      api.nvim_set_current_win(state.old_win)
      api.nvim_win_set_cursor(state.old_win, { filler, 0 })
      assert.is_false(lsp.run("lsp_hover"))
      assert.is_not_nil(message_with("this row holds no line of the file"))
      assert.are.same({}, server.calls("textDocument/hover"))
    end)

    it("gives a note for a hunk header row", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      local header
      for row = 1, api.nvim_buf_line_count(state.buf) do
        if state.map:kind(row) == "header" then
          header = row
          break
        end
      end
      assert.is_not_nil(header, "the diff holds a hunk header")
      api.nvim_win_set_cursor(state.win, { header, 0 })
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("this row holds no line of the file"))
    end)

    it("moves the cursor in the new window after a request from the old window", function()
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "old", "helper")
      answers["textDocument/definition"] = location(fixture, "lib.lua", 8, 11)
      request(server, "lsp_definition")
      wait_for(function()
        return api.nvim_get_current_win() == state.win and cursor_line() == 8
      end, "the cursor reached line 8 of the new side")
      assert.are.equal("helper() + 1", at_cursor())
    end)

    it("maps the LSP keys in the buffer of the old side of the split style", function()
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      local maps = maps_of(state.old_buf --[[@as integer]])
      assert.are.equal("codeview: LSP hover", maps["K"])
      assert.are.equal("codeview: LSP definition", maps["gd"])
      assert.are.equal("codeview: LSP rename", maps["grn"])
      assert.are.equal("codeview: LSP code action", maps["gra"])
      assert.are.equal("codeview: show the comment", maps[vim.fn.keytrans(vim.g.mapleader .. "ck")])
    end)

    it("keeps the marker out of the column after a change to the split style and back", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      view.set_style("split")
      view.set_style("inline")
      state = assert(view.current())
      put(state, 8, "new", "helper")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 7, character = 11 }, params.position)
      -- The style change loads no second buffer of the file.
      assert.are.same({ source_buf(state) }, lsp.owned(assert(opened)))
    end)

    it("lands an answer that comes after a change of the style", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "lib.lua", 3, 11)
      assert.is_true(lsp.run("lsp_definition"))
      view.set_style("split")
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3")
      assert.are.equal("helper()", at_cursor())
    end)

    it("sends a removed row of the inline style when the working copy holds the old side", function()
      -- A review of a pull request with no checkout: the working copy holds
      -- the base, and the review shows `base..change`.
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state, "old")))
      put(state, 4, "old", "return")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 3, character = 2 }, params.position)
    end)

    it("gives a note for an added row when the working copy holds the old side", function()
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state, "old")))
      put(state, 8, "new", "helper")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("does not hold this line"))
    end)

    it("sends a context row of the new side when the working copy holds the old side", function()
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state, "old")))
      -- `return M` is line 11 of the new side and line 7 of the base.
      put(state, 11, "new", "M")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 6, character = 7 }, params.position)
      assert.is_not_nil(message_with("differs from the review"))
    end)

    it("moves the cursor to a removed row for a target that only the old side holds", function()
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state, "old")))
      put(state, 11, "new", "M")
      -- Line 4 of the base is `  return 1`, a removed line of the review.
      answers["textDocument/definition"] = location(fixture, "lib.lua", 4, 2)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line("old") == 4 and cursor_line("new") == nil
      end, "the cursor reached the removed row")
      assert.are.equal("return 1", at_cursor())
      assert.are.equal(state, view.current())
    end)

    it("moves the cursor to the old window for a target that only the old side holds", function()
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      assert.is_true(server.wait(source_buf(state, "old")))
      put(state, 11, "new", "M")
      answers["textDocument/definition"] = location(fixture, "lib.lua", 4, 2)
      request(server, "lsp_definition")
      wait_for(function()
        return api.nvim_get_current_win() == state.old_win and cursor_line("old") == 4
      end, "the cursor reached the removed row of the old window")
      assert.are.equal("return 1", at_cursor())
    end)

    it("comes back to the removed row of the request with the back key", function()
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      vim.fn.writefile({ "local other = 1" }, file_of(fixture, "other.lua"))
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state, "old")))
      put(state, 4, "old", "return")
      answers["textDocument/definition"] = location(fixture, "other.lua", 1, 6)
      request(server, "lsp_definition")
      wait_for(function()
        return vim.b.codeview_origin ~= nil
      end, "the file outside the review opens")
      local finished
      view.back(nil, function(ok)
        finished = ok
      end)
      wait_for(function()
        return finished ~= nil
      end, "the back key ends")
      assert.is_true(finished)
      assert.are.equal("lib.lua", assert(view.current()).path)
      assert.are.equal(4, cursor_line("old"))
      assert.is_nil(cursor_line("new"))
    end)
  end)

  describe("kinds of files", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
    end)

    it("sends a row of a renamed file to the new path", function()
      local state = open_file(fixture, "renamed.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 5, "new", "name")
      local params = request(server, "lsp_definition")
      assert.are.equal(uri_of(fixture, "renamed.lua"), params.textDocument.uri)
      assert.are.same({ line = 4, character = 7 }, params.position)
    end)

    it("gives a note for the removed row of a renamed file", function()
      local state = open_file(fixture, "renamed.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 1, "old")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("does not hold this line of renamed.lua"))
    end)

    it("opens the diff of a renamed file for a target in it", function()
      local state = open_file(fixture, "main.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "renamed.lua", 5, 7)
      request(server, "lsp_definition")
      wait_for(function()
        local current = view.current()
        return current ~= nil and current.path == "renamed.lua" and cursor_line() == 5
      end, "the view shows line 5 of renamed.lua")
      assert.are.equal("name", at_cursor())
    end)

    it("gives a note for each row of a deleted file", function()
      local state = open_file(fixture, "gone.lua")
      put(state, 1, "old")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("the working copy holds no gone.lua"))
      assert.are.same({}, lsp.owned(assert(opened)))
    end)

    it("sends a row of a deleted file when the working copy still holds the file", function()
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      local state = open_file(fixture, "gone.lua")
      -- |codeview-lsp-lines|: a row of the old side answers when the working
      -- copy holds the old side.
      assert.is_true(server.wait(source_buf(state, "old")))
      put(state, 1, "old", "'gone'")
      local params = request(server, "lsp_hover")
      assert.are.same({ line = 0, character = 7 }, params.position)
    end)

    it("sends a row of an added file", function()
      local state = open_file(fixture, "added.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 1, "new", "'added'")
      local params = request(server, "lsp_hover")
      assert.are.same({ line = 0, character = 7 }, params.position)
    end)

    it("gives a note for a binary file and loads no buffer for it", function()
      open_file(fixture, "bin.dat")
      assert.is_false(lsp.run("lsp_hover"))
      assert.is_not_nil(message_with("this file has no lines for the language server"))
      assert.are.equal(0, vim.fn.bufexists(file_of(fixture, "bin.dat")))
    end)

    it("sends the column of a row of a file with CRLF line ends", function()
      local state = open_file(fixture, "crlf.txt")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 2, "new", "changed")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 1, character = 4 }, params.position)
    end)

    it("puts the cursor on the column of a target in a file with CRLF line ends", function()
      local state = open_file(fixture, "crlf.txt")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new")
      answers["textDocument/definition"] = location(fixture, "crlf.txt", 2, 4)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 2
      end, "the cursor reached line 2")
      assert.are.equal("changed", (at_cursor():gsub("\r$", "")))
    end)

    it("gives a note for a diff above the size limit, and sends a request after the load of the diff", function()
      setup({ diff = { max_lines = 5 } })
      local state = open_file(fixture, "lib.lua")
      assert.is_truthy(state.diff.limited)
      assert.is_false(lsp.run("lsp_hover"))
      assert.is_not_nil(message_with("this file has no lines for the language server"))
      assert.are.equal(0, vim.fn.bufexists(file_of(fixture, "lib.lua")))

      local finished = false
      assert.is_true(view.load_diff(function()
        finished = true
      end))
      wait_for(function()
        return finished
      end, "the diff loads")
      state = assert(view.current())
      assert.is_true(server.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 7, character = 11 }, params.position)
    end)

    it("gives a note when the file of the working copy became a directory", function()
      vim.fn.delete(file_of(fixture, "lib.lua"))
      vim.fn.mkdir(file_of(fixture, "lib.lua"))
      local state = open_file(fixture, "lib.lua")
      put(state, 3, "new")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("the working copy holds no lib.lua"))
    end)

    it("still sends a request after the file of the working copy went away", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      vim.fn.delete(file_of(fixture, "lib.lua"))
      put(state, 3, "new", "helper")
      -- The hidden buffer still holds the text, so the server still answers.
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 2, character = 11 }, params.position)
    end)

    it("gives a note after the file went away and the user wiped the hidden buffer", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      vim.fn.delete(file_of(fixture, "lib.lua"))
      api.nvim_buf_delete(buf, { force = true })
      put(state, 3, "new", "helper")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("lib.lua"))
    end)

    it("gives a note for a target in a file that does not exist", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "missing.lua", 1, 0)
      request(server, "lsp_definition")
      wait_for(function()
        return message_with("the working copy holds no") ~= nil
      end, "the jump reports the missing file")
      assert.are.equal(state, view.current())
      assert.are.equal(state.buf, api.nvim_win_get_buf(state.win))
    end)

    it("opens the real file for a target in a deleted file of the review", function()
      git(fixture, { "checkout", "--quiet", "--detach", fixture.ids.base })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state, "old")))
      put(state, 3, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "gone.lua", 1, 7)
      request(server, "lsp_definition")
      wait_for(function()
        local current = view.current()
        local on_diff = current ~= nil and current.path == "gone.lua"
        return on_diff or vim.b.codeview_origin ~= nil
      end, "the jump reached gone.lua")
    end)
  end)

  describe("odd content", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(odd_fixture())
    end)

    it("counts a character of two bytes and an emoji in UTF-16 units", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      -- `local é = "😀" .. name`: 21 bytes and 18 UTF-16 units before `name`.
      put(state, 2, "new", "name")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 1, character = 18 }, params.position)
    end)

    it("counts in bytes for a client with the UTF-8 encoding", function()
      server = start_server(fixture.root, {
        capabilities = { textDocumentSync = 1, definitionProvider = true, positionEncoding = "utf-8" },
      })
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "name")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 2, character = 25 }, params.position)
    end)

    it("counts in characters for a client with the UTF-32 encoding", function()
      server = start_server(fixture.root, {
        capabilities = { textDocumentSync = 1, definitionProvider = true, positionEncoding = "utf-32" },
      })
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "name")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 2, character = 18 }, params.position)
    end)

    it("puts the cursor on the byte of a target behind an emoji", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 4, "new")
      -- Line 3 holds 20 UTF-16 units before `name`.
      answers["textDocument/definition"] = location(fixture, "uni.lua", 3, 20)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3")
      assert.are.equal("name", at_cursor())
    end)

    it("puts the cursor on the byte of a target in a file outside the review that is not loaded", function()
      server = start_server(fixture.root)
      local other = file_of(fixture, "other.lua")
      vim.fn.writefile({ "-- one", 'local é = "😀" .. name' }, other)
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 4, "new")
      answers["textDocument/definition"] = location(fixture, "other.lua", 2, 18)
      request(server, "lsp_definition")
      wait_for(function()
        return vim.b.codeview_origin ~= nil
      end, "the file outside the review opens")
      assert.are.equal("name", at_cursor())
    end)

    it("clamps a target column that is behind the end of the line", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 4, "new")
      answers["textDocument/definition"] = location(fixture, "uni.lua", 1, 400)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 1
      end, "the cursor reached line 1")
    end)

    it("sends the column of a line that starts with a tab", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "tabs.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 2, "new", "value")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 1, character = 8 }, params.position)
    end)

    it("sends a line with CRLF of a file with mixed line ends", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "mixed.txt")
      assert.is_true(server.wait(source_buf(state)))
      -- Neovim reads the file with LF line ends, so line 1 keeps its
      -- carriage return in the buffer. The line did not change.
      assert.are.equal("unix", vim.bo[source_buf(state)].fileformat)
      put(state, 1, "new", "ne")
      assert.is_true(lsp.run("lsp_definition"), tostring(messages[#messages]))
      assert.is_nil(message_with("differs from the review"))
    end)

    it("reads a file with no line end after the last line as the same text", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "noeol.lua")
      local source = assert(lsp.sources(state).new)
      assert.is_true(lsp.sync(assert(opened), source))
      assert.is_true(source.same)
      put(state, 2, "new", "a")
      assert.is_true(server.wait(source.buf))
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 1, character = 7 }, params.position)
    end)

    it("gives a note for an empty file", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "empty.lua")
      api.nvim_win_set_cursor(state.win, { api.nvim_buf_line_count(state.buf), 0 })
      assert.is_false(lsp.run("lsp_hover"))
      assert.is_true(#messages > 0)
    end)

    it("sends a row of a file with a space and brackets in its name", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "we ird [1].lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 2, "new", "w")
      local params = request(server, "lsp_definition")
      assert.are.equal(uri_of(fixture, "we ird [1].lua"), params.textDocument.uri)
      assert.are.same({ line = 1, character = 7 }, params.position)
    end)

    it("opens the diff of a file with a space and brackets in its name", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 4, "new")
      answers["textDocument/definition"] = location(fixture, "we ird [1].lua", 2, 7)
      request(server, "lsp_definition")
      wait_for(function()
        local current = view.current()
        return current ~= nil and current.path == "we ird [1].lua" and cursor_line() == 2
      end, "the view shows the file")
      assert.are.equal("w", at_cursor())
    end)

    it("opens a file outside the review with a space and a percent sign in its name", function()
      server = start_server(fixture.root)
      local other = file_of(fixture, "out side %.lua")
      vim.fn.writefile({ "local other = 1", "return other" }, other)
      local state = open_file(fixture, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 4, "new")
      answers["textDocument/definition"] = location(fixture, "out side %.lua", 2, 7)
      request(server, "lsp_definition")
      wait_for(function()
        return vim.b.codeview_origin ~= nil
      end, "the file outside the review opens")
      assert.are.equal(vim.uv.fs_realpath(other), vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
      assert.are.equal("other", at_cursor())
    end)

    it("gives a note for the row of a collapsed section", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "long.lua")
      assert.is_true(server.wait(source_buf(state)))
      assert.is_nil(state.map:buf_row(2, "new"), "line 2 is inside a collapsed section")
      local filler
      for row = 1, api.nvim_buf_line_count(state.buf) do
        if state.map:kind(row) == "filler" then
          filler = row
          break
        end
      end
      assert.is_not_nil(filler, "the diff holds the row of a collapsed section")
      api.nvim_win_set_cursor(state.win, { filler, 0 })
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("this row holds no line of the file"))
    end)

    it("opens a collapsed section for a target inside it", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "long.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 30, "new", "v30")
      answers["textDocument/definition"] = location(fixture, "long.lua", 2, 6)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 2
      end, "the cursor reached line 2")
      assert.are.equal("v2 = 2", at_cursor())
    end)

    it("sends a row of a section that the reader opened", function()
      server = start_server(fixture.root)
      local state = open_file(fixture, "long.lua")
      assert.is_true(server.wait(source_buf(state)))
      view.expand_all()
      put(state, 55, "new", "v55")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 54, character = 6 }, params.position)
      view.collapse_all()
      assert.is_nil(state.map:buf_row(55, "new"))
    end)
  end)

  describe("a working copy that differs from the review", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
    end)

    ---Open lib.lua of the review `one..two` with the commit `three` on top.
    ---@return codeview.view.State
    local function open_stacked()
      fixture = keep(stacked_fixture())
      server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua", fixture.ids.one .. ".." .. fixture.ids.two)
      assert.is_true(server.wait(source_buf(state)))
      return state
    end

    it("sends the line of the later commit for a line that did not change", function()
      local state = open_stacked()
      put(state, 3, "new", "helper")
      local params = request(server, "lsp_definition")
      -- The commit on top put two lines in front of the file.
      assert.are.same({ line = 4, character = 11 }, params.position)
    end)

    it("gives a note for a line that the later commit changed", function()
      local state = open_stacked()
      put(state, 8, "new", "helper")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("does not hold this line"))
    end)

    it("maps a target of the later commit back to its line of the review", function()
      local state = open_stacked()
      put(state, 11, "new", "M")
      -- Line 5 of the working copy is line 3 of the review.
      answers["textDocument/definition"] = location(fixture, "lib.lua", 5, 11)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3 of the review")
      assert.are.equal("helper()", at_cursor())
      assert.are.equal(state, view.current())
    end)

    it("opens the real file for a target on a line that only the later commit holds", function()
      local state = open_stacked()
      put(state, 11, "new", "M")
      answers["textDocument/definition"] = location(fixture, "lib.lua", 1, 3)
      request(server, "lsp_definition")
      wait_for(function()
        return api.nvim_get_current_buf() == source_buf(state)
      end, "the window shows the file of the working copy")
      assert.are.same({ 1, 3 }, api.nvim_win_get_cursor(0))
      assert.are.equal("header", at_cursor())
    end)

    it("gives the note about the working copy one time for many requests", function()
      local state = open_stacked()
      put(state, 3, "new", "helper")
      request(server, "lsp_definition")
      request(server, "lsp_hover")
      put(state, 11, "new", "M")
      request(server, "lsp_definition")
      local notes = vim.tbl_filter(function(message)
        return message:find("differs from the review", 1, true) ~= nil
      end, messages)
      assert.are.equal(1, #notes)
    end)

    it("follows a change of the buffer that the user did not write", function()
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      api.nvim_buf_set_lines(buf, 0, 0, false, { "-- one", "-- two", "-- three" })
      put(state, 8, "new", "helper")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 10, character = 11 }, params.position)
      -- The server holds the text of the buffer, not the text of the disk.
      assert.is_truthy(server.docs[uri_of(fixture, "lib.lua")]:find("^%-%- one\n"))
      vim.bo[buf].modified = false
    end)

    it("follows a change of the file on the disk after the hidden buffer reads the file again", function()
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      local lines = vim.fn.readfile(file_of(fixture, "lib.lua"))
      table.insert(lines, 1, "-- on disk")
      vim.fn.writefile(lines, file_of(fixture, "lib.lua"))
      -- The hidden buffer keeps the old text until Neovim reads the file again.
      put(state, 8, "new", "helper")
      assert.are.same({ line = 7, character = 11 }, request(server, "lsp_definition").position)
      api.nvim_buf_call(buf, function()
        vim.cmd("silent edit!")
      end)
      assert.are.equal("-- on disk", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      assert.are.same({ line = 8, character = 11 }, request(server, "lsp_definition").position)
    end)

    it("answers every row again after the user takes the change back", function()
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      api.nvim_buf_set_lines(buf, 7, 8, false, { "  return 0" })
      put(state, 8, "new", "helper")
      assert.is_false(lsp.run("lsp_definition"))
      api.nvim_buf_set_lines(buf, 7, 8, false, { "  return M.helper() + 1" })
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 7, character = 11 }, params.position)
      vim.bo[buf].modified = false
    end)
  end)

  describe("a review of files with no repository", function()
    ---@type string
    local dir
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      dir = vim.fs.normalize(fixtures.tempdir("codeview-lsp-edge-files"))
      temp_dirs[#temp_dirs + 1] = dir
      vim.fn.writefile({ "local plan = 1", "local é = plan", "return plan" }, vim.fs.joinpath(dir, "plan.lua"))
      vim.fn.mkdir(vim.fs.joinpath(dir, "sub"))
      vim.fn.writefile({ "local second = 2", "return second" }, vim.fs.joinpath(dir, "sub", "second.lua"))
      vim.fn.writefile({ "local outside = 3", "return outside" }, vim.fs.joinpath(dir, "outside.lua"))
      server = start_server(dir)
    end)

    ---@param paths string[] Paths below the directory.
    ---@return codeview.view.State
    local function open_plan(paths)
      local full = vim.tbl_map(function(path)
        return vim.fs.joinpath(dir, path)
      end, paths)
      local session, err = session_mod.open_files(full, { dir = dir })
      assert.is_nil(err)
      opened = assert(session)
      local state = assert(view.open(opened, 1))
      api.nvim_set_current_win(state.win)
      assert.is_true(server.wait(source_buf(state)))
      return state
    end

    ---@param path string
    ---@param line integer
    ---@param character integer
    ---@return table location
    local function at(path, line, character)
      local position = { line = line - 1, character = character }
      return { uri = helpers.real_uri(vim.fs.joinpath(dir, path)), range = { start = position, ["end"] = position } }
    end

    it("sends the column of a row with no marker", function()
      local state = open_plan({ "plan.lua" })
      put(state, 3, "new", "plan")
      local params = request(server, "lsp_definition")
      assert.are.equal(helpers.real_uri(vim.fs.joinpath(dir, "plan.lua")), params.textDocument.uri)
      assert.are.same({ line = 2, character = 7 }, params.position)
    end)

    it("moves the cursor to a target in the same file", function()
      local state = open_plan({ "plan.lua" })
      put(state, 3, "new", "plan")
      answers["textDocument/definition"] = at("plan.lua", 2, 10)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 2
      end, "the cursor reached line 2")
      assert.are.equal("plan", at_cursor())
      assert.are.equal(state, view.current())
    end)

    it("opens the other file of the review for a target in it", function()
      local state = open_plan({ "plan.lua", "sub/second.lua" })
      put(state, 3, "new", "plan")
      answers["textDocument/definition"] = at("sub/second.lua", 2, 7)
      request(server, "lsp_definition")
      wait_for(function()
        local current = view.current()
        return current ~= nil and current ~= state and cursor_line() == 2
      end, "the view shows the second file")
      assert.are.equal("second", at_cursor())
      assert.is_nil(vim.b.codeview_origin)
    end)

    it("opens a file outside the review, and the back key comes back", function()
      local state = open_plan({ "plan.lua" })
      put(state, 3, "new", "plan")
      answers["textDocument/definition"] = at("outside.lua", 2, 7)
      request(server, "lsp_definition")
      wait_for(function()
        return vim.b.codeview_origin ~= nil
      end, "the file outside the review opens")
      assert.are.equal("outside", at_cursor())
      local finished
      view.back(nil, function(ok)
        finished = ok
      end)
      wait_for(function()
        return finished ~= nil
      end, "the back key ends")
      assert.is_true(finished)
      assert.are.equal(3, cursor_line())
    end)

    it("gives a note for a line that the user changed in the buffer", function()
      local state = open_plan({ "plan.lua" })
      local buf = source_buf(state)
      api.nvim_buf_set_lines(buf, 2, 3, false, { "return plan + 1" })
      put(state, 3, "new", "plan")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("does not hold this line"))
      put(state, 1, "new", "plan")
      assert.is_true(lsp.run("lsp_definition"))
      vim.bo[buf].modified = false
    end)

    it("says that the review keeps its text after a rename", function()
      local state = open_plan({ "plan.lua" })
      put(state, 1, "new", "plan")
      answers["textDocument/rename"] = {
        changes = { [helpers.real_uri(vim.fs.joinpath(dir, "plan.lua"))] = { edit(1, 6, 10, "idea") } },
      }
      request(server, "lsp_rename", { name = "idea" })
      wait_for(function()
        return message_with("the rename changed 1 file") ~= nil
      end, "the rename reports its change")
      local message = assert(message_with("the rename changed 1 file"))
      assert.is_truthy(message:find("plan.lua", 1, true))
      assert.is_truthy(message:find("its diff does not change", 1, true), message)
      assert.are.equal("local plan = 1", vim.fn.readfile(vim.fs.joinpath(dir, "plan.lua"))[1])
      vim.bo[source_buf(state)].modified = false
    end)

    it("removes the hidden buffers when the session closes", function()
      local state = open_plan({ "plan.lua", "sub/second.lua" })
      local buf = source_buf(state)
      assert(opened):close()
      opened = nil
      assert.is_false(api.nvim_buf_is_valid(buf))
    end)
  end)

  describe("clients", function()
    ---@type tests.Fixture
    local fixture

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(fixtures.git_lsp())
    end)

    it("names the request that no client of the file supports", function()
      local server = start_server(fixture.root, { capabilities = { textDocumentSync = 1, definitionProvider = true } })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      assert.is_false(lsp.run("lsp_hover"))
      assert.is_not_nil(message_with("no language server of lib.lua gives the hover"))
      assert.is_false(lsp.run("lsp_code_action"))
      assert.is_not_nil(message_with("no language server of lib.lua gives the code action"))
      lsp.run("lsp_rename", { name = "other" })
      assert.is_not_nil(message_with("no language server of lib.lua gives the rename"))
    end)

    it("returns false for a rename that no client of the file supports", function()
      local server = start_server(fixture.root, { capabilities = { textDocumentSync = 1, definitionProvider = true } })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      assert.is_false(lsp.run("lsp_rename", { name = "other" }))
    end)

    it("gives a note and no error while the client still starts", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      put(state, 3, "new", "helper")
      -- The server did not answer the initialize request yet.
      answers["textDocument/definition"] = location(fixture, "lib.lua", 8, 11)
      local ok, sent = pcall(lsp.run, "lsp_definition")
      assert.is_true(ok, tostring(sent))
      if sent then
        wait_for(function()
          return cursor_line() == 8
        end, "a request that went out gets its answer")
      else
        assert.is_true(#messages > 0, "a request that did not go out gives a note")
      end
      assert.is_true(server.wait(source_buf(state)))
    end)

    it("reports no definition after an error of the server", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/definition"] = function()
        return nil, { code = -32603, message = "boom" }
      end
      request(server, "lsp_definition")
      wait_for(function()
        return message_with("no definition found") ~= nil
      end, "the jump reports no definition")
      assert.are.equal(3, cursor_line())
    end)

    it("reports no hover text after an error of the server", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/hover"] = function()
        return nil, { code = -32603, message = "boom" }
      end
      request(server, "lsp_hover")
      wait_for(function()
        return message_with("gave no hover text") ~= nil
      end, "the hover reports no text")
      assert.are.same({}, floats())
    end)

    it("reports the message of a failed rename", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/rename"] = function()
        return nil, { code = -32602, message = "not a symbol" }
      end
      request(server, "lsp_rename", { name = "other" })
      wait_for(function()
        return message_with("the rename failed: not a symbol") ~= nil
      end, "the rename reports the error")
      assert.is_false(vim.bo[source_buf(state)].modified)
    end)

    it("reports no code action after an error of the server", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/codeAction"] = function()
        return nil, { code = -32603, message = "boom" }
      end
      request(server, "lsp_code_action")
      wait_for(function()
        return message_with("no code action for this line") ~= nil
      end, "the key reports no code action")
    end)

    it("takes a null answer and an empty answer as no result", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      for _, value in ipairs({ vim.NIL, {} }) do
        messages = {}
        answers["textDocument/definition"] = value
        answers["textDocument/references"] = value
        answers["textDocument/hover"] = value
        answers["textDocument/codeAction"] = value
        request(server, "lsp_definition")
        wait_for(function()
          return message_with("no definition found") ~= nil
        end, "no definition")
        request(server, "lsp_references")
        wait_for(function()
          return message_with("no references found") ~= nil
        end, "no references")
        request(server, "lsp_hover")
        wait_for(function()
          return message_with("gave no hover text") ~= nil
        end, "no hover")
        request(server, "lsp_code_action")
        wait_for(function()
          return message_with("no code action for this line") ~= nil
        end, "no code action")
      end
      assert.are.equal(3, cursor_line())
      assert.are.same({}, vim.fn.getqflist())
    end)

    it("reports no hover text for a hover with empty contents", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      for _, contents in ipairs({ "", {}, { kind = "markdown", value = "" }, { kind = "plaintext", value = "\n\n" } }) do
        messages = {}
        answers["textDocument/hover"] = { contents = contents }
        request(server, "lsp_hover")
        wait_for(function()
          return message_with("gave no hover text") ~= nil
        end, "the hover reports no text for " .. vim.inspect(contents))
        assert.are.same({}, floats())
      end
    end)

    it("jumps to the selection range of a location link", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      answers["textDocument/definition"] = {
        {
          originSelectionRange = { start = { line = 7, character = 11 }, ["end"] = { line = 7, character = 17 } },
          targetUri = uri_of(fixture, "lib.lua"),
          -- The whole function is the target range. The name is the selection.
          targetRange = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 3 } },
          targetSelectionRange = { start = { line = 2, character = 11 }, ["end"] = { line = 2, character = 17 } },
        },
      }
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3")
      assert.are.equal("helper()", at_cursor())
    end)

    it("opens the diff of another file of the review for a location link", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "main.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      local range = { start = { line = 6, character = 11 }, ["end"] = { line = 6, character = 16 } }
      answers["textDocument/definition"] = {
        { targetUri = uri_of(fixture, "lib.lua"), targetRange = range, targetSelectionRange = range },
      }
      request(server, "lsp_definition")
      wait_for(function()
        local current = view.current()
        return current ~= nil and current.path == "lib.lua" and cursor_line() == 7
      end, "the view shows line 7 of lib.lua")
      assert.are.equal("extra()", at_cursor())
    end)

    it("puts location links into the quickfix list at their selection range", function()
      local server = start_server(fixture.root)
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      local function link(path, line, character)
        local range =
          { start = { line = line - 1, character = character }, ["end"] = { line = line - 1, character = character } }
        return { targetUri = uri_of(fixture, path), targetRange = range, targetSelectionRange = range }
      end
      answers["textDocument/implementation"] = { link("lib.lua", 3, 11), link("main.lua", 3, 18) }
      request(server, "lsp_implementation")
      wait_for(function()
        return #vim.fn.getqflist() == 2
      end, "the quickfix list holds two entries")
      local list = vim.fn.getqflist({ title = 1, items = 1 })
      assert.are.equal("codeview: implementation", list.title)
      assert.are.equal(3, list.items[1].lnum)
      assert.are.equal(12, list.items[1].col)
      assert.are.equal(19, list.items[2].col)
    end)

    it("jumps one time when two clients give the same location", function()
      local first = start_server(fixture.root, { name = "edge-first" })
      local second = start_server(fixture.root, { name = "edge-second" })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(first.wait(source_buf(state)))
      assert.is_true(second.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "lib.lua", 3, 11)
      request(first, "lsp_definition")
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3")
      assert.are.equal(1, #second.calls("textDocument/definition"))
      assert.are.same({}, vim.fn.getqflist())
    end)

    it("lists the locations when two clients give different ones", function()
      local other = {}
      local first = start_server(fixture.root, { name = "edge-first" })
      local second = start_server(fixture.root, { name = "edge-second", answers = other })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(first.wait(source_buf(state)))
      assert.is_true(second.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "lib.lua", 3, 11)
      other["textDocument/definition"] = { location(fixture, "main.lua", 3, 18) }
      request(first, "lsp_definition")
      wait_for(function()
        return #vim.fn.getqflist() == 2
      end, "the quickfix list holds both locations")
      assert.are.equal(
        8,
        api.nvim_win_call(state.win, function()
          return cursor_line()
        end)
      )
    end)

    it("jumps to the answer of the one client that has one", function()
      local other = {}
      local first = start_server(fixture.root, { name = "edge-first" })
      local second = start_server(fixture.root, { name = "edge-second", answers = other })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(first.wait(source_buf(state)))
      assert.is_true(second.wait(source_buf(state)))
      put(state, 8, "new", "helper")
      answers["textDocument/definition"] = function()
        return nil, { code = -32603, message = "boom" }
      end
      other["textDocument/definition"] = location(fixture, "lib.lua", 3, 11)
      request(first, "lsp_definition")
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3")
    end)

    it("sends each client the column in its own encoding", function()
      local fixture_odd = keep(odd_fixture())
      local wide = start_server(fixture_odd.root, { name = "edge-wide" })
      local bytes = start_server(fixture_odd.root, {
        name = "edge-bytes",
        capabilities = { textDocumentSync = 1, definitionProvider = true, positionEncoding = "utf-8" },
      })
      local state = open_file(fixture_odd, "uni.lua")
      assert.is_true(wide.wait(source_buf(state)))
      assert.is_true(bytes.wait(source_buf(state)))
      put(state, 2, "new", "name")
      request(wide, "lsp_definition")
      wait_for(function()
        return #bytes.calls("textDocument/definition") == 1
      end, "the second client got the request")
      assert.are.equal(18, wide.calls("textDocument/definition")[1].position.character)
      assert.are.equal(21, bytes.calls("textDocument/definition")[1].position.character)
    end)

    it("shows the hover text of two clients in one float", function()
      local other = {}
      local first = start_server(fixture.root, { name = "edge-first" })
      local second = start_server(fixture.root, { name = "edge-second", answers = other })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(first.wait(source_buf(state)))
      assert.is_true(second.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/hover"] = { contents = { kind = "markdown", value = "first text" } }
      other["textDocument/hover"] = { contents = "second text" }
      request(first, "lsp_hover")
      wait_for(function()
        return #floats() == 1
      end, "one hover float opens")
      local text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(floats()[1]), 0, -1, false), "\n")
      assert.is_truthy(text:find("first text", 1, true))
      assert.is_truthy(text:find("second text", 1, true))
      -- The float does not take the focus, so the cursor stays in the diff.
      assert.are.equal(state.win, api.nvim_get_current_win())
    end)

    it("sends a rename to one client only", function()
      local first = start_server(fixture.root, { name = "edge-first" })
      local second = start_server(fixture.root, { name = "edge-second" })
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(first.wait(buf))
      assert.is_true(second.wait(buf))
      put(state, 3, "new", "helper")
      answers["textDocument/rename"] = { changes = { [uri_of(fixture, "lib.lua")] = { edit(3, 11, 17, "assist") } } }
      assert.is_true(lsp.run("lsp_rename", { name = "assist" }))
      wait_for(function()
        return api.nvim_buf_get_lines(buf, 2, 3, false)[1] == "function M.assist()"
      end, "the rename changed the line one time")
      vim.wait(50)
      assert.are.equal(1, #first.calls("textDocument/rename") + #second.calls("textDocument/rename"))
      vim.bo[buf].modified = false
    end)

    it("names the client of each code action when two clients answer", function()
      local other = {}
      local first = start_server(fixture.root, { name = "edge-first" })
      local second = start_server(fixture.root, { name = "edge-second", answers = other })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(first.wait(source_buf(state)))
      assert.is_true(second.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/codeAction"] = { { title = "fix one", edit = { changes = {} } } }
      other["textDocument/codeAction"] = { { title = "fix two", edit = { changes = {} } } }
      local titles
      vim.ui.select = function(items, opts, on_choice)
        titles = vim.tbl_map(opts.format_item, items)
        on_choice(nil)
      end
      request(first, "lsp_code_action")
      wait_for(function()
        return titles ~= nil
      end, "the menu opens")
      table.sort(titles)
      assert.are.same({ "fix one [edge-first]", "fix two [edge-second]" }, titles)
    end)
  end)

  describe("the option off", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup({ lsp = { enabled = false } })
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
    end)

    ---Text of the hint row of the view.
    ---@return string text
    local function hint_text()
      return table.concat(vim.tbl_map(function(chunk)
        return chunk.text
      end, require("codeview.hints").chunks("view", nil)))
    end

    it("loads no module and no file through the styles, the sections, and the files", function()
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      assert.is_nil(maps_of(state.old_buf --[[@as integer]])["gd"])
      assert.are.equal("codeview: show the comment", maps_of(state.old_buf --[[@as integer]])["K"])
      view.set_style("inline")
      view.expand_all()
      view.collapse_all()
      for _, path in ipairs({ "main.lua", "renamed.lua", "added.lua", "crlf.txt", "bin.dat", "gone.lua" }) do
        open_file(fixture, path)
      end
      assert.is_nil(package.loaded["codeview.lsp"], "the module does not load")
      for _, path in ipairs({ "lib.lua", "main.lua", "renamed.lua", "added.lua", "crlf.txt" }) do
        assert.are.equal(0, vim.fn.bufexists(file_of(fixture, path)), path)
      end
      assert.are.same({}, server.requests)
    end)

    it("keeps the edit key and the back key with no module", function()
      local state = open_file(fixture, "lib.lua")
      put(state, 8, "new")
      assert.is_true(view.edit())
      local buf = api.nvim_get_current_buf()
      assert.are.equal("lib.lua", vim.b[buf].codeview_file)
      assert.is_nil(vim.b[buf].codeview_origin)
      assert.are.equal(8, api.nvim_win_get_cursor(0)[1])
      -- A second file in the same window takes no back key of the LSP option.
      vim.cmd.edit(vim.fn.fnameescape(file_of(fixture, "main.lua")))
      assert.is_nil(vim.b.codeview_origin)
      vim.cmd.buffer(buf)
      assert.is_true(view.back())
      assert.are.equal("lib.lua", assert(view.current()).path)
      assert.are.equal(8, cursor_line())
      assert.is_nil(package.loaded["codeview.lsp"], "the module does not load")
    end)

    it("names no LSP key in the hint row", function()
      open_file(fixture, "lib.lua")
      local text = hint_text()
      assert.is_truthy(text:find("K read comment", 1, true))
      assert.is_nil(text:find("hover", 1, true))
      assert.is_nil(text:find("definition", 1, true))
    end)

    it("keeps the key of the user for the comment float, and not the key of the option", function()
      setup({ lsp = { enabled = false }, keymaps = { show_comment = "gK", show_comment_lsp = "gL" } })
      local state = open_file(fixture, "lib.lua")
      local maps = maps_of(state.buf)
      assert.are.equal("codeview: show the comment", maps["gK"])
      assert.is_nil(maps["gL"])
      assert.is_nil(maps["K"])
    end)

    it("rejects an option value that is no boolean", function()
      assert.has_error(function()
        assert(config.setup({ lsp = { enabled = "yes" } }))
      end)
      assert.has_error(function()
        assert(config.setup({ lsp = { enabled = true, diagnostics = 1 } }))
      end)
      assert.has_error(function()
        assert(config.setup({ lsp = true }))
      end)
    end)

    it("maps the LSP keys in the next file after setup() sets the option", function()
      open_file(fixture, "lib.lua")
      setup({ lsp = { enabled = true } })
      local state = open_file(fixture, "main.lua")
      local maps = maps_of(state.buf)
      assert.are.equal("codeview: LSP hover", maps["K"])
      assert.are.equal("codeview: LSP definition", maps["gd"])
      assert.is_true(server.wait(require("codeview.lsp").sources(state).new.buf))
    end)

    it("maps the keys that the hint row names after setup() sets the option", function()
      local state = open_file(fixture, "lib.lua")
      setup({ lsp = { enabled = true } })
      -- A render follows the new configuration, as a toggle of a section does.
      view.expand_all()
      assert.is_truthy(hint_text():find("K hover", 1, true))
      local maps = maps_of(state.buf)
      assert.are.equal("codeview: LSP hover", maps["K"])
      assert.are.equal("codeview: LSP definition", maps["gd"])
    end)

    it("removes the LSP keys of the open diff after setup() clears the option", function()
      setup({ lsp = { enabled = true } })
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(require("codeview.lsp").sources(state).new.buf))
      setup({ lsp = { enabled = false } })
      view.expand_all()
      assert.is_truthy(hint_text():find("K read comment", 1, true))
      local maps = maps_of(state.buf)
      assert.are.equal("codeview: show the comment", maps["K"])
      assert.is_nil(maps["gd"])
    end)

    it("maps no LSP key in the next file after setup() clears the option", function()
      setup({ lsp = { enabled = true } })
      open_file(fixture, "lib.lua")
      setup({ lsp = { enabled = false } })
      local state = open_file(fixture, "main.lua")
      local maps = maps_of(state.buf)
      assert.are.equal("codeview: show the comment", maps["K"])
      assert.is_nil(maps["gd"])
      assert.are.equal(0, vim.fn.bufexists(file_of(fixture, "main.lua")))
    end)

    it("still removes the hidden buffers at the close after setup() clears the option", function()
      setup({ lsp = { enabled = true } })
      local state = open_file(fixture, "lib.lua")
      local buf = require("codeview.lsp").sources(state).new.buf
      setup({ lsp = { enabled = false } })
      assert(opened):close()
      opened = nil
      assert.is_false(api.nvim_buf_is_valid(buf))
    end)
  end)

  describe("buffers of the working copy", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
    end)

    ---Number of notifications of one method for one file.
    ---@param method string
    ---@param path string
    ---@return integer count
    local function notified(method, path)
      local count = 0
      for _, item in ipairs(server.notifications) do
        if item.method == method and item.params.textDocument.uri == uri_of(fixture, path) then
          count = count + 1
        end
      end
      return count
    end

    it("keeps the hidden buffer unlisted and out of every window", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_false(vim.bo[buf].buflisted)
      assert.are.same({}, vim.fn.win_findbuf(buf))
      assert.is_false(vim.bo[buf].modified)
      assert.are.equal("", vim.bo[buf].buftype)
      assert.are.equal("lua", vim.bo[buf].filetype)
    end)

    it("loads only the file that the view shows", function()
      open_file(fixture, "lib.lua")
      assert.are.equal(1, #lsp.owned(assert(opened)))
      assert.are.equal(0, vim.fn.bufexists(file_of(fixture, "main.lua")))
    end)

    it("uses one buffer for a file that opens two times", function()
      local first = source_buf(open_file(fixture, "lib.lua"))
      open_file(fixture, "main.lua")
      local second = source_buf(open_file(fixture, "lib.lua"))
      assert.are.equal(first, second)
      assert.are.equal(2, #lsp.owned(assert(opened)))
      assert.is_true(server.wait(first))
      assert.are.equal(1, notified("textDocument/didOpen", "lib.lua"))
    end)

    it("closes the document of the server when the session closes", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      assert(opened):close()
      opened = nil
      assert.is_false(api.nvim_buf_is_valid(buf))
      wait_for(function()
        return notified("textDocument/didClose", "lib.lua") == 1
      end, "the server got the close of the document")
    end)

    it("loads the files again after the review opens again", function()
      local command = require("codeview.command")
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      assert(opened):close()
      opened = nil
      assert.is_false(api.nvim_buf_is_valid(buf))

      local finished, session
      command.reopen(function(review)
        finished, session = true, review
      end)
      wait_for(function()
        return finished == true
      end, "the reopen ends")
      opened = assert(session)
      wait_for(function()
        local current = view.current()
        return current ~= nil and current.path == "lib.lua"
      end, "the view shows lib.lua again")
      local again = source_buf(assert(view.current()))
      assert.is_true(api.nvim_buf_is_loaded(again))
      assert.is_true(server.wait(again))
      put(assert(view.current()), 8, "new", "helper")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 7, character = 11 }, params.position)
    end)

    it("uses the buffer of a file that a window of the user shows, and keeps it", function()
      vim.cmd.edit(vim.fn.fnameescape(file_of(fixture, "lib.lua")))
      local user_buf = api.nvim_get_current_buf()
      local user_win = api.nvim_get_current_win()
      api.nvim_buf_set_lines(user_buf, 0, 0, false, { "-- mine" })
      vim.cmd("split")
      local state = open_file(fixture, "lib.lua")
      assert.are.equal(user_buf, source_buf(state))
      assert.are.same({}, lsp.owned(assert(opened)))
      assert.is_true(server.wait(user_buf))
      put(state, 3, "new", "helper")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 3, character = 11 }, params.position)
      assert(opened):close()
      opened = nil
      assert.is_true(api.nvim_buf_is_loaded(user_buf))
      assert.is_true(vim.bo[user_buf].modified)
      assert.is_true(vim.bo[user_buf].buflisted)
      assert.are.equal(user_buf, api.nvim_win_get_buf(user_win))
      assert.are.equal("-- mine", api.nvim_buf_get_lines(user_buf, 0, 1, false)[1])
      vim.bo[user_buf].modified = false
    end)

    it("keeps a listed buffer of the user that no window shows", function()
      vim.cmd.badd(vim.fn.fnameescape(file_of(fixture, "lib.lua")))
      local user_buf = vim.fn.bufnr(file_of(fixture, "lib.lua"))
      assert.is_false(api.nvim_buf_is_loaded(user_buf))
      local state = open_file(fixture, "lib.lua")
      assert.are.equal(user_buf, source_buf(state))
      assert(opened):close()
      opened = nil
      assert.is_true(api.nvim_buf_is_valid(user_buf))
      assert.is_true(vim.bo[user_buf].buflisted)
    end)

    it("unloads, and does not wipe, an unlisted buffer that was there before", function()
      local user_buf = vim.fn.bufadd(file_of(fixture, "lib.lua"))
      assert.is_false(api.nvim_buf_is_loaded(user_buf))
      local state = open_file(fixture, "lib.lua")
      assert.are.equal(user_buf, source_buf(state))
      assert.is_true(api.nvim_buf_is_loaded(user_buf))
      assert(opened):close()
      opened = nil
      assert.is_true(api.nvim_buf_is_valid(user_buf))
      assert.is_false(api.nvim_buf_is_loaded(user_buf))
    end)

    it("loads the file again after the user wiped the hidden buffer", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      api.nvim_buf_delete(buf, { force = true })
      put(state, 8, "new", "helper")
      local position = assert(lsp.locate(state))
      assert.are_not.equal(buf, position.source.buf)
      assert.is_true(server.wait(position.source.buf))
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 7, character = 11 }, params.position)
      local again = position.source.buf
      assert(opened):close()
      opened = nil
      assert.is_false(api.nvim_buf_is_valid(again))
    end)

    it("loads the file again after the user unloaded the hidden buffer", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      api.nvim_buf_delete(buf, { unload = true })
      put(state, 8, "new", "helper")
      assert.is_not_nil(lsp.locate(state))
      assert.is_true(api.nvim_buf_is_loaded(buf))
      assert(opened):close()
      opened = nil
      assert.is_false(api.nvim_buf_is_valid(buf))
    end)

    it("keeps a hidden buffer that the user put into a window", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      vim.cmd("split")
      vim.cmd.buffer(buf)
      local win = api.nvim_get_current_win()
      assert(opened):close()
      opened = nil
      assert.is_true(api.nvim_buf_is_loaded(buf))
      assert.are.equal(buf, api.nvim_win_get_buf(win))
    end)

    it("keeps a hidden buffer with a change that is not written", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      api.nvim_buf_set_lines(buf, 0, 0, false, { "-- change" })
      assert(opened):close()
      opened = nil
      assert.is_true(api.nvim_buf_is_loaded(buf))
      assert.is_true(vim.bo[buf].modified)
      vim.bo[buf].modified = false
    end)

    it("lists a hidden buffer with a change after the session closes", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      api.nvim_buf_set_lines(buf, 0, 0, false, { "-- change" })
      assert(opened):close()
      opened = nil
      assert.is_true(api.nvim_buf_is_valid(buf))
      local listed = vim.bo[buf].buflisted
      vim.bo[buf].modified = false
      assert.is_true(listed, "`:ls` shows the buffer that holds the change")
    end)

    it("loads a file that has a swap file with no prompt", function()
      local swap_dir = fixtures.tempdir("codeview-lsp-edge-swap")
      temp_dirs[#temp_dirs + 1] = swap_dir
      local directory = vim.o.directory
      vim.o.directory = swap_dir .. "//"
      vim.o.swapfile = true
      -- Another Neovim holds the file open, so its swap file exists.
      local other = vim.system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "--cmd",
        "set swapfile directory=" .. vim.fn.fnameescape(swap_dir) .. "//",
        "-c",
        "edit " .. vim.fn.fnameescape(file_of(fixture, "lib.lua")),
        "-c",
        "normal! ix",
        "-c",
        "preserve",
      }, { text = true })
      wait_for(function()
        return #vim.fn.glob(swap_dir .. "/*", false, true) > 0
      end, "the other Neovim made its swap file")
      local ok, state = pcall(open_file, fixture, "lib.lua")
      local buf = ok and lsp.sources(state).new and lsp.sources(state).new.buf
      other:kill(9)
      other:wait(5000)
      vim.o.swapfile = false
      vim.o.directory = directory
      assert.is_true(ok, tostring(state))
      assert.is_truthy(buf, "the file loads")
      assert.is_false(vim.bo[buf].readonly)
      assert.are.equal("local M = {}", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    end)

    it("loads the files of every kind of change while the reader steps through the review", function()
      for _, entry in ipairs(open_session(fixture).files) do
        open_file(fixture, entry.path)
      end
      local names = vim.tbl_map(function(buf)
        return vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t")
      end, lsp.owned(assert(opened)))
      table.sort(names)
      assert.are.same({ "added.lua", "crlf.txt", "lib.lua", "main.lua", "renamed.lua" }, names)
    end)
  end)

  describe("renames and code actions", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(fixtures.git_lsp())
    end)

    ---Open lib.lua with the cursor on `helper` of line 3.
    ---@param capabilities table?
    ---@return codeview.view.State state
    ---@return integer buf Hidden buffer of lib.lua.
    local function open_lib(capabilities)
      server = start_server(fixture.root, { capabilities = capabilities })
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      put(state, 3, "new", "helper")
      return state, buf
    end

    ---Drop the changes of the buffers of the fixture, so the cleanup needs no force.
    local function forget_changes()
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if vim.bo[buf].buftype == "" then
          vim.bo[buf].modified = false
        end
      end
    end

    it("renames in a file of the review, in a second one, and in a file outside it", function()
      vim.fn.writefile({ "local h = require('lib').helper" }, file_of(fixture, "other.lua"))
      local state, buf = open_lib()
      answers["textDocument/rename"] = {
        changes = {
          [uri_of(fixture, "lib.lua")] = { edit(3, 11, 17, "assist"), edit(8, 11, 17, "assist") },
          [uri_of(fixture, "main.lua")] = { edit(3, 18, 24, "assist") },
          [uri_of(fixture, "other.lua")] = { edit(1, 25, 31, "assist") },
        },
      }
      local params = request(server, "lsp_rename", { name = "assist" })
      assert.are.equal("assist", params.newName)
      assert.are.same({ line = 2, character = 11 }, params.position)
      wait_for(function()
        return message_with("the rename changed") ~= nil
      end, "the rename reports its change")
      local message = assert(message_with("the rename changed"))
      assert.is_truthy(message:find("changed 3 files of the working copy", 1, true), message)
      for _, name in ipairs({ "lib.lua", "main.lua", "other.lua" }) do
        assert.is_truthy(message:find(name, 1, true), message)
      end
      assert.is_nil(message:find(fixture.root, 1, true), "the note names the files from the root of the review")
      assert.is_truthy(message:find("its diff does not change", 1, true), message)

      -- The edit is in the buffers. No file of the disk changed.
      assert.are.equal("function M.assist()", api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.equal("function M.helper()", vim.fn.readfile(file_of(fixture, "lib.lua"))[3])
      assert.are.equal("local value = lib.helper()", vim.fn.readfile(file_of(fixture, "main.lua"))[3])
      assert.are.equal("local h = require('lib').helper", vim.fn.readfile(file_of(fixture, "other.lua"))[1])
      -- |codeview-lsp-edit|: a buffer with a change becomes listed.
      for _, name in ipairs({ "lib.lua", "main.lua", "other.lua" }) do
        local changed = vim.fn.bufnr(file_of(fixture, name))
        assert.is_true(vim.bo[changed].buflisted, name .. " is listed")
        assert.is_true(vim.bo[changed].modified, name .. " holds the change")
      end
      -- The diff shows the revision, so it keeps its text.
      assert.are.equal("function M.helper()", state.diff.new_lines[3])
      assert.are.equal(state, view.current())
      forget_changes()
    end)

    it("sends no request from a line that a rename changed, and still sends from the other lines", function()
      local state, buf = open_lib()
      answers["textDocument/rename"] = { changes = { [uri_of(fixture, "lib.lua")] = { edit(3, 11, 17, "assist") } } }
      request(server, "lsp_rename", { name = "assist" })
      wait_for(function()
        return vim.bo[buf].modified
      end, "the rename changed the buffer")
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("does not hold this line"))
      put(state, 8, "new", "helper")
      local params = request(server, "lsp_definition")
      assert.are.same({ line = 7, character = 11 }, params.position)
      forget_changes()
    end)

    it("applies a rename that comes as document changes", function()
      local _, buf = open_lib()
      answers["textDocument/rename"] = {
        documentChanges = {
          { textDocument = { uri = uri_of(fixture, "lib.lua"), version = 0 }, edits = { edit(3, 11, 17, "assist") } },
        },
      }
      request(server, "lsp_rename", { name = "assist" })
      wait_for(function()
        return api.nvim_buf_get_lines(buf, 2, 3, false)[1] == "function M.assist()"
      end, "the rename changed the buffer")
      forget_changes()
    end)

    it("asks for the new name with the word under the cursor as the start", function()
      open_lib()
      local asked
      vim.ui.input = function(opts, on_confirm)
        asked = opts
        on_confirm(nil)
      end
      assert.is_true(lsp.run("lsp_rename"))
      assert.are.equal("helper", asked.default)
      vim.wait(50)
      assert.are.same({}, server.calls("textDocument/rename"))
    end)

    it("sends no rename for an empty name and for the same name", function()
      open_lib()
      for _, name in ipairs({ "", "   ", "helper" }) do
        vim.ui.input = function(_, on_confirm)
          on_confirm(name)
        end
        assert.is_true(lsp.run("lsp_rename"))
      end
      vim.wait(50)
      assert.are.same({}, server.calls("textDocument/rename"))
      assert.are.same({}, messages)
    end)

    it("asks for no name on a row with no line of the file", function()
      local state = open_lib()
      local asked = false
      vim.ui.input = function(_, on_confirm)
        asked = true
        on_confirm(nil)
      end
      put(state, 4, "old")
      assert.is_false(lsp.run("lsp_rename"))
      assert.is_false(asked)
      assert.is_not_nil(message_with("does not hold this line"))
    end)

    it("renames the symbol of the key, also when the cursor moves while the prompt is open", function()
      local state = open_lib()
      vim.ui.input = function(_, on_confirm)
        -- A prompt in a float can answer after the cursor moved.
        put(state, 11, "new", "M")
        on_confirm("assist")
      end
      assert.is_true(lsp.run("lsp_rename"))
      wait_for(function()
        return #server.calls("textDocument/rename") == 1
      end, "the server got the rename")
      assert.are.same({ line = 2, character = 11 }, server.calls("textDocument/rename")[1].position)
    end)

    it("renames when the prompt answers from its own window", function()
      open_lib()
      vim.ui.input = function(_, on_confirm)
        -- A prompt plugin answers from its float, before the float closes.
        local float = api.nvim_open_win(api.nvim_create_buf(false, true), true, {
          relative = "editor",
          row = 1,
          col = 1,
          width = 20,
          height = 1,
        })
        on_confirm("assist")
        api.nvim_win_close(float, true)
      end
      assert.is_true(lsp.run("lsp_rename"))
      vim.wait(100)
      assert.is_nil(message_with("the cursor is not in the diff"))
      assert.are.equal(1, #server.calls("textDocument/rename"))
    end)

    it("takes a word with a letter outside ASCII as the start of the new name", function()
      local odd = keep(odd_fixture())
      assert(opened == nil)
      server = start_server(odd.root)
      local state = open_file(odd, "uni.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 4, "new", "é")
      local asked
      vim.ui.input = function(opts, on_confirm)
        asked = opts
        on_confirm(nil)
      end
      assert.is_true(lsp.run("lsp_rename"))
      assert.are.equal("é", asked.default)
    end)

    it("drops a rename whose answer comes after the session closed", function()
      local _, buf = open_lib()
      answers["textDocument/rename"] = { changes = { [uri_of(fixture, "lib.lua")] = { edit(3, 11, 17, "assist") } } }
      api.nvim_buf_set_lines(buf, 0, 0, false, {})
      assert.is_true(lsp.run("lsp_rename", { name = "assist" }))
      assert(opened):close()
      opened = nil
      wait_for(function()
        return #server.calls("textDocument/rename") == 1
      end, "the server got the rename")
      vim.wait(100)
      assert.is_nil(message_with("the rename changed"))
      if api.nvim_buf_is_valid(buf) then
        assert.are.equal("function M.helper()", api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      end
    end)

    it("sends the line of the cursor as an empty range for the code actions", function()
      open_lib()
      answers["textDocument/codeAction"] = {}
      local params = request(server, "lsp_code_action")
      assert.are.same({ line = 2, character = 11 }, params.range.start)
      assert.are.same(params.range.start, params.range["end"])
      assert.is_nil(params.position)
      assert.are.same({}, params.context.diagnostics)
    end)

    it("sends the diagnostics of the line with the request for the code actions", function()
      local _, buf = open_lib()
      server.publish(uri_of(fixture, "lib.lua"), {
        diagnostic(3, 11, 3, 17, "on the line"),
        diagnostic(8, 2, 8, 8, "on another line"),
      })
      wait_for(function()
        return #vim.diagnostic.get(buf) == 2
      end, "the buffer holds the diagnostics")
      answers["textDocument/codeAction"] = {}
      local params = request(server, "lsp_code_action")
      assert.are.equal(1, #params.context.diagnostics)
      assert.are.equal("on the line", params.context.diagnostics[1].message)
    end)

    it("runs a code action that is only a command", function()
      local _, buf = open_lib()
      answers["textDocument/codeAction"] = { { title = "run it", command = "fake.command", arguments = { "one" } } }
      answers.command_edit = { changes = { [uri_of(fixture, "lib.lua")] = { edit(4, 9, 10, "3") } } }
      lsp.run("lsp_code_action", {
        choose = function(items, cb)
          cb(items[1])
        end,
      })
      wait_for(function()
        return answers.executed ~= nil
      end, "the server runs the command")
      assert.are.equal("fake.command", answers.executed.command)
      assert.are.same({ "one" }, answers.executed.arguments)
      wait_for(function()
        return message_with("the code action changed 1 file") ~= nil
      end, "the code action reports the edit of its command")
      assert.are.equal("  return 3", api.nvim_buf_get_lines(buf, 3, 4, false)[1])
      forget_changes()
    end)

    it("runs the edit of a code action before its command", function()
      local _, buf = open_lib()
      local text_at_command
      answers["textDocument/codeAction"] = {
        {
          title = "both",
          edit = { changes = { [uri_of(fixture, "lib.lua")] = { edit(4, 9, 10, "3") } } },
          command = { title = "then", command = "fake.command" },
        },
      }
      lsp.run("lsp_code_action", {
        choose = function(items, cb)
          text_at_command = nil
          cb(items[1])
        end,
      })
      wait_for(function()
        if answers.executed and not text_at_command then
          text_at_command = api.nvim_buf_get_lines(buf, 3, 4, false)[1]
        end
        return text_at_command ~= nil
      end, "the server runs the command")
      assert.are.equal("  return 3", text_at_command)
      forget_changes()
    end)

    it("runs nothing when the user leaves the menu of the code actions", function()
      local _, buf = open_lib()
      answers["textDocument/codeAction"] = {
        { title = "edit", edit = { changes = { [uri_of(fixture, "lib.lua")] = { edit(4, 9, 10, "3") } } } },
        { title = "run it", command = "fake.command" },
      }
      local shown
      vim.ui.select = function(items, opts, on_choice)
        shown = { count = #items, prompt = opts.prompt, kind = opts.kind }
        on_choice(nil)
      end
      request(server, "lsp_code_action")
      wait_for(function()
        return shown ~= nil
      end, "the menu opens")
      assert.are.same({ count = 2, prompt = "Code actions:", kind = "codeaction" }, shown)
      vim.wait(50)
      assert.is_nil(answers.executed)
      assert.is_false(vim.bo[buf].modified)
      assert.are.same({}, messages)
    end)

    it("runs no code action when the session closed while the menu was open", function()
      local _, buf = open_lib()
      answers["textDocument/codeAction"] = {
        { title = "edit", edit = { changes = { [uri_of(fixture, "lib.lua")] = { edit(4, 9, 10, "3") } } } },
      }
      api.nvim_buf_set_lines(buf, 0, 0, false, {})
      local done = false
      vim.ui.select = function(items, _, on_choice)
        assert(opened):close()
        opened = nil
        on_choice(items[1])
        done = true
      end
      request(server, "lsp_code_action")
      wait_for(function()
        return done
      end, "the menu answers")
      if api.nvim_buf_is_valid(buf) then
        assert.are.equal("  return 2", api.nvim_buf_get_lines(buf, 3, 4, false)[1])
      end
    end)

    it("keeps the code action when the resolve request fails", function()
      local _, buf = open_lib({
        textDocumentSync = 1,
        codeActionProvider = { resolveProvider = true },
        executeCommandProvider = { commands = { "fake.command" } },
      })
      answers["textDocument/codeAction"] = { { title = "lazy", command = { title = "c", command = "fake.command" } } }
      answers["codeAction/resolve"] = function()
        return nil, { code = -32603, message = "boom" }
      end
      lsp.run("lsp_code_action", {
        choose = function(items, cb)
          cb(items[1])
        end,
      })
      wait_for(function()
        return answers.executed ~= nil
      end, "the server runs the command of the action")
      assert.is_false(vim.bo[buf].modified)
    end)

    it("sends the code action request from the old window of the split style", function()
      local state = open_lib()
      view.set_style("split")
      put(state, 3, "old", "helper")
      answers["textDocument/codeAction"] = {}
      local params = request(server, "lsp_code_action")
      assert.are.same({ line = 2, character = 11 }, params.range.start)
    end)

    if vim.fn.executable("jj") == 1 then
      describe("in a jj repository", function()
        ---@type tests.Fixture
        local jj
        ---@type integer
        local refreshes

        before_each(function()
          jj = keep(fixtures.jj())
          server = start_server(jj.root)
          refreshes = 0
          local refresh = view.refresh
          view.refresh = function(...)
            refreshes = refreshes + 1
            return refresh(...)
          end
        end)

        ---Open a.txt of a review, and rename in a.txt and in added.txt.
        ---@param spec string
        ---@return integer buf Buffer of a.txt.
        ---@return integer other Buffer of added.txt.
        local function rename_two(spec)
          local state = open_file(jj, "a.txt", spec)
          local buf = source_buf(state)
          assert.is_true(server.wait(buf))
          put(state, 1, "new", "one")
          answers["textDocument/rename"] = {
            changes = {
              [uri_of(jj, "a.txt")] = { edit(1, 0, 3, "ONE") },
              [uri_of(jj, "added.txt")] = { edit(1, 0, 5, "ADDED") },
            },
          }
          request(server, "lsp_rename", { name = "ONE" })
          wait_for(function()
            return message_with("the rename changed 2 files") ~= nil
          end, "the rename reports its change")
          return buf, vim.fn.bufnr(file_of(jj, "added.txt"))
        end

        it("reads the review of the working copy one time after a write of all files", function()
          local buf = rename_two("@")
          local message = assert(message_with("the rename changed 2 files"))
          assert.is_truthy(message:find("reads the working copy again after the write", 1, true), message)
          api.nvim_buf_call(buf, function()
            vim.cmd("silent wall")
          end)
          wait_for(function()
            local current = view.current()
            return current ~= nil and current.diff.new_lines[1] == "ONE"
          end, "the review holds the write")
          vim.wait(200)
          assert.are.equal(1, refreshes)
          -- The file that the rename changed outside the review is now part of it.
          assert.is_not_nil(assert(opened):index_of("added.txt"))
        end)

        it("sends a request again from the line of a rename after the write", function()
          local buf = rename_two("@")
          assert.is_false(lsp.run("lsp_definition"))
          api.nvim_buf_call(buf, function()
            vim.cmd("silent wall")
          end)
          wait_for(function()
            local current = view.current()
            return current ~= nil and current.diff.new_lines[1] == "ONE"
          end, "the review holds the write")
          put(assert(view.current()), 1, "new", "ONE")
          local params = request(server, "lsp_definition")
          assert.are.same({ line = 0, character = 0 }, params.position)
        end)

        it("reads the review again after each of two writes", function()
          local buf, other = rename_two("@")
          api.nvim_buf_call(buf, function()
            vim.cmd("silent write")
          end)
          wait_for(function()
            local current = view.current()
            return current ~= nil and current.diff.new_lines[1] == "ONE"
          end, "the review holds the first write")
          api.nvim_buf_call(other, function()
            vim.cmd("silent write")
          end)
          wait_for(function()
            return assert(opened):index_of("added.txt") ~= nil
          end, "the review holds the second write")
        end)

        it("keeps the diff of a review of another commit, and says so", function()
          local buf = rename_two(jj.ids.edit)
          local message = assert(message_with("the rename changed 2 files"))
          assert.is_truthy(message:find("its diff does not change", 1, true), message)
          assert.is_nil(message:find("reads the working copy again", 1, true), message)
          api.nvim_buf_call(buf, function()
            vim.cmd("silent wall")
          end)
          vim.wait(300)
          assert.are.equal(0, refreshes)
        end)

        it("keeps the diff of the working copy with `auto_reload` off, and says so", function()
          setup({ auto_reload = false })
          local buf = rename_two("@")
          local message = assert(message_with("the rename changed 2 files"))
          assert.is_truthy(message:find("its diff does not change", 1, true), message)
          api.nvim_buf_call(buf, function()
            vim.cmd("silent wall")
          end)
          vim.wait(300)
          assert.are.equal(0, refreshes)
        end)

        it("reads nothing after a write that comes after the session closed", function()
          local buf = rename_two("@")
          assert(opened):close()
          opened = nil
          assert.is_true(api.nvim_buf_is_valid(buf), "the buffer with the change stays")
          local ok, err = pcall(api.nvim_buf_call, buf, function()
            vim.cmd("silent wall")
          end)
          assert.is_true(ok, tostring(err))
          vim.wait(200)
          assert.are.equal(0, refreshes)
          assert.are.equal("ONE", vim.fn.readfile(file_of(jj, "a.txt"))[1])
        end)
      end)
    end
  end)

  describe("diagnostics", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup({ lsp = { enabled = true, diagnostics = true } })
      lsp = require("codeview.lsp")
    end)

    ---Open a file and wait for the server.
    ---@param made_fixture tests.Fixture
    ---@param path string
    ---@param side "old"|"new"?
    ---@return codeview.view.State state
    ---@return integer buf Hidden buffer of the file.
    local function open_with_server(made_fixture, path, side)
      fixture = made_fixture
      server = start_server(fixture.root)
      local state = open_file(fixture, path)
      local buf = source_buf(state, side)
      assert.is_true(server.wait(buf))
      return state, buf
    end

    ---Number of diagnostics of codeview in the buffers of a view.
    ---@param state codeview.view.State
    ---@return integer count
    local function shown(state)
      local count = #vim.diagnostic.get(state.buf, { namespace = lsp.ns })
      if state.old_buf and api.nvim_buf_is_valid(state.old_buf) then
        count = count + #vim.diagnostic.get(state.old_buf, { namespace = lsp.ns })
      end
      return count
    end

    ---Send diagnostics of one file, and wait until the diff shows a number of them.
    ---@param state codeview.view.State
    ---@param path string
    ---@param list table[]
    ---@param count integer
    local function publish(state, path, list, count)
      server.publish(uri_of(fixture, path), list)
      wait_for(function()
        return shown(state) == count
      end, string.format("the diff shows %d diagnostics, not %d", count, shown(state)))
    end

    it("keeps the diagnostics of the diff buffer on, so the reader sees them", function()
      local state = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      publish(state, "lib.lua", { diagnostic(3, 11, 3, 17, "on helper") }, 1)
      -- |codeview-lsp-diagnostics|: the diff shows it with the configuration
      -- of |vim.diagnostic|.
      assert.is_true(vim.diagnostic.is_enabled({ bufnr = state.buf }))
      assert.is_true(vim.diagnostic.is_enabled({ bufnr = state.buf, ns_id = lsp.ns }))
    end)

    it("reaches a diagnostic of the diff with a jump to the next diagnostic", function()
      local state = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      publish(state, "lib.lua", { diagnostic(8, 11, 8, 17, "on helper") }, 1)
      api.nvim_win_set_cursor(state.win, { 1, 0 })
      vim.diagnostic.jump({ count = 1, float = false })
      assert.are.equal(8, cursor_line())
      assert.are.equal("helper() + 1", at_cursor())
    end)

    it("moves a range of many lines to the rows of its first and last line", function()
      local state = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      publish(state, "lib.lua", { diagnostic(7, 0, 9, 3, "the whole function") }, 1)
      local first = row_of(state.map, 7, "new")
      local last = row_of(state.map, 9, "new")
      local item = assert(by_row(state.buf)[first])
      assert.are.equal(1, item.col)
      assert.are.equal(last - 1, item.end_lnum)
      assert.are.equal(4, item.end_col)
    end)

    it("ends a range at the end of its first row when the diff holds no row for its last line", function()
      local state, buf = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      -- The working copy changes line 9, the last line of the range.
      api.nvim_buf_set_lines(buf, 8, 9, false, { "end -- changed" })
      publish(state, "lib.lua", { diagnostic(7, 9, 9, 3, "the whole function") }, 1)
      local first = row_of(state.map, 7, "new")
      local item = assert(by_row(state.buf)[first])
      assert.are.equal(first - 1, item.end_lnum)
      assert.are.equal(#api.nvim_buf_get_lines(state.buf, first - 1, first, false)[1], item.end_col)
      vim.bo[buf].modified = false
    end)

    it("drops a range that starts inside a collapsed section", function()
      local state = open_with_server(keep(odd_fixture()), "long.lua")
      assert.is_nil(state.map:buf_row(2, "new"))
      publish(state, "long.lua", { diagnostic(2, 0, 30, 5, "long range"), diagnostic(30, 6, 30, 9, "seen") }, 1)
      view.expand_all()
      assert.are.equal(2, shown(state))
      view.collapse_all()
      assert.are.equal(1, shown(state))
    end)

    it("puts a diagnostic of a removed line on its row when the working copy holds the old side", function()
      local made_fixture = keep(fixtures.git_lsp())
      git(made_fixture, { "checkout", "--quiet", "--detach", made_fixture.ids.base })
      local state = open_with_server(made_fixture, "lib.lua", "old")
      publish(state, "lib.lua", { diagnostic(4, 9, 4, 10, "old value") }, 1)
      local row = row_of(state.map, 4, "old")
      local item = assert(by_row(state.buf)[row])
      assert.are.equal(10, item.col)
      assert.are.equal(11, item.end_col)
    end)

    it("puts a diagnostic of a removed line into the old buffer of the split style", function()
      local made_fixture = keep(fixtures.git_lsp())
      git(made_fixture, { "checkout", "--quiet", "--detach", made_fixture.ids.base })
      local state = open_with_server(made_fixture, "lib.lua", "old")
      view.set_style("split")
      -- Line 4 is a removed line. Line 7 of the base is line 11 of the new side.
      publish(state, "lib.lua", { diagnostic(4, 9, 4, 10, "old value"), diagnostic(7, 7, 7, 8, "context") }, 2)
      local old_row = row_of(state.old_map, 4, "old")
      local item = assert(by_row(state.old_buf --[[@as integer]])[old_row])
      assert.are.equal(9, item.col)
      local new_row = row_of(state.map, 11, "new")
      assert.are.equal(7, assert(by_row(state.buf)[new_row]).col)
    end)

    it("shows the diagnostics of a deleted file that the working copy still holds", function()
      local made_fixture = keep(fixtures.git_lsp())
      git(made_fixture, { "checkout", "--quiet", "--detach", made_fixture.ids.base })
      local state = open_with_server(made_fixture, "gone.lua", "old")
      publish(state, "gone.lua", { diagnostic(1, 7, 1, 13, "gone") }, 1)
      local row = row_of(state.map, 1, "old")
      assert.are.equal(8, assert(by_row(state.buf)[row]).col)
    end)

    it("keeps the diagnostics through two changes of the style", function()
      local state = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      publish(state, "lib.lua", { diagnostic(3, 11, 3, 17, "one"), diagnostic(8, 11, 8, 17, "two") }, 2)
      view.set_style("split")
      assert.are.equal(2, #vim.diagnostic.get(state.buf, { namespace = lsp.ns }))
      assert.are.equal(0, #vim.diagnostic.get(state.old_buf --[[@as integer]], { namespace = lsp.ns }))
      local row = row_of(state.map, 8, "new")
      assert.are.equal(11, assert(by_row(state.buf)[row]).col)
      view.set_style("inline")
      assert.are.equal(2, shown(state))
      row = row_of(state.map, 8, "new")
      assert.are.equal(12, assert(by_row(state.buf)[row]).col)
    end)

    it("removes the diagnostics after the server takes them back", function()
      local state = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      publish(state, "lib.lua", { diagnostic(3, 11, 3, 17, "one") }, 1)
      publish(state, "lib.lua", {}, 0)
    end)

    it("shows the diagnostics of the file of the view only", function()
      local state = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      publish(state, "lib.lua", { diagnostic(3, 11, 3, 17, "in lib") }, 1)
      local main = open_file(fixture, "main.lua")
      assert.is_true(server.wait(source_buf(main)))
      assert.are.equal(0, shown(main))
      -- New diagnostics of the file that the view left change nothing.
      server.publish(uri_of(fixture, "lib.lua"), { diagnostic(3, 11, 3, 17, "in lib"), diagnostic(8, 2, 8, 8, "more") })
      vim.wait(100)
      assert.are.equal(0, shown(main))
      -- The file shows its diagnostics again when it opens again.
      local again = open_file(fixture, "lib.lua")
      assert.are.equal(2, shown(again))
    end)

    it("counts the columns of a diagnostic behind an emoji in bytes", function()
      local state = open_with_server(keep(odd_fixture()), "uni.lua")
      publish(state, "uni.lua", { diagnostic(3, 20, 3, 24, "on name") }, 1)
      local row = row_of(state.map, 3, "new")
      local item = assert(by_row(state.buf)[row])
      local text = api.nvim_buf_get_lines(state.buf, row - 1, row, false)[1]
      assert.are.equal("name", text:sub(item.col + 1, item.end_col))
    end)

    it("puts a diagnostic of a file with CRLF line ends behind the marker", function()
      local state = open_with_server(keep(fixtures.git_lsp()), "crlf.txt")
      publish(state, "crlf.txt", { diagnostic(2, 4, 2, 11, "on changed") }, 1)
      local row = row_of(state.map, 2, "new")
      local item = assert(by_row(state.buf)[row])
      local text = api.nvim_buf_get_lines(state.buf, row - 1, row, false)[1]
      assert.are.equal("changed", text:sub(item.col + 1, item.end_col))
    end)

    it("draws three thousand diagnostics in less than a second", function()
      local state = open_with_server(keep(odd_fixture()), "long.lua")
      view.expand_all()
      local list = {}
      for index = 1, 3000 do
        local line = (index % 60) + 1
        list[index] = diagnostic(line, index % 5, line, 6, "number " .. index)
      end
      publish(state, "long.lua", list, 3000)
      local start = vim.uv.hrtime()
      lsp.draw_diagnostics(state)
      local elapsed = (vim.uv.hrtime() - start) / 1e6
      assert.is_true(elapsed < 1000, string.format("one draw took %.0f ms", elapsed))
    end)

    it("takes new diagnostics after the session closed with no error", function()
      local state, buf = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      publish(state, "lib.lua", { diagnostic(3, 11, 3, 17, "one") }, 1)
      -- A window keeps the file buffer, so the server keeps the document.
      vim.cmd("split")
      vim.cmd.buffer(buf)
      local diff_buf = state.buf
      assert(opened):close()
      opened = nil
      assert.is_false(api.nvim_buf_is_valid(diff_buf))
      server.publish(uri_of(fixture, "lib.lua"), { diagnostic(3, 11, 3, 17, "one"), diagnostic(8, 2, 8, 8, "two") })
      wait_for(function()
        return #vim.diagnostic.get(buf) == 2
      end, "the file buffer takes the diagnostics")
      vim.wait(50)
      assert.is_nil(message_with("Error"))
    end)

    it("shows nothing and loads no module with the diagnostics option but no LSP option", function()
      package.loaded["codeview.lsp"] = nil
      setup({ lsp = { enabled = false, diagnostics = true } })
      fixture = keep(fixtures.git_lsp())
      open_file(fixture, "lib.lua")
      assert.is_nil(package.loaded["codeview.lsp"])
      assert.are.equal(0, vim.fn.bufexists(file_of(fixture, "lib.lua")))
    end)

    it("mirrors a diagnostic that another source put on the file", function()
      local state, buf = open_with_server(keep(fixtures.git_lsp()), "lib.lua")
      local linter = api.nvim_create_namespace("codeview-edge-linter")
      vim.diagnostic.set(linter, buf, { { lnum = 7, col = 2, end_lnum = 7, end_col = 8, message = "from a linter" } })
      wait_for(function()
        return shown(state) == 1
      end, "the diff shows the diagnostic of the linter")
      local row = row_of(state.map, 8, "new")
      assert.are.equal("from a linter", assert(by_row(state.buf)[row]).message)
      vim.diagnostic.reset(linter, buf)
    end)
  end)

  describe("the layouts with the option on", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
    end)

    ---Run the map of a key of a buffer.
    ---@param buf integer
    ---@param lhs string Key, as `keytrans()` prints it.
    local function press(buf, lhs)
      for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
        if vim.fn.keytrans(map.lhs) == lhs then
          map.callback()
          return
        end
      end
      error("the buffer holds no map for " .. lhs)
    end

    it("keeps the keys of the sections, the styles, the comments, and the edit", function()
      local state = open_file(fixture, "lib.lua")
      local maps = maps_of(state.buf)
      local leader = vim.fn.keytrans(vim.g.mapleader)
      for _, lhs in ipairs({ "za", "zR", "zM", "gf", "q", "i", "o", leader .. "ct", leader .. "cc", leader .. "cR" }) do
        assert.is_truthy(vim.startswith(maps[lhs] or "", "codeview: "), "the key " .. lhs .. " is a codeview key")
        assert.is_nil((maps[lhs] or ""):find("LSP", 1, true), "the key " .. lhs .. " is no LSP key")
      end
    end)

    it("runs the comment float from its new key and sends no hover", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      local comments = require("codeview.comments")
      put(state, 3, "new")
      local shown = 0
      local show = comments.show
      comments.show = function(...)
        shown = shown + 1
        return show(...)
      end
      press(state.buf, vim.fn.keytrans(vim.g.mapleader) .. "ck")
      comments.show = show
      vim.wait(50)
      assert.are.same({}, server.calls("textDocument/hover"))
      assert.is_true(shown == 1 or #messages > 0, "the key runs the comment action")
    end)

    it("sends a hover from the K key", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      answers["textDocument/hover"] = { contents = "text of the hover" }
      press(state.buf, "K")
      wait_for(function()
        return #floats() == 1
      end, "the hover float opens")
    end)

    it("opens and closes the sections with a pending hover and no error", function()
      local odd = keep(odd_fixture())
      local odd_server = start_server(odd.root)
      local state = open_file(odd, "long.lua")
      assert.is_true(odd_server.wait(source_buf(state)))
      put(state, 30, "new", "v30")
      answers["textDocument/hover"] = { contents = "text of the hover" }
      assert.is_true(lsp.run("lsp_hover"))
      view.expand_all()
      view.collapse_all()
      wait_for(function()
        return #floats() == 1
      end, "the hover float opens")
      assert.are.equal(30, cursor_line())
    end)

    it("gives a note for an LSP key in the sidebar window", function()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      local bar = assert(require("codeview.sidebar").open({ session = assert(opened) }))
      local bar_win = bar.panel:window()
      assert.is_not_nil(bar_win)
      api.nvim_set_current_win(bar_win)
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_not_nil(message_with("the cursor is not in the diff"))
      assert.are.same({}, server.calls("textDocument/definition"))
    end)

    it("keeps the sidebar window when a jump opens a file outside the review", function()
      vim.fn.writefile({ "local other = 1" }, file_of(fixture, "other.lua"))
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      local bar = assert(require("codeview.sidebar").open({ session = assert(opened) }))
      api.nvim_set_current_win(state.win)
      put(state, 3, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "other.lua", 1, 6)
      request(server, "lsp_definition")
      wait_for(function()
        return vim.b.codeview_origin ~= nil
      end, "the file outside the review opens")
      local bar_win = bar.panel:window()
      assert.is_not_nil(bar_win)
      assert.is_true(api.nvim_win_is_valid(bar_win))
      assert.are_not.equal(bar_win, api.nvim_get_current_win())
    end)

    it("keeps the edit key and the back key", function()
      local state = open_file(fixture, "lib.lua")
      local buf = source_buf(state)
      put(state, 8, "new")
      assert.is_true(view.edit())
      assert.are.equal(buf, api.nvim_get_current_buf())
      assert.are.equal("lib.lua", vim.b[buf].codeview_file)
      assert.is_nil(vim.b[buf].codeview_origin)
      assert.are.equal(8, api.nvim_win_get_cursor(0)[1])
      api.nvim_win_set_cursor(0, { 3, 0 })
      assert.is_true(view.back())
      assert.are.equal("lib.lua", assert(view.current()).path)
      assert.are.equal(3, cursor_line())
    end)

    it("keeps the edit key and the back key in the split style", function()
      local state = open_file(fixture, "lib.lua")
      view.set_style("split")
      put(state, 8, "new")
      local old_win = state.old_win
      assert.is_true(view.edit())
      assert.is_false(api.nvim_win_is_valid(old_win))
      assert.are.equal("lib.lua", vim.b.codeview_file)
      assert.is_true(view.back())
      local current = assert(view.current())
      assert.are.equal("split", current.style)
      assert.are.equal(8, cursor_line())
    end)

    it("gives a note for a commit document and loads no file for it", function()
      setup({ commit_message = true })
      local session = open_session(fixture)
      local found = false
      for index, entry in ipairs(session.files) do
        if entry.virtual then
          found = true
          local state = assert(view.open(session, index))
          api.nvim_set_current_win(state.win)
          assert.is_false(lsp.run("lsp_hover"))
          assert.is_not_nil(message_with("this file has no lines for the language server"))
          assert.are.same({}, vim.diagnostic.get(state.buf, { namespace = lsp.ns }))
        end
      end
      assert.is_true(found, "the review holds a commit document")
      assert.are.same({}, lsp.owned(session))
    end)
  end)

  describe("races and the quickfix list", function()
    ---@type tests.Fixture
    local fixture
    ---@type tests.FakeLsp
    local server

    before_each(function()
      setup()
      lsp = require("codeview.lsp")
      fixture = keep(fixtures.git_lsp())
      server = start_server(fixture.root)
      vim.fn.writefile({ "local other = 1", "return other" }, file_of(fixture, "other.lua"))
    end)

    ---Open lib.lua with the cursor on `helper` of line 3.
    ---@return codeview.view.State
    local function open_lib()
      local state = open_file(fixture, "lib.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      return state
    end

    ---Run the back key and wait for its end.
    ---@return boolean opened
    local function back()
      local finished
      view.back(nil, function(ok)
        finished = ok
      end)
      wait_for(function()
        return finished ~= nil
      end, "the back key ends")
      return finished
    end

    ---Messages of the error level.
    ---@return string[]
    local function errors()
      return vim.tbl_filter(function(message)
        return message:lower():find("error", 1, true) ~= nil or message:find("E%d+:") ~= nil
      end, messages)
    end

    it("drops a jump whose answer comes after the session closed", function()
      open_lib()
      answers["textDocument/definition"] = location(fixture, "other.lua", 2, 7)
      assert.is_true(lsp.run("lsp_definition"))
      assert(opened):close()
      opened = nil
      local wins = #api.nvim_list_wins()
      wait_for(function()
        return #server.calls("textDocument/definition") == 1
      end, "the server got the request")
      vim.wait(100)
      assert.are.equal(wins, #api.nvim_list_wins())
      assert.are.equal(0, vim.fn.bufexists(file_of(fixture, "other.lua")))
      assert.are.same({}, errors())
    end)

    it("drops a hover whose answer comes after the session closed", function()
      open_lib()
      answers["textDocument/hover"] = { contents = "late" }
      assert.is_true(lsp.run("lsp_hover"))
      assert(opened):close()
      opened = nil
      vim.wait(100)
      assert.are.same({}, floats())
      assert.are.same({}, errors())
    end)

    it("drops a list whose answer comes after the view closed", function()
      open_lib()
      answers["textDocument/references"] = { location(fixture, "lib.lua", 3, 11), location(fixture, "main.lua", 3, 18) }
      assert.is_true(lsp.run("lsp_references"))
      view.close()
      vim.wait(100)
      assert.are.same({}, vim.fn.getqflist())
    end)

    it("lands only the answer of the last of two requests", function()
      local state = open_lib()
      local count = 0
      answers["textDocument/definition"] = function()
        count = count + 1
        return location(fixture, "lib.lua", count == 1 and 11 or 8, 0)
      end
      assert.is_true(lsp.run("lsp_definition"))
      assert.is_true(lsp.run("lsp_definition"))
      wait_for(function()
        return cursor_line() == 8
      end, "the cursor reached the target of the second request")
      vim.wait(50)
      assert.are.equal(8, cursor_line())
      assert.are.equal(state, view.current())
    end)

    it("does not land a jump after a hover that the reader asked for later", function()
      open_lib()
      answers["textDocument/definition"] = location(fixture, "lib.lua", 11, 0)
      answers["textDocument/hover"] = { contents = "text" }
      assert.is_true(lsp.run("lsp_definition"))
      assert.is_true(lsp.run("lsp_hover"))
      wait_for(function()
        return #floats() == 1
      end, "the hover float opens")
      assert.are.equal(3, cursor_line())
    end)

    it("reports no error when the session closes while the diff of a target loads", function()
      local state = open_file(fixture, "main.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      local landed = false
      local land = lsp.land
      lsp.land = function(...)
        land(...)
        -- The diff of lib.lua loads now. The reader closes the review.
        assert(opened):close()
        opened = nil
        landed = true
      end
      answers["textDocument/definition"] = location(fixture, "lib.lua", 3, 11)
      request(server, "lsp_definition")
      wait_for(function()
        return landed
      end, "the jump started")
      vim.wait(300)
      lsp.land = land
      assert.is_nil(view.current())
      assert.are.same({}, errors())
    end)

    it("shows the file that the reader opened while the diff of a target loaded", function()
      local state = open_file(fixture, "main.lua")
      assert.is_true(server.wait(source_buf(state)))
      put(state, 3, "new", "helper")
      local landed = false
      local land = lsp.land
      lsp.land = function(...)
        land(...)
        -- The diff of lib.lua loads now. The reader opens another file.
        view.open(
          assert(opened),
          assert(assert(opened):index_of("added.lua"), "the review holds added.lua"),
          nil,
          function() end
        )
        landed = true
      end
      answers["textDocument/definition"] = location(fixture, "lib.lua", 3, 11)
      request(server, "lsp_definition")
      wait_for(function()
        local current = view.current()
        return landed and current ~= nil and current.path == "added.lua"
      end, "the view shows the file of the reader")
      vim.wait(300)
      lsp.land = land
      assert.are.equal("added.lua", assert(view.current()).path)
      assert.are.same({}, errors())
    end)

    it("moves a file that Enter in the quickfix window opens into the window of the diff", function()
      local state = open_lib()
      answers["textDocument/references"] = {
        location(fixture, "other.lua", 2, 7),
        location(fixture, "main.lua", 3, 18),
        location(fixture, "lib.lua", 8, 11),
      }
      request(server, "lsp_references")
      wait_for(function()
        return #vim.fn.getqflist() == 3
      end, "the quickfix list holds the references")
      -- The cursor is in the quickfix window after the key. The reader
      -- presses Enter on the first entry.
      assert.are.equal("quickfix", vim.bo.buftype)
      local windows = #api.nvim_tabpage_list_wins(0)
      vim.cmd([[execute "normal! \<CR>"]])
      -- The file moves into the window of the diff after the jump.
      wait_for(function()
        return api.nvim_get_current_win() == state.win
      end, "the window of the diff takes the file")
      assert.are.equal(vim.uv.fs_realpath(file_of(fixture, "other.lua")), vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
      assert.are.equal(windows, #api.nvim_tabpage_list_wins(0), "the new window of the jump closed")
      -- |codeview-lsp-jump|: a file of the list takes the back key.
      assert.is_not_nil(maps_of(0)[vim.fn.keytrans(vim.g.mapleader) .. "cb"], "other.lua has the back key")
    end)

    it("opens the first entry of the list in the window of the diff, and the back key comes back", function()
      local state = open_lib()
      answers["textDocument/references"] = {
        location(fixture, "other.lua", 2, 7),
        location(fixture, "main.lua", 3, 18),
        location(fixture, "lib.lua", 8, 11),
      }
      request(server, "lsp_references")
      wait_for(function()
        return #vim.fn.getqflist() == 3
      end, "the quickfix list holds the references")
      api.nvim_set_current_win(state.win)
      vim.cmd("cfirst")
      assert.are.equal(state.win, api.nvim_get_current_win())
      assert.are.equal(vim.uv.fs_realpath(file_of(fixture, "other.lua")), vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
      assert.are.same({ path = "lib.lua", line = 3, side = "new" }, vim.b.codeview_origin)
      assert.is_not_nil(maps_of(0)[vim.fn.keytrans(vim.g.mapleader) .. "cb"])
      assert.is_true(back())
      assert.are.equal("lib.lua", assert(view.current()).path)
      assert.are.equal(3, cursor_line())
    end)

    it("gives the back key to each file that the list opens in the window", function()
      open_lib()
      answers["textDocument/references"] = {
        location(fixture, "other.lua", 2, 7),
        location(fixture, "main.lua", 3, 18),
        location(fixture, "lib.lua", 8, 11),
      }
      request(server, "lsp_references")
      wait_for(function()
        return #vim.fn.getqflist() == 3
      end, "the quickfix list holds the references")
      vim.cmd("wincmd p")
      vim.cmd("cfirst")
      local win = api.nvim_get_current_win()
      vim.cmd("cnext")
      assert.are.equal(win, api.nvim_get_current_win())
      assert.are.equal(vim.uv.fs_realpath(file_of(fixture, "main.lua")), vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
      assert.are.same({ 3, 18 }, api.nvim_win_get_cursor(0))
      assert.is_not_nil(maps_of(0)[vim.fn.keytrans(vim.g.mapleader) .. "cb"], "main.lua has the back key")
      -- A file of the review goes back to its own diff, on the line of the cursor.
      assert.is_true(back())
      assert.are.equal("main.lua", assert(view.current()).path)
      assert.are.equal(3, cursor_line())
    end)

    it("goes on in the list after the back key showed a diff again", function()
      open_lib()
      answers["textDocument/references"] = {
        location(fixture, "other.lua", 2, 7),
        location(fixture, "main.lua", 3, 18),
        location(fixture, "lib.lua", 8, 11),
      }
      request(server, "lsp_references")
      wait_for(function()
        return #vim.fn.getqflist() == 3
      end, "the quickfix list holds the references")
      vim.cmd("wincmd p")
      vim.cmd("cfirst")
      assert.is_true(back())
      local state = assert(view.current())
      api.nvim_set_current_win(state.win)
      vim.cmd("cnext")
      assert.are.equal(vim.uv.fs_realpath(file_of(fixture, "main.lua")), vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
      assert.is_not_nil(maps_of(0)[vim.fn.keytrans(vim.g.mapleader) .. "cb"], "main.lua has the back key")
      vim.cmd("cnext")
      assert.are.equal(vim.uv.fs_realpath(file_of(fixture, "lib.lua")), vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
      assert.is_true(back())
      assert.are.equal("lib.lua", assert(view.current()).path)
      assert.are.equal(8, cursor_line())
    end)

    ---Open a file of the list from one window of the split style, and go back.
    ---@param side "old"|"new" Side of the window that takes the file.
    local function list_jump_in_split(side)
      local state = open_lib()
      view.set_style("split")
      put(state, 3, side, "helper")
      local new_win, old_win = state.win, state.old_win
      local win = side == "old" and old_win or new_win
      local other = side == "old" and new_win or old_win
      answers["textDocument/references"] =
        { location(fixture, "other.lua", 2, 7), location(fixture, "main.lua", 3, 18) }
      request(server, "lsp_references")
      wait_for(function()
        return #vim.fn.getqflist() == 2
      end, "the quickfix list holds the references")
      api.nvim_set_current_win(win)
      vim.cmd("cfirst")
      assert.are.equal(win, api.nvim_get_current_win())
      assert.are.equal(vim.uv.fs_realpath(file_of(fixture, "other.lua")), vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
      assert.is_false(api.nvim_win_is_valid(other), "the window of the other side closed")
      assert.is_not_nil(vim.b.codeview_origin)
      assert.is_true(back())
      local current = view.current()
      assert.is_not_nil(current, "the view shows a diff again")
      ---@cast current codeview.view.State
      assert.are.equal("lib.lua", current.path)
      assert.are.equal("split", current.style)
      assert.is_true(api.nvim_win_is_valid(current.win), "the window of the new side is open")
      assert.is_not_nil(current.old_win)
      assert.is_true(api.nvim_win_is_valid(current.old_win), "the window of the old side is open")
    end

    it("shows both sides again after the list opened a file in the new window of the split style", function()
      list_jump_in_split("new")
    end)

    it("shows both sides again after the list opened a file in the old window of the split style", function()
      list_jump_in_split("old")
    end)

    it(
      "keeps the file of the user in the old window of the split style when the next file of the review opens",
      function()
        local state = open_lib()
        view.set_style("split")
        put(state, 3, "old", "helper")
        local file_win = state.old_win
        assert.is_not_nil(file_win)
        vim.cmd.edit(vim.fn.fnameescape(file_of(fixture, "other.lua")))
        local file_buf = api.nvim_get_current_buf()
        assert.are.equal(file_win, api.nvim_get_current_win())
        -- The reader opens the next file of the review, for example from the sidebar.
        vim.cmd("botright vnew")
        local finished = false
        view.open(
          assert(opened),
          assert(assert(opened):index_of("main.lua"), "the review holds main.lua"),
          nil,
          function()
            finished = true
          end
        )
        wait_for(function()
          return finished
        end, "the next file opens")
        assert.is_true(api.nvim_win_is_valid(file_win), "the window of the file stays")
        assert.are.equal(file_buf, api.nvim_win_get_buf(file_win))
      end
    )

    it("removes the back key of a file of the list when the session closes", function()
      open_lib()
      answers["textDocument/references"] =
        { location(fixture, "other.lua", 2, 7), location(fixture, "main.lua", 3, 18) }
      request(server, "lsp_references")
      wait_for(function()
        return #vim.fn.getqflist() == 2
      end, "the quickfix list holds the references")
      vim.cmd("wincmd p")
      vim.cmd("cfirst")
      local buf = api.nvim_get_current_buf()
      local win = api.nvim_get_current_win()
      assert(opened):close()
      opened = nil
      assert.is_true(api.nvim_win_is_valid(win), "the window of the file stays")
      assert.are.equal(buf, api.nvim_win_get_buf(win))
      assert.is_nil(vim.b[buf].codeview_origin)
      assert.is_nil(maps_of(buf)[vim.fn.keytrans(vim.g.mapleader) .. "cb"])
      -- The list still works after the close.
      vim.cmd("cnext")
      assert.is_nil(vim.b.codeview_origin)
      assert.are.same({}, errors())
    end)

    it("gives no back key to a file that the user opens in a window of their own", function()
      local state = open_lib()
      request(server, "lsp_hover")
      vim.cmd("botright new")
      vim.cmd.edit(vim.fn.fnameescape(file_of(fixture, "other.lua")))
      assert.is_nil(vim.b.codeview_origin)
      assert.is_nil(maps_of(0)[vim.fn.keytrans(vim.g.mapleader) .. "cb"])
      assert.are.equal(state, view.current())
      assert.are.equal(state.buf, api.nvim_win_get_buf(state.win))
      assert.is_nil(vim.w[state.win].codeview_released)
    end)

    it("gives no back key to a help window", function()
      local state = open_lib()
      request(server, "lsp_hover")
      vim.cmd("help help")
      assert.are.equal("help", vim.bo.buftype)
      assert.is_nil(vim.b.codeview_origin)
      vim.cmd("close")
      assert.are.equal(state, view.current())
    end)

    it("gives the back key to a file that the user opens in the window of the diff", function()
      local state = open_lib()
      put(state, 8, "new")
      vim.cmd.edit(vim.fn.fnameescape(file_of(fixture, "other.lua")))
      assert.are.same({ path = "lib.lua", line = 8, side = "new" }, vim.b.codeview_origin)
      assert.is_true(back())
      assert.are.equal("lib.lua", assert(view.current()).path)
      assert.are.equal(8, cursor_line())
    end)

    it("comes back with CTRL-O after a jump inside the diff", function()
      local state = open_lib()
      put(state, 8, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "lib.lua", 3, 11)
      request(server, "lsp_definition")
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3")
      vim.cmd([[execute "normal! \<C-o>"]])
      assert.are.equal(state.buf, api.nvim_get_current_buf())
      assert.are.equal(8, cursor_line())
    end)

    it("comes back to the line of the request after two jumps outside the review", function()
      vim.fn.writefile({ "local third = 3" }, file_of(fixture, "third.lua"))
      local state = open_lib()
      put(state, 8, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "other.lua", 2, 7)
      request(server, "lsp_definition")
      wait_for(function()
        return vim.b.codeview_origin ~= nil
      end, "the file outside the review opens")
      -- The reader goes on from the file with a jump of Neovim.
      vim.cmd.edit(vim.fn.fnameescape(file_of(fixture, "third.lua")))
      assert.are.same({ path = "lib.lua", line = 8, side = "new" }, vim.b.codeview_origin)
      assert.is_true(back())
      assert.are.equal("lib.lua", assert(view.current()).path)
      assert.are.equal(8, cursor_line())
    end)

    it("takes the place of the last request for the back key of a later jump", function()
      local state = open_lib()
      put(state, 8, "new", "helper")
      answers["textDocument/hover"] = { contents = "text" }
      request(server, "lsp_hover")
      put(state, 3, "new", "helper")
      answers["textDocument/definition"] = location(fixture, "other.lua", 2, 7)
      request(server, "lsp_definition")
      wait_for(function()
        return vim.b.codeview_origin ~= nil
      end, "the file outside the review opens")
      assert.are.same({ path = "lib.lua", line = 3, side = "new" }, vim.b.codeview_origin)
    end)
  end)
end)
