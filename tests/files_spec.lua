-- Tests of a review of files with no repository.
--
-- The files live in a temporary directory outside every repository. The
-- session reads them through the file backend of `codeview.vcs.file`.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview review of files", function()
  local comments, config, editor, session_mod, view
  ---@type string
  local dir
  ---@type string
  local store_dir
  ---@type codeview.Session?
  local opened
  ---@type string[]
  local messages
  ---@type fun(msg: string, level?: integer, opts?: table)
  local notify

  ---Write a file below the test directory.
  ---@param path string Path relative to the test directory.
  ---@param content string
  local function write(path, content)
    local full = vim.fs.joinpath(dir, path)
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    local handle = assert(io.open(full, "wb"))
    handle:write(content)
    handle:close()
  end

  ---Open a review of files in the sync form.
  ---@param paths string[]
  ---@return codeview.Session
  local function open(paths)
    local session, err = session_mod.open_files(paths, { dir = dir })
    assert.is_nil(err)
    opened = assert(session)
    return opened
  end

  ---Comment on one row of the view, through the editor.
  ---@param row integer Buffer row of the cursor.
  ---@param body string
  ---@return codeview.store.Comment
  local function comment_on(row, body)
    local state = assert(view.current())
    api.nvim_set_current_win(state.win)
    api.nvim_win_set_cursor(state.win, { row, 0 })
    assert.is_true(comments.add())
    local edit = assert(editor.current())
    api.nvim_buf_set_lines(edit.buf, 0, -1, false, { body })
    assert.is_true(editor.submit())
    local store = assert(comments.store())
    return store.comments[#store.comments]
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = vim.fs.normalize(fixtures.tempdir("review-files"))
    store_dir = fixtures.tempdir("review-files-store")
    assert(config.setup({ comments = { dir = store_dir }, log_level = vim.log.levels.INFO }))
    comments = require("codeview.comments")
    editor = require("codeview.editor")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    messages = {}
    notify = vim.notify
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
  end)

  after_each(function()
    vim.notify = notify
    editor.cancel()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(store_dir, "rf")
    config.reset()
    helpers.unload()
  end)

  it("opens one file with no repository", function()
    write("plan.md", "# Plan\n\nStep one.\n")
    local session = open({ "plan.md" })
    assert.is_true(session:is_files())
    assert.are.equal("file", session.repo.backend)
    assert.are.equal(dir, session.repo.root)
    assert.are.same({ dir .. "/plan.md" }, session.paths)
    assert.are.same({ { path = "plan.md", status = "file" } }, session.files)
    assert.are.same({}, session.commits)
    assert.is_nil(session.range.from)
    assert.are.equal("1 file", session:counts())
  end)

  it("opens a directory as a tree of its files", function()
    write("docs/a.md", "a\n")
    write("docs/sub/b.lua", "return 1\n")
    write("docs/.hidden", "x\n")
    local session = open({ "docs" })
    assert.are.equal(dir .. "/docs", session.repo.root)
    assert.are.same(
      { "a.md", "sub/b.lua" },
      vim.tbl_map(function(file)
        return file.path
      end, session.files)
    )
    assert.are.equal("2 files", session:counts())
  end)

  it("reports the files that the walk of a directory skips", function()
    write("docs/a.md", "a\n")
    write("docs/image.png", "\0\0")
    open({ "docs" })
    assert.is_truthy(
      vim.iter(messages):any(function(msg)
        return msg:find("skips 1 binary file", 1, true) ~= nil
      end),
      table.concat(messages, "\n")
    )
  end)

  it("gives the error of a missing file in the async form", function()
    local answer
    session_mod.open_files({ "missing.txt" }, { dir = dir }, function(session, err)
      answer = { session = session, err = err }
    end)
    vim.wait(2000, function()
      return answer ~= nil
    end)
    assert.is_nil(answer.session)
    assert.are.equal("not_found", answer.err.code)
    assert.is_nil(session_mod.current())
  end)

  it("shows the plain file, with the filetype of the file", function()
    write("init.lua", "local a = 1\nreturn a\n")
    local session = open({ "init.lua" })
    local state = assert(view.open(session, 1))
    assert.are.same({ "local a = 1", "return a" }, api.nvim_buf_get_lines(state.buf, 0, -1, false))
    assert.are.equal("inline", state.style)
    assert.is_true(state.diff.plain)
    assert.is_true(state.diff.message)
    assert.are.equal("lua", vim.bo[state.buf].filetype)
    assert.are.equal(1, state.map:buf_row(1, "new"))
    assert.are.equal(2, state.map:buf_row(2, "new"))
  end)

  it("opens a file in the inline style when the next style is side by side", function()
    write("a.txt", "one\n")
    local session = open({ "a.txt" })
    view.set_style("split")
    local state = assert(view.open(session, 1))
    assert.are.equal("inline", state.style)
    assert.are.equal("inline", view.set_style("split"))
  end)

  it("shows the note of an empty file and of a binary file", function()
    write("empty.txt", "")
    write("blob.bin", "\0\1\2")
    local session = open({ "empty.txt", "blob.bin" })
    local state = assert(view.open(session, assert(session:index_of("empty.txt"))))
    assert.are.same({ "The file is empty." }, api.nvim_buf_get_lines(state.buf, 0, -1, false))
    state = assert(view.open(session, assert(session:index_of("blob.bin"))))
    assert.are.same({ "The file is binary. It has no text diff." }, api.nvim_buf_get_lines(state.buf, 0, -1, false))
  end)

  it("stops a file above the line limit, and the load key shows it", function()
    config.setup({ comments = { dir = store_dir }, diff = { max_lines = 2 } })
    write("long.txt", "1\n2\n3\n")
    local session = open({ "long.txt" })
    local state = assert(view.open(session, 1))
    assert.matches("The file holds 3 lines", api.nvim_buf_get_lines(state.buf, 0, 1, false)[1])
    state = assert(view.open(session, 1, { force = true }))
    assert.are.same({ "1", "2", "3" }, api.nvim_buf_get_lines(state.buf, 0, -1, false))
  end)

  it("keeps a comment with no commit, and finds it again for the same content", function()
    write("plan.md", "one\ntwo\nthree\n")
    local session = open({ "plan.md" })
    assert(view.open(session, 1))
    local comment = comment_on(2, "say more")
    assert.are.equal("plan.md", comment.file)
    assert.are.equal(2, comment.start_line)
    assert.are.equal("new", comment.side)
    assert.are.equal("", comment.commit)

    session:close()
    local again = open({ "plan.md" })
    local store = assert(comments.store(again))
    assert.are.equal(1, #store.comments)
    assert.are.equal("say more", store.comments[1].body)
  end)

  it("starts a new comment store after a change of the file", function()
    write("plan.md", "one\n")
    local session = open({ "plan.md" })
    assert(view.open(session, 1))
    comment_on(1, "first")
    session:close()

    write("plan.md", "one\nand two\n")
    local again = open({ "plan.md" })
    local store = assert(comments.store(again))
    assert.are.equal(0, #store.comments)
  end)

  it("reads the files again from the disk on a refresh", function()
    write("docs/a.txt", "a\n")
    local session = open({ "docs" })
    write("docs/b.txt", "b\n")
    local refreshed = assert(session:refresh())
    assert.are.equal(2, refreshed:changed_count())
  end)

  it("starts no watcher of a repository", function()
    write("a.txt", "a\n")
    open({ "a.txt" })
    assert.is_false(require("codeview.watch").start(assert(opened)))
  end)

  it("hides the keys of a diff in the hint row", function()
    write("a.txt", "a\n")
    local session = open({ "a.txt" })
    local text = table.concat(vim.tbl_map(function(chunk)
      return chunk.text
    end, require("codeview.hints").chunks("view", session)))
    assert.is_nil(text:find("next hunk", 1, true))
    assert.is_nil(text:find("unfold", 1, true))
    assert.is_nil(text:find("style", 1, true))
    assert.is_truthy(text:find("next file", 1, true))
  end)

  it("keeps the paths in the record of the closed session", function()
    write("a.txt", "a\n")
    open({ "a.txt" }):close()
    local record = assert(session_mod.last())
    assert.are.same({ dir .. "/a.txt" }, record.paths)
    assert.are.equal(dir, record.dir)
  end)
end)
