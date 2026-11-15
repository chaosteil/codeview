-- The edit and the delete of a sent comment go to GitHub at once. The
-- session file changes only after GitHub confirms the change.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview sent comments", function()
  local fixture = fixtures.git_comments()
  local comments, config, editor, gh, session_mod, view
  ---@type codeview.Session?
  local opened
  ---@type string
  local dir
  ---Calls of `gh.api`: the path and the options.
  ---@type { path: string, opts: table }[]
  local calls
  ---Answer of the stub: a value, or nil and an error.
  ---@type { value: any, err: any }
  local reply
  ---Number of calls of `remote.load`.
  ---@type integer
  local loads
  ---@type { msg: string, level: integer }[]
  local seen
  local real_notify

  ---Open the session, with one comment that a submit sent.
  ---@param fields? table Fields of the comment.
  ---@param mark? table Fields of the sync mark.
  ---@return codeview.store.Comment comment
  local function sent_comment(fields, mark)
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    local comment = assert(comments.create(
      review,
      vim.tbl_extend("force", {
        file = "call.lua",
        start_line = 2,
        end_line = 2,
        side = "new",
        commit = fixture.ids.change,
        body = "the old text",
      }, fields or {})
    ))
    local store = assert(comments.store(review))
    assert(store:mark_synced(comment.id, mark or { time = 100, review_id = "77", remote_id = "1000000001" }))
    assert(store:save())
    return assert(store:get(comment.id))
  end

  ---Write a body into the editor and save it.
  ---@param body string
  local function write_comment(body)
    local state = assert(editor.current())
    api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
    editor.submit()
  end

  ---Wait until the stub answered.
  local function settle()
    vim.wait(100, function()
      return false
    end, 10)
  end

  ---Messages of one level.
  ---@param level integer
  ---@return string[]
  local function said(level)
    local out = {}
    for _, entry in ipairs(seen) do
      if entry.level == level then
        out[#out + 1] = entry.msg
      end
    end
    return out
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    dir = fixtures.tempdir("codeview-sent")
    assert(config.setup({ commit_message = false, comments = { dir = dir }, log_level = vim.log.levels.INFO }))
    comments = require("codeview.comments")
    editor = require("codeview.editor")
    gh = require("codeview.gh")
    session_mod = require("codeview.session")
    view = require("codeview.view")

    calls, loads, seen = {}, 0, {}
    reply = { value = {} }
    gh.api = function(path, opts, cb) ---@diagnostic disable-line: duplicate-set-field
      calls[#calls + 1] = { path = path, opts = opts }
      vim.schedule(function()
        cb(reply.value, reply.err)
      end)
    end
    require("codeview.remote").load = function() ---@diagnostic disable-line: duplicate-set-field
      loads = loads + 1
      return true
    end
    -- The fixture is a local review. A sent comment needs a pull request.
    require("codeview.pr").current = function() ---@diagnostic disable-line: duplicate-set-field
      return { repo = "ada/demo", number = 12, url = "https://github.com/ada/demo/pull/12" }
    end
    real_notify = vim.notify
    vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = { msg = tostring(msg), level = level }
    end
  end)

  after_each(function()
    vim.notify = real_notify
    editor.cancel()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    vim.fn.delete(dir, "rf")
    config.reset()
    helpers.unload()
  end)

  describe("edit", function()
    it("sends the new text to GitHub, then writes the store", function()
      local comment = sent_comment()
      assert.is_true(comments.edit({ id = comment.id, session = opened }))
      write_comment("the new text")
      -- The store keeps the old text until GitHub answers.
      assert.are.equal("the old text", assert(comments.store(opened)):get(comment.id).body)
      settle()

      assert.are.equal(1, #calls)
      assert.are.equal("repos/ada/demo/pulls/comments/1000000001", calls[1].path)
      assert.are.equal("PATCH", calls[1].opts.method)
      assert.are.same({ body = "the new text" }, vim.json.decode(calls[1].opts.stdin))
      local held = assert(comments.store(opened)):get(comment.id)
      assert.are.equal("the new text", held.body)
      -- GitHub holds the new text, so the comment stays sent.
      assert.is_true(require("codeview.store").is_synced(held))
      assert.are.equal("1000000001", held.remote_id)
      assert.are.same({ "codeview: the new text went to GitHub" }, said(vim.log.levels.INFO))
    end)

    it("keeps the old text after a failure of GitHub", function()
      local comment = sent_comment()
      reply = { value = nil, err = require("codeview.error").new("gh_failed", "HTTP 403: forbidden") }
      comments.edit({ id = comment.id, session = opened })
      write_comment("the new text")
      settle()

      local held = assert(comments.store(opened)):get(comment.id)
      assert.are.equal("the old text", held.body)
      assert.is_true(require("codeview.store").is_synced(held))
      assert.are.equal(1, #said(vim.log.levels.ERROR))
      assert.is_truthy(said(vim.log.levels.ERROR)[1]:find("HTTP 403", 1, true))
    end)

    it("sends nothing for the same text", function()
      local comment = sent_comment()
      comments.edit({ id = comment.id, session = opened })
      write_comment("the old text")
      settle()
      assert.are.equal(0, #calls)
    end)

    it("sends a comment on the pull request document to the conversation", function()
      local comment = sent_comment({ file = require("codeview.message").pr_path(12), start_line = 1, end_line = 1 })
      comments.edit({ id = comment.id, session = opened })
      write_comment("the new text")
      settle()
      assert.are.equal("repos/ada/demo/issues/comments/1000000001", calls[1].path)
    end)

    it("keeps a comment without a remote id local", function()
      -- The comment went into the text of a review, so GitHub holds no
      -- comment of its own for it.
      local comment = sent_comment(nil, { time = 100, review_id = "77" })
      comments.edit({ id = comment.id, session = opened })
      write_comment("the new text")
      settle()
      assert.are.equal(0, #calls)
      local held = assert(comments.store(opened)):get(comment.id)
      assert.are.equal("the new text", held.body)
      assert.is_false(require("codeview.store").is_synced(held))
    end)
  end)

  describe("delete", function()
    it("deletes the comment on GitHub, then in the store", function()
      local comment = sent_comment()
      assert.is_true(comments.remove({ id = comment.id, session = opened, confirm = false }))
      assert.is_truthy(assert(comments.store(opened)):get(comment.id))
      settle()

      assert.are.equal(1, #calls)
      assert.are.equal("repos/ada/demo/pulls/comments/1000000001", calls[1].path)
      assert.are.equal("DELETE", calls[1].opts.method)
      assert.is_true(calls[1].opts.allow_empty)
      assert.is_nil(assert(comments.store(opened)):get(comment.id))
      assert.are.equal(1, loads)
      assert.are.same({ "codeview: deleted the comment on GitHub" }, said(vim.log.levels.INFO))
    end)

    it("keeps the comment after a failure of GitHub", function()
      local comment = sent_comment()
      reply = { value = nil, err = require("codeview.error").new("gh_failed", "HTTP 404: not found") }
      comments.remove({ id = comment.id, session = opened, confirm = false })
      settle()
      assert.is_truthy(assert(comments.store(opened)):get(comment.id))
      assert.are.equal(1, #said(vim.log.levels.ERROR))
      assert.are.equal(0, loads)
    end)

    it("deletes a sent comment on GitHub after a save of an empty text", function()
      local comment = sent_comment()
      comments.edit({ id = comment.id, session = opened })
      write_comment("")
      settle()
      assert.are.equal("DELETE", calls[1].opts.method)
      assert.is_nil(assert(comments.store(opened)):get(comment.id))
    end)

    it("deletes a comment that no submit sent in the store only", function()
      local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
      assert.is_nil(err)
      opened = assert(review)
      local comment = assert(comments.create(review, {
        file = "call.lua",
        start_line = 2,
        end_line = 2,
        side = "new",
        commit = fixture.ids.change,
        body = "a draft",
      }))
      assert.is_true(comments.remove({ id = comment.id, session = review, confirm = false }))
      assert.are.equal(0, #calls)
      assert.is_nil(assert(comments.store(review)):get(comment.id))
    end)
  end)
end)
