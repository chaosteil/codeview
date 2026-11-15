-- Tests of the LSP keys of the diff view.
--
-- A language server in the test process answers the requests. It attaches to
-- the files of the working copy, the same way as the configuration of a user
-- does: on the FileType event of a buffer below the root.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview lsp keys", function()
  local fixture = fixtures.git_lsp()
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
  ---Answer of the next location request. A function gets the parameters.
  ---@type any
  local answer

  ---@param path string
  ---@return string uri
  local function uri_of(path)
    return helpers.real_uri(vim.fs.joinpath(fixture.root, path))
  end

  ---Location in a file of the fixture.
  ---@param path string
  ---@param line integer Line from 1.
  ---@param character integer
  ---@return table location
  local function location(path, line, character)
    local position = { line = line - 1, character = character }
    return { uri = uri_of(path), range = { start = position, ["end"] = position } }
  end

  ---@param params table
  ---@return any
  local function reply(params)
    if type(answer) == "function" then
      return answer(params)
    end
    return answer
  end

  ---Configure the plugin.
  ---@param enabled boolean Value of `lsp.enabled`.
  local function setup(enabled)
    assert(config.setup({
      commit_message = false,
      comments = { dir = store_dir },
      sidebar = { auto_open = false },
      lsp = { enabled = enabled },
    }))
  end

  ---Open one file of the review, with the cursor on a line of one side.
  ---@param path string
  ---@param line integer?
  ---@param side "old"|"new"?
  ---@return codeview.view.State
  local function open_file(path, line, side)
    if not opened then
      local session, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
      assert.is_nil(err)
      opened = assert(session)
    end
    local index = assert(opened:index_of(path), "the review holds " .. path)
    local state = assert(view.open(opened, index))
    api.nvim_set_current_win(state.win)
    if line then
      view.go_to_line(line, side or "new", { focus = true })
    end
    return state
  end

  ---Hidden buffer of the working copy for the new side of a view.
  ---@param state codeview.view.State
  ---@return integer buf
  local function source_buf(state)
    local source = lsp.sources(state).new
    assert.is_not_nil(source, "the view has a source")
    return source.buf
  end

  ---Wait for a condition.
  ---@param fn fun(): boolean
  ---@param what string
  local function wait_for(fn, what)
    assert.is_true(vim.wait(2000, fn, 10), what)
  end

  ---Line of the new side under the cursor of the view.
  ---@return integer? line
  local function cursor_line()
    local state = view.current()
    if not state then
      return nil
    end
    local row = api.nvim_win_get_cursor(api.nvim_get_current_win())[1]
    local map = api.nvim_get_current_win() == state.old_win and state.old_map or state.map
    return map:row(row) and map:row(row).new
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    store_dir = fixtures.tempdir("codeview-lsp-view-store")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    answer = nil
    messages = {}
    notify = vim.notify
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    server = helpers.fake_lsp({
      root = fixture.root,
      handlers = {
        ["textDocument/definition"] = reply,
        ["textDocument/declaration"] = reply,
        ["textDocument/typeDefinition"] = reply,
        ["textDocument/implementation"] = reply,
        ["textDocument/references"] = reply,
        ["textDocument/hover"] = reply,
      },
    })
    server.attach_on_filetype()
  end)

  after_each(function()
    vim.notify = notify
    pcall(vim.cmd, "cclose")
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
      local name = api.nvim_buf_get_name(buf)
      local real_root = vim.uv.fs_realpath(fixture.root) or fixture.root
      if vim.startswith(vim.uv.fs_realpath(name) or name, real_root) then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
    -- Only one window stays, so the next test starts from a clean layout.
    vim.cmd("silent! only")
    if store_dir then
      vim.fn.delete(store_dir, "rf")
    end
    store_dir = nil
    vim.fn.setqflist({}, "r")
    config.reset()
    helpers.unload()
  end)

  describe("with the option off", function()
    before_each(function()
      setup(false)
    end)

    it("loads no file and maps no LSP key", function()
      local state = open_file("lib.lua")
      assert.is_nil(package.loaded["codeview.lsp"], "the module does not load")
      local file = vim.fs.joinpath(fixture.root, "lib.lua")
      assert.are.equal(0, vim.fn.bufexists(file))
      local maps = {}
      for _, map in ipairs(api.nvim_buf_get_keymap(state.buf, "n")) do
        maps[vim.fn.keytrans(map.lhs)] = map.desc
      end
      assert.are.equal("codeview: show the comment", maps["K"])
      assert.is_nil(maps["gd"])
      assert.is_nil(maps["grr"])
      local text = table.concat(vim.tbl_map(function(chunk)
        return chunk.text
      end, require("codeview.hints").chunks("view", nil)))
      assert.is_truthy(text:find("K read comment", 1, true))
      assert.is_nil(text:find("definition", 1, true))
    end)
  end)

  describe("with the option on", function()
    before_each(function()
      setup(true)
      lsp = require("codeview.lsp")
    end)

    it("loads the file of the working copy and attaches the server to it", function()
      local state = open_file("lib.lua")
      local buf = source_buf(state)
      assert.is_true(server.wait(buf), "the server serves the file")
      assert.is_not_nil(server.docs[uri_of("lib.lua")], "the server holds the text of the file")
      -- No client attaches to the diff buffer itself.
      assert.are.same({}, vim.lsp.get_clients({ bufnr = state.buf }))
    end)

    it("moves K to the hover and the comment float to another key", function()
      local state = open_file("lib.lua")
      local maps = {}
      for _, map in ipairs(api.nvim_buf_get_keymap(state.buf, "n")) do
        maps[vim.fn.keytrans(map.lhs)] = map.desc
      end
      assert.are.equal("codeview: LSP hover", maps["K"])
      assert.are.equal("codeview: show the comment", maps[vim.fn.keytrans(vim.g.mapleader .. "ck")])
      assert.are.equal("codeview: LSP definition", maps["gd"])
      assert.are.equal("codeview: LSP declaration", maps["gD"])
      assert.are.equal("codeview: LSP type definition", maps["grt"])
      assert.are.equal("codeview: LSP implementation", maps["gri"])
      assert.are.equal("codeview: LSP references", maps["grr"])
    end)

    it("names the LSP keys in the hint row", function()
      local text = table.concat(vim.tbl_map(function(chunk)
        return chunk.text
      end, require("codeview.hints").chunks("view", nil)))
      assert.is_truthy(text:find("gd definition", 1, true))
      assert.is_truthy(text:find("K hover", 1, true))
      assert.is_truthy(text:find("<space>ck read comment", 1, true))
      assert.is_nil(text:find("K read comment", 1, true))
    end)

    it("sends the position of the working copy without the marker column", function()
      local state = open_file("lib.lua", 8)
      assert.is_true(server.wait(source_buf(state)))
      -- `  return M.helper() + 1`: the cursor on `helper`.
      local row = api.nvim_win_get_cursor(state.win)[1]
      api.nvim_win_set_cursor(state.win, { row, 12 })
      answer = location("lib.lua", 3, 11)
      assert.is_true(lsp.run("lsp_definition"))
      wait_for(function()
        return #server.calls("textDocument/definition") == 1
      end, "the server got the request")
      local params = server.calls("textDocument/definition")[1]
      assert.are.equal(uri_of("lib.lua"), params.textDocument.uri)
      assert.are.same({ line = 7, character = 11 }, params.position)
    end)

    it("jumps inside the diff to a definition in the same file", function()
      local state = open_file("lib.lua", 8)
      assert.is_true(server.wait(source_buf(state)))
      answer = location("lib.lua", 3, 11)
      assert.is_true(lsp.run("lsp_definition"))
      wait_for(function()
        return cursor_line() == 3
      end, "the cursor reached line 3")
      assert.are.equal(state, view.current())
      local cursor = api.nvim_win_get_cursor(state.win)
      -- The inline marker takes one byte in front of the line.
      assert.are.equal(12, cursor[2])
      -- The jump list holds the place of the request.
      local jumps = vim.fn.getjumplist()
      assert.is_true(#jumps[1] > 0)
    end)

    it("opens the diff of another file of the review", function()
      local state = open_file("main.lua", 3)
      assert.is_true(server.wait(source_buf(state)))
      answer = location("lib.lua", 3, 11)
      assert.is_true(lsp.run("lsp_definition"))
      wait_for(function()
        local current = view.current()
        return current ~= nil and current.path == "lib.lua" and cursor_line() == 3
      end, "the view shows line 3 of lib.lua")
    end)

    it("opens a file outside the review, and the back key comes back", function()
      local other = vim.fs.joinpath(fixture.root, "other.lua")
      vim.fn.writefile({ "local other = 1", "return other" }, other)
      local state = open_file("main.lua", 4)
      assert.is_true(server.wait(source_buf(state)))
      answer = location("other.lua", 2, 7)
      assert.is_true(lsp.run("lsp_definition"))
      wait_for(function()
        return vim.uv.fs_realpath(api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(other)
      end, "the window shows other.lua")
      assert.are.same({ 2, 7 }, api.nvim_win_get_cursor(0))
      local buf = api.nvim_get_current_buf()
      assert.are.same({ path = "main.lua", line = 4, side = "new" }, vim.b[buf].codeview_origin)
      assert.is_nil(vim.b[buf].codeview_file)

      local back
      view.back(nil, function(ok)
        back = ok
      end)
      wait_for(function()
        return back ~= nil
      end, "the back key ends")
      assert.is_true(back)
      assert.are.equal("main.lua", assert(view.current()).path)
      assert.are.equal(4, cursor_line())
    end)

    it("puts the references into the quickfix list", function()
      local state = open_file("lib.lua", 3)
      assert.is_true(server.wait(source_buf(state)))
      answer = function(params)
        assert.are.same({ includeDeclaration = true }, params.context)
        return { location("lib.lua", 3, 11), location("main.lua", 3, 18), location("lib.lua", 3, 11) }
      end
      assert.is_true(lsp.run("lsp_references"))
      wait_for(function()
        return #vim.fn.getqflist() > 0
      end, "the quickfix list holds the references")
      local list = vim.fn.getqflist({ title = 1, items = 1 })
      assert.are.equal("codeview: references", list.title)
      assert.are.equal(2, #list.items, "the list drops a location that two answers hold")
    end)

    it("gives the back key to a file that the quickfix list opens", function()
      local state = open_file("lib.lua", 3)
      assert.is_true(server.wait(source_buf(state)))
      local other = vim.fs.joinpath(fixture.root, "other.lua")
      vim.fn.writefile({ "local other = 1" }, other)
      answer = { location("other.lua", 1, 6), location("main.lua", 3, 18) }
      assert.is_true(lsp.run("lsp_definition"))
      wait_for(function()
        return #vim.fn.getqflist() == 2
      end, "two definitions go to the quickfix list")
      -- The first entry opens in the window of the diff.
      vim.cmd("wincmd p")
      vim.cmd("cfirst")
      local buf = api.nvim_get_current_buf()
      local win = api.nvim_get_current_win()
      assert.are.equal(vim.uv.fs_realpath(other), vim.uv.fs_realpath(api.nvim_buf_get_name(buf)))
      assert.are.equal("lib.lua", vim.b[buf].codeview_origin.path)
      assert.is_false(vim.tbl_contains(opened.windows, win), "the window left the session")
    end)

    it("shows the hover text in a float", function()
      local state = open_file("lib.lua", 3)
      assert.is_true(server.wait(source_buf(state)))
      answer = { contents = { kind = "markdown", value = "helper docs" } }
      assert.is_true(lsp.run("lsp_hover"))
      local float
      wait_for(function()
        for _, win in ipairs(api.nvim_list_wins()) do
          if api.nvim_win_get_config(win).relative ~= "" then
            float = win
          end
        end
        return float ~= nil
      end, "the hover float opens")
      local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(float), 0, -1, false)
      assert.is_truthy(table.concat(lines, "\n"):find("helper docs", 1, true))
      pcall(api.nvim_win_close, float, true)
    end)

    it("reports a request without a server", function()
      server.stop()
      local state = open_file("lib.lua", 3)
      assert.are.same({}, vim.lsp.get_clients({ bufnr = source_buf(state) }))
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_truthy(messages[#messages]:find("no language server is attached to lib.lua", 1, true))
    end)

    it("reports a removed line", function()
      local state = open_file("lib.lua", 4, "old")
      assert.is_true(server.wait(source_buf(state)))
      assert.is_false(lsp.run("lsp_definition"))
      assert.is_truthy(messages[#messages]:find("does not hold this line", 1, true))
      assert.are.same({}, server.calls("textDocument/definition"))
    end)

    it("opens the real file when the working copy changed the target line", function()
      local state = open_file("lib.lua", 8)
      local buf = source_buf(state)
      assert.is_true(server.wait(buf))
      -- The working copy changes line 3, the line of the definition.
      api.nvim_buf_set_lines(buf, 2, 3, false, { "function M.helper(changed)" })
      answer = location("lib.lua", 3, 11)
      assert.is_true(lsp.run("lsp_definition"))
      wait_for(function()
        return api.nvim_get_current_buf() == buf
      end, "the window shows the file of the working copy")
      assert.are.same({ 3, 11 }, api.nvim_win_get_cursor(0))
      -- The note about the working copy came once.
      local notes = vim.tbl_filter(function(message)
        return message:find("differs from the review", 1, true) ~= nil
      end, messages)
      assert.are.equal(1, #notes)
      vim.bo[buf].modified = false
    end)

    it("drops an answer that comes after the view changed", function()
      local state = open_file("lib.lua", 8)
      assert.is_true(server.wait(source_buf(state)))
      answer = location("lib.lua", 3, 11)
      assert.is_true(lsp.run("lsp_definition"))
      -- The next file opens before the answer comes.
      open_file("main.lua", 1)
      vim.wait(100)
      local current = assert(view.current())
      assert.are.equal("main.lua", current.path)
      assert.are.equal(1, cursor_line())
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
  end)
end)
