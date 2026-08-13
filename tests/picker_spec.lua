local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

---Build a selector that answers with fixed positions.
---
--- A position of `false` stands for a cancelled list.
---@param picks (integer|boolean)[]
---@return function select
---@return table[] calls Items and options of every call.
local function chooser(picks)
  local calls = {}
  return function(items, opts, on_choice)
    calls[#calls + 1] = { items = items, opts = opts }
    local pick = picks[#calls]
    if not pick then
      on_choice(nil, nil)
      return
    end
    on_choice(items[pick], pick)
  end,
    calls
end

---Run a pick flow and wait for its answer.
---@param fn fun(cb: fun(session: codeview.Session?, err: codeview.Error?))
---@return codeview.Session? session
---@return codeview.Error? err
local function await(fn)
  local out, finished = {}, false
  fn(function(session, err)
    out.session, out.err, finished = session, err, true
  end)
  assert.is_true(
    vim.wait(20000, function()
      return finished
    end, 10),
    "the picker did not answer"
  )
  return out.session, out.err
end

describe("codeview.picker", function()
  local fixture = fixtures.git()
  local branched = fixtures.git_branched()
  local picker, session

  before_each(function()
    helpers.unload()
    require("codeview.config").setup({ commit_message = false })
    picker = require("codeview.picker")
    session = require("codeview.session")
  end)

  after_each(function()
    session.close()
    helpers.unload()
  end)

  describe("parse_date", function()
    it("reads a UTC timestamp", function()
      assert.are.equal(1704106800, picker.parse_date("2024-01-01T11:00:00+00:00"))
    end)

    it("reads a timestamp with the Z suffix", function()
      assert.are.equal(1704106800, picker.parse_date("2024-01-01T11:00:00Z"))
    end)

    it("reads a positive time zone offset", function()
      assert.are.equal(1704106800, picker.parse_date("2024-01-01T12:00:00+01:00"))
    end)

    it("reads a negative time zone offset", function()
      assert.are.equal(1704106800, picker.parse_date("2024-01-01T06:00:00-0500"))
    end)

    it("rejects text of another form", function()
      assert.is_nil(picker.parse_date("last tuesday"))
      assert.is_nil(picker.parse_date(nil))
    end)
  end)

  describe("relative_date", function()
    local now = 1704106800

    it("names a fresh timestamp", function()
      assert.are.equal("just now", picker.relative_date(now - 10, now))
    end)

    it("counts the minutes", function()
      assert.are.equal("1 minute ago", picker.relative_date(now - 60, now))
      assert.are.equal("5 minutes ago", picker.relative_date(now - 300, now))
    end)

    it("counts the hours", function()
      assert.are.equal("2 hours ago", picker.relative_date(now - 7200, now))
    end)

    it("counts the days", function()
      assert.are.equal("3 days ago", picker.relative_date(now - 3 * 86400, now))
    end)

    it("counts the months", function()
      assert.are.equal("2 months ago", picker.relative_date(now - 60 * 86400, now))
    end)

    it("counts the years", function()
      assert.are.equal("1 year ago", picker.relative_date(now - 400 * 86400, now))
      assert.are.equal("3 years ago", picker.relative_date(now - 3 * 366 * 86400, now))
    end)
  end)

  describe("format_commit", function()
    it("shows the short id, the subject, and the age", function()
      local commit = {
        short_id = "abc1234",
        subject = "feat: add the picker",
        date = "2024-01-01T11:00:00+00:00",
      }
      local entry = picker.format_commit(commit, 1704106800 + 2 * 86400)
      assert.is_truthy(entry:find("abc1234", 1, true), entry)
      assert.is_truthy(entry:find("feat: add the picker", 1, true), entry)
      assert.is_truthy(entry:find("2 days ago", 1, true), entry)
    end)

    it("falls back to the raw date", function()
      local entry = picker.format_commit({ short_id = "abc1234", subject = "s", date = "yesterday" })
      assert.is_truthy(entry:find("yesterday", 1, true), entry)
    end)
  end)

  describe("build_range", function()
    local first = { id = "aaa", short_id = "aaaaaaa", parents = { "base" } }
    local last = { id = "bbb", short_id = "bbbbbbb", parents = { "aaa" } }

    it("takes the parent of the older commit as the base", function()
      local range = picker.build_range(first, last)
      assert.are.equal("range", range.kind)
      assert.are.equal("base", range.from)
      assert.are.equal("bbb", range.to)
      assert.are.equal("aaaaaaa^..bbbbbbb", range.spec)
    end)

    it("builds a single commit range for two equal picks", function()
      local range = picker.build_range(first, first)
      assert.are.equal("single", range.kind)
      assert.are.equal("aaa", range.to)
      assert.are.equal("aaaaaaa", range.spec)
    end)

    it("has no base when the older commit is the first commit", function()
      local range = picker.build_range({ id = "root", short_id = "rootroo", parents = {} }, last)
      assert.are.equal("explicit", range.kind)
      assert.is_nil(range.from)
      assert.are.equal("bbb", range.to)
    end)
  end)

  describe("pick_single", function()
    it("opens a session for the picked commit", function()
      local select = chooser({ 2 })
      local opened, err = await(function(cb)
        picker.pick_single({ dir = fixture.dir, select = select }, cb)
      end)
      assert.is_nil(err)
      assert.are.equal(fixture.ids.edit, opened.range.to)
      assert.are.equal(fixture.ids.init, opened.range.from)
      assert.are.equal(opened, session.current())
    end)

    it("shows the log newest first, with a short id and an age", function()
      local select, calls = chooser({ 1 })
      await(function(cb)
        picker.pick_single({ dir = fixture.dir, select = select }, cb)
      end)
      assert.are.equal(1, #calls)
      assert.are.equal(3, #calls[1].items)
      assert.are.equal(fixture.ids.shuffle, calls[1].items[1].id)

      local entry = calls[1].opts.format_item(calls[1].items[1])
      assert.is_truthy(entry:find("shuffle: delete, rename, and modify", 1, true), entry)
      assert.is_truthy(entry:find("ago", 1, true), entry)
    end)

    it("respects the limit", function()
      local select, calls = chooser({ 1 })
      await(function(cb)
        picker.pick_single({ dir = fixture.dir, limit = 2, select = select }, cb)
      end)
      assert.are.equal(2, #calls[1].items)
    end)

    it("reports a cancelled pick without an error", function()
      local opened, err = await(function(cb)
        picker.pick_single({ dir = fixture.dir, select = chooser({}) }, cb)
      end)
      assert.is_nil(opened)
      assert.is_nil(err)
      assert.is_nil(session.current())
    end)

    it("reports a directory outside a repository", function()
      local outside = fixtures.tempdir("codeview-outside")
      local opened, err = await(function(cb)
        picker.pick_single({ dir = outside, select = chooser({ 1 }) }, cb)
      end)
      vim.fn.delete(outside, "rf")
      assert.is_nil(opened)
      assert.are.equal("not_a_repo", err.code)
    end)
  end)

  describe("pick_range", function()
    it("builds the range from two picks", function()
      -- The log is [shuffle, edit, init]. Pick edit first, then shuffle.
      local select = chooser({ 2, 1 })
      local opened, err = await(function(cb)
        picker.pick_range({ dir = fixture.dir, select = select }, cb)
      end)
      assert.is_nil(err)
      assert.are.equal(fixture.ids.init, opened.range.from)
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
      assert.are.equal(2, #opened.commits)
    end)

    it("shows only the commits that are not older than the first pick", function()
      local select, calls = chooser({ 2, 1 })
      await(function(cb)
        picker.pick_range({ dir = fixture.dir, select = select }, cb)
      end)
      assert.are.equal(2, #calls)
      assert.are.equal(3, #calls[1].items)
      assert.are.equal(2, #calls[2].items)
      assert.are.equal(fixture.ids.edit, calls[2].items[2].id)
    end)

    it("reviews one commit when both picks are equal", function()
      local select = chooser({ 1, 1 })
      local opened = assert(await(function(cb)
        picker.pick_range({ dir = fixture.dir, select = select }, cb)
      end))
      assert.are.equal(fixture.ids.edit, opened.range.from)
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
    end)

    it("has no base when the first pick is the first commit", function()
      local select = chooser({ 3, 2 })
      local opened = assert(await(function(cb)
        picker.pick_range({ dir = fixture.dir, select = select }, cb)
      end))
      assert.is_nil(opened.range.from)
      assert.are.equal(fixture.ids.edit, opened.range.to)
      assert.are.equal(4, #opened.files)
    end)

    it("reports a cancelled second pick", function()
      local opened, err = await(function(cb)
        picker.pick_range({ dir = fixture.dir, select = chooser({ 2 }) }, cb)
      end)
      assert.is_nil(opened)
      assert.is_nil(err)
      assert.is_nil(session.current())
    end)
  end)

  describe("descendants", function()
    -- base <- one <- two, and base <- other on a second branch.
    local base = { id = "base", short_id = "base", parents = {} }
    local one = { id = "one", short_id = "one", parents = { "base" } }
    local two = { id = "two", short_id = "two", parents = { "one" } }
    local other = { id = "other", short_id = "other", parents = { "base" } }
    local log = { two, other, one, base }

    it("keeps the commits that follow the pick, in the order of the log", function()
      local ids = vim.tbl_map(function(commit)
        return commit.id
      end, picker.descendants(log, one))
      assert.are.same({ "two", "one" }, ids)
    end)

    it("keeps every commit for the first commit of the history", function()
      assert.are.equal(4, #picker.descendants(log, base))
    end)

    it("follows every parent of a merge", function()
      local merge = { id = "merge", short_id = "merge", parents = { "two", "other" } }
      local ids = vim.tbl_map(function(commit)
        return commit.id
      end, picker.descendants({ merge, two, other, one, base }, other))
      assert.are.same({ "merge", "other" }, ids)
    end)
  end)

  describe("pick_range on a branched history", function()
    -- The log is [merge, feature_two, main_one, feature_one, base].
    it("offers only the descendants of the first pick", function()
      local select, calls = chooser({ 4, 1 })
      local opened = assert(await(function(cb)
        picker.pick_range({ dir = branched.dir, select = select }, cb)
      end))

      local ids = vim.tbl_map(function(commit)
        return commit.id
      end, calls[2].items)
      assert.are.same({ branched.ids.merge, branched.ids.feature_two, branched.ids.feature_one }, ids)

      -- The first pick belongs to the review, together with its file.
      assert.are.equal(branched.ids.base, opened.range.from)
      assert.are.equal(branched.ids.merge, opened.range.to)
      assert.is_truthy(vim.iter(opened.commits):any(function(commit)
        return commit.id == branched.ids.feature_one
      end))
      assert.is_truthy(opened:index_of("c.txt"))
    end)

    it("rejects a last pick that is not a descendant of the first pick", function()
      local first_list
      local step = 0
      local select = function(items, _, on_choice)
        step = step + 1
        if step == 1 then
          first_list = items
          on_choice(items[4], 4)
          return
        end
        -- main_one sits on the other branch. It is not in the second list.
        on_choice(first_list[3], 3)
      end

      local opened, err = await(function(cb)
        picker.pick_range({ dir = branched.dir, select = select }, cb)
      end)
      assert.is_nil(opened)
      assert.are.equal("invalid_arg", err.code)
      assert.is_truthy(err.message:find("is not an ancestor of", 1, true), err.message)
      assert.is_nil(session.current())
    end)
  end)

  describe("pick", function()
    it("asks for one commit by default", function()
      local select, calls = chooser({ 1 })
      await(function(cb)
        picker.pick({ dir = fixture.dir, select = select }, cb)
      end)
      assert.are.equal(1, #calls)
    end)

    it("asks for two commits in the range mode", function()
      local select, calls = chooser({ 2, 1 })
      await(function(cb)
        picker.pick({ dir = fixture.dir, mode = "range", select = select }, cb)
      end)
      assert.are.equal(2, #calls)
    end)

    it("uses vim.ui.select without a selector", function()
      local seen
      local ui_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice) ---@diagnostic disable-line: duplicate-set-field
        seen = opts
        on_choice(items[1], 1)
      end
      local opened = assert(await(function(cb)
        picker.pick({ dir = fixture.dir }, cb)
      end))
      vim.ui.select = ui_select

      assert.are.equal("codeview.commit", seen.kind)
      assert.are.equal(fixture.ids.shuffle, opened.range.to)
    end)
  end)

  it("removes the fixtures", function()
    fixture.cleanup()
    branched.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
    assert.are.equal(0, vim.fn.isdirectory(branched.dir))
  end)
end)
