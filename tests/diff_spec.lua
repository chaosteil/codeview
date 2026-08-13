local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.diff", function()
  local fixture = fixtures.git_diff()
  local diff, session_mod
  ---@type codeview.Session?
  local opened

  ---Open a session for the whole fixture history.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Diff of one path of the session.
  ---@param review codeview.Session
  ---@param path string
  ---@return codeview.diff.File
  local function diff_of(review, path)
    local index = assert(review:index_of(path), "no changed file " .. path)
    local result, err = diff.for_file(review, assert(review:file(index)))
    assert.is_nil(err)
    return assert(result)
  end

  before_each(function()
    helpers.unload()
    session_mod = require("codeview.session")
    diff = require("codeview.diff")
  end)

  after_each(function()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    helpers.unload()
  end)

  describe("split", function()
    it("drops the element after a final line break", function()
      assert.are.same({ "one", "two" }, diff.split("one\ntwo\n"))
      assert.are.same({ "one", "two" }, diff.split("one\ntwo"))
      assert.are.same({}, diff.split(""))
      assert.are.same({}, diff.split(nil))
      assert.are.same({ "one", "" }, diff.split("one\n\n"))
    end)
  end)

  describe("is_binary", function()
    it("finds a NUL byte", function()
      assert.is_true(diff.is_binary("a\0b"))
      assert.is_false(diff.is_binary("plain text\n"))
      assert.is_false(diff.is_binary(nil))
    end)
  end)

  describe("compute", function()
    it("reports one hunk per change", function()
      local result = diff.compute("one\ntwo\nthree\n", "one\ntwo changed\nthree\n")
      assert.are.equal(1, #result.hunks)
      local hunk = result.hunks[1]
      assert.are.equal(2, hunk.old_start)
      assert.are.equal(1, hunk.old_count)
      assert.are.equal(2, hunk.new_start)
      assert.are.equal(1, hunk.new_count)
      assert.are.equal(2, hunk.old_first)
      assert.are.equal(2, hunk.new_first)
    end)

    it("reports the line after the insert point of an addition", function()
      local result = diff.compute("", "one\ntwo\n")
      local hunk = result.hunks[1]
      assert.are.equal(0, hunk.old_start)
      assert.are.equal(0, hunk.old_count)
      assert.are.equal(1, hunk.old_first)
      assert.are.equal(1, hunk.new_first)
      assert.are.equal(2, hunk.new_count)
    end)

    it("reports no hunk for equal content", function()
      local result = diff.compute("one\n", "one\n")
      assert.are.same({}, result.hunks)
      assert.is_true(diff.is_empty(result))
    end)

    it("keeps both sides as lines", function()
      local result = diff.compute("one\ntwo\n", "one\n")
      assert.are.same({ "one", "two" }, result.old_lines)
      assert.are.same({ "one" }, result.new_lines)
    end)

    it("marks binary content and reads no lines", function()
      local result = diff.compute("a\0b", "a\0c")
      assert.is_true(result.binary)
      assert.are.same({}, result.old_lines)
      assert.are.same({}, result.new_lines)
      assert.are.same({}, result.hunks)
      assert.is_false(diff.is_empty(result))
    end)

    it("keeps two near changes apart at every context length", function()
      local old = "1\n2\n3\n4\n5\n6\n7\n8\n"
      local new = "1 x\n2\n3\n4\n5\n6\n7 x\n8\n"
      for _, context in ipairs({ 1, 3, 10 }) do
        local result = diff.compute(old, new, { context = context })
        assert.are.equal(2, #result.hunks)
        assert.are.equal(context, result.context)
        local added, removed = diff.stat(result)
        assert.are.equal(2, added)
        assert.are.equal(2, removed)
      end
    end)

    it("counts the added and the removed lines", function()
      local result = diff.compute("one\ntwo\n", "one\ntwo changed\nthree\n")
      local added, removed = diff.stat(result)
      assert.are.equal(2, added)
      assert.are.equal(1, removed)
    end)
  end)

  describe("revisions", function()
    it("drops the old side of an added file", function()
      local review = open_session()
      local old_rev, new_rev = diff.revisions(review, { path = "added.txt", status = "added" })
      assert.is_nil(old_rev)
      assert.are.equal(review.range.to, new_rev)
    end)

    it("drops the new side of a deleted file", function()
      local review = open_session()
      local old_rev, new_rev = diff.revisions(review, { path = "gone.txt", status = "deleted" })
      assert.are.equal(review.range.from, old_rev)
      assert.is_nil(new_rev)
    end)

    it("takes the old path of a rename", function()
      local old_path, new_path = diff.paths({ path = "new/name.txt", old_path = "old/name.txt", status = "renamed" })
      assert.are.equal("old/name.txt", old_path)
      assert.are.equal("new/name.txt", new_path)
    end)
  end)

  describe("for_file", function()
    it("reads both sides of a modified file", function()
      local review = open_session()
      local result = diff_of(review, "long.txt")
      assert.are.equal("long.txt", result.path)
      assert.are.equal("modified", result.status)
      assert.are.equal(review.range.from, result.old_rev)
      assert.are.equal(review.range.to, result.new_rev)
      assert.are.equal(40, #result.old_lines)
      assert.are.equal(40, #result.new_lines)
      assert.are.equal(2, #result.hunks)
      assert.are.equal(3, result.hunks[1].old_first)
      assert.are.equal(30, result.hunks[2].old_first)
    end)

    it("reads an added file with an empty old side", function()
      local review = open_session()
      local result = diff_of(review, "added.txt")
      assert.are.same({}, result.old_lines)
      assert.are.same({ "added one", "added two" }, result.new_lines)
      assert.are.equal(1, #result.hunks)
      assert.are.equal(0, result.hunks[1].old_count)
    end)

    it("reads a deleted file with an empty new side", function()
      local review = open_session()
      local result = diff_of(review, "gone.txt")
      assert.are.same({ "gone one", "gone two" }, result.old_lines)
      assert.are.same({}, result.new_lines)
      assert.are.equal(0, result.hunks[1].new_count)
    end)

    it("reads both paths of a renamed file", function()
      local review = open_session()
      local result = diff_of(review, "new/name.txt")
      assert.are.equal("old/name.txt", result.old_path)
      assert.are.equal("new/name.txt", result.path)
      assert.are.equal("renamed", result.status)
      assert.is_true(diff.is_empty(result))
    end)

    it("reads an empty added file", function()
      local review = open_session()
      local result = diff_of(review, "empty.txt")
      assert.are.same({}, result.old_lines)
      assert.are.same({}, result.new_lines)
      assert.is_true(diff.is_empty(result))
    end)

    it("marks a binary file", function()
      local review = open_session()
      local result = diff_of(review, "bin.dat")
      assert.is_true(result.binary)
      assert.are.same({}, result.hunks)
    end)

    it("reads asynchronously", function()
      local review = open_session()
      local index = assert(review:index_of("long.txt"))
      local out, finished = {}, false
      diff.for_file(review, assert(review:file(index)), function(result, err)
        out.result, out.err, finished = result, err, true
      end)
      assert.is_true(vim.wait(20000, function()
        return finished
      end, 10))
      assert.is_nil(out.err)
      assert.are.equal(2, #out.result.hunks)
    end)

    it("reports an error of the backend", function()
      local review = open_session()
      local errors = require("codeview.error")
      review.repo.file_content = function()
        return nil, errors.new(errors.codes.NOT_FOUND, "no such object")
      end
      local result, err = diff.for_file(review, assert(review:file(1)))
      assert.is_nil(result)
      assert.are.equal("not_found", err.code)
    end)

    it("reports an argument that is not a session", function()
      local result, err = diff.for_file({}, { path = "a.txt", status = "added" })
      assert.is_nil(result)
      assert.are.equal("invalid_arg", err.code)
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
