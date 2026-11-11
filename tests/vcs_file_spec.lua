-- Tests of the file backend: files on the disk, with no repository.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.vcs.file", function()
  local config, file
  ---@type string
  local dir

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

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    file = require("codeview.vcs.file")
    dir = vim.fs.normalize(fixtures.tempdir("files"))
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
    helpers.unload()
  end)

  it("collects one file, with its directory as the root", function()
    write("plan.md", "# Plan\n")
    local collected = assert(file.collect({ vim.fs.joinpath(dir, "plan.md") }))
    assert.are.equal(dir, collected.root)
    assert.are.same({ "plan.md" }, collected.paths)
  end)

  it("reads a relative path from the directory of the caller", function()
    write("notes/a.txt", "a\n")
    local collected = assert(file.collect({ "notes/a.txt" }, { dir = dir }))
    assert.are.equal(dir .. "/notes", collected.root)
    assert.are.same({ "a.txt" }, collected.paths)
  end)

  it("takes the deepest common directory of the files as the root", function()
    write("a/one.txt", "1\n")
    write("b/c/two.txt", "2\n")
    local collected = assert(file.collect({ dir .. "/a/one.txt", dir .. "/b/c/two.txt" }))
    assert.are.equal(dir, collected.root)
    assert.are.same({ "a/one.txt", "b/c/two.txt" }, collected.paths)
  end)

  it("walks a directory, without the hidden, binary, and large files", function()
    write("docs/a.md", "a\n")
    write("docs/sub/b.md", "b\n")
    write("docs/.hidden.md", "hidden\n")
    write("docs/.git/config", "[core]\n")
    write("docs/.jj/repo", "x\n")
    write("docs/image.bin", "PNG\0\0data")
    write("docs/big.txt", string.rep("x", 200))
    config.setup({ files = { max_bytes = 100 } })

    local collected = assert(file.collect({ dir .. "/docs" }))
    assert.are.equal(dir .. "/docs", collected.root)
    assert.are.same({ "a.md", "sub/b.md" }, collected.paths)
    assert.are.same({ binary = 1, large = 1 }, collected.skipped)
  end)

  it("keeps a binary file, a large file, and a hidden file that the caller names", function()
    write("image.bin", "\0\0")
    write(".env", string.rep("x", 200))
    config.setup({ files = { max_bytes = 100 } })
    local collected = assert(file.collect({ dir .. "/image.bin", dir .. "/.env" }))
    assert.are.same({ ".env", "image.bin" }, collected.paths)
  end)

  it("skips the files that .gitignore ignores inside a git work tree", function()
    write("keep.txt", "keep\n")
    write("build/out.txt", "out\n")
    write(".gitignore", "build/\n")
    local res = vim
      .system({ "git", "init", "--quiet", dir }, { env = { GIT_CONFIG_GLOBAL = "/dev/null" }, text = true })
      :wait(30000)
    assert.are.equal(0, res.code, res.stderr)

    local collected = assert(file.collect({ dir }))
    assert.are.same({ "keep.txt" }, collected.paths)
  end)

  it("gives each file once", function()
    write("a.txt", "a\n")
    local collected = assert(file.collect({ dir .. "/a.txt", dir, "a.txt" }, { dir = dir }))
    assert.are.same({ "a.txt" }, collected.paths)
  end)

  it("stops at the limit of files.max_files", function()
    for index = 1, 4 do
      write("many/" .. index .. ".txt", tostring(index))
    end
    config.setup({ files = { max_files = 3 } })
    local collected, err = file.collect({ dir .. "/many" })
    assert.is_nil(collected)
    assert.are.equal("invalid_arg", err.code)
    assert.matches("more than 3 files", err.message)
  end)

  it("reports a path that does not exist", function()
    local collected, err = file.collect({ dir .. "/missing.txt" })
    assert.is_nil(collected)
    assert.are.equal("not_found", err.code)
    assert.matches("no such file", err.message)
  end)

  it("reports a directory without a file to review", function()
    write("empty/.hidden", "x\n")
    local collected, err = file.collect({ dir .. "/empty" })
    assert.is_nil(collected)
    assert.are.equal("not_found", err.code)
  end)

  it("rejects an empty path list", function()
    local collected, err = file.collect({})
    assert.is_nil(collected)
    assert.are.equal("invalid_arg", err.code)
  end)

  describe("handle", function()
    it("gives a range without a base, and the files of the paths", function()
      write("a.txt", "one\n")
      write("b/c.txt", "two\n")
      local repo = assert(file.new({ dir }))
      assert.are.equal("file", repo.backend)
      assert.are.equal(dir, repo.root)

      local range = assert(repo:resolve_range("label"))
      assert.is_nil(range.from)
      assert.matches("^%x+$", range.to)
      assert.are.equal("label", range.spec)

      assert.are.same({
        { path = "a.txt", status = "file" },
        { path = "b/c.txt", status = "file" },
      }, repo:changed_files(range))
      assert.are.same({}, repo:log({ range = range }))
      assert.are.equal("one\n", repo:file_content(range.to, "a.txt"))
      assert.are.equal("", repo:file_content(nil, "a.txt"))
      assert.are.same({}, repo:state_dirs())
    end)

    it("gives a new digest after a change of a file", function()
      write("a.txt", "one\n")
      local repo = assert(file.new({ dir .. "/a.txt" }))
      local first = assert(repo:resolve_range("a"))
      local again = assert(repo:resolve_range("a"))
      assert.are.equal(first.to, again.to)

      write("a.txt", "two\n")
      local changed = assert(repo:resolve_range("a"))
      assert.are_not.equal(first.to, changed.to)
    end)

    it("gives a digest for a binary file, and tells two binary files apart", function()
      write("a.bin", "x\0y")
      local repo = assert(file.new({ dir .. "/a.bin" }))
      local first = assert(repo:resolve_range("a"))
      write("a.bin", "x\\0y")
      local second = assert(repo:resolve_range("a"))
      assert.are_not.equal(first.to, second.to)
    end)

    it("finds a new file of a directory on the next resolve", function()
      write("a.txt", "one\n")
      local repo = assert(file.new({ dir }))
      local range = assert(repo:resolve_range("dir"))
      assert.are.equal(1, #repo:changed_files(range))
      write("b.txt", "two\n")
      range = assert(repo:resolve_range("dir"))
      assert.are.equal(2, #repo:changed_files(range))
    end)

    it("answers in the async form", function()
      write("a.txt", "one\n")
      local repo = assert(file.new({ dir .. "/a.txt" }))
      local answer
      repo:resolve_range("a", function(range, err)
        answer = { range = range, err = err }
      end)
      assert.is_nil(answer, "the callback runs on the main loop")
      vim.wait(1000, function()
        return answer ~= nil
      end)
      assert.is_nil(answer.err)
      assert.is_truthy(answer.range.to)
    end)

    it("reports a file that went away", function()
      write("a.txt", "one\n")
      local repo = assert(file.new({ dir .. "/a.txt" }))
      assert(repo:resolve_range("a"))
      os.remove(dir .. "/a.txt")
      local content, err = repo:file_content("x", "a.txt")
      assert.is_nil(content)
      assert.are.equal("not_found", err.code)
    end)

    it("is no candidate of the detection", function()
      local repo, err = file.detect(dir)
      assert.is_nil(repo)
      assert.are.equal("not_a_repo", err.code)
    end)
  end)
end)
