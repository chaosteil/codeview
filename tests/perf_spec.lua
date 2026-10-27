-- Performance guards for a large review range.
--
-- The budgets are generous. They do not measure the speed of a machine: they
-- catch a change that makes the cost grow with the square of the input again.
-- The numbers of the reference machine are in the comment of each test.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview performance", function()
  local fixture = fixtures.git_large({ files = 400, lines = 8000 })
  local config, diff, inline, sidebar, session_mod, split, syntax, view
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

  ---Diff of a Lua file of 9000 lines that changes every 100th line.
  ---
  --- Neovim ships a Lua parser, so the diff runs the syntax path. The file
  --- `big.txt` of the fixture has no parser.
  ---@return codeview.diff.File
  local function lua_diff()
    ---@param changed boolean
    ---@return string
    local function text(changed)
      local lines = {}
      for index = 1, 9000 do
        lines[index] = string.format("local value_%05d = { name = %q, size = %d } -- note", index, "item", index)
        if changed and index % 100 == 0 then
          lines[index] = lines[index] .. " changed"
        end
      end
      return table.concat(lines, "\n") .. "\n"
    end
    local file = diff.compute(text(false), text(true))
    file.path, file.old_path = "big.lua", "big.lua"
    return file
  end

  ---Number of syntax highlights in a buffer.
  ---@param buf integer
  ---@return integer
  local function syntax_marks(buf)
    return #vim.api.nvim_buf_get_extmarks(buf, syntax.ns, 0, -1, {})
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    diff = require("codeview.diff")
    inline = require("codeview.inline")
    session_mod = require("codeview.session")
    sidebar = require("codeview.sidebar")
    split = require("codeview.split")
    syntax = require("codeview.syntax")
    view = require("codeview.view")
    config.setup({ commit_message = false, comments = { dir = vim.fs.joinpath(fixture.dir, ".review") } })
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

  it("renders a Lua file of 9000 lines with syntax highlights", function()
    -- Reference: 1180 ms. The first render parses both sides, because the
    -- removed rows read the old side.
    local file = lua_diff()
    local buf = vim.api.nvim_create_buf(false, true)
    local ms = took(function()
      return inline.render(buf, file)
    end)
    assert.is_true(syntax_marks(buf) > 0, "the render wrote no syntax highlights")
    assert.is_true(ms < 6000, string.format("the render took %.1f ms", ms))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("renders the same Lua diff again without a parse", function()
    -- Reference: 37 ms for an unfold, 24 ms for a switch to the split style.
    -- The captures of the first render stay with the diff.
    local file = lua_diff()
    local buf = vim.api.nvim_create_buf(false, true)
    inline.render(buf, file)

    local again_ms = took(function()
      return inline.render(buf, file, { expanded = { [1] = true } })
    end)
    assert.is_true(syntax_marks(buf) > 0)
    assert.is_true(again_ms < 1000, string.format("the second render took %.1f ms", again_ms))

    local old_buf = vim.api.nvim_create_buf(false, true)
    local split_ms = took(function()
      return split.render(old_buf, buf, file)
    end)
    assert.is_true(syntax_marks(old_buf) > 0)
    assert.is_true(split_ms < 1000, string.format("the switch to the split style took %.1f ms", split_ms))
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(old_buf, { force = true })
  end)

  it("renders a Lua diff of 9000 lines in the split style", function()
    -- Reference: 1200 ms. Each side gets one parse.
    local file = lua_diff()
    local old_buf = vim.api.nvim_create_buf(false, true)
    local new_buf = vim.api.nvim_create_buf(false, true)
    local ms, build = took(function()
      return split.render(old_buf, new_buf, file)
    end)
    assert.are.equal(#build.old.lines, #build.new.lines)
    assert.is_true(syntax_marks(old_buf) > 0)
    assert.is_true(syntax_marks(new_buf) > 0)
    assert.is_true(ms < 6000, string.format("the split render took %.1f ms", ms))
    vim.api.nvim_buf_delete(old_buf, { force = true })
    vim.api.nvim_buf_delete(new_buf, { force = true })
  end)

  it("stops a Lua file with one line of 22 MB", function()
    -- Reference: 10 ms for the limited diff, 57 ms for the forced read and
    -- its render. Without the byte limits the parse blocked for 92 s.
    local long = 'local s = "' .. string.rep("x", 22 * 1024 * 1024) .. '"\n'
    local limited_ms, limited = took(function()
      return diff.compute(long, long .. "local t = 1\n")
    end)
    assert.is_true(limited.limited)
    assert.is_true(limited_ms < 1000, string.format("the limited diff took %.1f ms", limited_ms))

    local buf = vim.api.nvim_create_buf(false, true)
    local forced_ms = took(function()
      local file = diff.compute(long, long .. "local t = 1\n", { max_lines = 0 })
      file.path, file.old_path = "long.lua", "long.lua"
      return inline.render(buf, file)
    end)
    assert.is_true(forced_ms < 3000, string.format("the forced render took %.1f ms", forced_ms))
    vim.api.nvim_buf_delete(buf, { force = true })
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
