-- The comment editor: the send key.

local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.editor", function()
  local config, editor

  ---Text of one key, after the leader and the termcodes.
  ---@param lhs string
  ---@return string
  local function normal(lhs)
    local text = (lhs:gsub("<[lL]eader>", vim.g.mapleader or "\\"))
    return vim.fn.keytrans(api.nvim_replace_termcodes(text, true, true, true))
  end

  ---Text of the footer of a window.
  ---@param win integer
  ---@return string
  local function footer_text(win)
    local footer = api.nvim_win_get_config(win).footer
    if type(footer) == "string" then
      return footer
    end
    local out = {}
    for _, chunk in ipairs(footer or {}) do
      out[#out + 1] = type(chunk) == "string" and chunk or chunk[1]
    end
    return table.concat(out)
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    editor = require("codeview.editor")
    config.reset()
  end)

  after_each(function()
    editor.cancel()
    helpers.unload()
  end)

  it("sends the body to the send handler and closes", function()
    local saved = false
    ---@type string?
    local sent = nil
    local buf = editor.open({
      on_save = function()
        saved = true
      end,
      on_send = function(body)
        sent = body
      end,
    })
    api.nvim_buf_set_lines(buf, 0, -1, false, { "send me" })

    assert.is_true(editor.send())
    assert.are.equal("send me", sent)
    assert.is_false(saved)
    assert.is_false(editor.is_open())
  end)

  it("keeps the editor open without a send handler", function()
    local buf = editor.open({ on_save = function() end })
    api.nvim_buf_set_lines(buf, 0, -1, false, { "a note" })

    local said = {}
    local notify = vim.notify
    vim.notify = function(message)
      said[#said + 1] = message
    end
    local sent = editor.send()
    vim.notify = notify

    assert.is_false(sent)
    assert.is_true(editor.is_open())
    assert.is_true(vim.iter(said):any(function(message)
      return message:find("no pull request", 1, true) ~= nil
    end))
  end)

  it("keeps an empty comment open", function()
    local ran = false
    editor.open({
      on_save = function() end,
      on_send = function()
        ran = true
      end,
    })

    assert.is_false(editor.send())
    assert.is_true(editor.is_open())
    assert.is_false(ran)
  end)

  it("names the send key in the footer", function()
    config.setup({ comments = { editor = "float" } })
    local hints = require("codeview.hints")

    local _, win = editor.open({ on_save = function() end, on_send = function() end })
    local text = footer_text(win)
    assert.is_truthy(text:find("sends", 1, true))
    assert.is_truthy(text:find(hints.key_text("<leader>cs"), 1, true))

    local _, plain = editor.open({ on_save = function() end })
    assert.is_nil(footer_text(plain):find("sends", 1, true))
  end)

  describe("a second open", function()
    ---Replace `vim.fn.confirm` with a fixed answer.
    ---@param answer integer
    ---@return table calls Number of questions in `calls.count`.
    local function answer_with(answer)
      local calls = { count = 0 }
      local confirm = vim.fn.confirm
      vim.fn.confirm = function()
        calls.count = calls.count + 1
        return answer
      end
      calls.restore = function()
        vim.fn.confirm = confirm
      end
      return calls
    end

    it("keeps a changed comment on no", function()
      local cancelled = false
      local first = editor.open({
        on_save = function() end,
        on_cancel = function()
          cancelled = true
        end,
      })
      api.nvim_buf_set_lines(first, 0, -1, false, { "typed text" })

      local calls = answer_with(2)
      local buf, win = editor.open({ on_save = function() end })
      calls.restore()

      assert.are.equal(1, calls.count)
      assert.is_nil(buf)
      assert.is_nil(win)
      assert.are.equal(first, assert(editor.current()).buf)
      assert.are.equal("typed text", editor.body())
      assert.is_false(cancelled)
    end)

    it("discards a changed comment on yes", function()
      local cancelled = false
      local first = editor.open({
        on_save = function() end,
        on_cancel = function()
          cancelled = true
        end,
      })
      api.nvim_buf_set_lines(first, 0, -1, false, { "typed text" })

      local calls = answer_with(1)
      local buf = editor.open({ on_save = function() end })
      calls.restore()

      assert.are.equal(1, calls.count)
      assert.are.equal(buf, assert(editor.current()).buf)
      assert.is_false(api.nvim_buf_is_valid(first))
      assert.are.equal("", editor.body())
      assert.is_true(cancelled)
    end)

    it("asks nothing for an unchanged comment", function()
      local first = editor.open({ on_save = function() end, text = "a note" })

      local calls = answer_with(2)
      local buf = editor.open({ on_save = function() end })
      calls.restore()

      assert.are.equal(0, calls.count)
      assert.are.equal(buf, assert(editor.current()).buf)
      assert.is_false(api.nvim_buf_is_valid(first))
    end)
  end)

  describe("the spacer", function()
    local ns = api.nvim_create_namespace("codeview.editor")

    ---Show a buffer of three lines in the current window, and open an inline
    ---editor under its second row.
    ---@return integer diff Buffer under the editor.
    ---@return integer win Window of the editor.
    local function open_inline()
      local diff = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(diff, 0, -1, false, { "one", "two", "three" })
      local host = api.nvim_get_current_win()
      api.nvim_win_set_buf(host, diff)
      local _, win = editor.open({
        on_save = function() end,
        anchor = { win = host, buf = diff, row = 2 },
      })
      assert.are.equal("inline", assert(editor.current()).style)
      assert.are.equal(1, #api.nvim_buf_get_extmarks(diff, ns, 0, -1, {}))
      return diff, win
    end

    ---Press keys in the window that has the focus.
    ---@param lhs string
    local function press(lhs)
      api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
    end

    for _, case in ipairs({
      {
        name = ":q",
        run = function()
          vim.cmd.quit()
        end,
      },
      {
        name = ":q!",
        run = function(win)
          api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, -1, false, { "never saved" })
          vim.cmd("quit!")
        end,
      },
      {
        name = "<C-w>c",
        run = function()
          press("<C-w>c")
        end,
      },
      {
        name = "ZZ without a change",
        run = function()
          press("ZZ")
        end,
      },
      {
        -- A mouse close and the close of another plugin take this path.
        name = "a close from outside the editor",
        run = function(win)
          api.nvim_win_close(win, false)
        end,
      },
    }) do
      it("goes away after " .. case.name, function()
        local diff, win = open_inline()
        case.run(win)

        assert.is_false(api.nvim_win_is_valid(win))
        assert.is_false(editor.is_open())
        assert.are.equal(0, #api.nvim_buf_get_extmarks(diff, ns, 0, -1, {}))
        api.nvim_buf_delete(diff, { force = true })
      end)
    end
  end)

  it("maps the send key in the editor", function()
    local buf = editor.open({ on_save = function() end })

    local found = false
    for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
      if type(map.desc) == "string" and map.desc:find("^codeview: ") then
        if normal(map.lhs) == normal("<leader>cs") then
          found = true
        end
      end
    end
    assert.is_true(found)
  end)
end)
