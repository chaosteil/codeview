-- Performance guards for a large review range.
--
-- The budgets are generous. They do not measure the speed of a machine: they
-- catch a change that makes the cost grow with the square of the input again.
-- The numbers of the reference machine are in the comment of each test.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview performance", function()
  local fixture = fixtures.git_large({ files = 400, lines = 8000 })
  local config, diff, inline, sidebar, session_mod, view
  ---@type codeview.Session?
  local opened

  ---Time of one call, in milliseconds.
  ---@param fn fun(): any
  ---@return number ms
  ---@return any value
  local function took(fn)
    local start = vim.uv.hrtime()
    local value = fn()
    return (vim.uv.hrtime() - start) / 1e6, value
  end

  ---Open a session for the range of the fixture.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Text of a file that changes every second line.
  ---@param count integer Number of lines.
  ---@param changed boolean True marks every second line.
  ---@return string
  local function alternating(count, changed)
    local lines = {}
    for index = 1, count do
      lines[index] = string.format("big line %05d", index)
      if changed and index % 2 == 0 then
        lines[index] = lines[index] .. " changed"
      end
    end
    return table.concat(lines, "\n") .. "\n"
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    diff = require("codeview.diff")
    inline = require("codeview.inline")
    session_mod = require("codeview.session")
    sidebar = require("codeview.sidebar")
    view = require("codeview.view")
    config.setup({ comments = { dir = vim.fs.joinpath(fixture.dir, ".review") } })
  end)

  after_each(function()
    view.close()
    sidebar.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    config.reset()
    helpers.unload()
  end)

  it("opens a session of 401 files without reading a diff", function()
    -- Reference: 29 ms. The open reads the file list and the log only.
    local ms, review = took(open_session)
    assert.are.equal(401, #review:changed_files())
    assert.is_true(ms < 3000, string.format("the session open took %.1f ms", ms))
  end)

  it("renders the sidebar of 401 files", function()
    -- Reference: 6 ms for the open, 2 ms for one render.
    local review = open_session()
    local open_ms, panel = took(function()
      return sidebar.open({ session = review })
    end)
    assert.is_true(open_ms < 2000, string.format("the sidebar open took %.1f ms", open_ms))

    local render_ms = took(function()
      for _ = 1, 5 do
        panel:render()
      end
    end)
    assert.is_true(render_ms < 2000, string.format("five sidebar renders took %.1f ms", render_ms))
  end)

  it("compares a file of 32000 lines with one hunk per two lines", function()
    -- Reference: 4 ms with myers. The histogram algorithm costs 1300 ms on
    -- this input, because its cost grows with the square of the number of
    -- hunks. |codeview.diff.algorithm()| keeps it out of a file of this size.
    local old_text = alternating(16000, false)
    local new_text = alternating(16000, true)
    local ms, result = took(function()
      return diff.compute(old_text, new_text, { max_lines = 0 })
    end)
    assert.are.equal(8000, #result.hunks)
    assert.is_true(ms < 500, string.format("the comparison took %.1f ms", ms))
  end)

  it("builds the rows of a diff with 8000 hunks", function()
    -- Reference: 15 ms for 24001 rows.
    local result = diff.compute(alternating(16000, false), alternating(16000, true), { max_lines = 0 })
    local ms, build = took(function()
      return inline.build(result)
    end)
    assert.are.equal(24001, #build.lines)
    assert.is_true(ms < 1000, string.format("the build took %.1f ms", ms))
  end)

  it("opens the diff of the large file in the view", function()
    -- Reference: 36 ms, with two git calls of about 10 ms.
    local review = open_session()
    local index = assert(review:index_of("big.txt"))
    local ms, state = took(function()
      return view.open(review, index, { force = true })
    end)
    assert.are.equal("big.txt", assert(state).path)
    assert.is_true(ms < 3000, string.format("the view open took %.1f ms", ms))
  end)

  it("walks ten files of the range", function()
    -- Reference: 8 ms per file. Each open runs two backend calls at once.
    local review = open_session()
    view.open(review, 1)
    local ms = took(function()
      for _ = 1, 10 do
        local index = view.step(review, 1)
        if not index then
          break
        end
        local done = false
        view.open(review, index, function()
          done = true
        end)
        vim.wait(20000, function()
          return done
        end, 1)
      end
    end)
    assert.is_true(ms < 10000, string.format("ten file opens took %.1f ms", ms))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
  end)
end)
