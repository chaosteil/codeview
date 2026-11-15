-- Tests of the LSP edits of the diff view: rename and code actions.
--
-- An edit changes the buffers of the working copy and writes no file. A
-- review of a revision keeps its diff. A review of the jj commit `@` reads
-- itself again after the write.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview lsp edits", function()
  local config, lsp, session_mod, view
  ---@type codeview.Session?
  local opened
  ---@type string?
  local store_dir
  ---@type tests.FakeLsp?
  local server
  ---@type string[]
  local messages
  local notify
  ---@type table<string, any>
  local answers

  ---@param fixture tests.Fixture
  ---@param path string
  ---@return string uri
  local function uri_of(fixture, path)
    return helpers.real_uri(vim.fs.joinpath(fixture.root, path))
  end

  ---Text edit that replaces part of one line.
  ---@param line integer Line from 1.
  ---@param first integer Character of the start.
  ---@param last integer Character of the end.
  ---@param text string
  ---@return table edit
  local function edit(line, first, last, text)
    return {
      range = { start = { line = line - 1, character = first }, ["end"] = { line = line - 1, character = last } },
      newText = text,
    }
  end

  ---Start the server of a fixture.
  ---@param fixture tests.Fixture
  ---@param filetypes string[]
  local function start_server(fixture, filetypes)
    server = helpers.fake_lsp({
      root = fixture.root,
      filetypes = filetypes,
      handlers = {
        ["textDocument/rename"] = function(params)
          return type(answers.rename) == "function" and answers.rename(params) or answers.rename
        end,
        ["textDocument/codeAction"] = function(params)
          return type(answers.code_action) == "function" and answers.code_action(params) or answers.code_action
        end,
        ["codeAction/resolve"] = function(params)
          return answers.resolve and answers.resolve(params) or params
        end,
        ["workspace/executeCommand"] = function(params, fake)
          answers.executed = params
          if answers.command_edit then
            fake.dispatchers.server_request("workspace/applyEdit", { edit = answers.command_edit })
          end
          return vim.NIL
        end,
      },
      capabilities = {
        textDocumentSync = 1,
        renameProvider = true,
        codeActionProvider = { resolveProvider = true },
        executeCommandProvider = { commands = { "fake.command" } },
      },
    })
    server.attach_on_filetype()
  end

  ---Open a file of a review, with the cursor on a line of the new side.
  ---@param spec string
  ---@param dir string
  ---@param path string
  ---@param line integer
  ---@return codeview.view.State
  local function open_file(spec, dir, path, line)
    local session, err = session_mod.open(spec, { dir = dir })
    assert.is_nil(err)
    opened = assert(session)
    local state = assert(view.open(opened, assert(opened:index_of(path))))
    api.nvim_set_current_win(state.win)
    view.go_to_line(line, "new", { focus = true })
    return state
  end

  ---@param state codeview.view.State
  ---@return integer buf
  local function source_buf(state)
    local source = lsp.sources(state).new
    assert.is_not_nil(source)
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

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    store_dir = fixtures.tempdir("codeview-lsp-edit-store")
    assert(config.setup({
      commit_message = false,
      comments = { dir = store_dir },
      sidebar = { auto_open = false },
      lsp = { enabled = true },
    }))
    lsp = require("codeview.lsp")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    answers = {}
    messages = {}
    notify = vim.notify
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
  end)

  after_each(function()
    vim.notify = notify
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    if server then
      server.stop()
    end
    server = nil
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= "" then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.cmd("silent! only")
    if store_dir then
      vim.fn.delete(store_dir, "rf")
    end
    store_dir = nil
    config.reset()
    helpers.unload()
  end)

  describe("in a review of a revision", function()
    local fixture = fixtures.git_lsp()
    local spec = fixture.ids.base .. ".." .. fixture.ids.change

    before_each(function()
      start_server(fixture, { "lua" })
    end)

    it("renames in the buffers of the working copy and keeps the diff", function()
      local state = open_file(spec, fixture.dir, "lib.lua", 3)
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      local row = api.nvim_win_get_cursor(state.win)[1]
      -- `function M.helper()`: the cursor on `helper`, after the marker.
      api.nvim_win_set_cursor(state.win, { row, 13 })
      answers.rename = function(params)
        assert.are.equal("assist", params.newName)
        assert.are.same({ line = 2, character = 12 }, params.position)
        return {
          changes = {
            [uri_of(fixture, "lib.lua")] = { edit(3, 11, 17, "assist") },
            [uri_of(fixture, "main.lua")] = { edit(3, 18, 24, "assist") },
          },
        }
      end
      local diff = state.diff
      assert.is_true(lsp.run("lsp_rename", { name = "assist" }))
      wait_for(function()
        return message_with("the rename changed") ~= nil
      end, "the rename reports its change")

      assert.are.equal("function M.assist()", api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.is_true(vim.bo[buf].modified)
      assert.is_true(vim.bo[buf].buflisted, "a changed buffer is listed")
      local main = vim.fn.bufadd(vim.fs.joinpath(fixture.root, "main.lua"))
      assert.are.equal("local value = lib.assist()", api.nvim_buf_get_lines(main, 2, 3, false)[1])
      -- The files on disk keep their text.
      assert.are.equal("function M.helper()", vim.fn.readfile(vim.fs.joinpath(fixture.root, "lib.lua"))[3])

      local message = assert(message_with("the rename changed"))
      assert.is_truthy(message:find("2 files", 1, true), message)
      assert.is_truthy(message:find("lib.lua, main.lua", 1, true), message)
      assert.is_truthy(message:find("its diff does not change", 1, true), message)
      assert.are.equal(diff, assert(view.current()).diff, "the diff stays")

      -- The renamed line now differs from the review, so it sends no request.
      assert.is_false(lsp.run("lsp_rename", { name = "other" }))
      assert.is_truthy(message_with("does not hold this line"))

      -- The buffers with changes stay after the close.
      view.close()
      opened:close()
      opened = nil
      assert.is_true(api.nvim_buf_is_valid(buf))
      assert.is_true(vim.bo[buf].modified)
    end)

    it("takes the word under the cursor as the start of the new name", function()
      assert.are.equal("helper", lsp.word_at("function M.helper()", 13))
      assert.are.equal("helper", lsp.word_at("function M.helper()", 11))
      assert.are.equal("", lsp.word_at("a  b", 1))
    end)

    it("reports a failed rename", function()
      local state = open_file(spec, fixture.dir, "lib.lua", 3)
      assert.is_true(server.wait(source_buf(state)))
      answers.rename = vim.NIL
      assert.is_true(lsp.run("lsp_rename", { name = "assist" }))
      wait_for(function()
        return message_with("gave no rename") ~= nil
      end, "the rename reports no edit")
      assert.is_false(vim.bo[source_buf(state)].modified)
    end)

    it("runs the edit of the chosen code action", function()
      local state = open_file(spec, fixture.dir, "lib.lua", 4)
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      answers.code_action = function(params)
        assert.are.same({ line = 3, character = 0 }, params.range.start)
        assert.are.equal(1, params.context.triggerKind)
        return {
          { title = "Return three", edit = { changes = { [uri_of(fixture, "lib.lua")] = { edit(4, 9, 10, "3") } } } },
          { title = "Other" },
        }
      end
      local titles
      assert.is_true(lsp.run("lsp_code_action", {
        choose = function(items, cb)
          titles = vim.tbl_map(function(item)
            return item.action.title
          end, items)
          cb(items[1])
        end,
      }))
      wait_for(function()
        return message_with("the code action changed") ~= nil
      end, "the code action reports its change")
      assert.are.same({ "Return three", "Other" }, titles)
      assert.are.equal("  return 3", api.nvim_buf_get_lines(buf, 3, 4, false)[1])
    end)

    it("resolves a code action without an edit, and runs its command", function()
      local state = open_file(spec, fixture.dir, "lib.lua", 4)
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      answers.code_action = { { title = "Lazy", data = { id = 1 } } }
      answers.resolve = function(params)
        assert.are.same({ id = 1 }, params.data)
        return {
          title = "Lazy",
          command = { title = "Lazy", command = "fake.command", arguments = { 7 } },
        }
      end
      answers.command_edit = { changes = { [uri_of(fixture, "lib.lua")] = { edit(4, 9, 10, "9") } } }
      assert.is_true(lsp.run("lsp_code_action", {
        choose = function(items, cb)
          cb(items[1])
        end,
      }))
      wait_for(function()
        return message_with("the code action changed") ~= nil
      end, "the command reports its change")
      assert.are.same({ 7 }, answers.executed.arguments)
      assert.are.equal("  return 9", api.nvim_buf_get_lines(buf, 3, 4, false)[1])
    end)

    it("reports a line with no code action", function()
      local state = open_file(spec, fixture.dir, "lib.lua", 4)
      assert.is_true(server.wait(source_buf(state)))
      answers.code_action = {}
      assert.is_true(lsp.run("lsp_code_action", {
        choose = function()
          error("no menu without an action")
        end,
      }))
      wait_for(function()
        return message_with("no code action for this line") ~= nil
      end, "the note comes")
    end)

    it("removes the fixture", function()
      fixture.cleanup()
    end)
  end)

  if vim.fn.executable("jj") == 1 then
    describe("in a review of the jj working copy", function()
      ---@type tests.Fixture
      local fixture

      before_each(function()
        fixture = fixtures.jj()
        start_server(fixture, { "text" })
      end)

      after_each(function()
        fixture.cleanup()
      end)

      it("reads the review again after the write of a rename", function()
        local state = open_file("@", fixture.dir, "a.txt", 5)
        local buf = source_buf(state)
        assert.is_true(server.wait(buf))
        local head = assert(opened).range.to
        answers.rename = { changes = { [uri_of(fixture, "a.txt")] = { edit(5, 0, 4, "FIVE") } } }
        assert.is_true(lsp.run("lsp_rename", { name = "FIVE" }))
        wait_for(function()
          return message_with("the rename changed") ~= nil
        end, "the rename reports its change")
        local message = assert(message_with("the rename changed"))
        assert.is_truthy(message:find("reads the working copy again after the write", 1, true), message)

        api.nvim_buf_call(buf, function()
          vim.cmd("silent write")
        end)
        wait_for(function()
          local current = view.current()
          return assert(opened).range.to ~= head and current ~= nil and current.diff.new_lines[5] == "FIVE"
        end, "the review holds the write")
      end)
    end)
  end
end)
