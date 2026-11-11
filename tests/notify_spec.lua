local helpers = require("tests.helpers")

describe("codeview.notify", function()
  local notify, config
  local real_notify
  ---@type { message: string, level: integer }[]
  local seen

  before_each(function()
    helpers.unload()
    notify = require("codeview.notify")
    config = require("codeview.config")
    seen = {}
    real_notify = vim.notify
    vim.notify = function(message, level) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = { message = message, level = level }
    end
  end)

  after_each(function()
    vim.notify = real_notify
    helpers.unload()
  end)

  it("puts the name of the plugin in front of the message", function()
    notify.error("the diff failed")
    assert.are.same({ { message = "codeview: the diff failed", level = vim.log.levels.ERROR } }, seen)
  end)

  it("drops a message below the log_level option", function()
    assert(config.setup({ log_level = vim.log.levels.WARN }))
    notify.info("no hunk after this one")
    notify.notify("a debug line", vim.log.levels.DEBUG)
    notify.warn("the reload failed")
    notify.error("the open failed")
    assert.are.same({
      { message = "codeview: the reload failed", level = vim.log.levels.WARN },
      { message = "codeview: the open failed", level = vim.log.levels.ERROR },
    }, seen)
  end)

  it("shows every message at a low log_level", function()
    assert(config.setup({ log_level = vim.log.levels.DEBUG }))
    notify.notify("a debug line", vim.log.levels.DEBUG)
    notify.notify("no hunk after this one")
    assert.are.same({
      { message = "codeview: a debug line", level = vim.log.levels.DEBUG },
      { message = "codeview: no hunk after this one", level = vim.log.levels.INFO },
    }, seen)
  end)

  it("reads the log_level option at the time of the call", function()
    assert(config.setup({ log_level = vim.log.levels.ERROR }))
    notify.warn("first")
    assert(config.setup({ log_level = vim.log.levels.WARN }))
    notify.warn("second")
    assert.are.same({ { message = "codeview: second", level = vim.log.levels.WARN } }, seen)
  end)

  describe("background", function()
    after_each(function()
      for _, win in ipairs(notify.popups()) do
        pcall(vim.api.nvim_win_close, win, true)
      end
    end)

    ---Text of the message history.
    ---@return string
    local function history()
      return vim.api.nvim_exec2("messages", { output = true }).output
    end

    it("shows a popup in the top-right corner when vim.notify is the default one", function()
      vim.notify = real_notify
      assert.is_true(notify.default_notify())
      local before = vim.api.nvim_get_current_win()
      notify.background("PR #12 changed on GitHub: the review reloads with head 0123abcd")

      local wins = notify.popups()
      assert.are.equal(1, #wins)
      local win_config = vim.api.nvim_win_get_config(wins[1])
      assert.are.equal("editor", win_config.relative)
      assert.are.equal(0, win_config.row)
      assert.are.equal(vim.o.columns, win_config.col)
      assert.is_false(win_config.focusable)
      assert.are.equal(before, vim.api.nvim_get_current_win())
      assert.are.same(
        { "codeview: PR #12 changed on GitHub: the review reloads with head 0123abcd" },
        vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[1]), 0, -1, false)
      )
      assert.are.same({}, seen)
    end)

    it("stacks the popups and closes each one by itself", function()
      vim.notify = real_notify
      notify.popup_ms = { info = 50, warn = 150 }
      notify.background("first")
      notify.background("second", vim.log.levels.WARN)
      local wins = notify.popups()
      assert.are.equal(2, #wins)
      assert.is_true(vim.api.nvim_win_get_config(wins[2]).row > vim.api.nvim_win_get_config(wins[1]).row)

      assert.is_true(vim.wait(1000, function()
        return #notify.popups() == 1
      end, 10))
      -- The warning moves up into the place of the first popup.
      assert.are.equal(0, vim.api.nvim_win_get_config(notify.popups()[1]).row)
      assert.is_true(vim.wait(1000, function()
        return #notify.popups() == 0
      end, 10))
    end)

    it("sends the message to vim.notify when a plugin replaced it", function()
      assert.is_false(notify.default_notify())
      notify.background("the check of PR #12 failed: HTTP 502", vim.log.levels.WARN)
      assert.are.same(
        { { message = "codeview: the check of PR #12 failed: HTTP 502", level = vim.log.levels.WARN } },
        seen
      )
      assert.are.same({}, notify.popups())
    end)

    it("never writes to the command line, so a long message gives no hit-enter prompt", function()
      vim.notify = real_notify
      local before = history()
      local long = string.rep("a very long message ", 30)
      notify.background(long, vim.log.levels.WARN)
      assert.are.equal(before, history())
      assert.are.equal("n", vim.api.nvim_get_mode().mode)
      assert.are.equal(1, #notify.popups())
    end)

    it("drops a message below the log_level option", function()
      vim.notify = real_notify
      assert(config.setup({ log_level = vim.log.levels.WARN }))
      notify.background("updated to the new base")
      assert.are.same({}, notify.popups())
    end)
  end)

  it("calls the vim.notify of the time of the call", function()
    local later = {}
    vim.notify = function(message) ---@diagnostic disable-line: duplicate-set-field
      later[#later + 1] = message
    end
    notify.error("late")
    assert.are.same({}, seen)
    assert.are.same({ "codeview: late" }, later)
  end)
end)
