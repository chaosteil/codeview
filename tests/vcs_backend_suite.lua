-- Backend-agnostic tests for the interface of `codeview.vcs`.
--
-- One spec file per backend calls this function with its own fixture builder.
-- The file name has no `_spec` suffix, so the test runner does not load it on
-- its own.

local fixtures = require("tests.fixtures")

---@class tests.ShapeCommit
---@field name string Key of the commit in `fixture.ids`.
---@field parents string[] Names of the parent commits, first parent first. The first commit has none.
---@field message string Commit message.
---@field write table<string, string> Files to write, path to content.
---@field links table<string, string> Symbolic links to make, path to target.

---History of the shapes fixture, oldest commit first.
---
--- The history is:
---
---     base -> left  -> merge (parents: left, right)
---     base -> right -> cross (parents: right, left)
---
--- `merge` and `cross` make a criss-cross history: the two commits have two
--- merge bases, `left` and `right`. `base` holds a symbolic link, a path with
--- a space, a binary file, and a message with a body.
---@type tests.ShapeCommit[]
local SHAPES = {
  {
    name = "base",
    parents = {},
    message = "base: add the odd files\nsecond line of the first paragraph\n\nbody one\nbody two\n",
    write = {
      ["a.txt"] = "one\ntwo\n",
      ["space dir/with space.txt"] = "spaced\n",
      ["bin.dat"] = "\0\1\2 binary \3\0\255",
    },
    links = { ["link.txt"] = "a.txt" },
  },
  {
    name = "left",
    parents = { "base" },
    message = "left: add left.txt",
    write = { ["left.txt"] = "left\n" },
    links = {},
  },
  {
    name = "right",
    parents = { "base" },
    message = "right: add right.txt",
    write = { ["right.txt"] = "right\n" },
    links = {},
  },
  { name = "merge", parents = { "left", "right" }, message = "merge: right into left", write = {}, links = {} },
  { name = "cross", parents = { "right", "left" }, message = "cross: left into right", write = {}, links = {} },
}

---@class tests.SuiteOpts
---@field name string Name of the backend under test.
---@field backend codeview.vcs.Backend Backend module.
---@field fixture fun(): tests.Fixture Builder of the fixture repository.
---@field shapes fun(history: tests.ShapeCommit[]): tests.Fixture Builder of a repository with the given history.
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

    describe("state_dirs", function()
      it("reports directories that exist", function()
        local dirs, err = repo:state_dirs()
        assert.is_nil(err)
        assert.is_true(#dirs > 0, "the backend reports no state directory")
        for _, dir in ipairs(dirs) do
          assert.are.equal(1, vim.fn.isdirectory(dir), dir .. " is no directory")
          assert.is_truthy(dir:find(fixture.root, 1, true), dir .. " is outside " .. fixture.root)
        end
      end)

      it("reports the same directories asynchronously", function()
        local first = assert(repo:state_dirs())
        local dirs, err = await(function(cb)
          repo:state_dirs(cb)
        end)
        assert.is_nil(err)
        assert.are.same(first, dirs)
      end)
    end)

    describe("errors in the async form", function()
      it("reports a directory outside a repository", function()
        local found, err = await(function(cb)
          backend.detect(outside, cb)
        end)
        assert.is_nil(found)
        assert.are.equal("not_a_repo", err.code)
      end)

      it("reports a directory that does not exist", function()
        local found, err = await(function(cb)
          backend.detect(vim.fs.joinpath(outside, "missing"), cb)
        end)
        assert.is_nil(found)
        assert.are.equal("not_found", err.code)
      end)

      it("reports an unknown revision in resolve_rev", function()
        local id, err = await(function(cb)
          repo:resolve_rev("no-such-revision", cb)
        end)
        assert.is_nil(id)
        assert.are.equal("bad_revision", err.code)
      end)

      it("reports an empty revision in resolve_rev", function()
        local id, err = await(function(cb)
          repo:resolve_rev("", cb)
        end)
        assert.is_nil(id)
        assert.are.equal("invalid_arg", err.code)
      end)

      it("reports an unknown revision in resolve_range", function()
        local range, err = await(function(cb)
          repo:resolve_range("no-such-revision", cb)
        end)
        assert.is_nil(range)
        assert.are.equal("bad_revision", err.code)
      end)

      it("reports an unknown side of a table form", function()
        for _, kind in ipairs({ "single", "range", "triple" }) do
          local range, err = await(function(cb)
            repo:resolve_range({ kind = kind, from = "no-such-revision", to = "no-such-revision", spec = "x" }, cb)
          end)
          assert.is_nil(range, kind)
          assert.are.equal("bad_revision", err.code, kind)
        end
      end)

      it("reports a table without a head revision", function()
        local range, err = await(function(cb)
          repo:resolve_range({}, cb)
        end)
        assert.is_nil(range)
        assert.are.equal("invalid_arg", err.code)
      end)

      it("reports an unknown revision in the log", function()
        local commits, err = await(function(cb)
          repo:log({ revs = { "no-such-revision" } }, cb)
        end)
        assert.is_nil(commits)
        assert.are.equal("bad_revision", err.code)
      end)

      it("reports an unknown revision in changed_files", function()
        local files, err = await(function(cb)
          repo:changed_files({ from = "no-such-revision", to = fixture.ids.shuffle }, cb)
        end)
        assert.is_nil(files)
        assert.are.equal("bad_revision", err.code)
      end)

      it("reports a range without a head revision in changed_files", function()
        local files, err = await(function(cb)
          repo:changed_files({}, cb)
        end)
        assert.is_nil(files)
        assert.are.equal("invalid_arg", err.code)
      end)

      it("reports an unknown revision in file_content", function()
        local content, err = await(function(cb)
          repo:file_content("no-such-revision", "a.txt", cb)
        end)
        assert.is_nil(content)
        assert.are.equal("bad_revision", err.code)
      end)

      it("reports an empty path in file_content", function()
        local content, err = await(function(cb)
          repo:file_content(opts.head_rev, "", cb)
        end)
        assert.is_nil(content)
        assert.are.equal("invalid_arg", err.code)
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

  describe("codeview.vcs backend: " .. opts.name .. " on merges and odd files", function()
    local shapes = opts.shapes(SHAPES)
    local ids = shapes.ids
    local repo = assert(backend.detect(shapes.root))

    ---Ids of a list of commits.
    ---@param commits codeview.vcs.Commit[]
    ---@return string[]
    local function ids_of(commits)
      return vim.tbl_map(function(commit)
        return commit.id
      end, commits)
    end

    describe("a merge", function()
      it("lists both parents, the first parent first", function()
        local commit = assert(repo:log({ revs = { ids.merge }, limit = 1 }))[1]
        assert.are.equal(ids.merge, commit.id)
        assert.are.same({ ids.left, ids.right }, commit.parents)
      end)

      it("uses the first parent as the base, in the text form and in the table form", function()
        for _, spec in ipairs({ ids.merge, { kind = "single", to = ids.merge, spec = "merge" } }) do
          local range, err = repo:resolve_range(spec)
          assert.is_nil(err)
          assert.are.equal(ids.left, range.from)
          assert.are.equal(ids.merge, range.to)
        end
      end)

      it("lists the changes against the first parent", function()
        local range = assert(repo:resolve_range({ kind = "single", to = ids.merge, spec = "merge" }))
        local files = assert(repo:changed_files(range))
        assert.are.equal(1, #files)
        assert.are.equal("right.txt", files[1].path)
        assert.are.equal("added", files[1].status)
      end)

      it("lists the revisions of the log with all their ancestors", function()
        local commits = assert(repo:log({ revs = { ids.merge } }))
        local listed = ids_of(commits)
        assert.are.equal(4, #listed)
        assert.are.equal(ids.merge, listed[1])
        assert.are.equal(ids.base, listed[4])
        assert.is_true(vim.tbl_contains(listed, ids.left))
        assert.is_true(vim.tbl_contains(listed, ids.right))
      end)

      it("lists the commits of a range into a merge", function()
        local commits = assert(repo:log({ range = { from = ids.left, to = ids.merge } }))
        assert.are.same({ ids.merge, ids.right }, ids_of(commits))
      end)
    end)

    describe("the table forms", function()
      it("gives no base for a single commit without a parent", function()
        local range, err = repo:resolve_range({ kind = "single", to = ids.base, spec = "base" })
        assert.is_nil(err)
        assert.is_nil(range.from)
        assert.are.equal(ids.base, range.to)
      end)

      it("reads range as a diff of two trees", function()
        for _, spec in ipairs({
          { kind = "range", from = ids.left, to = ids.right, spec = "left..right" },
          { from = ids.left, to = ids.right },
        }) do
          local range, err = repo:resolve_range(spec)
          assert.is_nil(err)
          assert.are.equal(ids.left, range.from)
          assert.are.equal(ids.right, range.to)
          local map = by_path(assert(repo:changed_files(range)))
          assert.are.equal("deleted", map["left.txt"].status)
          assert.are.equal("added", map["right.txt"].status)
        end
      end)

      it("reads a table without a base as the whole tree", function()
        for _, spec in ipairs({ { to = ids.left }, { kind = "explicit", to = ids.left, spec = "left" } }) do
          local range, err = repo:resolve_range(spec)
          assert.is_nil(err)
          assert.is_nil(range.from)
          assert.are.equal(ids.left, range.to)
          local map = by_path(assert(repo:changed_files(range)))
          assert.are.equal("added", map["left.txt"].status)
          assert.are.equal("added", map["a.txt"].status)
        end
      end)

      it("reads triple through the merge base", function()
        local range, err = repo:resolve_range({ kind = "triple", from = ids.left, to = ids.right, spec = "x" })
        assert.is_nil(err)
        assert.are.equal(ids.base, range.from)
        assert.are.equal(ids.right, range.to)
      end)

      it("reads the parsed form of `a...b`", function()
        local parsed = assert(require("codeview.vcs").parse_range(ids.left .. "..." .. ids.right))
        local range, err = repo:resolve_range(parsed)
        assert.is_nil(err)
        assert.are.equal(ids.base, range.from)
        assert.are.equal(ids.right, range.to)
        assert.are.equal(ids.left .. "..." .. ids.right, range.spec)
      end)

      it("takes one merge base of a criss-cross history", function()
        local range, err = repo:resolve_range({ kind = "triple", from = ids.merge, to = ids.cross, spec = "x" })
        assert.is_nil(err)
        assert.are.equal(ids.cross, range.to)
        assert.is_true(range.from == ids.left or range.from == ids.right, tostring(range.from))
      end)

      it("takes one merge base asynchronously", function()
        local range, err = await(function(cb)
          repo:resolve_range({ kind = "triple", from = ids.merge, to = ids.cross, spec = "x" }, cb)
        end)
        assert.is_nil(err)
        assert.is_true(range.from == ids.left or range.from == ids.right, tostring(range.from))
      end)

      it("rejects a range form without a base", function()
        for _, kind in ipairs({ "range", "triple" }) do
          local range, err = repo:resolve_range({ kind = kind, to = ids.left, spec = "x" })
          assert.is_nil(range, kind)
          assert.are.equal("invalid_arg", err.code, kind)
        end
      end)
    end)

    describe("commit messages", function()
      it("splits the subject at the first line", function()
        local commit = assert(repo:log({ revs = { ids.base }, limit = 1 }))[1]
        assert.are.equal("base: add the odd files", commit.subject)
        assert.are.equal("second line of the first paragraph\n\nbody one\nbody two", commit.body)
      end)

      it("gives an empty body for a message of one line", function()
        local commit = assert(repo:log({ revs = { ids.left }, limit = 1 }))[1]
        assert.are.equal("left: add left.txt", commit.subject)
        assert.are.equal("", commit.body)
      end)
    end)

    describe("odd files", function()
      it("lists a symbolic link, a path with a space, and a binary file", function()
        local map = by_path(assert(repo:changed_files({ to = ids.base })))
        assert.are.equal("added", map["link.txt"].status)
        assert.are.equal("added", map["space dir/with space.txt"].status)
        assert.are.equal("added", map["bin.dat"].status)
      end)

      it("reads a symbolic link as its target", function()
        assert.are.equal("a.txt", assert(repo:file_content(ids.base, "link.txt")))
      end)

      it("reads a path with a space", function()
        assert.are.equal("spaced\n", assert(repo:file_content(ids.base, "space dir/with space.txt")))
      end)

      it("reads the bytes of a binary file", function()
        assert.are.equal(SHAPES[1].write["bin.dat"], assert(repo:file_content(ids.base, "bin.dat")))
      end)

      it("reads them asynchronously", function()
        for path, want in pairs({ ["link.txt"] = "a.txt", ["space dir/with space.txt"] = "spaced\n" }) do
          local content, err = await(function(cb)
            repo:file_content(ids.base, path, cb)
          end)
          assert.is_nil(err)
          assert.are.equal(want, content)
        end
      end)
    end)

    describe("cleanup", function()
      it("removes the fixture", function()
        shapes.cleanup()
        assert.are.equal(0, vim.fn.isdirectory(shapes.dir))
      end)
    end)
  end)
end
