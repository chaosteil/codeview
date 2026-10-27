local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

---Collect the notifications of one call.
---@param fn fun()
---@return { msg: string, level: integer }[]
local function capture_notify(fn)
  local seen = {}
  local notify = vim.notify
  vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
    seen[#seen + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert.is_true(ok, tostring(err))
  return seen
end

describe(":Codeview reopen", function()
  local fixture = fixtures.git()
  local spec = fixture.ids.init .. ".." .. fixture.ids.shuffle
  local command, session, view, sidebar, overview

  ---Run the reopen and wait until the restore ends.
  ---@return codeview.Session? session
  ---@return codeview.Error? err
  local function reopen()
    local out, finished = {}, false
    command.reopen(function(review, err)
      out.session, out.err, finished = review, err, true
    end)
    assert.is_true(
      vim.wait(20000, function()
        return finished
      end, 10),
      "the reopen did not answer"
    )
    return out.session, out.err
  end

  before_each(function()
    helpers.unload()
    require("codeview.config").setup({ commit_message = false })
    command = require("codeview.command")
    session = require("codeview.session")
    view = require("codeview.view")
    sidebar = require("codeview.sidebar")
    overview = require("codeview.overview")
  end)

  after_each(function()
    session.close()
    helpers.unload()
  end)

  it("opens the same file, line, style, and panels again", function()
    local opened = assert(session.open(spec, { dir = fixture.dir }))
    local bar = assert(sidebar.open({ session = opened }))
    assert.is_true(bar:toggle_node(bar.tree.children[1]))
    assert(overview.open({ session = opened }))
    assert(view.open(opened, assert(opened:index_of("a.txt"))))
    view.set_style("split")
    view.go_to_line(4, "new")

    opened:close()
    -- The next file takes the inline style again, so the reopen must set the
    -- split style itself.
    view.set_style("inline")

    local review, err = reopen()
    assert.is_nil(err)
    review = assert(review)
    assert.are_not.equal(opened, review)
    assert.are.equal(spec, review.input)

    local state = assert(view.current())
    assert.are.equal(review, state.session)
    assert.are.equal("a.txt", state.path)
    assert.are.equal(4, view.cursor_line(state))
    assert.are.equal("split", state.style)
    assert.is_true(sidebar.is_open())
    assert.are.same({ dir = false }, assert(sidebar.get()).expanded)
    assert.is_true(overview.is_open())
  end)

  it("warns without a closed session", function()
    local seen = capture_notify(function()
      command.reopen()
    end)
    assert.are.equal(1, #seen)
    assert.are.equal(vim.log.levels.WARN, seen[1].level)
    assert.is_truthy(seen[1].msg:find("no closed session", 1, true), seen[1].msg)
    assert.is_nil(session.current())
  end)

  it("warns while a session is open", function()
    assert(session.open(spec, { dir = fixture.dir })):close()
    local opened = assert(session.open(fixture.ids.edit, { dir = fixture.dir }))

    local seen = capture_notify(function()
      command.reopen()
    end)
    assert.are.equal(1, #seen)
    assert.are.equal(vim.log.levels.WARN, seen[1].level)
    assert.is_truthy(seen[1].msg:find("a session is open, close it first", 1, true), seen[1].msg)
    assert.are.equal(opened, session.current())
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
