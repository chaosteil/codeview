local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.remote", function()
  local remote

  before_each(function()
    helpers.unload()
    remote = require("codeview.remote")
  end)

  after_each(function()
    helpers.unload()
  end)

  describe("side", function()
    it("maps the sides of GitHub to the sides of the diff", function()
      assert.are.equal("old", remote.side("LEFT"))
      assert.are.equal("new", remote.side("RIGHT"))
      assert.are.equal("new", remote.side(nil))
    end)
  end)

  describe("hunk_line", function()
    ---A hunk that ends on an added line.
    local hunk = table.concat({
      "@@ -70,7 +70,7 @@ GLOBAL MAPPINGS",
      " BUFFER-LOCAL MAPPINGS",
      " ",
      " • <CR> opens the file under the cursor.",
      "-• - opens the parent directory.",
      "+• 1- opens the current working directory.",
    }, "\n")

    it("counts the lines of the new side", function()
      assert.are.equal(73, remote.hunk_line(hunk, "new"))
    end)

    it("counts the lines of the old side", function()
      assert.are.equal(73, remote.hunk_line(hunk, "old"))
    end)

    it("answers nothing without a hunk header", function()
      assert.is_nil(remote.hunk_line("no hunk here", "new"))
      assert.is_nil(remote.hunk_line(nil, "new"))
    end)
  end)

  describe("anchor", function()
    it("takes the lines of the newest version first", function()
      local anchor = assert(remote.anchor({ line = 18, original_line = 17, side = "RIGHT" }))
      assert.are.equal(18, anchor.start_line)
      assert.are.equal(18, anchor.end_line)
      assert.are.equal("new", anchor.side)
      assert.is_false(anchor.outdated)
    end)

    it("reads a comment over more than one line", function()
      local anchor = assert(remote.anchor({ line = 1590, start_line = 1585, side = "RIGHT" }))
      assert.are.equal(1585, anchor.start_line)
      assert.are.equal(1590, anchor.end_line)
    end)

    it("falls back to the lines of the older version", function()
      local anchor = assert(remote.anchor({ line = nil, original_line = 17, side = "RIGHT" }))
      assert.are.equal(17, anchor.start_line)
      assert.is_true(anchor.outdated)
    end)

    it("falls back to the last line of the diff hunk", function()
      local anchor = assert(remote.anchor({
        side = "LEFT",
        diff_hunk = "@@ -10,3 +10,2 @@\n one\n-two\n",
      }))
      assert.are.equal("old", anchor.side)
      assert.are.equal(11, anchor.start_line)
      assert.is_true(anchor.outdated)
    end)

    it("answers nothing without a position", function()
      assert.is_nil(remote.anchor({ side = "RIGHT" }))
      assert.is_nil(remote.anchor("not a table"))
    end)

    it("keeps the last line of a range that starts on the other side", function()
      local anchor = assert(remote.anchor({ line = 12, start_line = 40, start_side = "LEFT", side = "RIGHT" }))
      assert.are.equal("new", anchor.side)
      assert.are.equal(12, anchor.start_line)
      assert.are.equal(12, anchor.end_line)
      assert.is_true(anchor.anchored)
    end)

    it("keeps a range that starts on the same side", function()
      local anchor = assert(remote.anchor({ line = 40, start_line = 35, start_side = "LEFT", side = "LEFT" }))
      assert.are.equal("old", anchor.side)
      assert.are.equal(35, anchor.start_line)
      assert.are.equal(40, anchor.end_line)
    end)

    it("leaves an outdated comment unanchored with the lines of its hunk", function()
      local anchor = assert(remote.anchor({
        side = "RIGHT",
        original_line = 3,
        diff_hunk = "@@ -1,3 +1,3 @@\n one\n-two\n+two changed\n three",
      }))
      assert.is_true(anchor.outdated)
      assert.is_false(anchor.anchored)
      assert.are.equal(3, anchor.end_line)
      assert.are.same({ "one", "two changed", "three" }, anchor.hunk)
    end)
  end)

  describe("hunk_lines", function()
    local hunk = "@@ -1,6 +1,6 @@\n a\n b\n c\n d\n-e\n+e changed\n f"

    it("keeps the commented lines and the lines above them", function()
      assert.are.same({ "c", "d", "e changed", "f" }, remote.hunk_lines(hunk, "new", 1))
      assert.are.same({ "b", "c", "d", "e changed", "f" }, remote.hunk_lines(hunk, "new", 2))
      assert.are.same({ "c", "d", "e", "f" }, remote.hunk_lines(hunk, "old", 1))
    end)

    it("answers no line without a hunk header", function()
      assert.are.same({}, remote.hunk_lines("no hunk", "new", 1))
    end)
  end)

  describe("locate", function()
    it("finds the one place of the lines", function()
      assert.are.equal(4, remote.locate({ "b", "c" }, { "a", "x", "b", "c", "d" }))
    end)

    it("answers nothing for no match or for two matches", function()
      assert.is_nil(remote.locate({ "b", "z" }, { "a", "b", "c" }))
      assert.is_nil(remote.locate({ "b" }, { "b", "a", "b" }))
      assert.is_nil(remote.locate({}, { "a" }))
    end)
  end)

  describe("parse", function()
    it("reads a recorded answer of the review comments", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments.json"))
      assert.are.equal(6, #comments)

      local first = comments[1]
      assert.are.equal(3745425897, first.id)
      assert.are.equal("runtime/doc/plugins.txt", first.file)
      assert.are.equal(73, first.start_line)
      assert.are.equal(73, first.end_line)
      assert.are.equal("new", first.side)
      assert.are.equal("justinmk", first.author)
      assert.is_true(first.outdated)
      assert.is_truthy(first.body:find("doc", 1, true))
      assert.are.equal("aae84443b6a6b81de32ced9ec8376371151d7d9a", first.commit)

      local last = comments[#comments]
      assert.are.equal(18, last.start_line)
      assert.is_false(last.outdated)
    end)

    it("drops the carriage returns of the recorded bodies", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments.json"))
      local bodies = 0
      for _, comment in ipairs(comments) do
        assert.is_nil(comment.body:find("\r", 1, true), comment.body)
        if comment.body:find("\n", 1, true) then
          bodies = bodies + 1
        end
      end
      assert.is_true(bodies > 0)
    end)

    it("reads a comment over a line range", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments-multiline.json"))
      assert.are.equal(1, #comments)
      assert.are.equal("src/nvim/undo.c", comments[1].file)
      assert.are.equal(1585, comments[1].start_line)
      assert.are.equal(1590, comments[1].end_line)
    end)

    it("keeps the answer of a reply", function()
      local comments = remote.parse({
        { id = 1, path = "a.lua", line = 3, side = "RIGHT", body = "one", user = { login = "ada" } },
        {
          id = 2,
          path = "a.lua",
          line = 3,
          side = "RIGHT",
          body = "two",
          in_reply_to_id = 1,
          user = { login = "grace" },
        },
      })
      assert.are.equal(2, #comments)
      assert.is_nil(comments[1].reply_to)
      assert.are.equal(1, comments[2].reply_to)
    end)

    it("reads the counts of the reactions of the REST answer", function()
      local comments = remote.parse({
        {
          id = 1,
          path = "a.lua",
          line = 3,
          side = "RIGHT",
          body = "one",
          reactions = { total_count = 3, ["+1"] = 2, hooray = 1, eyes = 0 },
        },
      })
      assert.are.same({
        { content = "THUMBS_UP", count = 2, mine = false },
        { content = "HOORAY", count = 1, mine = false },
      }, comments[1].reactions)
    end)

    it("maps a comment of the old side", function()
      local comments = remote.parse({ { id = 5, path = "a.lua", line = 9, side = "LEFT", body = "gone" } })
      assert.are.equal("old", comments[1].side)
      assert.are.equal(9, comments[1].start_line)
    end)

    it("drops an entry without a file or without a position", function()
      local comments = remote.parse({
        { id = 1, line = 3, side = "RIGHT" },
        { id = 2, path = "a.lua", side = "RIGHT" },
        { id = 3, path = "a.lua", line = 4, side = "RIGHT" },
      })
      assert.are.equal(1, #comments)
      assert.are.equal(3, comments[1].id)
    end)

    it("keeps the review of every comment", function()
      local comments = remote.parse(fixtures.gh_json("pr-comments.json"))
      assert.are.equal("4892676268", comments[1].review_id)
      assert.are.equal("", remote.parse({ { path = "a.lua", line = 4, side = "RIGHT" } })[1].review_id)
    end)

    it("reads no comment out of an empty answer", function()
      assert.are.same({}, remote.parse(nil))
      assert.are.same({}, remote.parse({}))
    end)
  end)

  describe("fetch", function()
    it("needs a repository and a number", function()
      local comments, err = remote.fetch({ repo = "", number = 12 })
      assert.is_nil(comments)
      assert.are.equal("invalid_arg", err.code)
    end)

    describe("with a gh stub", function()
      ---@type string[][]
      local calls
      ---Request bodies of the GraphQL calls.
      ---@type table[]
      local graphql
      ---Answer of the GraphQL call with one number.
      ---@type fun(index: integer): string
      local threads_answer

      ---Answer of one page of threads.
      ---@param nodes table[]
      ---@param cursor string?
      ---@return string
      local function threads_page(nodes, cursor)
        return vim.json.encode({
          data = {
            repository = {
              pullRequest = {
                reviewThreads = {
                  pageInfo = { hasNextPage = cursor ~= nil, endCursor = cursor or vim.NIL },
                  nodes = nodes,
                },
              },
            },
          },
        })
      end

      before_each(function()
        calls = {}
        graphql = {}
        threads_answer = function()
          return threads_page({})
        end
        local gh = require("codeview.gh")
        gh.available = function() ---@diagnostic disable-line: duplicate-set-field
          return true
        end
        -- Every page is full, so the fetch only stops at a limit.
        require("codeview.exec").capture = function(cmd, opts, cb) ---@diagnostic disable-line: duplicate-set-field
          calls[#calls + 1] = cmd
          local stdout
          if cmd[3] == "graphql" then
            graphql[#graphql + 1] = vim.json.decode(opts.stdin)
            stdout = threads_answer(#graphql)
          else
            local page = tonumber(cmd[3]:match("[?&]page=(%d+)"))
            local per_page = tonumber(cmd[3]:match("per_page=(%d+)"))
            local entries = {}
            for index = 1, per_page do
              entries[index] = { id = page * 1000 + index, path = "a.lua", line = index, side = "RIGHT", body = "one" }
            end
            stdout = vim.json.encode(entries)
          end
          local result = {
            command = cmd,
            code = 0,
            signal = 0,
            stdout = stdout,
            stderr = "",
          }
          if cb then
            vim.schedule(function()
              cb(result, nil)
            end)
            return nil, nil
          end
          return result, nil
        end
      end)

      it("names the host of the pull request", function()
        assert(remote.fetch({ repo = "team/app", number = 7, max = 1, host = "github.acme.com" }))
        local at = assert(vim.iter(ipairs(calls[1])):find(function(_, arg)
          return arg == "--hostname"
        end))
        assert.are.equal("github.acme.com", calls[1][at + 1])
      end)

      it("marks a fetch that stops at the limit", function()
        local comments = assert(remote.fetch({ repo = "ada/demo", number = 12, max = 3 }))
        assert.are.equal(3, #comments)
        assert.is_true(comments.truncated)
      end)

      it("warns once when the fetch stops at the limit", function()
        local seen = {}
        local notify = vim.notify
        vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
          seen[#seen + 1] = { msg = msg, level = level }
        end
        local finished = false
        local session = {
          id = 999,
          is_active = function()
            return false
          end,
        }
        remote.load(session --[[@as codeview.Session]], { repo = "ada/demo", number = 12, max = 3 }, function()
          finished = true
        end)
        local ok = vim.wait(5000, function()
          return finished
        end, 5)
        vim.notify = notify

        assert.is_true(ok)
        assert.are.equal(1, #seen)
        assert.are.equal(vim.log.levels.WARN, seen[1].level)
        assert.is_truthy(seen[1].msg:find("oldest 3", 1, true), seen[1].msg)
      end)

      it("joins the review threads to the comments", function()
        threads_answer = function(index)
          if index == 1 then
            return threads_page({
              {
                id = "PRRT_1",
                isResolved = true,
                resolvedBy = { login = "ada" },
                viewerCanResolve = false,
                viewerCanUnresolve = true,
                viewerCanReply = true,
                comments = {
                  nodes = {
                    {
                      databaseId = 1001,
                      id = "PRRC_1001",
                      viewerCanUpdate = true,
                      viewerCanDelete = true,
                      reactionGroups = {
                        { content = "THUMBS_UP", viewerHasReacted = true, reactors = { totalCount = 2 } },
                        { content = "LAUGH", viewerHasReacted = false, reactors = { totalCount = 0 } },
                      },
                    },
                  },
                },
              },
            }, "cursor-1")
          end
          return threads_page({})
        end
        local comments = assert(remote.fetch({ repo = "ada/demo", number = 12, max = 2 }))
        assert.are.equal(2, #graphql)
        assert.are.same({ owner = "ada", name = "demo", number = 12 }, graphql[1].variables)
        assert.are.equal("cursor-1", graphql[2].variables.cursor)
        assert.is_nil(comments.thread_error)

        local first = comments[1]
        assert.are.equal(1001, first.id)
        assert.are.equal("PRRC_1001", first.node_id)
        assert.is_true(first.can_update)
        assert.is_true(first.can_delete)
        assert.are.same({ { content = "THUMBS_UP", count = 2, mine = true } }, first.reactions)
        assert.are.same({
          id = "PRRT_1",
          resolved = true,
          resolved_by = "ada",
          can_resolve = false,
          can_unresolve = true,
          can_reply = true,
        }, first.thread)
        assert.is_nil(comments[2].thread)
        assert.is_nil(comments[2].node_id)
      end)

      it("stops after the last page of threads", function()
        threads_answer = function(index)
          return threads_page({}, "cursor-" .. index)
        end
        assert(remote.fetch({ repo = "ada/demo", number = 12, max = 1 }))
        assert.are.equal(remote.thread_pages, #graphql)
      end)

      it("keeps the comments when the GraphQL call fails", function()
        threads_answer = function()
          return vim.json.encode({ errors = { { message = "Something went wrong" } } })
        end
        local comments = assert(remote.fetch({ repo = "ada/demo", number = 12, max = 2 }))
        assert.are.equal(2, #comments)
        assert.is_truthy(tostring(comments.thread_error):find("Something went wrong", 1, true))
        assert.is_nil(comments[1].thread)

        local seen = {}
        local notify = vim.notify
        vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
          seen[#seen + 1] = { msg = msg, level = level }
        end
        local finished = false
        local session = {
          id = 998,
          is_active = function()
            return false
          end,
        }
        remote.load(session --[[@as codeview.Session]], { repo = "ada/demo", number = 12, max = 200 }, function(loaded)
          finished = loaded ~= nil
        end)
        local ok = vim.wait(5000, function()
          return finished
        end, 5)
        vim.notify = notify

        assert.is_true(ok, "the load gave no comments")
        -- Every page of the stub is full, so the fetch also stops at the limit.
        local warned = vim.tbl_filter(function(entry)
          return entry.msg:find("without the thread state", 1, true) ~= nil
        end, seen)
        assert.are.equal(1, #warned)
        assert.are.equal(vim.log.levels.WARN, warned[1].level)
      end)
    end)
  end)
end)

describe("codeview.remote in the review", function()
  local fixture = fixtures.git_comments()
  local comments_mod, config, overview, remote, session_mod, view
  ---@type codeview.Session?
  local opened

  ---Text of the range of the fixture.
  ---@return string
  local function spec()
    return fixture.ids.base .. ".." .. fixture.ids.change
  end

  ---Open a review session for the fixture range.
  ---@return codeview.Session
  local function open_session()
    if opened then
      return opened
    end
    local review, err = session_mod.open(spec(), { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Show the diff of one file of the session.
  ---
  --- The inline diff of call.lua is:
  ---
  ---     1  @@ -1,4 +1,4 @@
  ---     2   local a = call(one, two)
  ---     3  -local b = 2
  ---     4  +local b = 22
  ---     5   local c = 3
  ---     6   local d = 4
  ---@param path string
  ---@return codeview.view.State
  local function open_diff(path)
    local review = open_session()
    local state = assert(view.open(review, assert(review:index_of(path))))
    api.nvim_set_current_win(state.win)
    return state
  end

  ---Comments of the pull request, as the mapping gives them.
  ---@param fields? table Fields that replace the defaults.
  ---@return codeview.remote.Comment
  local function remote_comment(fields)
    return vim.tbl_extend("force", {
      id = 501,
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      commit = fixture.ids.change,
      author = "grace",
      body = "this line needs a test",
      url = "https://github.com/ada/demo/pull/12#discussion_r501",
      created_at = 0,
      outdated = false,
    }, fields or {})
  end

  ---Marks of the remote namespace in a buffer.
  ---@param buf integer
  ---@return table[]
  local function marks(buf)
    return remote.marks(buf)
  end

  ---Text of one virtual line, with the frame.
  ---@param line table[] Chunks of the line.
  ---@return string
  local function line_text(line)
    local text = ""
    for _, chunk in ipairs(line) do
      text = text .. chunk[1]
    end
    return text
  end

  ---Extmarks of the boxes in a buffer.
  ---@param buf integer
  ---@return table[]
  local function box_marks(buf)
    return require("codeview.stack").marks(buf)
  end

  ---Text of the virtual lines of the first mark with virtual lines.
  ---@param buf integer
  ---@return string[]
  local function virt_lines(buf)
    for _, mark in ipairs(box_marks(buf)) do
      if mark[4].virt_lines then
        return vim.tbl_map(line_text, mark[4].virt_lines)
      end
    end
    return {}
  end

  before_each(function()
    helpers.unload()
    comments_mod = require("codeview.comments")
    config = require("codeview.config")
    overview = require("codeview.overview")
    remote = require("codeview.remote")
    session_mod = require("codeview.session")
    view = require("codeview.view")
    config.reset()
  end)

  after_each(function()
    view.close()
    overview.close()
    if opened then
      opened:close()
      opened = nil
    end
    helpers.unload()
  end)

  it("keeps the comments of one session", function()
    local review = open_session()
    assert.are.same({}, remote.list(review))
    remote.attach(review, { remote_comment() })
    assert.are.equal(1, #remote.list(review))
    assert.are.equal(1, #remote.for_file(review, "call.lua"))
    assert.are.equal(0, #remote.for_file(review, "tail.txt"))
    assert.are.equal(1, #remote.at(review, "call.lua", "new", 2))
    assert.are.equal(0, #remote.at(review, "call.lua", "old", 2))
  end)

  it("groups the comments of a thread, oldest first", function()
    local review = open_session()
    remote.attach(review, {
      remote_comment({ id = 503, reply_to = 501, created_at = 30, body = "third" }),
      remote_comment({ id = 501, created_at = 10, body = "first" }),
      remote_comment({ id = 600, start_line = 3, end_line = 3, created_at = 5, body = "other" }),
      remote_comment({ id = 502, reply_to = 501, created_at = 30, body = "second" }),
    })
    local threads = remote.threads(review)
    assert.are.equal(2, #threads)
    assert.are.equal(600, threads[1].root.id)
    local thread = threads[2]
    assert.are.equal(501, thread.root.id)
    assert.are.same(
      { 501, 502, 503 },
      vim.tbl_map(function(comment)
        return comment.id
      end, thread.comments)
    )
    assert.are.equal(2, thread.start_line)
    assert.is_nil(thread.id)
    assert.is_false(thread.resolved)

    assert.are.equal(1, #remote.threads_at(review, "call.lua", "new", 2))
    assert.are.equal(0, #remote.threads_at(review, "call.lua", "old", 2))
    assert.are.equal(501, remote.threads_at(review, "call.lua", "new", 2)[1].root.id)
  end)

  it("takes the state of a thread from its comments", function()
    local review = open_session()
    local state = {
      id = "PRRT_1",
      resolved = true,
      resolved_by = "ada",
      can_resolve = false,
      can_unresolve = true,
      can_reply = true,
    }
    remote.attach(review, {
      remote_comment({ id = 501, created_at = 10 }),
      remote_comment({ id = 502, reply_to = 501, created_at = 20, thread = state }),
    })
    local thread = remote.threads(review)[1]
    assert.are.equal("PRRT_1", thread.id)
    assert.is_true(thread.resolved)
    assert.are.equal("ada", thread.resolved_by)
    assert.is_true(thread.can_unresolve)
    assert.is_true(thread.can_reply)
  end)

  it("drops the copy of a comment with the same remote id", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    local comment = assert(store:add({
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      body = "a reply of mine",
    }))
    assert(store:mark_synced(comment.id, { remote_id = 502 }))
    assert(store:update(comment.id, { body = "a new text" }))
    remote.attach(review, { remote_comment(), remote_comment({ id = 502, reply_to = 501, body = "a reply of mine" }) })

    local held = remote.list(review)
    assert.are.equal(1, #held)
    assert.are.equal(501, held[1].id)
  end)

  it("drops the comments when the session closes", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    review:close()
    assert.are.same({}, remote.list(review))
    opened = nil
  end)

  it("marks the line of a remote comment in the diff", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local state = open_diff("call.lua")

    local found = marks(state.buf)
    assert.are.equal(1, #found)
    -- Row 4 of the render holds the new line 2.
    assert.are.equal(3, found[1][2])
    local details = found[1][4]
    assert.are.equal(config.get().comments.remote_sign, vim.trim(details.sign_text))
    assert.are.equal("CodeViewRemoteSign", details.sign_hl_group)
    local box = box_marks(state.buf)
    assert.are.equal(1, #box)
    assert.are.equal(3, box[1][2])
    local lines = box[1][4].virt_lines
    assert.is_truthy(line_text(lines[1]):find("@grace", 1, true))
    assert.is_nil(line_text(lines[1]):find("read-only", 1, true))
  end)

  it("draws a remote comment as a framed box with the grey tint", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local state = open_diff("call.lua")

    local width = api.nvim_win_get_width(state.win) - vim.fn.getwininfo(state.win)[1].textoff - 1
    local lines = virt_lines(state.buf)
    assert.are.equal(3, #lines)
    assert.is_true(vim.startswith(lines[1], "╭─ @grace L2 (new) ─"))
    assert.is_true(vim.endswith(lines[1], "─╮"))
    assert.are.equal("│ this line needs a test" .. string.rep(" ", width - 26) .. " │", lines[2])
    assert.are.equal("╰" .. string.rep("─", width - 2) .. "╯", lines[3])
    for _, line in ipairs(lines) do
      assert.are.equal(width, vim.fn.strdisplaywidth(line))
    end

    local chunks = box_marks(state.buf)[1][4].virt_lines
    assert.are.same({ "╭─ ", "CodeViewRemoteBorder" }, chunks[1][1])
    assert.are.same({ "CodeViewRemoteHeader", "CodeViewRemoteBox" }, chunks[1][2][2])
    assert.are.same({ "│", "CodeViewRemoteBorder" }, chunks[2][1])
    assert.are.same({ "CodeViewRemote", "CodeViewRemoteBox" }, chunks[2][2][2])

    -- The grey box of a remote comment is not the blue box of a local one.
    local own = api.nvim_get_hl(0, { name = "CodeViewCommentBox" })
    local other = api.nvim_get_hl(0, { name = "CodeViewRemoteBox" })
    assert.is_number(other.bg)
    assert.are_not.equal(own.bg, other.bg)
  end)

  it("draws a remote comment without a frame with the border none", function()
    config.setup({ comments = { border = "none" } })
    local review = open_session()
    remote.attach(review, { remote_comment({ body = "one\ntwo" }) })
    local state = open_diff("call.lua")

    local width = api.nvim_win_get_width(state.win) - vim.fn.getwininfo(state.win)[1].textoff - 1
    local header = " @grace L2 (new)"
    assert.are.same({
      header .. string.rep(" ", width - 1 - vim.fn.strdisplaywidth(header)) .. " ",
      " one" .. string.rep(" ", width - 5) .. " ",
      " two" .. string.rep(" ", width - 5) .. " ",
    }, virt_lines(state.buf))
  end)

  it("draws a thread as one box, oldest comment first", function()
    local review = open_session()
    remote.attach(review, {
      remote_comment({ id = 502, reply_to = 501, created_at = 20, author = "ada", body = "a reply" }),
      remote_comment({
        id = 501,
        created_at = 10,
        reactions = {
          { content = "THUMBS_UP", count = 2, mine = false },
          { content = "HOORAY", count = 1, mine = true },
        },
      }),
    })
    local state = open_diff("call.lua")

    local width = api.nvim_win_get_width(state.win) - vim.fn.getwininfo(state.win)[1].textoff - 1
    local found = box_marks(state.buf)
    assert.are.equal(1, #found)
    local lines = virt_lines(state.buf)
    assert.are.equal(6, #lines)
    assert.is_true(vim.startswith(lines[1], "╭─ @grace L2 (new) ─"))
    assert.is_truthy(lines[2]:find("this line needs a test", 1, true))
    assert.is_truthy(lines[3]:find("👍 2  🎉 1", 1, true), lines[3])
    assert.is_true(vim.startswith(lines[4], "├─ @ada ─"))
    assert.is_true(vim.endswith(lines[4], "─┤"))
    assert.is_truthy(lines[5]:find("a reply", 1, true))
    assert.is_true(vim.startswith(lines[6], "╰"))
    for _, line in ipairs(lines) do
      assert.are.equal(width, vim.fn.strdisplaywidth(line))
    end
    local chunks = found[1][4].virt_lines
    assert.are.same({ "CodeViewRemoteReactions", "CodeViewRemoteBox" }, chunks[3][2][2])
  end)

  it("shows a resolved thread as one header line", function()
    local review = open_session()
    local state = {
      id = "PRRT_1",
      resolved = true,
      resolved_by = "ada",
      can_resolve = false,
      can_unresolve = true,
      can_reply = true,
    }
    remote.attach(review, {
      remote_comment({ id = 501, created_at = 10, thread = state }),
      remote_comment({ id = 502, reply_to = 501, created_at = 20, thread = state }),
    })
    local diff = open_diff("call.lua")

    local lines = virt_lines(diff.buf)
    assert.are.equal(2, #lines)
    assert.is_true(vim.startswith(lines[1], "╭─ ✓ resolved · @grace L2 (new) · 2 comments ─"), lines[1])
    local chunks = box_marks(diff.buf)[1][4].virt_lines
    assert.are.same({ "CodeViewRemoteResolved", "CodeViewRemoteBox" }, chunks[1][2][2])
  end)

  it("puts the boxes of one row into one extmark, oldest first", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    assert(store:add({ file = "call.lua", start_line = 2, end_line = 2, side = "new", body = "mine", created_at = 20 }))
    remote.attach(review, { remote_comment({ created_at = 10 }) })
    local state = open_diff("call.lua")

    assert.are.equal(1, #box_marks(state.buf))
    local lines = virt_lines(state.buf)
    assert.is_true(vim.startswith(lines[1], "╭─ @grace L2 (new) ─"))
    assert.is_true(vim.startswith(lines[4], "╭─ comment L2 (new) ─"))
  end)

  it("shows the boxes of one row in the order of their time on the screen", function()
    config.setup({ comments = { border = "none" } })
    local lines = vim.o.lines
    vim.o.lines = 60
    local review = open_session()
    local store = assert(comments_mod.store(review))
    -- The comments go in as A, B, C, D. Neovim does not keep that order for
    -- marks with a sign on one row, so the stack must.
    for index, body in ipairs({ "alpha", "bravo", "charlie", "delta" }) do
      assert(
        store:add({ file = "call.lua", start_line = 2, end_line = 2, side = "new", body = body, created_at = index })
      )
    end
    local state = open_diff("call.lua")
    vim.cmd("redraw")

    local top = vim.fn.win_screenpos(state.win)[1]
    local width = api.nvim_win_get_width(state.win)
    local left = vim.fn.win_screenpos(state.win)[2]
    ---@type table<string, integer>
    local at = {}
    for row = top, top + api.nvim_win_get_height(state.win) - 1 do
      local text = {}
      for col = left, left + width - 1 do
        text[#text + 1] = vim.fn.screenstring(row, col)
      end
      local line = table.concat(text)
      for _, body in ipairs({ "alpha", "bravo", "charlie", "delta" }) do
        if line:find(body, 1, true) and not at[body] then
          at[body] = row
        end
      end
    end
    vim.o.lines = lines

    assert.is_truthy(at.alpha and at.bravo and at.charlie and at.delta, vim.inspect(at))
    assert.is_true(at.alpha < at.bravo)
    assert.is_true(at.bravo < at.charlie)
    assert.is_true(at.charlie < at.delta)
    assert.is_truthy(comments_mod.marks(state.buf)[1][4].sign_text)
  end)

  it("gives the other side of the split as many blank lines as the remote box", function()
    local review = open_session()
    remote.attach(review, { remote_comment({ body = string.rep("long words ", 40) }) })
    open_diff("call.lua")
    assert.are.equal("split", view.set_style("split"))
    local state = assert(view.current())

    local count = #virt_lines(state.buf)
    assert.is_true(count > 3)
    local blank = 0
    for _, mark in ipairs(box_marks(assert(state.old_buf))) do
      blank = blank + #(mark[4].virt_lines or {})
    end
    assert.are.equal(count, blank)
  end)

  it("keeps the marks of the local comments", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local store = assert(comments_mod.store(review))
    assert(store:add({ file = "call.lua", start_line = 2, end_line = 2, side = "new", body = "mine" }))

    local state = open_diff("call.lua")
    assert.are.equal(1, #marks(state.buf))
    assert.is_true(#comments_mod.marks(state.buf) > 0)
  end)

  it("drops the copy of a comment that a submit sent", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    local comment = assert(store:add({
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      body = "this line needs a test",
    }))
    assert(store:mark_synced(comment.id, { review_id = "77" }))
    remote.attach(review, { remote_comment({ review_id = "77" }), remote_comment({ id = 502, body = "another one" }) })

    local held = remote.list(review)
    assert.are.equal(1, #held)
    assert.are.equal(502, held[1].id)

    local state = open_diff("call.lua")
    assert.are.equal(1, #marks(state.buf))
  end)

  it("keeps the comment of GitHub while the local comment is not sent", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    assert(store:add({
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      body = "this line needs a test",
    }))
    remote.attach(review, { remote_comment() })
    assert.are.equal(1, #remote.list(review))
  end)

  it("keeps the comment of GitHub after an edit of the local text", function()
    local review = open_session()
    local store = assert(comments_mod.store(review))
    local comment = assert(store:add({
      file = "call.lua",
      start_line = 2,
      end_line = 2,
      side = "new",
      body = "this line needs a test",
    }))
    assert(store:mark_synced(comment.id, { review_id = "77" }))
    assert(store:update(comment.id, { body = "this line needs two tests" }))
    remote.attach(review, { remote_comment({ review_id = "77" }) })
    assert.are.equal(1, #remote.list(review))
  end)

  it("marks a comment of an older push", function()
    local review = open_session()
    remote.attach(review, { remote_comment({ outdated = true }) })
    local state = open_diff("call.lua")

    local details = marks(state.buf)[1][4]
    assert.are.equal("CodeViewRemoteOutdated", details.sign_hl_group)
    assert.is_truthy(virt_lines(state.buf)[1]:find("outdated", 1, true))
  end)

  it("draws an outdated comment where the current file holds its lines", function()
    local review = open_session()
    remote.attach(
      review,
      remote.parse({
        {
          id = 601,
          path = "call.lua",
          side = "RIGHT",
          original_line = 9,
          body = "an older push",
          diff_hunk = "@@ -1,2 +1,2 @@\n local a = call(one, two)\n-local b = 1\n+local b = 22",
        },
      })
    )
    local state = open_diff("call.lua")

    local found = marks(state.buf)
    assert.are.equal(1, #found)
    -- Row 4 of the render holds the new line 2, not the old line 9.
    assert.are.equal(3, found[1][2])
    assert.are.equal("CodeViewRemoteOutdated", found[1][4].sign_hl_group)
    assert.are.equal(1, #remote.at(review, "call.lua", "new", 2))
  end)

  it("lists an outdated comment that the current file does not hold, without a mark", function()
    local review = open_session()
    remote.attach(
      review,
      remote.parse({
        {
          id = 602,
          path = "call.lua",
          side = "RIGHT",
          original_line = 2,
          body = "a line that is gone",
          diff_hunk = "@@ -1,2 +1,2 @@\n local a = call(one, two)\n-local b = 1\n+local b = 99",
        },
      })
    )
    local state = open_diff("call.lua")

    assert.are.equal(0, #marks(state.buf))
    assert.are.equal(0, #remote.at(review, "call.lua", "new", 2))
    assert.are.equal(1, #remote.list(review))
    local count, hidden = remote.decorate(state)
    assert.are.equal(0, count)
    assert.are.equal(1, hidden)
  end)

  it("draws the comments that arrive after the file is open", function()
    local review = open_session()
    local state = open_diff("call.lua")
    assert.are.equal(0, #marks(state.buf))

    remote.attach(review, { remote_comment() })
    assert.are.equal(1, #marks(state.buf))
  end)

  it("shows a remote comment in the float", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local state = open_diff("call.lua")
    api.nvim_win_set_cursor(state.win, { 4, 0 })

    local buf = assert(comments_mod.show())
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("@grace", 1, true), text)
    assert.is_truthy(text:find("this line needs a test", 1, true), text)
  end)

  it("sends the edit key on a remote comment to the thread actions", function()
    local review = open_session()
    remote.attach(review, { remote_comment() })
    local state = open_diff("call.lua")
    api.nvim_win_set_cursor(state.win, { 4, 0 })

    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    local edited = comments_mod.edit()
    vim.notify = notify

    -- The thread actions need a pull request. The fixture is a local review.
    assert.is_false(edited)
    assert.are.equal(1, #seen)
    assert.is_truthy(seen[1]:find("does not review a pull request", 1, true), seen[1])
  end)

  it("lists the remote comments in the overview", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment(), remote_comment({ id = 502, file = "tail.txt", start_line = 40 }) })

    local text = table.concat(bar.panel:lines(), "\n")
    assert.is_truthy(text:find("2 remote comments", 1, true), text)
    assert.is_truthy(text:find("call.lua", 1, true), text)

    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))
    local comment = assert(bar:cursor_remote())
    assert.are.equal(501, comment.id)
    assert.are.equal(2, #bar:remote())
  end)

  it("keeps the remote comments out of the local section", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment() })

    assert.are.equal(0, #bar:comments())
    local text = table.concat(bar.panel:lines(), "\n")
    assert.is_truthy(text:find("no comments", 1, true), text)
  end)

  it("sends the edit, delete, and resolve keys of a thread line to the thread actions", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment() })

    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))

    local seen = {}
    require("codeview.config").setup({ log_level = vim.log.levels.INFO })
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    local edited = bar:edit()
    local removed = bar:remove({ confirm = false })
    local state = bar:set_state()
    vim.notify = notify

    -- The thread actions need a pull request. The fixture is a local review.
    assert.is_false(edited)
    assert.is_false(removed)
    assert.is_nil(state)
    assert.are.equal(3, #seen)
    for _, message in ipairs(seen) do
      assert.is_truthy(message:find("does not review a pull request", 1, true), message)
    end
  end)

  it("jumps from the overview to the line of a remote comment", function()
    local review = open_session()
    local bar = assert(overview.open({ session = review }))
    remote.attach(review, { remote_comment() })

    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))

    local finished = false
    bar:open_cursor(function()
      finished = true
    end)
    assert.is_true(
      vim.wait(20000, function()
        return finished
      end, 10),
      "the jump did not answer"
    )

    local state = assert(view.current())
    assert.are.equal("call.lua", state.path)
    assert.are.equal(4, api.nvim_win_get_cursor(state.win)[1])
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
