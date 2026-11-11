local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

describe("codeview.agent", function()
  local agent, config

  before_each(function()
    helpers.unload()
    agent = require("codeview.agent")
    config = require("codeview.config")
    config.reset()
  end)

  after_each(function()
    helpers.unload()
  end)

  describe("root", function()
    local held

    before_each(function()
      held = { root = vim.env.CHAOSHUB_AGENT_ROOT, state = vim.env.XDG_STATE_HOME }
    end)

    after_each(function()
      vim.env.CHAOSHUB_AGENT_ROOT = held.root
      vim.env.XDG_STATE_HOME = held.state
    end)

    it("takes the option first, then the env of chaoshub, then the state directory", function()
      vim.env.CHAOSHUB_AGENT_ROOT = "/from/chaoshub"
      vim.env.XDG_STATE_HOME = "/state"
      assert(config.setup({ github = { agent_dir = "/from/option" } }))
      assert.are.equal("/from/option", agent.root())

      config.reset()
      assert.are.equal("/from/chaoshub", agent.root())

      vim.env.CHAOSHUB_AGENT_ROOT = nil
      assert.are.equal("/state/chaoshub/agent", agent.root())

      vim.env.XDG_STATE_HOME = nil
      assert.are.equal(vim.fs.normalize("~/.local/state/chaoshub/agent"), agent.root())
    end)

    it("puts the files of a pull request under the owner, the repository, and the number", function()
      assert(config.setup({ github = { agent_dir = "/root" } }))
      assert.are.equal("/root/ada/demo/12", agent.dir({ repo = "ada/demo", number = 12 }))
    end)
  end)

  describe("read", function()
    local dir

    before_each(function()
      dir = fixtures.tempdir("codeview-agent")
      assert(config.setup({ github = { agent_dir = dir } }))
    end)

    after_each(function()
      vim.fn.delete(dir, "rf")
    end)

    ---Write one result file of the pull request ada/demo#12.
    ---@param tool string
    ---@param record table
    local function write(tool, record)
      local path = vim.fs.joinpath(dir, "ada", "demo", "12", tool .. ".json")
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ vim.json.encode(record) }, path)
    end

    it("reads the files of the four tools", function()
      write("review", { version = 1, tool = "review", pr = 12, head_sha = "abc", data = { review = {} } })
      write("ask", { version = 1, tool = "ask", pr = 12, head_sha = "abc", data = {} })
      local results = agent.read({ repo = "ada/demo", number = 12 })
      assert.are.equal("review", results.review.tool)
      assert.are.equal("abc", results.review.head_sha)
      assert.are.equal("ask", results.ask.tool)
      assert.is_nil(results.improve)
      assert.is_nil(results.describe)
      assert.are.same({}, results.errors)
    end)

    it("refuses a file of another version", function()
      write("improve", { version = 2, tool = "improve" })
      local results = agent.read({ repo = "ada/demo", number = 12 })
      assert.is_nil(results.improve)
      assert.are.equal("version 2 is not 1", results.errors.improve)
    end)

    it("refuses a file without a JSON object", function()
      local path = vim.fs.joinpath(dir, "ada", "demo", "12", "describe.json")
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ "not json" }, path)
      local record, err = agent.read_file(path)
      assert.is_nil(record)
      assert.are.equal("the file holds no JSON object", err)
    end)

    it("reads no file and no error for a missing directory", function()
      local results = agent.read({ repo = "ada/other", number = 1 })
      assert.is_nil(results.review)
      assert.are.same({}, results.errors)
    end)
  end)
end)

describe("codeview.agent in a pull request review", function()
  local fixture = fixtures.git_comments()
  local agent, config, events, session_mod
  local dir
  ---@type codeview.Session?
  local opened

  ---Write one result file of the pull request ada/demo#12.
  ---@param tool string
  ---@param record table
  local function write(tool, record)
    local path = vim.fs.joinpath(dir, "ada", "demo", "12", tool .. ".json")
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ vim.json.encode(record) }, path)
  end

  ---Open a review of the fixture as the pull request ada/demo#12.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, {
      dir = fixture.dir,
      pr = {
        repo = "ada/demo",
        number = 12,
        title = "Demo",
        author = "ada",
        head_ref = "change",
        base_ref = "main",
        state = "OPEN",
        url = "https://github.com/ada/demo/pull/12",
        body = "",
        head_sha = fixture.ids.change,
      },
    })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  before_each(function()
    helpers.unload()
    agent = require("codeview.agent")
    config = require("codeview.config")
    events = require("codeview.events")
    session_mod = require("codeview.session")
    dir = fixtures.tempdir("codeview-agent")
    config.reset()
    -- The comment files go to the temporary directory too, so an adopt of one
    -- test leaves no comment for the next one.
    assert(config.setup({ github = { agent_dir = dir }, comments = { dir = vim.fs.joinpath(dir, "comments") } }))
  end)

  after_each(function()
    if opened then
      opened:close()
      opened = nil
    end
    vim.fn.delete(dir, "rf")
    helpers.unload()
  end)

  it("reads the results with the session and sends an event", function()
    write("review", { version = 1, tool = "review", pr = 12, head_sha = fixture.ids.change, data = { review = {} } })
    local seen = 0
    events.on(events.agent, function()
      seen = seen + 1
    end)
    local review = open_session()
    local results = assert(agent.attach(review))
    assert.are.equal("review", results.review.tool)
    assert.are.equal(results, agent.get(review.pr))
    assert.are.equal(1, seen)
  end)

  it("reads nothing for a session without a pull request", function()
    local review = assert(session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir }))
    opened = review
    assert.is_nil(agent.attach(review))
  end)

  it("reads the files again after a refresh of the session", function()
    local review = open_session()
    assert.is_nil(assert(agent.attach(review)).improve)
    write("improve", { version = 1, tool = "improve", pr = 12, head_sha = fixture.ids.change, data = {} })
    vim.api.nvim_exec_autocmds("User", { pattern = "CodeViewSessionRefreshed", data = { id = review.id } })
    assert.are.equal("improve", agent.get(review.pr).improve.tool)
  end)

  it("follows a change of the directory", function()
    local review = open_session()
    agent.attach(review)
    write("describe", { version = 1, tool = "describe", pr = 12, head_sha = fixture.ids.change, data = {} })
    assert.is_true(
      vim.wait(5000, function()
        local results = agent.get(review.pr)
        return results ~= nil and results.describe ~= nil
      end, 20),
      "the watcher did not read the new file"
    )
  end)

  it("warns once for a file of another version", function()
    write("ask", { version = 3, tool = "ask" })
    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    local review = open_session()
    agent.attach(review)
    agent.load(review)
    vim.notify = notify
    assert.are.equal(1, #seen)
    assert.is_truthy(seen[1]:find("ask.json", 1, true), seen[1])
  end)

  ---A review result of the head of the fixture, with one key issue.
  ---@param head? string Head commit of the run.
  ---@return table
  local function review_record(head)
    return {
      version = 1,
      tool = "review",
      pr = 12,
      head_sha = head or fixture.ids.change,
      model = "anthropic/claude-sonnet-5-5",
      finished_at = "2026-11-05T17:00:00Z",
      data = {
        review = {
          ["estimated_effort_to_review_[1-5]"] = 2,
          key_issues_to_review = {
            {
              relevant_file = "call.lua",
              issue_header = "Possible Bug",
              issue_content = "The value changed.",
              start_line = 2,
              end_line = 2,
            },
          },
        },
      },
    }
  end

  ---Lines of the document of one entry of the session.
  ---@param review codeview.Session
  ---@param path string
  ---@return string[]
  local function document(review, path)
    local message = require("codeview.message")
    local file = assert(review:file(assert(review:index_of(path))))
    local built = assert(message.for_file(review, file))
    return built.new_lines
  end

  it("lists the documents under the node Agent, after the pull request document", function()
    write("review", review_record())
    write("ask", { version = 1, tool = "ask", pr = 12, head_sha = fixture.ids.change, data = {} })
    local message = require("codeview.message")
    local review = open_session()
    assert.is_nil(review:index_of(message.agent_path("review")))
    agent.attach(review)

    assert.is_true(message.is_pr(review.files[1].path))
    assert.are.equal(message.agent_path("review"), review.files[2].path)
    assert.are.equal(message.agent_path("ask"), review.files[3].path)
    assert.is_nil(review:index_of(message.agent_path("describe")))
    assert.are.equal("Agent", review.files[2].group)
    assert.are.equal(2, review.files[2].order)
    assert.is_true(review.files[2].virtual)
    assert.are.equal("pr-agent review", message.display(review.files[2].path, review))
  end)

  it("keeps the documents after a refresh of the session", function()
    write("review", review_record())
    local message = require("codeview.message")
    local review = open_session()
    agent.attach(review)
    assert.is_true(review:refresh({ snapshot = false }) ~= nil)
    assert.is_truthy(review:index_of(message.agent_path("review")))
  end)

  it("shows the fields and the key issues of a review", function()
    write("review", review_record())
    local review = open_session()
    agent.attach(review)
    local lines = document(review, "codeview://agent/review")
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("pr-agent review of #12", 1, true), text)
    assert.is_truthy(vim.tbl_contains(lines, "Estimated effort to review: 2"), text)
    -- The issue lines are markdown, so they keep no indent.
    assert.is_truthy(vim.tbl_contains(lines, "Possible Bug  call.lua:2"), text)
    assert.is_truthy(vim.tbl_contains(lines, "The value changed."), text)
    assert.is_nil(text:find("Outdated", 1, true), text)
  end)

  it("says in the first line that a result is outdated", function()
    write("review", review_record("3a1f2c0e9b"))
    local review = open_session()
    agent.attach(review)
    local first = document(review, "codeview://agent/review")[1]
    assert.are.equal(
      string.format("Outdated: pr-agent ran on 3a1f2c0, the head is now %s.", fixture.ids.change:sub(1, 7)),
      first
    )
  end)

  it("shows the new title and body of a describe result", function()
    write("describe", {
      version = 1,
      tool = "describe",
      pr = 12,
      head_sha = fixture.ids.change,
      data = {
        title = "Add a greeting",
        description = "- Add a greeting",
        pr_files = { { filename = "call.lua", changes_title = "Greet", label = "enhancement" } },
      },
    })
    local review = open_session()
    agent.attach(review)
    local lines = document(review, "codeview://agent/describe")
    local text = table.concat(lines, "\n")
    assert.is_truthy(vim.tbl_contains(lines, "Title: Add a greeting"), text)
    assert.is_truthy(vim.tbl_contains(lines, "- Add a greeting"), text)
    assert.is_truthy(vim.tbl_contains(lines, "- `call.lua` (enhancement): Greet"), text)
  end)

  it("shows the questions and answers, newest first", function()
    write("ask", {
      version = 1,
      tool = "ask",
      pr = 12,
      head_sha = fixture.ids.change,
      data = {
        { question = "How?", answer = "Like this.", head_sha = fixture.ids.change, at = "2026-11-05T18:00:00Z" },
        { question = "Why?", answer = "Because.", head_sha = fixture.ids.change, at = "2026-11-05T17:00:00Z" },
      },
    })
    local review = open_session()
    agent.attach(review)
    local lines = document(review, "codeview://agent/ask")
    local text = table.concat(lines, "\n")
    local how, why = text:find("Q: How?", 1, true), text:find("Q: Why?", 1, true)
    assert.is_truthy(how and why and how < why, text)
    assert.is_truthy(vim.tbl_contains(lines, "Like this."), text)
  end)

  it("writes the pr-agent documents as markdown", function()
    write("describe", {
      version = 1,
      tool = "describe",
      pr = 12,
      -- An older head adds the "Outdated" line on top.
      head_sha = "3a1f2c0e9b",
      data = { title = "Add a greeting", description = "Use `greet`.\n\n- one\n- two" },
    })
    write("ask", {
      version = 1,
      tool = "ask",
      pr = 12,
      head_sha = fixture.ids.change,
      data = {
        { question = "How?", answer = "Like **this**.", head_sha = fixture.ids.change, at = "2026-11-05T18:00:00Z" },
      },
    })
    write("review", review_record())
    local message = require("codeview.message")
    local review = open_session()
    agent.attach(review)

    for _, tool in ipairs(message.agent_tools) do
      local path = message.agent_path(tool)
      local built = assert(message.for_file(review, assert(review:file(assert(review:index_of(path))))))
      assert.are.equal("markdown", built.filetype, path)
      -- An indent of four spaces makes an indented code block in markdown.
      for _, line in ipairs(built.new_lines) do
        assert.is_falsy(line:find("^    "), path .. ": " .. line)
      end
    end

    local described = document(review, "codeview://agent/describe")
    assert.is_truthy(vim.startswith(described[1], "Outdated: pr-agent ran on 3a1f2c0"), described[1])
    assert.is_truthy(vim.tbl_contains(described, "Use `greet`."))
    assert.is_truthy(vim.tbl_contains(described, "- one"))
    assert.is_truthy(vim.tbl_contains(document(review, "codeview://agent/ask"), "Like **this**."))
  end)

  it("loads a pr-agent document as markdown in the view", function()
    write("describe", {
      version = 1,
      tool = "describe",
      pr = 12,
      head_sha = "3a1f2c0e9b",
      data = { title = "Add a greeting", description = "Use `greet`." },
    })
    local syntax = require("codeview.syntax")
    local view = require("codeview.view")
    local review = open_session()
    agent.attach(review)
    local state = assert(view.open(review, assert(review:index_of("codeview://agent/describe"))))
    helpers.start_markdown_treesitter(state.buf)

    assert.are.equal("markdown", vim.bo[state.buf].filetype)
    assert.is_not_nil(vim.treesitter.highlighter.active[state.buf])
    -- The colors come from the filetype, not from codeview.
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(state.buf, syntax.ns, 0, -1, {}))
    local row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
      if line == "Use `greet`." then
        row = index
      end
    end
    assert(row, "no row with the body")
    local captures = helpers.captures_at(state.buf, row - 1, 5)
    assert.is_true(
      vim.iter(captures):any(function(capture)
        return capture.capture == "markup.raw"
      end),
      "no code span color on the body of the describe result"
    )
    view.close()
  end)

  it("keeps a comment on a pr-agent document local", function()
    write("review", review_record())
    local review = open_session()
    agent.attach(review)
    local store = assert(require("codeview.comments").store(review))
    assert(store:add({
      file = "codeview://agent/review",
      start_line = 1,
      end_line = 1,
      side = "new",
      commit = fixture.ids.change,
      body = "a note on the review",
    }))
    local plan = assert(require("codeview.submit").plan({ session = review }))
    assert.are.equal(0, #plan.entries)
    assert.are.equal(1, #plan.skipped)
    assert.are.equal(0, #plan.notes)
  end)

  ---An improve result with one suggestion on call.lua.
  ---@param fields? table Fields of the suggestion that replace the defaults.
  ---@param head? string Head commit of the run.
  ---@return table
  local function improve_record(fields, head)
    return {
      version = 1,
      tool = "improve",
      pr = 12,
      head_sha = head or fixture.ids.change,
      data = {
        code_suggestions = {
          vim.tbl_extend("force", {
            relevant_file = "call.lua",
            relevant_lines_start = 2,
            relevant_lines_end = 2,
            existing_code = "local b = 22",
            improved_code = "local b = 23",
            suggestion_content = "Use the next number.",
            one_sentence_summary = "Next number",
            label = "possible issue",
            score = 8,
          }, fields or {}),
        },
      },
    }
  end

  ---Show the diff of call.lua. Row 4 of the inline render holds the new
  ---line 2.
  ---@param review codeview.Session
  ---@return codeview.view.State
  local function open_diff(review)
    local view = require("codeview.view")
    local state = assert(view.open(review, assert(review:index_of("call.lua"))))
    vim.api.nvim_set_current_win(state.win)
    return state
  end

  ---Extmarks of the pr-agent namespace in a buffer.
  ---@param buf integer
  ---@return table[]
  local function agent_marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, agent.ns, 0, -1, { details = true })
  end

  ---Virtual lines of the first box in a buffer.
  ---@param buf integer
  ---@return table[][]
  local function box_lines(buf)
    local found = require("codeview.stack").marks(buf)
    return found[1] and found[1][4].virt_lines or {}
  end

  it("marks the lines of a suggestion in the diff", function()
    write("improve", improve_record())
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)

    local found = agent_marks(state.buf)
    assert.are.equal(1, #found)
    assert.are.equal(3, found[1][2])
    local details = found[1][4]
    assert.are.equal("✦", vim.trim(details.sign_text))
    assert.are.equal("CodeViewAgentSign", details.sign_hl_group)
    local lines = box_lines(state.buf)
    assert.are.same({ "╭─ ", "CodeViewAgentBorder" }, lines[1][1])
    assert.are.same({
      "pr-agent · possible issue · score 8 · L2 · read-only",
      { "CodeViewAgentHeader", "CodeViewAgentBox" },
    }, lines[1][2])
    assert.are.same({ "│", "CodeViewAgentBorder" }, lines[2][1])
    assert.are.equal("Use the next number.", vim.trim(lines[2][2][1]))
    assert.are.same({ "CodeViewAgent", "CodeViewAgentBox" }, lines[2][2][2])
    assert.are.equal("local b = 23", vim.trim(lines[4][2][1]))
    assert.are.equal(0, #require("codeview.remote").marks(state.buf))

    -- The box of a suggestion has its own tint, not the grey of GitHub.
    local agent_box = vim.api.nvim_get_hl(0, { name = "CodeViewAgentBox" })
    local remote_box = vim.api.nvim_get_hl(0, { name = "CodeViewRemoteBox" })
    assert.is_number(agent_box.bg)
    assert.are_not.equal(remote_box.bg, agent_box.bg)
    require("codeview.view").close()
  end)

  it("marks a key issue of the review that names a file and lines", function()
    write("review", review_record())
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)

    local found = agent_marks(state.buf)
    assert.are.equal(1, #found)
    assert.are.equal("pr-agent · Possible Bug · L2 · read-only", box_lines(state.buf)[1][2][1])
    require("codeview.view").close()
  end)

  it("finds the existing code of an outdated suggestion in the current file", function()
    write("improve", improve_record({ relevant_lines_start = 9, relevant_lines_end = 9 }, "3a1f2c0e9b"))
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)

    local found = agent_marks(state.buf)
    assert.are.equal(1, #found)
    assert.are.equal(3, found[1][2])
    assert.are.equal("CodeViewRemoteOutdated", found[1][4].sign_hl_group)
    assert.is_truthy(box_lines(state.buf)[1][2][1]:find("outdated", 1, true))
    require("codeview.view").close()
  end)

  it("leaves out an outdated suggestion whose code the file does not hold", function()
    write("improve", improve_record({ existing_code = "local z = 0" }, "3a1f2c0e9b"))
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)
    assert.are.equal(0, #agent_marks(state.buf))
    assert.are.equal(1, #agent.items(review))
    require("codeview.view").close()
  end)

  it("shows a suggestion in the float and keeps it read-only", function()
    write("improve", improve_record())
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)
    vim.api.nvim_win_set_cursor(state.win, { 4, 0 })

    local comments_mod = require("codeview.comments")
    local buf = assert(comments_mod.show())
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("pr-agent · possible issue", 1, true), text)
    assert.is_truthy(text:find("Use the next number.", 1, true), text)

    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    local edited = comments_mod.edit()
    vim.notify = notify
    assert.is_false(edited)
    assert.is_truthy(seen[1]:find("pr-agent suggestions are read-only", 1, true), seen[1])
    require("codeview.view").close()
  end)

  it("lists the items in the overview, after the comments of GitHub", function()
    write("improve", improve_record())
    write("review", review_record())
    local review = open_session()
    local overview = require("codeview.overview")
    local bar = assert(overview.open({ session = review }))
    require("codeview.remote").attach(review, {
      {
        id = 501,
        file = "call.lua",
        start_line = 2,
        end_line = 2,
        side = "new",
        author = "grace",
        body = "a remote note",
        outdated = false,
      },
    })
    agent.attach(review)

    local text = table.concat(bar.panel:lines(), "\n")
    local remote_at = text:find("1 remote comment", 1, true)
    local agent_at = text:find("2 agent suggestions", 1, true)
    assert.is_truthy(remote_at and agent_at and remote_at < agent_at, text)
    assert.is_truthy(text:find("possible issue", 1, true), text)

    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote" and item.source == "agent"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))
    local item = assert(bar:cursor_remote())
    assert.are.equal("call.lua", item.file)

    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    assert.is_false(bar:edit())
    vim.notify = notify
    assert.is_truthy(seen[1]:find("pr-agent suggestions are read-only", 1, true), seen[1])
    overview.close()
  end)

  it("adopts the suggestion of the line as a local comment with a suggestion block", function()
    write("improve", improve_record())
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)
    vim.api.nvim_win_set_cursor(state.win, { 4, 0 })

    local comment = assert(agent.adopt())
    assert.are.equal("call.lua", comment.file)
    assert.are.equal(2, comment.start_line)
    assert.are.equal(2, comment.end_line)
    assert.are.equal("new", comment.side)
    assert.are.equal("Use the next number.\n\n```suggestion\nlocal b = 23\n```", comment.body)
    local store = assert(require("codeview.comments").store(review))
    assert.are.equal(1, #store.comments)

    local editor = require("codeview.editor")
    assert.is_truthy(editor.current(), "the editor holds the new comment")
    editor.cancel()

    assert.is_true(agent.items(review)[1].adopted)
    local header = box_lines(state.buf)[1][2][1]
    assert.is_truthy(header:find("· adopted", 1, true), header)
    require("codeview.view").close()
  end)

  it("adopts a key issue with the text of the issue", function()
    write("review", review_record())
    local review = open_session()
    agent.attach(review)
    local comment = assert(agent.adopt({ item = agent.items(review)[1], session = review }))
    assert.are.equal("The value changed.", comment.body)
    require("codeview.editor").cancel()
  end)

  it("adopts from the key of the diff and from the overview", function()
    write("improve", improve_record())
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)
    vim.api.nvim_win_set_cursor(state.win, { 4, 0 })
    local lhs = vim.api.nvim_replace_termcodes(
      (config.get().keymaps.adopt:gsub("<leader>", vim.g.mapleader or "\\")),
      true,
      false,
      true
    )
    vim.api.nvim_feedkeys(lhs, "x", false)
    local store = assert(require("codeview.comments").store(review))
    assert.are.equal(1, #store.comments)
    require("codeview.editor").cancel()
    require("codeview.view").close()

    local overview = require("codeview.overview")
    local bar = assert(overview.open({ session = review }))
    local lnum = assert(bar.panel:find(function(item)
      return item.kind == "remote" and item.source == "agent"
    end))
    assert.is_true(bar.panel:set_cursor(lnum))
    assert(bar:adopt())
    assert.are.equal(2, #store.comments)
    require("codeview.editor").cancel()
    local text = table.concat(bar.panel:lines(), "\n")
    assert.is_truthy(text:find("possible issue adopted", 1, true), text)
    overview.close()
  end)

  it("adopts nothing on a line without a pr-agent item", function()
    local review = open_session()
    agent.attach(review)
    local state = open_diff(review)
    vim.api.nvim_win_set_cursor(state.win, { 2, 0 })
    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      seen[#seen + 1] = msg
    end
    assert.is_nil(agent.adopt())
    vim.notify = notify
    assert.is_truthy(seen[1]:find("no pr-agent item on this line", 1, true), seen[1])
    require("codeview.view").close()
  end)

  describe("without results", function()
    ---@type string
    local root
    ---@type string
    local adopt_key

    before_each(function()
      -- The root of the results is a directory that does not exist.
      root = vim.fs.joinpath(dir, "agent")
      assert(config.setup({ github = { agent_dir = root }, comments = { dir = vim.fs.joinpath(dir, "comments") } }))
      adopt_key = config.get().keymaps.adopt
    end)

    after_each(function()
      require("codeview.hints").close()
      require("codeview.overview").close()
      require("codeview.sidebar").close()
      require("codeview.view").close()
    end)

    ---Write one result file of the pull request ada/demo#12 under the root.
    ---@param tool string
    ---@param record table
    local function write_result(tool, record)
      local path = vim.fs.joinpath(root, "ada", "demo", "12", tool .. ".json")
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ vim.json.encode(record) }, path)
    end

    ---Map of the adopt key in one buffer, from |maparg()|.
    ---@param buf integer
    ---@return table map Empty without a map.
    local function adopt_map(buf)
      return vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(adopt_key, "n", false, true)
      end)
    end

    ---Every surface of a review: the sidebar, the diff, the overview, and
    ---the hint row, with the cursor in the diff.
    ---@param review codeview.Session
    ---@return { bar: table, state: codeview.view.State, overview: codeview.Overview }
    local function open_surfaces(review)
      local bar = assert(require("codeview.sidebar").open({ session = review }))
      local state = open_diff(review)
      local overview = assert(require("codeview.overview").open({ session = review }))
      assert.is_true(require("codeview.hints").open({ session = review }))
      vim.api.nvim_set_current_win(state.win)
      require("codeview.hints").refresh()
      return { bar = bar, state = state, overview = overview }
    end

    ---Text of the hint row.
    ---@return string
    local function hint_text()
      require("codeview.hints").refresh()
      return assert(require("codeview.hints").text())
    end

    it("creates nothing, sends nothing, and maps nothing", function()
      local seen, autocmds, messages = 0, 0, {}
      events.on(events.agent, function()
        seen = seen + 1
      end)
      vim.api.nvim_create_autocmd("User", {
        pattern = "CodeViewAgentLoaded",
        callback = function()
          autocmds = autocmds + 1
        end,
      })
      local notify = vim.notify
      vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
        messages[#messages + 1] = msg
      end

      local review = open_session()
      local surfaces = open_surfaces(review)
      local files = vim.deepcopy(review.files)
      local sidebar_lines = surfaces.bar.panel:lines()
      local renders = 0
      local render = surfaces.bar.render
      surfaces.bar.render = function(self)
        renders = renders + 1
        return render(self)
      end

      local results = assert(agent.attach(review))
      agent.load(review)
      assert.are.equal(0, renders, "a load without results draws the sidebar again")
      -- The sidebar draws itself again on a refresh. The read of the
      -- refresh must still create nothing.
      vim.api.nvim_exec_autocmds("User", { pattern = "CodeViewSessionRefreshed", data = { id = review.id } })
      vim.notify = notify

      -- No directory under the root, and no watcher.
      assert.are.equal(0, vim.fn.isdirectory(root))
      local watched, timer = agent.watched(review)
      assert.is_nil(watched)
      assert.is_false(timer)
      -- No event, no notification.
      assert.are.equal(0, seen)
      assert.are.equal(0, autocmds)
      assert.are.same({}, messages)
      assert.is_false(agent.holds_records(results))
      -- The file list and the sidebar are the same as without the module.
      assert.are.same(files, review.files)
      assert.are.same(sidebar_lines, surfaces.bar.panel:lines())
      assert.is_nil(table.concat(surfaces.bar.panel:lines(), "\n"):find("Agent", 1, true))
      -- No adopt key, and no hint of it.
      assert.is_false(agent.has_items(review))
      assert.are.same({}, adopt_map(surfaces.state.buf))
      assert.are.same({}, adopt_map(assert(surfaces.overview.panel:buffer())))
      assert.is_nil(hint_text():find("adopt", 1, true))
      -- No section, no sign, and no box.
      assert.is_nil(table.concat(surfaces.overview.panel:lines(), "\n"):find("agent suggestion", 1, true))
      assert.are.equal(0, #agent_marks(surfaces.state.buf))
    end)

    it("keeps a map of the user on the adopt key", function()
      local review = open_session()
      local state = open_diff(review)
      local used = false
      vim.keymap.set("n", adopt_key, function()
        used = true
      end, { buffer = state.buf, desc = "code action" })
      require("codeview.comments").set_adopt_keymap(review, state.buf)
      assert.are.equal("code action", adopt_map(state.buf).desc)
      vim.api.nvim_buf_call(state.buf, function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(adopt_key, true, false, true), "x", false)
      end)
      assert.is_true(used)
    end)

    ---Report whether the review shows the results: the adopt key, the hint,
    ---the group of the sidebar, and the signs of the diff.
    ---@param review codeview.Session
    ---@param surfaces { bar: table, state: codeview.view.State, overview: codeview.Overview }
    local function assert_shown(review, surfaces)
      assert.is_true(agent.has_items(review))
      assert.are.equal("codeview: adopt the pr-agent item of the line as a comment", adopt_map(surfaces.state.buf).desc)
      assert.is_truthy(adopt_map(assert(surfaces.overview.panel:buffer())).desc)
      assert.is_truthy(hint_text():find("adopt", 1, true))
      local message = require("codeview.message")
      assert.is_truthy(review:index_of(message.agent_path("review")))
      assert.is_truthy(table.concat(surfaces.bar.panel:lines(), "\n"):find("Agent", 1, true))
      local found = agent_marks(surfaces.state.buf)
      assert.are.equal(1, #found)
      assert.are.equal("✦", vim.trim(found[1][4].sign_text))
      assert.is_truthy(table.concat(surfaces.overview.panel:lines(), "\n"):find("1 agent suggestion", 1, true))
    end

    it("follows the first run of chaoshub down from the root", function()
      vim.fn.mkdir(root, "p")
      local seen = 0
      events.on(events.agent, function()
        seen = seen + 1
      end)
      local review = open_session()
      local surfaces = open_surfaces(review)
      agent.attach(review)
      assert.are.equal(root, (agent.watched(review)))
      assert.are.equal(0, seen)

      -- The watcher moves down as each part of the path comes to exist.
      vim.fn.mkdir(vim.fs.joinpath(root, "ada"))
      assert.is_true(
        vim.wait(5000, function()
          return agent.watched(review) == vim.fs.joinpath(root, "ada")
        end, 20),
        "the watcher did not move to the owner"
      )
      assert.are.equal(0, seen)

      write_result("review", review_record())
      assert.is_true(
        vim.wait(5000, function()
          return agent.has_items(review)
        end, 20),
        "the watcher did not read the new file"
      )
      assert.are.equal(vim.fs.joinpath(root, "ada", "demo", "12"), (agent.watched(review)))
      assert.are.equal(1, seen)
      assert_shown(review, surfaces)

      -- A read without a change sends no event.
      agent.load(review)
      assert.are.equal(1, seen)
    end)

    it("shows the results after a refresh when the root came to exist", function()
      local review = open_session()
      local surfaces = open_surfaces(review)
      agent.attach(review)
      assert.is_nil(agent.watched(review))

      write_result("review", review_record())
      vim.api.nvim_exec_autocmds("User", { pattern = "CodeViewSessionRefreshed", data = { id = review.id } })
      assert.are.equal(vim.fs.joinpath(root, "ada", "demo", "12"), (agent.watched(review)))
      assert_shown(review, surfaces)
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
