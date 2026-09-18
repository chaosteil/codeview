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
