-- Tests of the diagnostics of the working copy on the rows of a diff.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview lsp diagnostics", function()
  local fixture = fixtures.git_lsp()
  local config, lsp, session_mod, view
  ---@type codeview.Session?
  local opened
  ---@type string?
  local store_dir
  ---@type tests.FakeLsp?
  local server

  ---@param path string
  ---@return string uri
  local function uri_of(path)
    return vim.uri_from_fname(vim.fs.joinpath(fixture.root, path))
  end

  ---LSP diagnostic on one line.
  ---@param line integer Line from 1.
  ---@param first integer
  ---@param last integer
  ---@param message string
  ---@return table diagnostic
  local function diagnostic(line, first, last, message)
    return {
      range = { start = { line = line - 1, character = first }, ["end"] = { line = line - 1, character = last } },
      severity = 1,
      message = message,
    }
  end

  ---@param opts table Options of `setup()` on top of the test defaults.
  local function setup(opts)
    assert(config.setup(vim.tbl_deep_extend("force", {
      commit_message = false,
      comments = { dir = store_dir },
      sidebar = { auto_open = false },
      lsp = { enabled = true, diagnostics = true },
    }, opts or {})))
  end

  ---@param path string
  ---@return codeview.view.State
  local function open_file(path)
    if not opened then
      local session, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
      assert.is_nil(err)
      opened = assert(session)
    end
    local state = assert(view.open(opened, assert(opened:index_of(path))))
    api.nvim_set_current_win(state.win)
    return state
  end

  ---Diagnostics of codeview in one diff buffer, by row from 1.
  ---@param buf integer
  ---@return table<integer, vim.Diagnostic>
  local function by_row(buf)
    local out = {}
    for _, item in ipairs(vim.diagnostic.get(buf, { namespace = lsp.ns })) do
      out[item.lnum + 1] = item
    end
    return out
  end

  ---Send diagnostics and wait until the diff shows them.
  ---@param state codeview.view.State
  ---@param list table[]
  ---@param count integer Number of diagnostics that the diff must show.
  local function publish(state, list, count)
    local buf = assert(lsp.sources(state).new).buf
    assert.is_true(server.wait(buf))
    server.publish(uri_of("lib.lua"), list)
    assert.is_true(
      vim.wait(2000, function()
        return #vim.diagnostic.get(buf) == #list
          and #vim.diagnostic.get(state.buf, { namespace = lsp.ns })
              + (state.old_buf and #vim.diagnostic.get(state.old_buf, { namespace = lsp.ns }) or 0)
            == count
      end, 10),
      "the diff shows the diagnostics"
    )
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    store_dir = fixtures.tempdir("codeview-lsp-diag-store")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    lsp = require("codeview.lsp")
    server = helpers.fake_lsp({ root = fixture.root })
    server.attach_on_filetype()
  end)

  after_each(function()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    if server then
      server.stop()
    end
    server = nil
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= "" then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.cmd("silent! only")
    if store_dir then
      vim.fn.delete(store_dir, "rf")
    end
    store_dir = nil
    config.reset()
    helpers.unload()
  end)

  it("moves each diagnostic to the row of its line, after the marker", function()
    setup()
    local state = open_file("lib.lua")
    publish(state, { diagnostic(8, 9, 15, "added line"), diagnostic(3, 0, 8, "context line") }, 2)
    local rows = by_row(state.buf)
    local added = assert(state.map:buf_row(8, "new"))
    local context = assert(state.map:buf_row(3, "new"))
    assert.are.equal("added line", rows[added].message)
    assert.are.equal(10, rows[added].col)
    assert.are.equal(16, rows[added].end_col)
    assert.are.equal("context line", rows[context].message)
    assert.are.equal(1, rows[context].col)
  end)

  it("drops a diagnostic in a collapsed section, and shows it after the open", function()
    setup({ diff = { context = 1 } })
    local state = open_file("lib.lua")
    assert.is_nil(state.map:buf_row(1, "new"), "line 1 is collapsed")
    publish(state, { diagnostic(1, 0, 5, "first line"), diagnostic(8, 0, 2, "added line") }, 1)
    view.expand_all()
    local row = assert(state.map:buf_row(1, "new"))
    assert.are.equal("first line", by_row(state.buf)[row].message)
  end)

  it("drops a diagnostic on a line that the working copy changed", function()
    setup()
    local state = open_file("lib.lua")
    local buf = assert(lsp.sources(state).new).buf
    assert.is_true(server.wait(buf))
    api.nvim_buf_set_lines(buf, 7, 8, false, { "  return M.helper() + 2" })
    publish(state, { diagnostic(8, 0, 2, "changed line"), diagnostic(3, 0, 2, "same line") }, 1)
    local row = assert(state.map:buf_row(3, "new"))
    assert.are.equal("same line", by_row(state.buf)[row].message)
    vim.bo[buf].modified = false
  end)

  it("puts the diagnostics on the new side of the split style", function()
    setup({ diff = { style = "split" } })
    local state = open_file("lib.lua")
    assert.are.equal("split", state.style)
    publish(state, { diagnostic(3, 0, 8, "context line") }, 1)
    assert.are.equal(1, #vim.diagnostic.get(state.buf, { namespace = lsp.ns }))
    assert.are.equal(0, #vim.diagnostic.get(assert(state.old_buf), { namespace = lsp.ns }))
  end)

  it("shows nothing without the diagnostics option", function()
    setup({ lsp = { diagnostics = false } })
    local state = open_file("lib.lua")
    local buf = assert(lsp.sources(state).new).buf
    assert.is_true(server.wait(buf))
    server.publish(uri_of("lib.lua"), { diagnostic(3, 0, 8, "context line") })
    assert.is_true(vim.wait(2000, function()
      return #vim.diagnostic.get(buf) == 1
    end, 10))
    vim.wait(50)
    assert.are.same({}, vim.diagnostic.get(state.buf, { namespace = lsp.ns }))
  end)

  it("shows the diagnostics of a file of a review of files", function()
    setup()
    local dir = vim.fs.normalize(fixtures.tempdir("codeview-lsp-diag-files"))
    local file = vim.fs.joinpath(dir, "plan.lua")
    vim.fn.writefile({ "local plan = 1", "return plan" }, file)
    local files_server = helpers.fake_lsp({ root = dir })
    files_server.attach_on_filetype()
    local session, err = session_mod.open_files({ file }, { dir = dir })
    assert.is_nil(err)
    opened = assert(session)
    local state = assert(view.open(opened, 1))
    assert.is_true(vim.diagnostic.is_enabled({ bufnr = state.buf }))
    local buf = assert(lsp.sources(state).new).buf
    assert.is_true(files_server.wait(buf))
    files_server.publish(vim.uri_from_fname(file), { diagnostic(2, 7, 11, "plan line") })
    assert.is_true(vim.wait(2000, function()
      return #vim.diagnostic.get(state.buf, { namespace = lsp.ns }) == 1
    end, 10))
    local item = vim.diagnostic.get(state.buf, { namespace = lsp.ns })[1]
    assert.are.equal(1, item.lnum)
    assert.are.equal(7, item.col)
    files_server.stop()
    view.close()
    opened:close()
    opened = nil
    vim.fn.delete(dir, "rf")
  end)

  it("removes the fixture", function()
    fixture.cleanup()
  end)
end)
