local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.export", function()
  local fixture = fixtures.git_comments()
  local command, comments, config, events, export, session_mod, view
  ---@type string
  local dir
  ---@type codeview.Session?
  local opened

  ---Text of the range of the fixture.
  ---@return string
  local function spec()
    return fixture.ids.base .. ".." .. fixture.ids.change
  end

  ---Short commit id, as the export shows it.
  ---@param rev string
  ---@return string
  local function short(rev)
    return rev:sub(1, 8)
  end

  ---Open a review session for the fixture range.
  ---@return codeview.Session
  local function open_session()
    if opened then
      return opened
    end
    local review, err = session_mod.open(spec(), { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Add one comment to the store of the session.
  ---@param fields table Fields of the comment. `file` and `body` are needed.
  ---@return codeview.store.Comment
  local function add_comment(fields)
    local store = assert(comments.store(open_session()))
    local comment = assert(store:add(vim.tbl_extend("keep", fields, {
      side = "new",
      commit = fixture.ids.change,
      body = "a note",
    })))
    assert.is_true(store:save())
    return comment
  end

  ---Delete the scratch buffers of the export.
  local function wipe_buffers()
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf):match("export%.md$") then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = fixtures.tempdir("codeview-export")
    assert(config.setup({ comments = { dir = dir }, export = { register = "z" } }))
    command = require("codeview.command")
    comments = require("codeview.comments")
    events = require("codeview.events")
    export = require("codeview.export")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    vim.fn.setreg("z", "")
  end)

  after_each(function()
    wipe_buffers()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    events.clear()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  describe("the data", function()
    it("needs a session", function()
      local data, err = export.data()
      assert.is_nil(data)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("reads the session, the range, and the counts", function()
      local review = open_session()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      add_comment({ file = "tail.txt", start_line = 40, end_line = 40, state = "resolved" })

      local data = assert(export.data())
      assert.are.equal(review, data.session)
      assert.are.equal(spec(), data.spec)
      assert.are.equal(short(fixture.ids.base) .. ".." .. short(fixture.ids.change), data.range)
      assert.are.equal(fixture.root, data.repo)
      assert.are.equal(2, data.count)
      assert.are.equal(1, data.resolved)
      assert.are.equal(2, #data.files)
    end)

    it("groups the comments by file, in the order of the sidebar", function()
      add_comment({ file = "tail.txt", start_line = 40, end_line = 40 })
      add_comment({ file = "call.lua", start_line = 2, end_line = 2 })

      local data = assert(export.data())
      assert.are.same(
        { "call.lua", "tail.txt" },
        vim.tbl_map(function(file)
          return file.path
        end, data.files)
      )
      assert.is_true(data.files[1].changed)
    end)

    it("orders the comments of one file by line", function()
      add_comment({ file = "call.lua", start_line = 3, end_line = 4, body = "third" })
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "first" })
      add_comment({ file = "call.lua", start_line = 2, end_line = 2, side = "old", body = "second" })

      local data = assert(export.data())
      assert.are.same(
        { "first", "second", "third" },
        vim.tbl_map(function(comment)
          return comment.body
        end, data.comments)
      )
    end)

    it("keeps a comment on a file that the range does not change", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      add_comment({ file = "gone.txt", start_line = 2, end_line = 2 })

      local data = assert(export.data())
      assert.are.equal(2, #data.files)
      assert.are.equal("gone.txt", data.files[2].path)
      assert.is_false(data.files[2].changed)
    end)
  end)

  describe("the default template", function()
    it("renders every comment with its file, lines, side, and commit", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "the first note" })
      add_comment({
        file = "call.lua",
        start_line = 2,
        end_line = 3,
        side = "old",
        commit = fixture.ids.base,
        state = "resolved",
        body = "two lines",
      })
      add_comment({ file = "tail.txt", start_line = 40, end_line = 40, body = "a tail note" })

      local text = assert(export.render())
      local expected = table.concat({
        "# codeview review: " .. spec(),
        "",
        "- range: `" .. short(fixture.ids.base) .. ".." .. short(fixture.ids.change) .. "`",
        "- commits: 1",
        "- comments: 3 on 2 files, 1 resolved",
        "",
        "## call.lua",
        "",
        "### L1 · new · " .. short(fixture.ids.change),
        "",
        "the first note",
        "",
        "### L2-3 · old · " .. short(fixture.ids.base) .. " · resolved",
        "",
        "two lines",
        "",
        "## tail.txt",
        "",
        "### L40 · new · " .. short(fixture.ids.change),
        "",
        "a tail note",
        "",
      }, "\n")
      assert.are.equal(expected, text)
    end)

    it("reports a session without comments", function()
      open_session()
      local text = assert(export.render())
      assert.are.equal(
        table.concat({
          "# codeview review: " .. spec(),
          "",
          "- range: `" .. short(fixture.ids.base) .. ".." .. short(fixture.ids.change) .. "`",
          "- commits: 1",
          "- comments: 0",
          "",
          "No comments.",
          "",
        }, "\n"),
        text
      )
    end)

    it("keeps every line of a body", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "one\n\ntwo\n- three" })
      local text = assert(export.render())
      assert.is_truthy(text:find("one\n\ntwo\n- three\n", 1, true))
    end)

    it("marks a file that the range does not change", function()
      add_comment({ file = "gone.txt", start_line = 1, end_line = 1 })
      local text = assert(export.render())
      assert.is_truthy(text:find("## gone.txt (outside the range)", 1, true))
    end)
  end)

  describe("the template option", function()
    it("takes the function of the configuration", function()
      assert(config.setup({
        comments = { dir = dir },
        export = {
          register = "z",
          template = function(session, data)
            return string.format("%s has %d comments", session:label(), data.count)
          end,
        },
      }))
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })

      assert.are.equal(spec() .. " has 1 comments", assert(export.render()))
    end)

    it("falls back to the default template when the function fails", function()
      assert(config.setup({
        comments = { dir = dir },
        export = {
          register = "z",
          template = function()
            error("no")
          end,
        },
      }))
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })

      local text = assert(export.render())
      assert.is_truthy(text:find("# codeview review: ", 1, true))
    end)

    it("falls back to the default template for a value that is not a text", function()
      assert(config.setup({
        comments = { dir = dir },
        export = {
          register = "z",
          template = function()
            return 42
          end,
        },
      }))
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })

      local text = assert(export.render())
      assert.is_truthy(text:find("# codeview review: ", 1, true))
    end)
  end)

  describe("run", function()
    it("needs a session", function()
      local result, err = export.run()
      assert.is_nil(result)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("writes the register of the configuration", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local result = assert(export.run({ buffer = false, notify = false }))
      assert.are.equal("z", result.register)
      assert.are.equal(1, result.count)
      assert.are.equal(result.text, vim.fn.getreg("z"))
      assert.are.equal("V", vim.fn.getregtype("z"))
      assert.is_nil(result.buf)
    end)

    it("takes the register of the call", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local result = assert(export.run({ buffer = false, notify = false, register = "c" }))
      assert.are.equal("c", result.register)
      assert.are.equal(result.text, vim.fn.getreg("c"))
      assert.are.equal("", vim.fn.getreg("z"))
    end)

    it("writes no register for a name of more than one character", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      vim.fn.setreg("r", "a macro")
      local messages = {}
      local notify = vim.notify
      vim.notify = function(message)
        messages[#messages + 1] = message
      end
      local result = assert(export.run({ buffer = false, register = "reg" }))
      vim.notify = notify

      assert.is_nil(result.register)
      assert.are.equal("a macro", vim.fn.getreg("r"))
      assert.is_truthy(table.concat(messages, "\n"):find("not a register name: reg", 1, true))
    end)

    it("reports the clipboard register without a provider", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local provider = vim.g.clipboard
      vim.g.clipboard = nil
      local result = assert(export.run({ buffer = false, notify = false, register = "+" }))
      vim.g.clipboard = provider

      if vim.fn.has("clipboard") == 1 then
        assert.are.equal("+", result.register)
      else
        assert.is_nil(result.register)
      end
    end)

    it("writes no register for false", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local result = assert(export.run({ buffer = false, notify = false, register = false }))
      assert.is_nil(result.register)
      assert.are.equal("", vim.fn.getreg("z"))
    end)

    it("shows the text in a scratch buffer", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1, body = "the note" })
      local result = assert(export.run({ notify = false }))
      local buf = assert(result.buf)

      assert.is_true(api.nvim_buf_is_valid(buf))
      assert.are.equal("markdown", vim.bo[buf].filetype)
      assert.are.equal("nofile", vim.bo[buf].buftype)
      assert.is_false(vim.bo[buf].modifiable)
      assert.are.equal(result.text, table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n")
      local win = assert(result.win)
      assert.is_true(api.nvim_win_is_valid(win))
      assert.are.equal(buf, api.nvim_win_get_buf(win))
    end)

    it("keeps one export buffer per session", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local first = assert(export.run({ notify = false }))
      local second = assert(export.run({ notify = false }))
      local old_buf = assert(first.buf)
      local new_buf = assert(second.buf)
      assert.is_false(api.nvim_buf_is_valid(old_buf))
      assert.is_true(api.nvim_buf_is_valid(new_buf))

      local names = 0
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf):match("export%.md$") then
          names = names + 1
        end
      end
      assert.are.equal(1, names)
    end)

    it("closes the export window and buffer with the session", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local before = #api.nvim_tabpage_list_wins(0)
      local result = assert(export.run({ notify = false }))
      local buf = assert(result.buf)
      local win = assert(result.win)
      assert.are.equal(before + 1, #api.nvim_tabpage_list_wins(0))

      local review = open_session()
      review:close()
      opened = nil

      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_false(api.nvim_buf_is_valid(buf))
      assert.are.equal(before, #api.nvim_tabpage_list_wins(0))
    end)

    it("closes the export window with the close key", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local result = assert(export.run({ notify = false }))
      local win = assert(result.win)
      api.nvim_set_current_win(win)
      api.nvim_feedkeys(api.nvim_replace_termcodes("q", true, false, true), "x", false)
      assert.is_false(api.nvim_win_is_valid(win))
    end)
  end)

  describe(":CodeViewExport", function()
    it("reports a run without a session", function()
      local messages = {}
      local notify = vim.notify
      vim.notify = function(message)
        messages[#messages + 1] = message
      end
      local result = command.export({})
      vim.notify = notify

      assert.is_nil(result)
      assert.is_truthy(table.concat(messages, "\n"):find("no review session", 1, true))
    end)

    it("exports into the register of the argument", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local result = assert(command.export({ args = "c" }))
      assert.are.equal("c", result.register)
      assert.are.equal(result.text, vim.fn.getreg("c"))
      assert.is_truthy(result.buf)
    end)

    it("completes the register of the argument with the lead", function()
      local res = helpers.clean_nvim(
        'print(#vim.fn.getcompletion("CodeViewExport ", "cmdline"), vim.inspect(vim.fn.getcompletion("CodeViewExport z", "cmdline")))'
      )
      assert.are.equal(0, res.code)
      assert.is_truthy(res.output:find('{ "z" }', 1, true), res.output)
      assert.is_falsy(res.output:find("1 {", 1, true), res.output)
    end)

    it("opens no buffer after a bang", function()
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })
      local result = assert(command.export({ bang = true }))
      assert.is_nil(result.buf)
      assert.are.equal(result.text, vim.fn.getreg("z"))
    end)
  end)

  describe("the public API", function()
    it("exports through the plugin table", function()
      local codeview = require("codeview")
      add_comment({ file = "call.lua", start_line = 1, end_line = 1 })

      local text = assert(codeview.export_text())
      assert.is_truthy(text:find("# codeview review: ", 1, true))

      local result = assert(codeview.export({ buffer = false, notify = false }))
      assert.are.equal(text, result.text)
    end)
  end)

  it("leaves no windows behind", function()
    assert.are.equal(1, #api.nvim_tabpage_list_wins(0))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
