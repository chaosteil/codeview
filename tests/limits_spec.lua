local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview limits", function()
  local fixture = fixtures.git_diff()
  local codeview, comments, config, diff, inline, overview, session_mod, split, view
  ---@type codeview.Session?
  local opened

  ---Open a session for the range of the fixture.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Lines of a buffer.
  ---@param buf integer
  ---@return string[]
  local function lines_of(buf)
    return api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  ---Text of a number of lines, one per line.
  ---@param count integer
  ---@return string
  local function text_of(count)
    local out = {}
    for index = 1, count do
      out[index] = "line " .. index
    end
    return table.concat(out, "\n") .. "\n"
  end

  before_each(function()
    helpers.unload()
    codeview = require("codeview")
    comments = require("codeview.comments")
    config = require("codeview.config")
    diff = require("codeview.diff")
    inline = require("codeview.inline")
    overview = require("codeview.overview")
    session_mod = require("codeview.session")
    split = require("codeview.split")
    view = require("codeview.view")
  end)

  after_each(function()
    overview.close()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    config.reset()
    helpers.unload()
  end)

  describe("algorithm", function()
    it("takes the histogram algorithm for a file of a normal size", function()
      assert.are.equal("histogram", diff.algorithm(0, 0))
      assert.are.equal("histogram", diff.algorithm(100, 120))
      assert.are.equal("histogram", diff.algorithm(diff.histogram_limit, diff.histogram_limit))
    end)

    it("takes the myers algorithm when one side is large", function()
      assert.are.equal("myers", diff.algorithm(diff.histogram_limit + 1, 0))
      assert.are.equal("myers", diff.algorithm(0, diff.histogram_limit + 1))
    end)

    it("keeps the algorithm of the caller", function()
      local result = diff.compute("one\n", "two\n", { algorithm = "myers" })
      assert.are.equal(1, #result.hunks)
    end)
  end)

  describe("max_lines", function()
    it("compares a diff below the limit", function()
      config.setup({ diff = { max_lines = 100 } })
      local result = diff.compute(text_of(10), text_of(11))
      assert.is_false(result.limited)
      assert.are.equal(21, result.line_count)
      assert.are.equal(1, #result.hunks)
    end)

    it("stops a diff above the limit", function()
      config.setup({ diff = { max_lines = 10 } })
      local result = diff.compute(text_of(10), text_of(11))
      assert.is_true(result.limited)
      assert.are.equal(21, result.line_count)
      assert.are.equal(10, result.max_lines)
      assert.are.same({}, result.hunks)
      assert.are.same({}, result.old_lines)
      assert.are.same({}, result.new_lines)
    end)

    it("counts a limited diff as a diff with changes", function()
      config.setup({ diff = { max_lines = 10 } })
      assert.is_false(diff.is_empty(diff.compute(text_of(10), text_of(11))))
    end)

    it("removes the limit with 0", function()
      config.setup({ diff = { max_lines = 0 } })
      assert.is_false(diff.compute(text_of(10), text_of(11)).limited)
    end)

    it("removes the limit with the option of the call", function()
      config.setup({ diff = { max_lines = 10 } })
      assert.is_false(diff.compute(text_of(10), text_of(11), { max_lines = 0 }).limited)
    end)

    it("takes the limit of the call over the option", function()
      config.setup({ diff = { max_lines = 0 } })
      assert.is_true(diff.compute(text_of(10), text_of(11), { max_lines = 4 }).limited)
    end)

    it("names the count and the limit in the message", function()
      config.setup({ diff = { max_lines = 10 } })
      local result = diff.compute(text_of(10), text_of(11))
      assert.are.equal("The diff holds 21 lines. The limit diff.max_lines is 10.", diff.limit_message(result))
    end)

    it("keeps a binary file out of the limit", function()
      config.setup({ diff = { max_lines = 1 } })
      local result = diff.compute("a\0b", "a\0c")
      assert.is_true(result.binary)
      assert.is_false(result.limited)
    end)

    it("takes 0 as a valid option value", function()
      local merged, err = config.setup({ diff = { max_lines = 0 } })
      assert.is_nil(err)
      assert.are.equal(0, assert(merged).diff.max_lines)
    end)

    it("rejects a negative limit", function()
      local merged, err = config.setup({ diff = { max_lines = -1 } })
      assert.is_nil(merged)
      assert.is_truthy(tostring(err):find("max_lines", 1, true))
    end)
  end)

  describe("the render of a limited diff", function()
    it("shows the limit and the key in the inline style", function()
      config.setup({ diff = { max_lines = 10 } })
      local result = diff.compute(text_of(10), text_of(11))
      local build = inline.build(result)
      assert.are.same({
        "The diff holds 21 lines. The limit diff.max_lines is 10.",
        "Press <CR> to show it.",
      }, build.lines)
      assert.are.equal("message", build.map:kind(1))
    end)

    it("names the option when the key is off", function()
      config.setup({ diff = { max_lines = 10 }, keymaps = { load_diff = false } })
      local build = inline.build(diff.compute(text_of(10), text_of(11)))
      assert.are.equal("Set diff.max_lines higher to show it.", build.lines[2])
    end)

    it("names the key of the user", function()
      config.setup({ diff = { max_lines = 10 }, keymaps = { load_diff = "gl" } })
      local build = inline.build(diff.compute(text_of(10), text_of(11)))
      assert.are.equal("Press gl to show it.", build.lines[2])
    end)

    it("shows the same rows on both sides in the split style", function()
      config.setup({ diff = { max_lines = 10 } })
      local build = split.build(diff.compute(text_of(10), text_of(11)))
      assert.are.same(build.old.lines, build.new.lines)
      assert.are.equal(2, #build.old.lines)
      assert.are.equal("The diff holds 21 lines. The limit diff.max_lines is 10.", build.old.lines[1])
    end)
  end)

  describe("the view of a limited diff", function()
    it("shows the note instead of the file", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("long.txt"))))
      assert.is_true(state.diff.limited)
      assert.are.equal(2, #lines_of(state.buf))
      assert.is_truthy(lines_of(state.buf)[1]:find("The limit diff.max_lines is 10", 1, true))
    end)

    it("renders the diff after the load call", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      view.open(review, assert(review:index_of("long.txt")))

      local done = false
      assert.is_true(view.load_diff(function()
        done = true
      end))
      vim.wait(10000, function()
        return done
      end, 5)

      local state = assert(view.current())
      assert.is_false(state.diff.limited)
      assert.is_true(#lines_of(state.buf) > 2)
      assert.are.equal("long.txt", state.path)
    end)

    it("answers false on a diff that the view shows already", function()
      local review = open_session()
      view.open(review, assert(review:index_of("long.txt")))
      assert.is_false(view.load_diff())
    end)

    it("renders the diff with the force option of the open call", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("long.txt")), { force = true }))
      assert.is_false(state.diff.limited)
      assert.is_true(#state.diff.hunks > 0)
    end)

    it("renders the diff with the key of the diff buffer", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("long.txt"))))
      api.nvim_set_current_win(state.win)
      api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      vim.wait(10000, function()
        local current = view.current()
        return current ~= nil and not current.diff.limited
      end, 5)
      assert.is_false(assert(view.current()).diff.limited)
    end)

    it("keeps the load key out of a diff that the view shows", function()
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("long.txt"))))
      for _, map in ipairs(api.nvim_buf_get_keymap(state.buf, "n")) do
        assert.are_not.equal("<CR>", map.lhs)
      end
    end)

    it("maps the load key on a diff above the limit", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("long.txt"))))
      local keys = {}
      for _, map in ipairs(api.nvim_buf_get_keymap(state.buf, "n")) do
        keys[map.lhs] = true
      end
      assert.is_true(keys["<CR>"])
    end)

    it("keeps the limit out of a small file", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("added.txt"))))
      assert.is_false(state.diff.limited)
    end)

    it("reaches the call from the plugin table", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      codeview.open_file(assert(review:index_of("long.txt")), { session = review })
      assert.is_true(assert(codeview.view()).diff.limited)
      assert.is_true(codeview.load_diff(function() end))
    end)
  end)

  describe("the comments of a limited diff", function()
    it("takes no comment on a note row", function()
      config.setup({ diff = { max_lines = 10 } })
      local review = open_session()
      local state = assert(view.open(review, assert(review:index_of("long.txt"))))
      api.nvim_set_current_win(state.win)
      assert.is_false(codeview.comment())
    end)

    it("reaches the anchor of a comment from the overview", function()
      config.setup({
        comments = { dir = vim.fs.joinpath(fixture.dir, ".review") },
        diff = { max_lines = 10 },
      })
      local review = open_session()
      local store = assert(comments.store(review))
      local comment = assert(store:add({
        file = "long.txt",
        start_line = 30,
        end_line = 30,
        side = "new",
        commit = fixture.ids.change,
        body = "the limit hides this line",
      }))
      assert.is_true(store:save())

      local bar = assert(overview.open({ session = review }))
      local done, err = false, nil
      assert.is_true(bar:jump(comment, function(_, fail)
        done, err = true, fail
      end))
      assert.is_true(vim.wait(20000, function()
        return done
      end, 10))

      assert.is_nil(err)
      local state = assert(view.current())
      assert.is_false(state.diff.limited)
      local row = assert(assert(view.map()):buf_row(30, "new"))
      assert.are.equal(row, api.nvim_win_get_cursor(state.win)[1])
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
  end)
end)
