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
