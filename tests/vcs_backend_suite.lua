-- Backend-agnostic tests for the interface of `codeview.vcs`.
--
-- One spec file per backend calls this function with its own fixture builder.
-- The file name has no `_spec` suffix, so the test runner does not load it on
-- its own.

local fixtures = require("tests.fixtures")

---@class tests.SuiteOpts
---@field name string Name of the backend under test.
---@field backend codeview.vcs.Backend Backend module.
---@field fixture fun(): tests.Fixture Builder of the fixture repository.
---@field head_rev string Revision name of the newest commit, for example "HEAD".
---@field detects_renames boolean? False when the backend reports a rename as an add and a delete.

---Run an async call and wait for its callback.
---@param fn fun(cb: fun(value: any?, err: codeview.Error?))
---@return any? value
---@return codeview.Error? err
local function await(fn)
  local out, finished = {}, false
  fn(function(value, err)
    out.value, out.err, finished = value, err, true
  end)
  assert.is_true(
    vim.wait(20000, function()
      return finished
    end, 10),
    "the async call did not answer"
  )
  return out.value, out.err
end

---@param files codeview.vcs.FileChange[]
---@return table<string, codeview.vcs.FileChange>
local function by_path(files)
  local out = {}
  for _, file in ipairs(files) do
    out[file.path] = file
  end
  return out
end

---@param opts tests.SuiteOpts
return function(opts)
  local backend = opts.backend
  local detects_renames = opts.detects_renames ~= false

  describe("codeview.vcs backend: " .. opts.name, function()
    local fixture = opts.fixture()
    local outside = fixtures.tempdir("codeview-outside")
    local repo = assert(backend.detect(fixture.root))

    describe("detection", function()
      it("finds the root from the root directory", function()
        local found, err = backend.detect(fixture.root)
        assert.is_nil(err)
        assert.are.equal(fixture.root, found.root)
        assert.are.equal(opts.name, found.backend)
      end)

      it("finds the root from a subdirectory", function()
        local found, err = backend.detect(vim.fs.joinpath(fixture.root, "dir"))
        assert.is_nil(err)
        assert.are.equal(fixture.root, found.root)
      end)

      it("finds the root from a file inside the repository", function()
        local found, err = backend.detect(vim.fs.joinpath(fixture.root, "a.txt"))
        assert.is_nil(err)
        assert.are.equal(fixture.root, found.root)
      end)

      it("returns nil outside a repository", function()
        local found, err = backend.detect(outside)
        assert.is_nil(found)
        assert.are.equal("not_a_repo", err.code)
        assert.is_truthy(tostring(err):find(outside, 1, true), tostring(err))
      end)

      it("returns an error for a directory that does not exist", function()
        local found, err = backend.detect(vim.fs.joinpath(outside, "missing"))
        assert.is_nil(found)
        assert.are.equal("not_found", err.code)
      end)

      it("detects asynchronously", function()
        local found, err = await(function(cb)
          backend.detect(fixture.root, cb)
        end)
        assert.is_nil(err)
        assert.are.equal(fixture.root, found.root)
      end)
    end)

    describe("resolve_rev", function()
      it("resolves the head revision", function()
        local id, err = repo:resolve_rev(opts.head_rev)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.shuffle, id)
      end)

      it("resolves a full commit id to itself", function()
        local id, err = repo:resolve_rev(fixture.ids.init)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.init, id)
      end)

      it("resolves a short commit id", function()
        local id, err = repo:resolve_rev(fixture.ids.edit:sub(1, 8))
        assert.is_nil(err)
        assert.are.equal(fixture.ids.edit, id)
      end)

      it("returns an error for an unknown revision", function()
        local id, err = repo:resolve_rev("no-such-revision")
        assert.is_nil(id)
        assert.are.equal("bad_revision", err.code)
        assert.is_truthy(tostring(err):find("no-such-revision", 1, true), tostring(err))
      end)

      it("returns an error for an empty revision", function()
        local id, err = repo:resolve_rev("")
        assert.is_nil(id)
        assert.are.equal("invalid_arg", err.code)
      end)

      it("resolves asynchronously", function()
        local id, err = await(function(cb)
          repo:resolve_rev(opts.head_rev, cb)
        end)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.shuffle, id)
      end)
    end)

    describe("resolve_range", function()
      it("uses the parent as the base of one commit", function()
        local range, err = repo:resolve_range(fixture.ids.shuffle)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.shuffle, range.to)
        assert.are.equal(fixture.ids.edit, range.from)
      end)

      it("has no base for the first commit", function()
        local range, err = repo:resolve_range(fixture.ids.init)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.init, range.to)
        assert.is_nil(range.from)
      end)

      it("resolves both sides of a two dot range", function()
        local range, err = repo:resolve_range(fixture.ids.init .. ".." .. fixture.ids.shuffle)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.init, range.from)
        assert.are.equal(fixture.ids.shuffle, range.to)
      end)

      it("keeps the text of the range", function()
        local spec = fixture.ids.init .. ".." .. opts.head_rev
        local range = assert(repo:resolve_range(spec))
        assert.are.equal(spec, range.spec)
      end)

      it("returns an error for an unknown side", function()
        local range, err = repo:resolve_range("no-such-revision.." .. opts.head_rev)
        assert.is_nil(range)
        assert.are.equal("bad_revision", err.code)
      end)

      it("resolves asynchronously", function()
        local range, err = await(function(cb)
          repo:resolve_range(fixture.ids.edit, cb)
        end)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.init, range.from)
        assert.are.equal(fixture.ids.edit, range.to)
      end)
    end)

    describe("log", function()
      it("lists the commits, newest first", function()
        local commits, err = repo:log()
        assert.is_nil(err)
        assert.are.equal(#fixture.names, #commits)
        assert.are.equal(fixture.ids.shuffle, commits[1].id)
        assert.are.equal(fixture.ids.init, commits[#commits].id)
      end)

      it("fills every field of a commit record", function()
        local commits = assert(repo:log({ limit = 1 }))
        local commit = commits[1]
        assert.are.equal(fixture.ids.shuffle, commit.id)
        assert.are.equal("shuffle: delete, rename, and modify", commit.subject)
        assert.are.equal("Ada Lovelace", commit.author)
        assert.is_truthy(commit.date:find("^%d%d%d%d%-%d%d%-%d%d"), commit.date)
        assert.is_truthy(#commit.short_id > 0)
        assert.are.equal(1, #commit.parents)
        assert.are.equal(fixture.ids.edit, commit.parents[1])
      end)

      it("respects the limit", function()
        local commits = assert(repo:log({ limit = 2 }))
        assert.are.equal(2, #commits)
      end)

      it("lists only the commits of a range", function()
        local range = assert(repo:resolve_range(fixture.ids.init .. ".." .. fixture.ids.shuffle))
        local commits = assert(repo:log({ range = range }))
        assert.are.equal(2, #commits)
        assert.are.equal(fixture.ids.shuffle, commits[1].id)
        assert.are.equal(fixture.ids.edit, commits[2].id)
      end)

      it("reports the first commit for a range without a base", function()
        local range = assert(repo:resolve_range(fixture.ids.init))
        local commits = assert(repo:log({ range = range }))
        assert.are.equal(1, #commits)
        assert.are.equal(fixture.ids.init, commits[1].id)
      end)

      it("returns an error for an unknown revision", function()
        local commits, err = repo:log({ revs = { "no-such-revision" } })
        assert.is_nil(commits)
        assert.are.equal("bad_revision", err.code)
      end)

      it("reads the log asynchronously", function()
        local commits, err = await(function(cb)
          repo:log({ limit = 1 }, cb)
        end)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.shuffle, commits[1].id)
      end)
    end)

    describe("changed_files", function()
      it("reports every file of the first commit as added", function()
        local range = assert(repo:resolve_range(fixture.ids.init))
        local files = assert(repo:changed_files(range))
        local map = by_path(files)
        assert.are.equal(3, #files)
        assert.are.equal("added", map["a.txt"].status)
        assert.are.equal("added", map["keep.txt"].status)
        assert.are.equal("added", map["dir/nested.txt"].status)
      end)

      it("reports an add and a modification", function()
        local range = assert(repo:resolve_range(fixture.ids.edit))
        local map = by_path(assert(repo:changed_files(range)))
        assert.are.equal("modified", map["a.txt"].status)
        assert.are.equal("added", map["added.txt"].status)
      end)

      it("reports a delete, a rename, and a modification", function()
        local range = assert(repo:resolve_range(fixture.ids.shuffle))
        local map = by_path(assert(repo:changed_files(range)))
        assert.are.equal("modified", map["a.txt"].status)
        assert.are.equal("deleted", map["keep.txt"].status)
        if detects_renames then
          assert.are.equal("renamed", map["dir/renamed.txt"].status)
          assert.are.equal("dir/nested.txt", map["dir/renamed.txt"].old_path)
        end
      end)

      it("sums the changes of a range", function()
        local range = assert(repo:resolve_range(fixture.ids.init .. ".." .. fixture.ids.shuffle))
        local map = by_path(assert(repo:changed_files(range)))
        assert.are.equal("modified", map["a.txt"].status)
        assert.are.equal("added", map["added.txt"].status)
        assert.are.equal("deleted", map["keep.txt"].status)
      end)

      it("reports the whole tree when a later commit has no base", function()
        local map = by_path(assert(repo:changed_files({ to = fixture.ids.shuffle })))
        assert.are.equal("added", map["a.txt"].status)
        assert.are.equal("added", map["added.txt"].status)
        assert.are.equal("added", map["dir/renamed.txt"].status)
        assert.is_nil(map["keep.txt"])
      end)

      it("returns an empty list for a range without changes", function()
        local files, err = repo:changed_files({ from = fixture.ids.shuffle, to = fixture.ids.shuffle })
        assert.is_nil(err)
        assert.are.same({}, files)
      end)

      it("returns an error for a range without a head revision", function()
        local files, err = repo:changed_files({})
        assert.is_nil(files)
        assert.are.equal("invalid_arg", err.code)
      end)

      it("returns an error for an unknown revision", function()
        local files, err = repo:changed_files({ from = "no-such-revision", to = fixture.ids.shuffle })
        assert.is_nil(files)
        assert.are.equal("bad_revision", err.code)
      end)

      it("lists the changed files asynchronously", function()
        local range = assert(repo:resolve_range(fixture.ids.edit))
        local files, err = await(function(cb)
          repo:changed_files(range, cb)
        end)
        assert.is_nil(err)
        assert.are.equal("modified", by_path(files)["a.txt"].status)
      end)
    end)

    describe("file_content", function()
      it("reads a file at a revision", function()
        local content, err = repo:file_content(fixture.ids.init, "a.txt")
        assert.is_nil(err)
        assert.are.equal(fixtures.content_at("init", "a.txt"), content)
      end)

      it("reads the newest version of a file", function()
        local content = assert(repo:file_content(opts.head_rev, "a.txt"))
        assert.are.equal(fixtures.content_at("shuffle", "a.txt"), content)
      end)

      it("reads a file in a subdirectory", function()
        local content = assert(repo:file_content(fixture.ids.init, "dir/nested.txt"))
        assert.are.equal(fixtures.content_at("init", "dir/nested.txt"), content)
      end)

      it("reads a file under its old path before a rename", function()
        local content = assert(repo:file_content(fixture.ids.edit, "dir/nested.txt"))
        assert.are.equal(fixtures.content_at("edit", "dir/nested.txt"), content)
      end)

      it("returns empty content for a nil revision", function()
        local content, err = repo:file_content(nil, "a.txt")
        assert.is_nil(err)
        assert.are.equal("", content)
      end)

      it("returns empty content for the missing side of an added file", function()
        local content, err = repo:file_content(fixture.ids.init, "added.txt")
        assert.is_nil(err)
        assert.are.equal("", content)
      end)

      it("returns empty content for the missing side of a deleted file", function()
        local content, err = repo:file_content(fixture.ids.shuffle, "keep.txt")
        assert.is_nil(err)
        assert.are.equal("", content)
      end)

      it("returns an error for an unknown revision", function()
        local content, err = repo:file_content("no-such-revision", "a.txt")
        assert.is_nil(content)
        assert.are.equal("bad_revision", err.code)
      end)

      it("returns an error for an empty path", function()
        local content, err = repo:file_content(opts.head_rev, "")
        assert.is_nil(content)
        assert.are.equal("invalid_arg", err.code)
      end)

      it("reads a file asynchronously", function()
        local content, err = await(function(cb)
          repo:file_content(fixture.ids.init, "keep.txt", cb)
        end)
        assert.is_nil(err)
        assert.are.equal(fixtures.content_at("init", "keep.txt"), content)
      end)
    end)

    describe("working copy", function()
      it("reports the commit that the working copy sits on", function()
        local id, err = repo:working_rev()
        assert.is_nil(err)
        assert.are.equal(fixture.ids.shuffle, id)
      end)

      it("keeps the commit when no file changed", function()
        -- The fixture writes no file after the last commit, so the update of
        -- the working copy finds nothing new.
        local id, err = repo:snapshot()
        assert.is_nil(err)
        assert.are.equal(fixture.ids.shuffle, id)
      end)

      it("reads the working-copy commit asynchronously", function()
        local id, err = await(function(cb)
          repo:working_rev(cb)
        end)
        assert.is_nil(err)
        assert.are.equal(fixture.ids.shuffle, id)
      end)
    end)

    describe("cleanup", function()
      it("removes the fixture", function()
        fixture.cleanup()
        vim.fn.delete(outside, "rf")
        assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
      end)
    end)
  end)
end
