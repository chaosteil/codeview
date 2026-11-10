-- Syntax highlights inside a diff.
--
-- The diff buffer holds two revisions with a marker column, so treesitter
-- cannot attach to it. The module parses each side as a whole file and copies
-- the captures into the buffer. The tests read the extmarks of its namespace.

local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

describe("codeview.syntax", function()
  local fixture = fixtures.git_comments()
  local config, highlight, inline, session_mod, syntax, view
  ---@type codeview.Session?
  local opened

  ---Open a session on the fixture range.
  ---@return codeview.Session
  local function open_session()
    local review, err = session_mod.open(fixture.ids.base .. ".." .. fixture.ids.change, { dir = fixture.dir })
    assert.is_nil(err)
    opened = assert(review)
    return review
  end

  ---Open the diff of the Lua file of the fixture.
  ---@param session codeview.Session
  ---@return codeview.view.State
  local function open_lua(session)
    local index = assert(session:index_of("call.lua"), "no call.lua in the fixture")
    return assert(view.open(session, index))
  end

  ---Marks of the syntax namespace of a buffer.
  ---@param buf integer
  ---@return table[]
  local function marks_of(buf)
    return api.nvim_buf_get_extmarks(buf, syntax.ns, 0, -1, { details = true })
  end

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
    assert(config.setup({ commit_message = false }))
    highlight = require("codeview.highlight")
    inline = require("codeview.inline")
    session_mod = require("codeview.session")
    syntax = require("codeview.syntax")
    view = require("codeview.view")
  end)

  after_each(function()
    view.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    config.reset()
    helpers.unload()
  end)

  describe("the language", function()
    it("reads the language of a path", function()
      assert.are.equal("lua", syntax.language("lua/codeview/init.lua"))
    end)

    it("answers nothing for a path without a parser", function()
      assert.is_nil(syntax.language("notes.unknown-extension"))
      assert.is_nil(syntax.language(""))
    end)

    it("answers nothing for a filetype without an installed parser", function()
      -- Neovim knows the filetype, but ships no parser for it.
      assert.are.equal("cobol", vim.filetype.match({ filename = "report.cob" }))
      assert.is_nil(syntax.language("report.cob"))
    end)
  end)

  describe("the guards", function()
    ---Text of a Lua file, one assignment per line.
    ---@param count integer Number of lines.
    ---@return string
    local function lua_text(count)
      local lines = {}
      for index = 1, count do
        lines[index] = string.format("local value_%d = %d", index, index)
      end
      return table.concat(lines, "\n") .. "\n"
    end

    ---Render a Lua diff into a scratch buffer.
    ---@param old_text string
    ---@param new_text string
    ---@return integer buf
    ---@return codeview.inline.Build build
    local function render_lua(old_text, new_text)
      local file = require("codeview.diff").compute(old_text, new_text)
      file.path, file.old_path = "code.lua", "code.lua"
      local buf = api.nvim_create_buf(false, true)
      return buf, inline.render(buf, file)
    end

    ---@type table<string, any>
    local saved = {}

    before_each(function()
      saved = { get = vim.treesitter.query.get }
    end)

    after_each(function()
      vim.treesitter.query.get = saved.get
    end)

    it("renders the diff when the highlights query fails", function()
      vim.treesitter.query.get = function()
        error("invalid query")
      end
      local buf, build = render_lua(lua_text(3), lua_text(4))
      assert.is_true(#build.lines > 0)
      assert.are.equal(0, #marks_of(buf))
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("renders the diff when the captures fail", function()
      vim.treesitter.query.get = function()
        return {
          captures = {},
          iter_captures = function()
            error("invalid capture")
          end,
        }
      end
      local buf, build = render_lua(lua_text(3), lua_text(4))
      assert.is_true(#build.lines > 0)
      assert.are.equal(0, #marks_of(buf))
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("skips a side above the byte limit", function()
      local buf = render_lua(lua_text(3), lua_text(4))
      assert.is_true(#marks_of(buf) > 0, "a small side gets highlights")
      api.nvim_buf_delete(buf, { force = true })

      syntax.max_bytes = 20
      buf = render_lua(lua_text(3), lua_text(4))
      assert.are.equal(0, #marks_of(buf))
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("skips a line above the line limit", function()
      syntax.max_line_bytes = 40
      local long = "local long = " .. string.rep("1", 60)
      local buf, build = render_lua("local a = 1\n", "local a = 1\n" .. long .. "\nlocal b = 2\n")
      local rows = {}
      for _, mark in ipairs(marks_of(buf)) do
        rows[mark[2] + 1] = true
      end
      for lnum, text in ipairs(build.lines) do
        if #text > 40 then
          assert.is_nil(rows[lnum], "a mark on the long line " .. lnum)
        elseif text:find("local b", 1, true) then
          assert.is_true(rows[lnum], "no mark on the line after the long line")
        end
      end
      api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("the highlights", function()
    it("writes the captures of the code into the diff", function()
      local session = open_session()
      local state = open_lua(session)
      local marks = marks_of(state.buf)
      assert.is_true(#marks > 0, "no syntax marks in the diff")

      ---@type table<string, boolean>
      local groups = {}
      for _, mark in ipairs(marks) do
        groups[mark[4].hl_group] = true
      end
      -- The file of the fixture holds a call, so the query captures one.
      assert.is_true(groups["@function.call"] or groups["@variable"] or groups["@keyword"], vim.inspect(groups))
    end)

    it("shifts every capture by the marker column", function()
      local session = open_session()
      local state = open_lua(session)
      for _, mark in ipairs(marks_of(state.buf)) do
        -- No capture sits on the marker itself.
        assert.is_true(mark[3] >= #inline.markers.context, "a mark covers the marker column")
      end
    end)

    it("keeps the text of the diff", function()
      local session = open_session()
      local state = open_lua(session)
      local before = api.nvim_buf_get_lines(state.buf, 0, -1, false)
      syntax.apply(state.buf, state.diff, state.map, { offset = 1 })
      assert.are.same(before, api.nvim_buf_get_lines(state.buf, 0, -1, false))
      assert.is_false(vim.bo[state.buf].modifiable)
    end)

    it("writes nothing when the option is off", function()
      assert(config.setup({ commit_message = false, diff = { syntax = false } }))
      local session = open_session()
      local state = open_lua(session)
      assert.are.equal(0, #marks_of(state.buf))
    end)
  end)

  describe("the documents", function()
    local message

    ---Markdown text of the documents.
    ---@type string[]
    local markdown = {
      "## Why",
      "",
      "Some **bold** text and the `thing`.",
      "",
      "- one",
      "- two",
      "",
      "```lua",
      "local a = 1",
      "```",
    }

    ---Commit with a markdown body.
    ---@type codeview.vcs.Commit
    local commit = {
      id = "0123456789abcdef0123456789abcdef01234567",
      short_id = "01234567",
      parents = { "fedcba9876543210fedcba9876543210fedcba98" },
      author = "Ada",
      author_email = "ada@example.com",
      date = "2026-11-10",
      subject = "feat(x): add the `thing`",
      body = table.concat(markdown, "\n"),
    }

    ---Document of the commit, with one changed file.
    ---@return codeview.diff.File
    local function commit_document()
      local session = {
        commits = { commit },
        repo = {
          changed_files = function()
            return { { path = "lua/thing.lua", status = "modified" } }
          end,
        },
      }
      ---@diagnostic disable-next-line: missing-fields
      return assert(message.for_commit(session, { path = message.path_of(commit.id), commit = commit }))
    end

    ---Document of a pull request.
    ---@param body string Description of the pull request.
    ---@return codeview.diff.File
    local function pr_document(body)
      local session = {
        pr = {
          number = 7,
          title = "Add the thing",
          author = "ada",
          head_ref = "thing",
          base_ref = "main",
          state = "OPEN",
          url = "https://github.com/o/r/pull/7",
          body = body,
          head_sha = commit.id,
        },
        commits = { commit },
      }
      ---@diagnostic disable-next-line: missing-fields
      return assert(message.for_pr(session, { path = message.pr_path(7) }))
    end

    ---Document like the one of a pr-agent result: a plain header, then the
    ---markdown text with an indent of four spaces.
    ---@return codeview.diff.File
    local function agent_document()
      local lines = { "pr-agent describe of #7", "Title: Add the thing", "" }
      local first = #lines + 1
      for _, line in ipairs(markdown) do
        lines[#lines + 1] = line == "" and "" or ("    " .. line)
      end
      ---@type codeview.diff.File
      return {
        path = "codeview://agent/describe",
        old_path = "codeview://agent/describe",
        status = "message",
        old_lines = {},
        new_lines = lines,
        hunks = {},
        binary = false,
        limited = false,
        line_count = #lines,
        max_lines = 0,
        context = 0,
        message = true,
        markdown = { { first = first, last = #lines, indent = 4 } },
        files = {},
      }
    end

    ---Groups of the marks of a buffer, by row from 1.
    ---@param buf integer
    ---@return table<integer, table<string, string>> groups Text under each group, by row.
    local function groups_by_row(buf)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      local out = {}
      for _, mark in ipairs(marks_of(buf)) do
        local row = mark[2] + 1
        out[row] = out[row] or {}
        out[row][mark[4].hl_group] = lines[row]:sub(mark[3] + 1, mark[4].end_col)
      end
      return out
    end

    ---Row of the first buffer line that holds a text.
    ---@param buf integer
    ---@param text string
    ---@return integer row From 1.
    local function row_of(buf, text)
      for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(text, 1, true) then
          return row
        end
      end
      error("no line with " .. text)
    end

    before_each(function()
      message = require("codeview.message")
    end)

    it("writes the message of a commit as markdown, without an indent", function()
      local document = commit_document()
      assert.is_nil(document.markdown)
      assert.are.equal("markdown", document.filetype)
      assert.are.equal(commit.subject, document.new_lines[5])
      assert.are.same(markdown, vim.list_slice(document.new_lines, 7, 6 + #markdown))
      -- The file list stays an indented block.
      assert.are.equal("    M  lua/thing.lua", document.new_lines[#document.new_lines])
    end)

    it("writes the description of a pull request as markdown, without an indent", function()
      local document = pr_document("## Summary\r\n\r\nSome `code`.")
      assert.is_nil(document.markdown)
      assert.are.equal("markdown", document.filetype)
      local lines = document.new_lines
      assert.is_true(vim.tbl_contains(lines, "## Summary"))
      assert.is_true(vim.tbl_contains(lines, "Some `code`."))
      assert.is_true(vim.tbl_contains(lines, "    " .. message.label(commit)))
    end)

    it("writes the note of a missing description without an indent", function()
      local document = pr_document("")
      assert.is_true(vim.tbl_contains(document.new_lines, "The pull request has no description."))
    end)

    it("copies no colors into a commit document or a pull request document", function()
      for _, document in ipairs({ commit_document(), pr_document("## Summary") }) do
        local buf = api.nvim_create_buf(false, true)
        inline.render(buf, document)
        assert.are.equal(0, #marks_of(buf))
        api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("leaves the colors of an open commit document to the markdown filetype", function()
      assert(config.setup({}))
      local session = open_session()
      local index = assert(session:index_of(message.path_of(session.commits[1].id)))
      local state = assert(view.open(session, index))
      assert.are.equal("markdown", vim.bo[state.buf].filetype)
      assert.is_not_nil(vim.treesitter.highlighter.active[state.buf])
      assert.are.equal(0, #marks_of(state.buf))
    end)

    it("writes the colors of markdown into a pr-agent text", function()
      local buf = api.nvim_create_buf(false, true)
      inline.render(buf, agent_document())
      local groups = groups_by_row(buf)

      assert.are.equal("## Why", groups[row_of(buf, "## Why")]["@markup.heading.2"])
      assert.are.equal("- ", groups[row_of(buf, "- one")]["@markup.list"])
      -- The inline text and the fenced code are languages that markdown
      -- injects.
      assert.are.equal("**bold**", groups[row_of(buf, "**bold**")]["@markup.strong"])
      assert.are.equal("`thing`", groups[row_of(buf, "**bold**")]["@markup.raw"])
      assert.are.equal("local", groups[row_of(buf, "local a")]["@keyword"])
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("parses a pr-agent text without its indent", function()
      local buf = api.nvim_create_buf(false, true)
      inline.render(buf, agent_document())
      -- With the indent, markdown reads every line as an indented code block.
      local groups = groups_by_row(buf)
      assert.is_nil((groups[row_of(buf, "**bold**")] or {})["@markup.raw.block"])
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("keeps the header of a pr-agent document plain", function()
      local document = agent_document()
      local buf = api.nvim_create_buf(false, true)
      inline.render(buf, document)
      local groups = groups_by_row(buf)
      for row = 1, document.markdown[1].first - 1 do
        assert.is_nil(groups[row], "a mark on the header row " .. row)
      end
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("puts the same colors on the same columns in both styles", function()
      local document = agent_document()
      local buf = api.nvim_create_buf(false, true)
      local old_buf = api.nvim_create_buf(false, true)
      local new_buf = api.nvim_create_buf(false, true)
      inline.render(buf, document)
      require("codeview.split").render(old_buf, new_buf, document)

      ---Marks of a buffer without their ids.
      ---@param target integer
      ---@return table[]
      local function spans(target)
        local out = {}
        for _, mark in ipairs(marks_of(target)) do
          out[#out + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
        end
        table.sort(out, function(a, b)
          return table.concat(a, ":") < table.concat(b, ":")
        end)
        return out
      end
      local expected = spans(buf)
      assert.is_true(#expected > 0)
      assert.are.same(expected, spans(new_buf))
      assert.are.same(expected, spans(old_buf))
      for _, target in ipairs({ buf, old_buf, new_buf }) do
        api.nvim_buf_delete(target, { force = true })
      end
    end)

    it("writes nothing when the option is off", function()
      assert(config.setup({ diff = { syntax = false } }))
      local buf = api.nvim_create_buf(false, true)
      inline.render(buf, agent_document())
      assert.are.equal(0, #marks_of(buf))
      api.nvim_buf_delete(buf, { force = true })
    end)

    it("renders a pr-agent text plain without a markdown parser", function()
      local add = vim.treesitter.language.add
      vim.treesitter.language.add = function(lang, ...)
        if lang == "markdown" then
          return nil, "no parser for markdown"
        end
        return add(lang, ...)
      end
      local document = agent_document()
      local buf = api.nvim_create_buf(false, true)
      local ok, build = pcall(inline.render, buf, document)
      vim.treesitter.language.add = add

      assert.is_true(ok, tostring(build))
      assert.are.same(document.new_lines, api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.equal(0, #marks_of(buf))
      api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("the cache", function()
    ---Diff of a small Lua file.
    ---@return codeview.diff.File
    local function lua_diff()
      local file = require("codeview.diff").compute("local a = 1\n", "local a = 2\nlocal b = 3\n")
      file.path, file.old_path = "code.lua", "code.lua"
      return file
    end

    it("parses each side of a diff once over many renders", function()
      local parse = vim.treesitter.get_string_parser
      local calls = 0
      vim.treesitter.get_string_parser = function(...)
        calls = calls + 1
        return parse(...)
      end

      local file = lua_diff()
      local buf = api.nvim_create_buf(false, true)
      local old_buf = api.nvim_create_buf(false, true)
      inline.render(buf, file)
      inline.render(buf, file, { expanded = { [1] = true } })
      require("codeview.split").render(old_buf, buf, file)
      vim.treesitter.get_string_parser = parse

      assert.are.equal(2, calls)
      assert.is_true(#marks_of(buf) > 0)
      api.nvim_buf_delete(buf, { force = true })
      api.nvim_buf_delete(old_buf, { force = true })
    end)

    it("drops the captures when the diff goes", function()
      collectgarbage("collect")
      local before = syntax.cached()
      local buf = api.nvim_create_buf(false, true)
      inline.render(buf, lua_diff())
      assert.are.equal(before + 1, syntax.cached())

      -- The state of the buffer holds the diff until the buffer goes.
      api.nvim_buf_delete(buf, { force = true })
      collectgarbage("collect")
      collectgarbage("collect")
      assert.are.equal(before, syntax.cached())
    end)
  end)

  describe("the row colors", function()
    it("keeps the background of the diff and drops the foreground", function()
      vim.cmd("highlight DiffAdd guibg=#123456 guifg=#abcdef")
      vim.cmd("highlight DiffDelete guibg=#654321 guifg=#fedcba")
      highlight.apply()

      for group in pairs(highlight.diff_rows) do
        local hl = api.nvim_get_hl(0, { name = group, link = false })
        assert.is_nil(hl.fg, group .. " keeps a foreground")
        assert.is_truthy(hl.bg, group .. " has no background")
      end
    end)

    it("keeps the link when the option is off", function()
      assert(config.setup({ diff = { syntax = false } }))
      highlight.apply()
      for group, target in pairs(highlight.diff_rows) do
        local hl = api.nvim_get_hl(0, { name = group })
        assert.are.equal(target, hl.link)
      end
    end)
  end)

  describe("the word colors", function()
    it("mixes the diff color into the row background", function()
      vim.cmd("highlight DiffAdd guibg=#000000")
      vim.cmd("highlight DiffDelete guibg=#000000")
      vim.cmd("highlight Added guifg=#ff0000")
      vim.cmd("highlight Removed guifg=#0000ff")
      highlight.apply()

      -- A quarter of 255 is 63.75, which rounds to 64, or 0x40.
      local add = api.nvim_get_hl(0, { name = "CodeViewDiffTextAdd", link = false })
      assert.are.equal(0x400000, add.bg)
      assert.is_nil(add.fg)
      local removed = api.nvim_get_hl(0, { name = "CodeViewDiffTextDelete", link = false })
      assert.are.equal(0x000040, removed.bg)
      assert.is_nil(removed.fg)
    end)

    it("links to the shared group when a color is missing", function()
      vim.cmd("highlight Added guifg=NONE")
      vim.cmd("highlight Removed guifg=NONE")
      highlight.apply()
      for group in pairs(highlight.diff_words) do
        local hl = api.nvim_get_hl(0, { name = group })
        assert.are.equal("CodeViewDiffText", hl.link)
      end
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
