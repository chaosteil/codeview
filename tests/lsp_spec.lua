-- Tests of the map between the rows of a diff and the working copy.
--
-- The fixture range changes every kind of file. The working copy holds the
-- head of the range, so the new side of each file is the file on disk.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview lsp map", function()
  local fixture = fixtures.git_lsp()
  local config, lsp, session_mod, view
  ---@type codeview.Session?
  local opened
  ---@type string?
  local store_dir

  ---Open the review of the fixture range.
  ---@return codeview.Session
  local function open_session()
    local session, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(session)
    return opened
  end

  ---Open one file of the review in a style.
  ---@param path string
  ---@param style? "inline"|"split"
  ---@return codeview.view.State
  local function open_file(path, style)
    local session = opened or open_session()
    local index = assert(session:index_of(path), "the review holds " .. path)
    local state = assert(view.open(session, index))
    if style and state.style ~= style then
      view.set_style(style)
      state = assert(view.current())
    end
    return state
  end

  ---Row of a line of one side in the view.
  ---@param state codeview.view.State
  ---@param line integer
  ---@param side "old"|"new"
  ---@return integer row
  local function row_of(state, line, side)
    local map = side == "old" and state.old_map or state.map
    return assert(map:buf_row(line, side), "a row holds the line")
  end

  ---Real path of a file of the fixture.
  ---@param path string
  ---@return string
  local function real(path)
    return assert(vim.uv.fs_realpath(vim.fs.joinpath(fixture.root, path)))
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    store_dir = fixtures.tempdir("codeview-lsp-store")
    assert(config.setup({ commit_message = false, comments = { dir = store_dir }, sidebar = { auto_open = false } }))
    lsp = require("codeview.lsp")
    session_mod = require("codeview.session")
    view = require("codeview.view")
  end)

  after_each(function()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    if store_dir then
      vim.fn.delete(store_dir, "rf")
    end
    store_dir = nil
    -- The buffers of the working copy belong to the test that loaded them.
    for _, buf in ipairs(api.nvim_list_bufs()) do
      local name = api.nvim_buf_get_name(buf)
      if vim.startswith(vim.uv.fs_realpath(name) or name, vim.uv.fs_realpath(fixture.root) or fixture.root) then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
    config.reset()
    helpers.unload()
  end)

  it("loads the file of the working copy for both sides of a modified file", function()
    local state = open_file("lib.lua")
    local sources = lsp.sources(state)
    local new, old = assert(sources.new), assert(sources.old)
    assert.are.equal(new.buf, old.buf)
    assert.are.equal(real("lib.lua"), vim.uv.fs_realpath(api.nvim_buf_get_name(new.buf)))
    assert.is_true(api.nvim_buf_is_loaded(new.buf))
    assert.is_false(vim.bo[new.buf].buflisted)
    assert.are.same({}, vim.fn.win_findbuf(new.buf))
    -- A second call gives the same sources.
    assert.are.equal(sources, lsp.sources(state))
  end)

  it("maps the rows of the inline style to the lines of the working copy", function()
    local state = open_file("lib.lua", "inline")
    api.nvim_set_current_win(state.win)

    -- An added line: the new side is the working copy.
    local row = row_of(state, 8, "new")
    local position = assert(lsp.locate(state, { row = row, col = 3 }))
    assert.are.equal("new", position.side)
    assert.are.equal(8, position.file_line)
    assert.are.equal(1, position.prefix)
    assert.are.equal(2, position.col)

    -- A context row.
    position = assert(lsp.locate(state, { row = row_of(state, 3, "new"), col = 0 }))
    assert.are.equal(3, position.file_line)
    assert.are.equal(0, position.col)

    -- A removed line is not in the working copy.
    local found, reason = lsp.locate(state, { row = row_of(state, 4, "old") })
    assert.is_nil(found)
    assert.is_truthy(reason:find("does not hold this line", 1, true))

    -- A hunk header holds no line.
    found, reason = lsp.locate(state, { row = 1 })
    assert.is_nil(found)
    assert.are.equal("header", state.map:kind(1))
    assert.is_truthy(reason:find("no line of the file", 1, true))
  end)

  it("maps a context row of the old side through the new side", function()
    local state = open_file("lib.lua", "split")
    assert.are.equal("split", state.style)
    local old_win = state.old_win --[[@as integer]]
    api.nvim_set_current_win(old_win)
    local row = row_of(state, 3, "old")
    local position = assert(lsp.locate(state, { win = old_win, row = row, col = 4 }))
    assert.are.equal(3, position.file_line)
    assert.are.equal(0, position.prefix)
    assert.are.equal(4, position.col)

    -- The removed line of the old side has no line in the working copy.
    local found = lsp.locate(state, { win = old_win, row = row_of(state, 4, "old") })
    assert.is_nil(found)
    -- A filler row of the old side holds no line.
    local filler
    for lnum, record in ipairs(state.old_map.rows) do
      if record.kind == "filler" and not filler then
        filler = lnum
      end
    end
    assert.is_not_nil(filler, "the old side holds a filler row")
    found = lsp.locate(state, { win = old_win, row = filler })
    assert.is_nil(found)
  end)

  it("follows a working copy that differs from the review", function()
    local state = open_file("lib.lua", "inline")
    local source = assert(lsp.sources(state).new)
    -- Two new lines at the top and a change of the line of `extra`.
    api.nvim_buf_set_lines(source.buf, 0, 0, false, { "-- one", "-- two" })
    api.nvim_buf_set_lines(source.buf, 8, 9, false, { "function M.renamed()" })

    local notes = {}
    local position = assert(lsp.locate(state, {
      row = row_of(state, 3, "new"),
      note = function(message)
        notes[#notes + 1] = message
      end,
    }))
    assert.are.equal(5, position.file_line)
    assert.is_false(source.same)
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("lib.lua", 1, true))

    -- The changed line has no line in the working copy.
    local found = lsp.locate(state, { row = row_of(state, 7, "new") })
    assert.is_nil(found)

    -- The note comes once per file.
    lsp.locate(state, {
      row = row_of(state, 8, "new"),
      note = function(message)
        notes[#notes + 1] = message
      end,
    })
    assert.are.equal(1, #notes)

    -- The lines map back from the working copy too.
    assert.are.equal(3, lsp.review_line(state, source.file, 5))
    assert.is_nil(lsp.review_line(state, source.file, 9))
    assert.are.equal(11, lsp.review_line(state, source.file, 13))
  end)

  it("reads a renamed file through its new path", function()
    local state = open_file("renamed.lua", "inline")
    assert.are.equal("renamed", state.status)
    local sources = lsp.sources(state)
    assert.is_not_nil(sources.new)
    assert.is_nil(sources.old, "the working copy holds no old.lua")
    local position = assert(lsp.locate(state, { row = row_of(state, 2, "new") }))
    assert.are.equal(2, position.file_line)
  end)

  it("gives a deleted file no source", function()
    local state = open_file("gone.lua", "inline")
    local sources = lsp.sources(state)
    assert.is_nil(sources.new)
    assert.is_nil(sources.old)
    local found, reason = lsp.locate(state, { row = row_of(state, 1, "old") })
    assert.is_nil(found)
    assert.is_truthy(reason:find("holds no gone.lua", 1, true))
  end)

  it("gives an added file the new side only", function()
    local state = open_file("added.lua", "inline")
    local sources = lsp.sources(state)
    assert.is_not_nil(sources.new)
    assert.is_nil(sources.old)
    assert.is_truthy(lsp.locate(state, { row = row_of(state, 1, "new") }))
  end)

  it("gives a binary file no lines", function()
    local state = open_file("bin.dat", "inline")
    assert.is_false(lsp.has_lines(state.diff))
    local sources = lsp.sources(state)
    assert.is_nil(sources.new)
    local found, reason = lsp.locate(state, { row = 1 })
    assert.is_nil(found)
    assert.is_truthy(reason)
  end)

  it("compares the lines of a file with CRLF line ends", function()
    local state = open_file("crlf.txt", "inline")
    local source = assert(lsp.sources(state).new)
    assert.are.equal("dos", vim.bo[source.buf].fileformat)
    local position = assert(lsp.locate(state, { row = row_of(state, 2, "new") }))
    assert.is_true(source.same)
    assert.are.equal(2, position.file_line)
  end)

  it("removes the buffers that it loaded when the session closes", function()
    local state = open_file("lib.lua")
    local loaded = assert(lsp.sources(state).new).buf
    local kept_file = vim.fs.joinpath(fixture.root, "main.lua")
    -- The user holds main.lua in a buffer already, so it must stay.
    local kept = vim.fn.bufadd(kept_file)
    vim.fn.bufload(kept)
    local second = open_file("main.lua")
    assert.are.equal(kept, assert(lsp.sources(second).new).buf)
    local changed = open_file("added.lua")
    local edited = assert(lsp.sources(changed).new).buf
    api.nvim_buf_set_lines(edited, 0, 0, false, { "-- edit" })
    assert.are.same({ loaded, edited }, lsp.owned(assert(opened)))

    view.close()
    assert(opened):close()
    opened = nil
    assert.is_false(api.nvim_buf_is_valid(loaded))
    assert.is_true(api.nvim_buf_is_loaded(kept))
    assert.is_true(api.nvim_buf_is_valid(edited), "a buffer with changes stays")
    assert.is_true(vim.bo[edited].modified)
  end)

  it("reads a file of a review of files", function()
    local dir = vim.fs.normalize(fixtures.tempdir("codeview-lsp-files"))
    local file = vim.fs.joinpath(dir, "plan.lua")
    vim.fn.writefile({ "local plan = 1", "return plan" }, file)
    local session, err = session_mod.open_files({ file }, { dir = dir })
    assert.is_nil(err)
    opened = assert(session)
    local state = assert(view.open(opened, 1))
    assert.is_true(state.diff.plain)
    local position = assert(lsp.locate(state, { win = state.win, row = 2, col = 7 }))
    assert.are.equal(2, position.file_line)
    assert.are.equal(0, position.prefix)
    assert.are.equal(7, position.col)
    view.close()
    opened:close()
    opened = nil
    vim.fn.delete(dir, "rf")
  end)

  it("finds the inline marker in front of a line", function()
    assert.are.equal(1, lsp.prefix("+local a", "local a"))
    assert.are.equal(0, lsp.prefix("local a", "local a"))
    assert.are.equal(0, lsp.prefix("", ""))
    assert.are.equal(0, lsp.prefix("xyz", "abc"))
  end)

  it("names one file through a symbolic link", function()
    local dir = fixtures.tempdir("codeview-lsp-link")
    local target = vim.fs.joinpath(dir, "target.lua")
    local link = vim.fs.joinpath(dir, "link.lua")
    vim.fn.writefile({ "x" }, target)
    assert(vim.uv.fs_symlink(target, link))
    assert.is_true(lsp.same_file(target, link))
    assert.is_false(lsp.same_file(target, vim.fs.joinpath(dir, "other.lua")))
    vim.fn.delete(dir, "rf")
  end)

  it("removes the fixture", function()
    fixture.cleanup()
  end)
end)
