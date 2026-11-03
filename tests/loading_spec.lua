local helpers = require("tests.helpers")

describe("codeview.loading", function()
  local loading
  ---@type codeview.loading.View?
  local view

  local steps = {
    { key = "one", text = "do the first step" },
    { key = "two", text = "do the second step" },
  }

  ---Lines of the buffer of the view, without the left padding.
  ---@return string[]
  local function lines()
    local out = {}
    for i, line in ipairs(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)) do
      out[i] = line:gsub("^  ", "")
    end
    return out
  end

  before_each(function()
    helpers.unload()
    loading = require("codeview.loading")
    view = nil
  end)

  after_each(function()
    if view then
      view:close()
    end
    helpers.unload()
  end)

  it("opens a float with the title and the pending steps, without the cursor", function()
    local before = vim.api.nvim_get_current_win()
    view = loading.open({ title = "PR #12", steps = steps })
    assert.is_true(vim.api.nvim_win_is_valid(view.win))
    assert.are.equal("editor", vim.api.nvim_win_get_config(view.win).relative)
    assert.are.equal(before, vim.api.nvim_get_current_win())
    assert.are.same({ "PR #12", "", "· do the first step", "· do the second step" }, lines())
  end)

  it("marks the running step with the spinner and the ended steps with a check", function()
    view = loading.open({ title = "PR #12", steps = steps })
    view:start("one")
    assert.are.equal(loading.frames[1] .. " do the first step", lines()[3])
    view:start("two")
    assert.are.equal("✓ do the first step", lines()[3])
    assert.are.equal(loading.frames[1] .. " do the second step", lines()[4])
    view:set_title("PR #12 Add the feature")
    assert.are.equal("PR #12 Add the feature", lines()[1])
  end)

  it("turns the spinner while a step runs", function()
    view = loading.open({ title = "PR #12", steps = steps })
    view:start("one")
    assert.is_true(
      vim.wait(1000, function()
        return lines()[3] ~= loading.frames[1] .. " do the first step"
      end, 10),
      "the spinner did not move"
    )
  end)

  it("shows an error, takes the cursor, and closes on q", function()
    view = loading.open({ title = "PR #12", steps = steps })
    view:start("one")
    view:fail("cannot fetch pull request 12 from origin")
    assert.are.same({
      "PR #12",
      "",
      "✗ do the first step",
      "· do the second step",
      "",
      "cannot fetch pull request 12 from origin",
      "",
      "q closes this window",
    }, lines())
    assert.is_nil(view.timer, "the spinner stops")
    assert.are.equal(view.win, vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_true(view.closed)
    assert.is_false(vim.api.nvim_win_is_valid(view.win))
  end)

  it("wraps a text at spaces, and cuts a word that is wider than a line", function()
    assert.are.same({ "one two", "three" }, loading.wrap("one two three", 8))
    assert.are.same({ "abcd", "efgh", "ij" }, loading.wrap("abcdefghij", 4))
    assert.are.same({ "a", "", "b" }, loading.wrap("a\n\nb", 10))
  end)

  it("wraps a long error, so the close hint stays in the float", function()
    view = loading.open({ title = "PR #12", steps = steps })
    view:start("one")
    view:fail(string.rep("word ", 100))
    local shown = lines()
    assert.are.equal("q closes this window", shown[#shown])
    assert.are.equal(#shown, vim.api.nvim_win_get_height(view.win))
    for _, line in ipairs(shown) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= vim.o.columns - 6, line)
    end
  end)

  it("closes once, and ignores the calls after the close", function()
    view = loading.open({ title = "PR #12", steps = steps })
    local closes = 0
    view.on_close = function()
      closes = closes + 1
    end
    view:start("one")
    view:close()
    view:close()
    assert.are.equal(1, closes, "the close handler runs once")
    view:start("two")
    view:fail("too late")
    assert.is_nil(view.timer)
    assert.is_nil(view.error)
  end)
end)
