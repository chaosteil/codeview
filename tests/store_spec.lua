local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.store", function()
  local config, store_mod
  ---@type string
  local dir

  ---Build a store with a path in the test directory.
  ---@param opts? table
  ---@return codeview.store.Store
  local function new_store(opts)
    opts = vim.tbl_extend("force", {
      repo = "/home/ada/code/demo",
      range = "aaaa1111..bbbb2222",
      spec = "main..@",
    }, opts or {})
    local store = store_mod.new(opts)
    store.path = store_mod.path(store.repo, store.range)
    return store
  end

  ---Add one comment with the default fields.
  ---@param store codeview.store.Store
  ---@param fields? table
  ---@return codeview.store.Comment
  local function add(store, fields)
    local comment, err = store:add(vim.tbl_extend("force", {
      file = "lua/demo.lua",
      start_line = 3,
      end_line = 5,
      side = "new",
      commit = "bbbb2222",
      body = "the body",
    }, fields or {}))
    assert.is_nil(err)
    return assert(comment)
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    store_mod = require("codeview.store")
    dir = fixtures.tempdir("codeview-store")
    assert(config.setup({ comments = { dir = dir } }))
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  describe("the session key", function()
    it("gives the same key for the same repo and range", function()
      local first = store_mod.key("/home/ada/code/demo", "aaaa1111..bbbb2222")
      local second = store_mod.key("/home/ada/code/demo", "aaaa1111..bbbb2222")
      assert.are.equal(first, second)
      assert.are.equal(16, #first)
      assert.is_truthy(first:match("^%x+$"))
    end)

    it("reads the same key from a path with a trailing slash", function()
      assert.are.equal(
        store_mod.key("/home/ada/code/demo", "aaaa1111..bbbb2222"),
        store_mod.key("/home/ada/code/demo/", "aaaa1111..bbbb2222")
      )
    end)

    it("reads the same key from a range table and from its text", function()
      assert.are.equal(
        store_mod.key("/home/ada/code/demo", "aaaa1111..bbbb2222"),
        store_mod.key("/home/ada/code/demo", { from = "aaaa1111", to = "bbbb2222" })
      )
      assert.are.equal(
        store_mod.key("/home/ada/code/demo", "bbbb2222"),
        store_mod.key("/home/ada/code/demo", { to = "bbbb2222" })
      )
    end)

    it("gives another key for another range or another repo", function()
      local base = store_mod.key("/home/ada/code/demo", "aaaa1111..bbbb2222")
      assert.are_not.equal(base, store_mod.key("/home/ada/code/demo", "aaaa1111..cccc3333"))
      assert.are_not.equal(base, store_mod.key("/home/ada/code/other", "aaaa1111..bbbb2222"))
    end)

    it("puts the file in the directory of the repository", function()
      local path = store_mod.path("/home/ada/code/demo", "aaaa1111..bbbb2222")
      local expected = config.store_dir("/home/ada/code/demo")
      assert.are.equal(expected, vim.fs.dirname(path))
      assert.is_truthy(path:find(dir, 1, true))
      assert.are.equal(store_mod.key("/home/ada/code/demo", "aaaa1111..bbbb2222") .. ".md", vim.fs.basename(path))
    end)
  end)

  describe("the file format", function()
    it("writes the session data as frontmatter", function()
      local store = new_store()
      local text = store_mod.encode(store)
      local lines = vim.split(text, "\n", { plain = true })
      assert.are.equal("---", lines[1])
      assert.is_truthy(text:find("key: " .. store.key, 1, true))
      assert.is_truthy(text:find("repo: /home/ada/code/demo", 1, true))
      assert.is_truthy(text:find("range: aaaa1111..bbbb2222", 1, true))
      assert.is_truthy(text:find("spec: main..@", 1, true))
      assert.is_truthy(text:find("version: 1", 1, true))
    end)

    it("writes one section with a field block and a body", function()
      local store = new_store()
      local comment = add(store)
      local text = store_mod.encode(store)
      assert.is_truthy(text:find("## codeview%-comment " .. comment.id))
      assert.is_truthy(text:find("- file: lua/demo.lua", 1, true))
      assert.is_truthy(text:find("- start_line: 3", 1, true))
      assert.is_truthy(text:find("- end_line: 5", 1, true))
      assert.is_truthy(text:find("- side: new", 1, true))
      assert.is_truthy(text:find("- commit: bbbb2222", 1, true))
      assert.is_truthy(text:find("- state: open", 1, true))
      assert.is_truthy(text:find("\nthe body\n", 1, true))
    end)

    it("reads every field back", function()
      local store = new_store()
      local comment = add(store, { state = "resolved" })
      local back = assert(store_mod.decode(store_mod.encode(store)))

      assert.are.equal(store.key, back.key)
      assert.are.equal(store.repo, back.repo)
      assert.are.equal(store.range, back.range)
      assert.are.equal(store.spec, back.spec)
      assert.are.equal(store.created_at, back.created_at)
      assert.are.equal(1, back:count())
      assert.are.same(comment, back.comments[1])
    end)

    it("keeps a body with markdown, headings, and blank lines", function()
      local body = table.concat({
        "# a heading",
        "",
        "- a list item",
        "  with a wrapped line",
        "",
        "```lua",
        "local a = 1",
        "```",
        "",
        "## codeview-comment deadbeef",
        "\\a backslash line",
        "--- a rule",
      }, "\n")
      local store = new_store()
      add(store, { body = body })
      local back = assert(store_mod.decode(store_mod.encode(store)))
      assert.are.equal(body, back.comments[1].body)
      assert.are.equal(1, back:count())
    end)

    it("keeps every comment of a file with more than one", function()
      local store = new_store()
      local first = add(store, { start_line = 1, end_line = 1, body = "first" })
      local second = add(store, { file = "README.md", side = "old", start_line = 9, body = "second" })
      local back = assert(store_mod.decode(store_mod.encode(store)))
      assert.are.equal(2, back:count())
      assert.are.same(first, back.comments[1])
      assert.are.same(second, back.comments[2])
    end)

    it("reads the timestamps as UTC seconds", function()
      assert.are.equal("2026-08-12T09:30:00Z", store_mod.to_iso(store_mod.from_iso("2026-08-12T09:30:00Z")))
      assert.are.equal(0, store_mod.from_iso("1970-01-01T00:00:00Z"))
      assert.are.equal(1786527000, store_mod.from_iso("2026-08-12T09:30:00Z"))
      assert.is_nil(store_mod.from_iso("yesterday"))
    end)

    it("reports a file that is not a session file", function()
      local store, err = store_mod.decode("# just a note\n")
      assert.is_nil(store)
      assert.are.equal("invalid_arg", err.code)

      local open_store, open_err = store_mod.decode("---\nkey: abc\n")
      assert.is_nil(open_store)
      assert.are.equal("invalid_arg", open_err.code)
    end)
  end)

  describe("save and load", function()
    it("writes the file and reads it back", function()
      local store = new_store()
      local comment = add(store)
      local ok, err = store:save()
      assert.is_true(ok)
      assert.is_nil(err)
      assert.are.equal(1, vim.fn.filereadable(store.path))

      local back, load_err = store_mod.load({ repo = store.repo, range = store.range })
      assert.is_nil(load_err)
      back = assert(back)
      assert.are.equal(store.path, back.path)
      assert.are.equal(store.key, back.key)
      assert.are.equal(1, back:count())
      assert.are.same(comment, back.comments[1])
    end)

    it("makes the directory of the repository", function()
      local store = new_store()
      store.path = vim.fs.joinpath(dir, "deep", "nested", store.key .. ".md")
      add(store)
      assert.is_true(store:save())
      assert.are.equal(1, vim.fn.filereadable(store.path))
    end)

    it("leaves no temporary file behind", function()
      local store = new_store()
      add(store)
      assert.is_true(store:save())
      assert.is_true(store:save())
      local names = vim.fn.readdir(vim.fs.dirname(store.path))
      assert.are.same({ vim.fs.basename(store.path) }, names)
    end)

    it("keeps the file of the last save after a failed write", function()
      local store = new_store()
      add(store)
      assert.is_true(store:save())
      local before = vim.fn.readfile(store.path)

      local broken = new_store()
      broken.path = vim.fs.joinpath(store.path, "child.md")
      add(broken, { body = "never written" })
      local ok, err = broken:save()
      assert.is_false(ok)
      assert.is_truthy(err)
      assert.are.same(before, vim.fn.readfile(store.path))
    end)

    it("gives an empty store for a range without a file", function()
      local store, err = store_mod.load({ repo = "/home/ada/code/demo", range = "ffff9999..0000aaaa" })
      assert.is_nil(err)
      store = assert(store)
      assert.are.equal(0, store:count())
      assert.are.equal(0, vim.fn.filereadable(store.path))
    end)

    it("finds the file of the same range again", function()
      local store = new_store()
      add(store, { body = "the first note" })
      assert.is_true(store:save())

      local reopened = assert(store_mod.load({
        repo = "/home/ada/code/demo/",
        range = { from = "aaaa1111", to = "bbbb2222" },
      }))
      assert.are.equal(store.path, reopened.path)
      assert.are.equal(1, reopened:count())
      assert.are.equal("the first note", reopened.comments[1].body)
    end)

    it("reports a store without a path", function()
      local store = store_mod.new({ repo = "/home/ada/code/demo", range = "a..b" })
      store.path = ""
      local ok, err = store:save()
      assert.is_false(ok)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("reports a call without a repository", function()
      local store, err = store_mod.load({})
      assert.is_nil(store)
      assert.are.equal("invalid_arg", err.code)
    end)
  end)

  describe("the comment list", function()
    it("gives every comment an own id", function()
      local store = new_store()
      local first = add(store)
      local second = add(store)
      assert.are_not.equal(first.id, second.id)
      assert.are.equal(first, store:get(first.id))
      assert.is_nil(store:get("no-such-id"))
    end)

    it("reads the comments of one file and of one side", function()
      local store = new_store()
      add(store, { file = "a.lua", side = "new" })
      add(store, { file = "a.lua", side = "old" })
      add(store, { file = "b.lua", side = "new" })
      assert.are.equal(2, #store:for_file("a.lua"))
      assert.are.equal(1, #store:for_file("a.lua", { side = "old" }))
      assert.are.equal(0, #store:for_file("c.lua"))
    end)

    it("reads the comments that cover one line", function()
      local store = new_store()
      add(store, { file = "a.lua", side = "new", start_line = 3, end_line = 5 })
      assert.are.equal(1, #store:at("a.lua", "new", 3))
      assert.are.equal(1, #store:at("a.lua", "new", 5))
      assert.are.equal(0, #store:at("a.lua", "new", 6))
      assert.are.equal(0, #store:at("a.lua", "old", 3))
    end)

    it("changes the body and the state of one comment", function()
      local store = new_store()
      local comment = add(store)
      local updated, err = store:update(comment.id, { body = "  a new body  ", state = "resolved" })
      assert.is_nil(err)
      assert.are.equal("a new body", assert(updated).body)
      assert.are.equal("resolved", updated.state)
      assert.are.equal(comment.id, updated.id)
    end)

    it("removes one comment", function()
      local store = new_store()
      local comment = add(store)
      add(store, { body = "the other one" })
      assert.are.equal(comment, store:remove(comment.id))
      assert.are.equal(1, store:count())
      assert.is_nil(store:remove(comment.id))
    end)

    it("reports a comment without a file or without a body", function()
      local store = new_store()
      local comment, err = store:add({ start_line = 1, body = "x" })
      assert.is_nil(comment)
      assert.are.equal("invalid_arg", err.code)

      comment, err = store:add({ file = "a.lua", body = "   " })
      assert.is_nil(comment)
      assert.are.equal("invalid_arg", err.code)

      local _, update_err = store:update("no-such-id", { body = "x" })
      assert.are.equal("not_found", update_err.code)
    end)

    it("orders the line range and trims the body", function()
      local store = new_store()
      local comment = add(store, { start_line = 8, end_line = 2, body = "\n  a note  \n\n" })
      assert.are.equal(8, comment.start_line)
      assert.are.equal(8, comment.end_line)
      assert.are.equal("a note", comment.body)
    end)
  end)
end)
