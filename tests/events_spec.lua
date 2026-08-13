local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.events", function()
  local events

  before_each(function()
    helpers.unload()
    events = require("codeview.events")
  end)

  after_each(function()
    events.clear()
    helpers.unload()
  end)

  it("names a User autocmd for every comment event", function()
    assert.are.same({ "comment_added", "comment_changed", "comment_deleted", "review_submitted" }, events.comment)
    for _, name in ipairs(events.comment) do
      assert.is_truthy(events.autocmds[name])
    end
  end)

  it("calls the handler of one event", function()
    local seen = {}
    events.on("comment_added", function(data, name)
      seen[#seen + 1] = { data = data, name = name }
    end)

    assert.are.equal(1, events.emit("comment_added", { id = "a1", file = "one.lua" }))
    assert.are.equal(0, events.emit("comment_deleted", { id = "a1" }))

    assert.are.equal(1, #seen)
    assert.are.equal("comment_added", seen[1].name)
    assert.are.equal("one.lua", seen[1].data.file)
  end)

  it("takes a list of events for one handler", function()
    local count = 0
    events.on(events.comment, function()
      count = count + 1
    end)
    for _, name in ipairs(events.comment) do
      events.emit(name)
    end
    assert.are.equal(#events.comment, count)
  end)

  it("drops a subscription", function()
    local count = 0
    local id = events.on("comment_changed", function()
      count = count + 1
    end)
    events.emit("comment_changed")
    assert.is_true(events.off(id))
    events.emit("comment_changed")
    assert.are.equal(1, count)
    assert.is_false(events.off(id))
  end)

  it("keeps the other handlers after an error", function()
    local count = 0
    events.on("comment_added", function()
      error("this handler fails")
    end)
    events.on("comment_added", function()
      count = count + 1
    end)

    local notify = vim.notify
    vim.notify = function() end
    local ran = events.emit("comment_added")
    vim.notify = notify

    assert.are.equal(2, ran)
    assert.are.equal(1, count)
  end)

  it("runs a User autocmd with the payload", function()
    local seen
    local group = api.nvim_create_augroup("codeview.tests.events", { clear = true })
    api.nvim_create_autocmd("User", {
      group = group,
      pattern = "CodeViewCommentDeleted",
      callback = function(event)
        seen = event.data
      end,
    })

    events.emit("comment_deleted", { id = "b2", file = "two.lua", session = 7 })
    api.nvim_del_augroup_by_id(group)

    assert.are.equal("b2", seen.id)
    assert.are.equal("two.lua", seen.file)
    assert.are.equal(7, seen.session)
  end)

  it("clears every subscription", function()
    local count = 0
    events.on(events.comment, function()
      count = count + 1
    end)
    events.clear()
    events.emit("comment_added")
    assert.are.equal(0, count)
  end)
end)
