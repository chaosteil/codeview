local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.submit position mapping", function()
  local diff, inline, submit

  ---Line map of a diff between two texts.
  ---@param old string
  ---@param new string
  ---@return codeview.LineMap
  local function map_of(old, new)
    local computed = diff.compute(old, new, { context = submit.context })
    return inline.build(computed, { context = submit.context }).map
  end

  ---Line map and coverage of a diff between two texts.
  ---@param old string
  ---@param new string
  ---@return codeview.LineMap map
  ---@return codeview.submit.Coverage coverage
  local function diff_of(old, new)
    local computed = diff.compute(old, new, { context = submit.context })
    return inline.build(computed, { context = submit.context }).map, submit.coverage(computed, submit.context)
  end

  ---A comment of the store, with the fields of the anchor.
  ---@param fields table
  ---@return codeview.store.Comment
  local function anchor(fields)
    return vim.tbl_extend("force", {
      id = "0001",
      file = "long.txt",
      start_line = 20,
      end_line = 20,
      side = "new",
      commit = "abc",
      state = "open",
      synced_at = 0,
      review_id = "",
      created_at = 0,
      updated_at = 0,
      body = "a note",
    }, fields)
  end

  before_each(function()
    helpers.unload()
    diff = require("codeview.diff")
    inline = require("codeview.inline")
    submit = require("codeview.submit")
    require("codeview.config").reset()
  end)

  after_each(function()
    helpers.unload()
  end)

  it("maps a line of the new side to the right side of the API", function()
    local map = map_of(fixtures.numbered(40), fixtures.numbered(40, { [20] = " changed" }))
    local position = assert(submit.position(map, anchor({})))
    assert.are.equal("long.txt", position.path)
    assert.are.equal("RIGHT", position.side)
    assert.are.equal(20, position.line)
    assert.is_nil(position.start_line)
    assert.is_nil(position.start_side)
  end)

  it("maps a line of the old side to the left side of the API", function()
    local map = map_of(fixtures.numbered(40), fixtures.numbered(40, { [20] = " changed" }))
    local position = assert(submit.position(map, anchor({ side = "old" })))
    assert.are.equal("LEFT", position.side)
    assert.are.equal(20, position.line)
  end)

  it("maps a comment over more than one line to start_line and line", function()
    local map = map_of(fixtures.numbered(40), fixtures.numbered(40, { [20] = " changed" }))
    local position = assert(submit.position(map, anchor({ start_line = 19, end_line = 21 })))
    assert.are.equal(19, position.start_line)
    assert.are.equal("RIGHT", position.start_side)
    assert.are.equal(21, position.line)
    assert.are.equal("RIGHT", position.side)
  end)

  it("reports a line that the diff does not hold", function()
    local map = map_of(fixtures.numbered(40), fixtures.numbered(40, { [20] = " changed" }))
    local position, reason = submit.position(map, anchor({ start_line = 1, end_line = 1 }))
    assert.is_nil(position)
    assert.is_truthy(reason:find("does not hold new line 1", 1, true), reason)
  end)

  it("reports a line range that the diff breaks", function()
    local map = map_of(fixtures.numbered(40), fixtures.numbered(40, { [3] = " changed", [30] = " changed" }))
    local position, reason = submit.position(map, anchor({ start_line = 3, end_line = 30 }))
    assert.is_nil(position)
    assert.is_truthy(reason:find("breaks the line range", 1, true), reason)
  end)

  it("reports a value that is not a line map", function()
    local position, reason = submit.position(nil, anchor({}))
    assert.is_nil(position)
    assert.is_truthy(reason)
  end)

  it("reports the one line that GitHub leaves between two hunks", function()
    -- Two changes with seven unchanged lines between them give two hunks of
    -- three context lines each. Line 14 stays out of the diff of GitHub, but
    -- the review shows it, because the renderer hides no section of one line.
    local map, coverage =
      diff_of(fixtures.numbered(30), fixtures.numbered(30, { [10] = " changed", [18] = " changed" }))
    assert.is_truthy(map:buf_row(14, "new"))
    for _, line in ipairs({ 13, 15 }) do
      assert.is_truthy(submit.position(map, anchor({ start_line = line, end_line = line }), coverage), line)
    end
    local position, reason = submit.position(map, anchor({ start_line = 14, end_line = 14 }), coverage)
    assert.is_nil(position)
    assert.is_truthy(reason:find("does not hold new line 14", 1, true), reason)
  end)

  it("reports a line range over the two hunks of one file", function()
    local map, coverage =
      diff_of(fixtures.numbered(30), fixtures.numbered(30, { [10] = " changed", [18] = " changed" }))
    local position, reason = submit.position(map, anchor({ start_line = 13, end_line = 15 }), coverage)
    assert.is_nil(position)
    assert.is_truthy(reason)
  end)

  it("holds the lines of the context of every change", function()
    local coverage = select(2, diff_of(fixtures.numbered(20), fixtures.numbered(20, { [8] = " changed" })))
    assert.are.same({ { from = 5, to = 11 } }, coverage.new)
    assert.are.same({ { from = 5, to = 11 } }, coverage.old)
    assert.is_nil(submit.block_of(coverage, "new", 4))
    assert.are.equal(1, submit.block_of(coverage, "new", 5))
  end)

  it("holds the context of a line that the change adds", function()
    local coverage = select(2, diff_of(fixtures.numbered(20), fixtures.numbered(20) .. "line 21\n"))
    assert.are.same({ { from = 18, to = 21 } }, coverage.new)
    assert.are.same({ { from = 18, to = 20 } }, coverage.old)
  end)

  describe("events", function()
    it("reads the name of an event in every form", function()
      assert.are.equal("comment", submit.normalize_event("comment"))
      assert.are.equal("approve", submit.normalize_event("APPROVE"))
      assert.are.equal("request-changes", submit.normalize_event("request_changes"))
      assert.are.equal("request-changes", submit.normalize_event("REQUEST_CHANGES"))
      assert.is_nil(submit.normalize_event("merge"))
      assert.is_nil(submit.normalize_event(nil))
    end)

    it("maps the names to the events of the API", function()
      assert.are.equal("COMMENT", submit.events.comment)
      assert.are.equal("APPROVE", submit.events.approve)
      assert.are.equal("REQUEST_CHANGES", submit.events["request-changes"])
    end)
  end)
end)

describe("codeview.submit", function()
  local fixture = fixtures.git_pr()
  local comments_mod, errors, exec, gh, pr, session_mod, store_mod, submit
  ---@type { cmd: string[], opts: table }[]
  local gh_calls
  ---@type fun(cmd: string[]): table
  local answer
  ---@type { select: string[], input: string?, prompts: string[] }
  local ui
  local real_select, real_input
  ---@type string[]
  local messages
  local real_notify

  ---Answer of `gh pr view --json`, built from the fixture.
  ---@return string json
  local function pr_view()
    return vim.json.encode({
      number = 12,
      title = "Add the feature",
      state = "OPEN",
      isDraft = false,
      url = "https://github.com/ada/demo/pull/12",
      author = { login = "ada" },
      headRefName = "pr",
      baseRefName = "main",
      headRefOid = fixture.ids.pr_two,
      baseRefOid = fixture.ids.main_two,
      headRepository = { name = "demo", nameWithOwner = "ada/demo" },
      headRepositoryOwner = { login = "ada" },
      isCrossRepository = false,
      body = "the body of the pull request",
      commits = {},
    })
  end

  ---Answer every gh call. Every other command runs for real.
  ---@param cmd string[]
  ---@return table
  local function default_answer(cmd)
    if cmd[2] == "pr" and cmd[3] == "view" then
      return { stdout = pr_view() }
    end
    if cmd[2] == "api" then
      local path = cmd[3] or ""
      if path:find("/pulls/12/comments$") then
        return { stdout = fixtures.gh_text("pr-comment.json") }
      end
      if path:find("/issues/12/comments$") then
        return { stdout = fixtures.gh_text("pr-issue-comment.json") }
      end
      return { stdout = fixtures.gh_text("pr-review.json") }
    end
    return { code = 1, stderr = "unexpected gh call: " .. table.concat(cmd, " ") }
  end

  ---Calls of `gh api`.
  ---@return { cmd: string[], opts: table }[]
  local function api_calls()
    local out = {}
    for _, call in ipairs(gh_calls) do
      if call.cmd[2] == "api" then
        out[#out + 1] = call
      end
    end
    return out
  end

  ---Wait until a check answers true.
  ---@param check fun(): boolean
  ---@param message string
  local function wait_for(check, message)
    assert.is_true(vim.wait(20000, check, 10), message)
  end

  ---Open the pull request session of the fixture.
  ---@return codeview.Session
  local function open_session()
    local out, finished = {}, false
    pr.open(12, { dir = fixture.dir, comments = false }, function(opened, err)
      out.session, out.err, finished = opened, err, true
    end)
    wait_for(function()
      return finished
    end, "the pull request did not open")
    assert.is_nil(out.err)
    return assert(out.session)
  end

  ---Store of a session with the comments of the test.
  ---@param session codeview.Session
  ---@return codeview.store.Store
  local function store_of(session)
    return assert(comments_mod.store(session))
  end

  ---Add one comment to a store.
  ---@param store codeview.store.Store
  ---@param fields? table
  ---@return codeview.store.Comment
  local function add(store, fields)
    return assert(store:add(vim.tbl_extend("force", {
      file = "a.txt",
      start_line = 2,
      end_line = 2,
      side = "new",
      commit = fixture.ids.pr_two,
      body = "this line needs a test",
    }, fields or {})))
  end

  ---Run the submit flow and wait for the answer.
  ---@param opts? table
  ---@return codeview.submit.Result? result
  ---@return codeview.Error? err
  local function run(opts)
    local out, finished = {}, false
    submit.run(opts or {}, function(result, err)
      out.result, out.err, finished = result, err, true
    end)
    wait_for(function()
      return finished
    end, "the submit did not answer")
    return out.result, out.err
  end

  ---Send one comment and wait for the answer.
  ---@param opts? table
  ---@return codeview.submit.Result? result
  ---@return codeview.Error? err
  local function send(opts)
    local out, finished = {}, false
    submit.send(opts or {}, function(result, err)
      out.result, out.err, finished = result, err, true
    end)
    wait_for(function()
      return finished
    end, "the send did not answer")
    return out.result, out.err
  end

  ---Build the plan and wait for the answer.
  ---@param opts? table
  ---@return codeview.submit.Plan? plan
  ---@return codeview.Error? err
  local function plan_of(opts)
    local out, finished = {}, false
    submit.plan(opts or {}, function(plan, err)
      out.plan, out.err, finished = plan, err, true
    end)
    wait_for(function()
      return finished
    end, "the plan did not answer")
    return out.plan, out.err
  end

  ---Text of every notification of the test.
  ---@return string
  local function said()
    return table.concat(messages, "\n")
  end

  before_each(function()
    helpers.unload()
    comments_mod = require("codeview.comments")
    errors = require("codeview.error")
    exec = require("codeview.exec")
    gh = require("codeview.gh")
    pr = require("codeview.pr")
    session_mod = require("codeview.session")
    store_mod = require("codeview.store")
    submit = require("codeview.submit")
    require("codeview.config").reset()

    gh_calls = {}
    answer = default_answer
    local real = exec.capture
    exec.capture = function(cmd, opts, cb) ---@diagnostic disable-line: duplicate-set-field
      if cmd[1] ~= "gh" then
        return real(cmd, opts, cb)
      end
      gh_calls[#gh_calls + 1] = { cmd = cmd, opts = opts or {} }
      local scripted = answer(cmd)
      local result = {
        command = cmd,
        code = scripted.code or 0,
        signal = 0,
        stdout = scripted.stdout or "",
        stderr = scripted.stderr or "",
      }
      if cb then
        vim.schedule(function()
          cb(result, nil)
        end)
        return nil, nil
      end
      return result, nil
    end
    gh.available = function() ---@diagnostic disable-line: duplicate-set-field
      return true
    end

    -- The submit never posts without an answer of the user. The tests give the
    -- answers here, so that no test can reach GitHub by accident.
    ui = { select = { "submit" }, input = "look at these lines", prompts = {} }
    real_select, real_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, on_choice) ---@diagnostic disable-line: duplicate-set-field
      ui.prompts[#ui.prompts + 1] = (opts or {}).prompt or ""
      local choice = table.remove(ui.select, 1)
      on_choice(choice, choice and vim.tbl_contains(items, choice) and 1 or nil)
    end
    vim.ui.input = function(opts, on_confirm) ---@diagnostic disable-line: duplicate-set-field
      ui.prompts[#ui.prompts + 1] = (opts or {}).prompt or ""
      on_confirm(ui.input)
    end

    messages = {}
    real_notify = vim.notify
    vim.notify = function(message) ---@diagnostic disable-line: duplicate-set-field
      messages[#messages + 1] = tostring(message)
    end
  end)

  after_each(function()
    vim.notify = real_notify
    vim.ui.select, vim.ui.input = real_select, real_input
    session_mod.close()
    vim.fn.delete(store_mod.path(fixture.root, "pr-12-" .. fixture.ids.pr_two))
    helpers.unload()
  end)

  describe("plan", function()
    it("maps every comment of the pull request diff", function()
      local session = open_session()
      local store = store_of(session)
      add(store, { start_line = 2, end_line = 2, side = "new" })
      add(store, { start_line = 2, end_line = 2, side = "old", body = "the old line" })
      add(store, { file = "feature.txt", start_line = 1, end_line = 2, body = "the whole file" })

      local plan = assert(plan_of({ session = session }))
      assert.are.equal(3, #plan.entries)
      assert.are.equal(0, #plan.skipped)
      assert.are.equal(3, plan.total)
      assert.are.equal(0, plan.synced)
      assert.are.equal(12, plan.pr.number)

      local by_path = {}
      for _, entry in ipairs(plan.entries) do
        by_path[entry.position.path] = by_path[entry.position.path] or {}
        table.insert(by_path[entry.position.path], entry.position)
      end
      assert.are.equal(2, #by_path["a.txt"])
      assert.are.equal("LEFT", by_path["a.txt"][1].side)
      assert.are.equal("RIGHT", by_path["a.txt"][2].side)
      assert.are.equal(2, by_path["a.txt"][2].line)
      assert.are.equal(1, by_path["feature.txt"][1].start_line)
      assert.are.equal(2, by_path["feature.txt"][1].line)
      assert.are.equal("RIGHT", by_path["feature.txt"][1].start_side)
    end)

    it("collects the comments that do not map", function()
      local session = open_session()
      local store = store_of(session)
      add(store, { file = "main.txt", body = "another file" })
      add(store, { start_line = 99, end_line = 99, body = "a line that is gone" })

      local plan = assert(plan_of({ session = session }))
      assert.are.equal(0, #plan.entries)
      assert.are.equal(2, #plan.skipped)

      local reasons = {}
      for _, skipped in ipairs(plan.skipped) do
        reasons[skipped.comment.file] = skipped.reason
      end
      assert.is_truthy(reasons["main.txt"]:find("does not change this file", 1, true), reasons["main.txt"])
      assert.is_truthy(reasons["a.txt"]:find("does not hold new line 99", 1, true), reasons["a.txt"])
    end)

    it("leaves the comments of an earlier submit out", function()
      local session = open_session()
      local store = store_of(session)
      local first = add(store)
      add(store, { start_line = 3, body = "the third line" })
      assert(store:mark_synced(first.id, { review_id = "77" }))

      local plan = assert(plan_of({ session = session }))
      assert.are.equal(1, plan.synced)
      assert.are.equal(2, plan.total)
      for _, entry in ipairs(plan.entries) do
        assert.are_not.equal(first.id, entry.comment.id)
      end
      for _, skipped in ipairs(plan.skipped) do
        assert.are_not.equal(first.id, skipped.comment.id)
      end
    end)

    it("maps the comments on the diff settings of git", function()
      local session = open_session()
      add(store_of(session))
      local diff_mod = require("codeview.diff")
      local real = diff_mod.compute
      local seen = {}
      diff_mod.compute = function(old, new, opts) ---@diagnostic disable-line: duplicate-set-field
        seen[#seen + 1] = opts or {}
        return real(old, new, opts)
      end
      local ok, plan = pcall(plan_of, { session = session })
      diff_mod.compute = real
      assert.is_true(ok)
      assert.are.equal(1, #assert(plan).entries)

      assert.is_true(#seen > 0)
      -- GitHub validates every position against the diff of git, so the map
      -- of the submit runs with the settings of git and not with the settings
      -- of the display.
      for _, opts in ipairs(seen) do
        assert.are.equal("myers", opts.algorithm)
        assert.is_true(opts.indent_heuristic)
        assert.are.equal(0, opts.linematch)
      end
    end)

    it("needs a session that reviews a pull request", function()
      local opened = assert(session_mod.open(fixture.ids.base .. ".." .. fixture.ids.main_two, { dir = fixture.dir }))
      local plan, err = plan_of({ session = opened })
      assert.is_nil(plan)
      assert.are.equal(errors.codes.INVALID_ARG, err.code)
      assert.is_truthy(tostring(err):find("pull request", 1, true))
    end)

    it("rejects an event that GitHub does not know", function()
      local session = open_session()
      local plan, err = plan_of({ session = session, event = "merge" })
      assert.is_nil(plan)
      assert.are.equal(errors.codes.INVALID_ARG, err.code)
    end)

    it("takes a comment on the pull request document as the text of the review", function()
      local session = open_session()
      local store = store_of(session)
      add(store)
      local note = add(store, {
        file = require("codeview.message").pr_path(12),
        start_line = 1,
        end_line = 1,
        body = "looks good overall",
      })

      local plan = assert(plan_of({ session = session }))
      assert.are.equal(1, #plan.entries)
      assert.are.equal(1, #plan.notes)
      assert.are.equal(0, #plan.skipped)
      assert.are.equal(note.body, submit.body(plan))

      plan.body = "hello"
      assert.are.equal("hello\n\n" .. note.body, submit.body(plan))
    end)
  end)

  describe("payload", function()
    it("builds one review of every mapped comment", function()
      local session = open_session()
      local store = store_of(session)
      add(store, { body = "one line" })
      add(store, { file = "feature.txt", start_line = 1, end_line = 2, body = "two lines" })

      local plan = assert(plan_of({ session = session, event = "request-changes", body = "please look" }))
      local payload = submit.payload(plan)

      assert.are.equal(fixture.ids.pr_two, payload.commit_id)
      assert.are.equal("REQUEST_CHANGES", payload.event)
      assert.are.equal("please look", payload.body)
      assert.are.equal(2, #payload.comments)

      local decoded = vim.json.decode(vim.json.encode(payload))
      assert.are.equal(2, #decoded.comments)
      for _, item in ipairs(decoded.comments) do
        assert.is_truthy(item.path)
        assert.is_truthy(item.line)
        assert.is_truthy(item.side)
        assert.is_truthy(item.body)
      end
    end)

    it("takes the fallback text for an event that needs a body", function()
      local session = open_session()
      add(store_of(session))
      local plan = assert(plan_of({ session = session, event = "comment", body = "" }))
      assert.are.equal(submit.fallback_body, submit.payload(plan).body)
    end)

    it("keeps an empty body for an approval", function()
      local session = open_session()
      add(store_of(session))
      local plan = assert(plan_of({ session = session, event = "approve", body = "" }))
      assert.are.equal("", submit.payload(plan).body)
    end)

    it("writes no comment list for a review without comments", function()
      local session = open_session()
      local plan = assert(plan_of({ session = session, event = "approve" }))
      assert.is_nil(submit.payload(plan).comments)
    end)
  end)

  describe("summary", function()
    it("names the comments that go out and the comments that stay", function()
      local session = open_session()
      local store = store_of(session)
      add(store, { body = "this line needs a test" })
      add(store, { file = "main.txt", body = "another file" })

      local plan = assert(plan_of({ session = session, event = "approve" }))
      local text = table.concat(submit.summary(plan), "\n")
      assert.is_truthy(text:find("submit 1 comment to PR #12 of ada/demo as approve", 1, true), text)
      assert.is_truthy(text:find("a.txt L2 new", 1, true), text)
      assert.is_truthy(text:find("1 comment stays local", 1, true), text)
      assert.is_truthy(text:find("main.txt L2 new: the pull request does not change this file", 1, true), text)
    end)

    it("names the comments that go into the text of the review", function()
      local session = open_session()
      local store = store_of(session)
      add(store, {
        file = require("codeview.message").pr_path(12),
        start_line = 1,
        end_line = 1,
        body = "looks good overall",
      })

      local plan = assert(plan_of({ session = session, event = "approve" }))
      local text = table.concat(submit.summary(plan), "\n")
      assert.is_truthy(text:find("into the text of the review", 1, true), text)
      assert.is_truthy(text:find("looks good overall", 1, true), text)
    end)
  end)

  describe("run", function()
    it("posts one review after the confirmation", function()
      local session = open_session()
      local store = store_of(session)
      add(store)
      add(store, { file = "feature.txt", start_line = 1, end_line = 2, body = "two lines" })

      local result = assert(run({ session = session, event = "request-changes", body = "please look" }))
      assert.is_false(result.cancelled)
      assert.are.equal(2, result.posted)
      assert.are.equal(0, result.skipped)

      local calls = api_calls()
      assert.are.equal(1, #calls)
      assert.are.same({
        "gh",
        "api",
        "repos/ada/demo/pulls/12/reviews",
        "--method",
        "POST",
        "--input",
        "-",
      }, calls[1].cmd)

      local sent = vim.json.decode(calls[1].opts.stdin)
      assert.are.equal("REQUEST_CHANGES", sent.event)
      assert.are.equal("please look", sent.body)
      assert.are.equal(fixture.ids.pr_two, sent.commit_id)
      assert.are.equal(2, #sent.comments)
      assert.is_truthy(said():find("2 comments went to PR #12", 1, true), said())
      assert.is_truthy(said():find("pullrequestreview-2371558991", 1, true), said())
    end)

    it("shows the summary before the post", function()
      local session = open_session()
      add(store_of(session))
      assert(run({ session = session, event = "comment", body = "hello" }))
      assert.is_truthy(ui.prompts[1]:find("post 1 comment to PR #12 as comment?", 1, true), ui.prompts[1])
    end)

    it("posts nothing when the user cancels", function()
      local session = open_session()
      add(store_of(session))
      ui.select = { "cancel" }

      local result = assert(run({ session = session, event = "comment", body = "hello" }))
      assert.is_true(result.cancelled)
      assert.are.equal(0, result.posted)
      assert.are.equal(0, #api_calls())
      assert.are.equal(1, #store_of(session):unsynced())
      assert.is_truthy(said():find("canceled", 1, true), said())
    end)

    it("asks for the event and for the text of the review", function()
      local session = open_session()
      add(store_of(session))
      ui.select = { "approve", "submit" }
      ui.input = "looks good"

      local result = assert(run({ session = session }))
      assert.is_false(result.cancelled)
      local sent = vim.json.decode(api_calls()[1].opts.stdin)
      assert.are.equal("APPROVE", sent.event)
      assert.are.equal("looks good", sent.body)
      assert.is_truthy(ui.prompts[1]:find("submit 1 comment to PR #12 as", 1, true), ui.prompts[1])
      assert.is_truthy(ui.prompts[2]:find("text of the approve review", 1, true), ui.prompts[2])
    end)

    it("posts nothing when the user picks no event", function()
      local session = open_session()
      add(store_of(session))
      ui.select = {}

      local result = assert(run({ session = session }))
      assert.is_true(result.cancelled)
      assert.are.equal(0, #api_calls())
    end)

    it("posts nothing when the user cancels the text of the review", function()
      local session = open_session()
      add(store_of(session))
      ui.select = { "comment" }
      ui.input = nil

      local result = assert(run({ session = session }))
      assert.is_true(result.cancelled)
      assert.are.equal(0, #api_calls())
    end)

    it("marks every posted comment as synced in the session file", function()
      local session = open_session()
      local store = store_of(session)
      local comment = add(store)
      assert(run({ session = session, event = "comment", body = "hello" }))

      assert.is_true(store_mod.is_synced(assert(store:get(comment.id))))
      assert.are.equal("2371558991", assert(store:get(comment.id)).review_id)

      local reloaded = assert(store_mod.load({ repo = fixture.root, range = "pr-12-" .. fixture.ids.pr_two }))
      assert.are.equal(1, reloaded:count())
      assert.is_true(store_mod.is_synced(reloaded.comments[1]))
      assert.are.equal("2371558991", reloaded.comments[1].review_id)
      assert.are.equal(0, #reloaded:unsynced())
    end)

    it("sends a synced comment no second time", function()
      local session = open_session()
      add(store_of(session))
      assert(run({ session = session, event = "comment", body = "hello" }))
      assert.are.equal(1, #api_calls())

      messages = {}
      local result = assert(run({ session = session, event = "comment", body = "hello" }))
      assert.are.equal(0, result.posted)
      assert.is_true(result.cancelled)
      assert.are.equal(1, #api_calls())
      assert.is_truthy(said():find("already", 1, true), said())
    end)

    it("marks nothing after an error of the API", function()
      local session = open_session()
      local store = store_of(session)
      local comment = add(store)
      answer = function(cmd)
        if cmd[2] == "pr" then
          return { stdout = pr_view() }
        end
        return {
          code = 1,
          stderr = "HTTP 422: Validation Failed (https://api.github.com/repos/ada/demo/pulls/12/reviews)\n"
            .. "line must be part of the diff",
        }
      end

      local result, err = run({ session = session, event = "comment", body = "hello" })
      assert.is_nil(result)
      assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
      assert.is_truthy(tostring(err):find("HTTP 422", 1, true), tostring(err))
      assert.is_truthy(said():find("line must be part of the diff", 1, true), said())

      assert.is_false(store_mod.is_synced(assert(store:get(comment.id))))
      local reloaded = assert(store_mod.load({ repo = fixture.root, range = "pr-12-" .. fixture.ids.pr_two }))
      for _, held in ipairs(reloaded.comments) do
        assert.is_false(store_mod.is_synced(held))
      end
    end)

    it("reports the comments that stay local after an error of the API", function()
      local session = open_session()
      local store = store_of(session)
      add(store)
      local gone = add(store, { start_line = 99, end_line = 99, body = "a line that is gone" })
      answer = function(cmd)
        if cmd[2] == "pr" then
          return { stdout = pr_view() }
        end
        return { code = 1, stderr = "HTTP 422: Validation Failed\nline must be part of the diff" }
      end

      local result, err = run({ session = session, event = "comment", body = "hello" })
      assert.is_nil(result)
      assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
      assert.is_truthy(said():find("stays local", 1, true), said())
      assert.is_truthy(said():find("does not hold new line 99", 1, true), said())
      assert.is_false(store_mod.is_synced(assert(store:get(gone.id))))
    end)

    it("says that no comment maps when every comment stays local", function()
      local session = open_session()
      local store = store_of(session)
      add(store, { start_line = 99, end_line = 99, body = "a line that is gone" })
      local synced = add(store, { start_line = 3, body = "the third line" })
      assert(store:mark_synced(synced.id, { review_id = "77" }))

      local result = assert(run({ session = session, event = "comment", body = "hello" }))
      assert.is_true(result.cancelled)
      assert.are.equal(1, result.skipped)
      assert.are.equal(0, #api_calls())
      assert.is_truthy(said():find("no comment maps to the diff", 1, true), said())
      assert.is_nil(said():find("every comment went to the pull request already", 1, true), said())
    end)

    it("keeps a comment that does not map and reports it", function()
      local session = open_session()
      local store = store_of(session)
      add(store)
      local gone = add(store, { start_line = 99, end_line = 99, body = "a line that is gone" })

      local result = assert(run({ session = session, event = "comment", body = "hello" }))
      assert.are.equal(1, result.posted)
      assert.are.equal(1, result.skipped)
      assert.is_false(store_mod.is_synced(assert(store:get(gone.id))))
      assert.is_truthy(said():find("stays local", 1, true), said())
      assert.is_truthy(said():find("does not hold new line 99", 1, true), said())
    end)

    it("posts nothing and reports the reason without a comment", function()
      local session = open_session()
      local result = assert(run({ session = session, event = "comment", body = "hello" }))
      assert.are.equal(0, result.posted)
      assert.is_true(result.cancelled)
      assert.are.equal(0, #api_calls())
      assert.is_truthy(said():find("no comment to submit", 1, true), said())
    end)

    it("reports a session that does not review a pull request", function()
      local opened = assert(session_mod.open(fixture.ids.base .. ".." .. fixture.ids.main_two, { dir = fixture.dir }))
      local result, err = run({ session = opened, event = "comment", body = "hello" })
      assert.is_nil(result)
      assert.are.equal(errors.codes.INVALID_ARG, err.code)
      assert.are.equal(0, #api_calls())
    end)

    it("sends the notes as the text of the review without a prompt", function()
      local session = open_session()
      local store = store_of(session)
      local line = add(store)
      local note = add(store, {
        file = require("codeview.message").pr_path(12),
        start_line = 1,
        end_line = 1,
        body = "looks good overall",
      })

      local result = assert(run({ session = session, event = "comment" }))
      assert.are.equal(2, result.posted)
      local sent = vim.json.decode(api_calls()[1].opts.stdin)
      assert.are.equal(note.body, sent.body)
      for _, prompt in ipairs(ui.prompts) do
        assert.is_nil(prompt:find("codeview: text of", 1, true), prompt)
      end
      assert.are.equal("2371558991", assert(store:get(line.id)).review_id)
      assert.are.equal("2371558991", assert(store:get(note.id)).review_id)
    end)

    it("posts a review of the notes alone", function()
      local session = open_session()
      local store = store_of(session)
      local note = add(store, {
        file = require("codeview.message").pr_path(12),
        start_line = 1,
        end_line = 1,
        body = "looks good overall",
      })

      local result = assert(run({ session = session, event = "comment" }))
      assert.are.equal(1, result.posted)
      local sent = vim.json.decode(api_calls()[1].opts.stdin)
      assert.is_nil(sent.comments)
      assert.are.equal(note.body, sent.body)
    end)
  end)

  describe("send", function()
    it("posts one line comment to the review comments", function()
      local session = open_session()
      local store = store_of(session)
      local comment = add(store)

      local result = assert(send({ session = session, id = comment.id }))
      assert.are.equal(1, result.posted)
      assert.is_false(result.cancelled)
      assert.is_truthy(result.url:find("discussion_r1000000001", 1, true), result.url)

      local calls = api_calls()
      assert.are.equal(1, #calls)
      assert.are.same({
        "gh",
        "api",
        "repos/ada/demo/pulls/12/comments",
        "--method",
        "POST",
        "--input",
        "-",
      }, calls[1].cmd)

      local sent = vim.json.decode(calls[1].opts.stdin)
      assert.are.equal(comment.body, sent.body)
      assert.are.equal("a.txt", sent.path)
      assert.are.equal(2, sent.line)
      assert.are.equal("RIGHT", sent.side)
      assert.are.equal(fixture.ids.pr_two, sent.commit_id)
      assert.is_nil(sent.start_line)

      assert.is_true(store_mod.is_synced(assert(store:get(comment.id))))
      assert.are.equal("2371558991", assert(store:get(comment.id)).review_id)

      local reloaded = assert(store_mod.load({ repo = fixture.root, range = "pr-12-" .. fixture.ids.pr_two }))
      assert.are.equal(0, #reloaded:unsynced())
      assert.is_truthy(said():find("the comment went to PR #12", 1, true), said())
    end)

    it("posts a comment over more than one line with its start", function()
      local session = open_session()
      local comment = add(store_of(session), { file = "feature.txt", start_line = 1, end_line = 2, body = "two lines" })

      assert(send({ session = session, id = comment.id }))
      local sent = vim.json.decode(api_calls()[1].opts.stdin)
      assert.are.equal(1, sent.start_line)
      assert.are.equal("RIGHT", sent.start_side)
    end)

    it("posts a comment on the pull request document to the conversation", function()
      local session = open_session()
      local store = store_of(session)
      local comment = add(store, {
        file = require("codeview.message").pr_path(12),
        start_line = 1,
        end_line = 1,
        body = "looks good overall",
      })

      local result = assert(send({ session = session, id = comment.id }))
      local calls = api_calls()
      assert.are.equal(1, #calls)
      assert.are.equal("repos/ada/demo/issues/12/comments", calls[1].cmd[3])
      assert.are.same({ body = "looks good overall" }, vim.json.decode(calls[1].opts.stdin))

      assert.is_true(store_mod.is_synced(assert(store:get(comment.id))))
      assert.are.equal("", assert(store:get(comment.id)).review_id)
      assert.is_truthy(result.url:find("issuecomment", 1, true), result.url)
    end)

    it("keeps a comment on a commit message local", function()
      local session = open_session()
      local store = store_of(session)
      local comment = add(store, { file = require("codeview.message").path_of(fixture.ids.pr_two) })

      local result, err = send({ session = session, id = comment.id })
      assert.is_nil(result)
      assert.is_truthy(tostring(err):find("commit message", 1, true), tostring(err))
      assert.are.equal(0, #api_calls())
      assert.is_false(store_mod.is_synced(assert(store:get(comment.id))))
    end)

    it("reports a line that the diff does not hold", function()
      local session = open_session()
      local store = store_of(session)
      local comment = add(store, { file = "main.txt", body = "another file" })

      local result, err = send({ session = session, id = comment.id })
      assert.is_nil(result)
      assert.is_truthy(tostring(err):find("does not change this file", 1, true), tostring(err))
      assert.are.equal(0, #api_calls())
      assert.is_false(store_mod.is_synced(assert(store:get(comment.id))))
    end)

    it("sends a synced comment no second time", function()
      local session = open_session()
      local comment = add(store_of(session))
      assert(send({ session = session, id = comment.id }))
      assert.are.equal(1, #api_calls())

      messages = {}
      local result = assert(send({ session = session, id = comment.id }))
      assert.are.equal(0, result.posted)
      assert.is_true(result.cancelled)
      assert.are.equal(1, #api_calls())
      assert.is_truthy(said():find("already", 1, true), said())
    end)

    it("marks nothing after an error of the API", function()
      local session = open_session()
      local store = store_of(session)
      local comment = add(store)
      answer = function(cmd)
        if cmd[2] == "pr" then
          return { stdout = pr_view() }
        end
        return { code = 1, stderr = "HTTP 422: Validation Failed" }
      end

      local result, err = send({ session = session, id = comment.id })
      assert.is_nil(result)
      assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
      assert.is_false(store_mod.is_synced(assert(store:get(comment.id))))

      local reloaded = assert(store_mod.load({ repo = fixture.root, range = "pr-12-" .. fixture.ids.pr_two }))
      for _, held in ipairs(reloaded.comments) do
        assert.is_false(store_mod.is_synced(held))
      end
    end)

    it("needs a pull request session", function()
      local opened = assert(session_mod.open(fixture.ids.base .. ".." .. fixture.ids.pr_two, { dir = fixture.dir }))
      local comment = add(assert(comments_mod.store(opened)))

      local result, err = send({ session = opened, id = comment.id })
      assert.is_nil(result)
      assert.is_truthy(tostring(err):find("pull request", 1, true), tostring(err))
      assert.are.equal(0, #api_calls())
      opened:close()
    end)

    it("builds the two payloads", function()
      local info = { repo = "ada/demo", number = 12, head_sha = "abc" }
      local comment = { body = "a note" }

      local path, payload = submit.send_payload(info, comment, nil)
      assert.are.equal("repos/ada/demo/issues/12/comments", path)
      assert.are.same({ body = "a note" }, payload)

      local position = { path = "a.txt", side = "LEFT", line = 4, start_line = 2, start_side = "LEFT" }
      local line_path, line_payload = submit.send_payload(info, comment, position)
      assert.are.equal("repos/ada/demo/pulls/12/comments", line_path)
      assert.are.same({
        body = "a note",
        commit_id = "abc",
        path = "a.txt",
        line = 4,
        side = "LEFT",
        start_line = 2,
        start_side = "LEFT",
      }, line_payload)
    end)
  end)

  describe("the editor", function()
    ---Open the diff of a file and put the cursor on one line of the new side.
    ---@param opened codeview.Session
    ---@param path string
    ---@param line integer
    ---@return codeview.view.State
    local function cursor_on(opened, path, line)
      local view = require("codeview.view")
      local state = assert(view.open(opened, assert(opened:index_of(path))))
      vim.api.nvim_set_current_win(state.win)
      vim.api.nvim_win_set_cursor(state.win, { assert(state.map:buf_row(line, "new")), 0 })
      return state
    end

    it("posts the comment of the editor with the send key", function()
      local editor = require("codeview.editor")
      local view = require("codeview.view")
      local session = open_session()
      local state = cursor_on(session, "a.txt", 2)

      assert.is_true(comments_mod.add({ view = state }))
      vim.api.nvim_buf_set_lines(assert(editor.current()).buf, 0, -1, false, { "from the editor" })
      assert.is_true(editor.send())

      local store = store_of(session)
      wait_for(function()
        return store:count() == 1 and #store:unsynced() == 0
      end, "the comment did not go to the pull request")

      assert.are.equal(1, #api_calls())
      assert.are.equal("from the editor", vim.json.decode(api_calls()[1].opts.stdin).body)

      editor.cancel()
      view.close()
    end)

    it("gives the editor of a local review no send handler", function()
      local editor = require("codeview.editor")
      local view = require("codeview.view")
      local opened = assert(session_mod.open(fixture.ids.base .. ".." .. fixture.ids.pr_two, { dir = fixture.dir }))
      local state = cursor_on(opened, "a.txt", 2)

      assert.is_true(comments_mod.add({ view = state }))
      assert.is_nil(assert(editor.current()).on_send)

      editor.cancel()
      view.close()
      opened:close()
    end)
  end)

  describe(":Codeview submit", function()
    it("takes the event as its argument", function()
      local session = open_session()
      add(store_of(session))
      local out, finished = {}, false
      require("codeview.command").submit({
        args = "approve",
        bang = true,
        on_done = function(result, err)
          out.result, out.err, finished = result, err, true
        end,
      })
      wait_for(function()
        return finished
      end, "the command did not answer")

      assert.is_nil(out.err)
      assert.are.equal(1, out.result.posted)
      assert.are.equal("APPROVE", vim.json.decode(api_calls()[1].opts.stdin).event)
      -- The bang answers the question about the text of the review.
      for _, prompt in ipairs(ui.prompts) do
        assert.is_nil(prompt:find("text of the", 1, true), prompt)
      end
    end)

    it("reports an event that GitHub does not know", function()
      local session = open_session()
      add(store_of(session))
      local out, finished = {}, false
      require("codeview.command").submit({
        args = "merge",
        on_done = function(result, err)
          out.result, out.err, finished = result, err, true
        end,
      })
      wait_for(function()
        return finished
      end, "the command did not answer")

      assert.is_nil(out.result)
      assert.are.equal(errors.codes.INVALID_ARG, out.err.code)
      assert.are.equal(0, #api_calls())
    end)

    it("completes the events in a clean Neovim", function()
      local res = helpers.clean_nvim('print(vim.inspect(vim.fn.getcompletion("Codeview submit ", "cmdline")))')
      assert.are.equal(0, res.code)
      assert.is_truthy(res.output:find("request%-changes"), res.output)
      assert.is_truthy(res.output:find("approve", 1, true), res.output)
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.root))
  end)
end)
