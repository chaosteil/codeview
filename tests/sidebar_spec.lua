local fixtures = require("tests.fixtures")
local helpers = require("tests.helpers")

local api = vim.api

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

---Wait until a check answers true.
---@param check fun(): boolean
---@param message string
local function wait_for(check, message)
  assert.is_true(vim.wait(20000, check, 10), message)
end

---Press a key in the current window.
---@param lhs string
local function press(lhs)
  api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
end

---Report whether an autocmd group exists.
---@param name string
---@return boolean
local function group_exists(name)
  return (pcall(api.nvim_get_autocmds, { group = name }))
end

describe("codeview.sidebar", function()
  -- Lines above the tree: the range, the counts, a blank line, the Comments
  -- line, and a blank line. The first node of the tree follows them.
  local HEAD = 5

  local fixture = fixtures.git()
  local sidebar, session_mod, view, panel, config
  ---@type codeview.Session?
  local opened

  ---Open a session for the whole fixture history.
  ---@param spec? string
  ---@return codeview.Session
  local function open_session(spec)
    local review, err = session_mod.open(spec or (fixture.ids.init .. ".." .. fixture.ids.shuffle), {
      dir = fixture.dir,
    })
    assert.is_nil(err)
    opened = assert(review)
    return opened
  end

  ---Open a session and its sidebar.
  ---@param opts? table
  ---@return codeview.Sidebar
  ---@return codeview.Session
  local function open_sidebar(opts)
    local review = opened or open_session()
    local bar, err = sidebar.open(opts)
    assert.is_nil(err)
    return assert(bar), review
  end

  ---Line of one node in the sidebar.
  ---@param bar codeview.Sidebar
  ---@param path string
  ---@return integer lnum
  local function line_of(bar, path)
    local lnum = bar.panel:find(function(node)
      return node.path == path
    end)
    assert.is_truthy(lnum, "no line for " .. path)
    return lnum
  end

  ---Text of one line.
  ---@param bar codeview.Sidebar
  ---@param lnum integer
  ---@return string
  local function text_of(bar, lnum)
    return bar.panel:lines()[lnum]
  end

  ---Extmark details of one line.
  ---@param bar codeview.Sidebar
  ---@param lnum integer
  ---@return table[]
  local function marks_of(bar, lnum)
    local buf = assert(bar.panel:buffer())
    return api.nvim_buf_get_extmarks(buf, panel.ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
  end

  ---Highlight group at one column of one line.
  ---@param bar codeview.Sidebar
  ---@param lnum integer
  ---@param col integer Column, in bytes, from 0.
  ---@return string? group
  local function hl_at(bar, lnum, col)
    for _, mark in ipairs(marks_of(bar, lnum)) do
      local details = mark[4]
      if details.hl_group and mark[3] <= col and (details.end_col or 0) > col then
        return details.hl_group
      end
    end
    return nil
  end

  ---Text of one line and the marks at its right edge.
  ---
  --- A "|" divides the text from the marks. The marks keep their blanks, so
  --- the result shows the columns of the marks.
  ---@param bar codeview.Sidebar
  ---@param lnum integer
  ---@return string
  local function shown(bar, lnum)
    local right = ""
    for _, mark in ipairs(marks_of(bar, lnum)) do
      local details = mark[4]
      if details.virt_text_pos == "right_align" then
        for _, chunk in ipairs(details.virt_text) do
          right = right .. chunk[1]
        end
      end
    end
    return text_of(bar, lnum) .. "|" .. right
  end

  ---Rows of the tree, from the first node.
  ---@param bar codeview.Sidebar
  ---@return string[]
  local function rows(bar)
    local out = {}
    for lnum = HEAD + 1, bar.panel:line_count() do
      out[#out + 1] = shown(bar, lnum)
    end
    return out
  end

  ---Highlight group of a mark at the right edge.
  ---@param bar codeview.Sidebar
  ---@param lnum integer
  ---@param needle string Text of one part of the marks.
  ---@return string? group
  local function right_hl(bar, lnum, needle)
    for _, mark in ipairs(marks_of(bar, lnum)) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1] == needle then
          return chunk[2]
        end
      end
    end
    return nil
  end

  ---Highlight group of a part of a line.
  ---@param bar codeview.Sidebar
  ---@param lnum integer
  ---@param needle string Text inside the line.
  ---@return string? group
  local function hl_of(bar, lnum, needle)
    local from = text_of(bar, lnum):find(needle, 1, true)
    assert.is_truthy(from, needle .. " is not in line " .. lnum)
    return hl_at(bar, lnum, from - 1)
  end

  before_each(function()
    helpers.unload()
    -- The specs run in a `-c` command of Neovim, which looks like a start
    -- from the command line. A quit there ends the test run.
    require("codeview.config").setup({ commit_message = false, quit = "never" })
    config = require("codeview.config")
    panel = require("codeview.panel")
    session_mod = require("codeview.session")
    sidebar = require("codeview.sidebar")
    view = require("codeview.view")
  end)

  after_each(function()
    sidebar.close()
    if opened then
      opened:close()
    end
    opened = nil
    session_mod.close()
    helpers.unload()
  end)

  describe("open", function()
    it("needs a session", function()
      local bar, err = sidebar.open()
      assert.is_nil(bar)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("opens a panel window for the session that runs", function()
      local review = open_session()
      local bar = assert(sidebar.open())
      assert.are.equal(review, bar.session)
      assert.is_true(bar:is_open())
      assert.is_true(panel.is_panel_win(assert(bar.panel:window())))
      assert.are.equal(bar, sidebar.get())
      assert.is_true(sidebar.is_open())
    end)

    it("takes the width and the side from the configuration", function()
      config.setup({ commit_message = false, sidebar = { width = 25, position = "right" } })
      local bar = open_sidebar()
      local win = assert(bar.panel:window())
      assert.are.equal(25, api.nvim_win_get_width(win))
      assert.is_true(api.nvim_win_get_position(win)[2] > 0)
    end)

    it("returns the same sidebar for the same session", function()
      local bar = open_sidebar()
      assert.are.equal(bar, assert(sidebar.open()))
    end)

    it("keeps the cursor outside the sidebar by default", function()
      local before = api.nvim_get_current_win()
      local bar = open_sidebar()
      assert.are.equal(before, api.nvim_get_current_win())

      sidebar.open({ focus = true })
      assert.are.equal(bar.panel:window(), api.nvim_get_current_win())
      api.nvim_set_current_win(before)
    end)

    it("lets the session own the window and the buffer", function()
      local bar = open_sidebar()
      local win = assert(bar.panel:window())
      local buf = assert(bar.panel:buffer())
      assert.are.equal("codeview-files", vim.bo[buf].filetype)

      assert(opened):close()
      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_false(api.nvim_buf_is_valid(buf))
      assert.is_nil(sidebar.get())
      assert.is_false(group_exists("codeview.panel." .. bar.panel.id))
    end)
  end)

  describe("the header", function()
    it("shows the range and the counts", function()
      local bar, review = open_sidebar()
      local lines = bar.panel:lines()
      assert.are.equal(review:label(), lines[1])
      assert.are.equal("4 files, 2 commits", lines[2])
      assert.are.equal("", lines[3])
    end)

    it("counts one file and one commit in the singular", function()
      open_session(fixture.ids.edit .. ".." .. fixture.ids.shuffle)
      local bar = assert(sidebar.open())
      assert.are.equal("3 files, 1 commit", bar.panel:lines()[2])
    end)

    it("highlights the range and the counts", function()
      local bar = open_sidebar()
      assert.are.equal("CodeViewTitle", marks_of(bar, 1)[1][4].line_hl_group)
      assert.are.equal("CodeViewCount", marks_of(bar, 2)[1][4].line_hl_group)
    end)
  end)

  describe("the tree", function()
    it("renders the directories and the files", function()
      local bar = open_sidebar()
      local lines = bar.panel:lines()
      assert.are.equal(HEAD + 5, #lines)
      -- The sidebar is 20 columns wide, so the old path of the rename gets
      -- cut before its mark.
      assert.are.same({
        "  ▾ dir|",
        "  │   renamed.txt…|R",
        "    a.txt|M",
        "    added.txt|A",
        "    keep.txt|D",
      }, rows(bar))
    end)

    it("keeps the node of the line in the line data", function()
      local bar = open_sidebar()
      local node = bar.panel:data(HEAD + 4)
      assert.are.equal("file", node.kind)
      assert.are.equal(2, node.index)
      assert.are.equal("added.txt", node.path)
      assert.are.equal("dir", bar.panel:data(HEAD + 1).kind)
      assert.is_nil(bar.panel:data(1))
    end)

    it("highlights the status mark of every file", function()
      local bar = open_sidebar()
      for path, group in pairs({
        ["a.txt"] = "CodeViewModified",
        ["added.txt"] = "CodeViewAdded",
        ["dir/renamed.txt"] = "CodeViewRenamed",
        ["keep.txt"] = "CodeViewDeleted",
      }) do
        local lnum = line_of(bar, path)
        local mark = shown(bar, lnum):sub(-1)
        assert.are.equal(group, right_hl(bar, lnum, mark))
      end
    end)

    it("highlights the name of a file with its status", function()
      local bar = open_sidebar()
      assert.are.equal("CodeViewAdded", hl_of(bar, line_of(bar, "added.txt"), "added.txt"))
      assert.are.equal("CodeViewRenamed", hl_of(bar, line_of(bar, "dir/renamed.txt"), "renamed.txt"))
    end)

    it("highlights the directory, the icon, and the old path", function()
      config.setup({ commit_message = false, sidebar = { width = 40 } })
      local bar = open_sidebar()
      local dir = line_of(bar, "dir")
      assert.are.equal("CodeViewDir", hl_of(bar, dir, "▾"))
      assert.are.equal("CodeViewDir", hl_of(bar, dir, "dir"))
      assert.are.equal("CodeViewDir", hl_of(bar, line_of(bar, "dir/renamed.txt"), "←"))
    end)

    it("highlights the indent guides", function()
      local bar = open_sidebar()
      assert.are.equal("CodeViewIndent", hl_of(bar, line_of(bar, "dir/renamed.txt"), "│"))
    end)

    it("defines the highlight groups", function()
      open_sidebar()
      assert.are.equal("Changed", api.nvim_get_hl(0, { name = "CodeViewModified" }).link)
      assert.are.equal("NonText", api.nvim_get_hl(0, { name = "CodeViewIndent" }).link)
    end)

    it("takes the icons from the configuration", function()
      config.setup({
        commit_message = false,
        sidebar = { width = 40, icons = { expanded = "-", file = ".", guide = ":" } },
      })
      local bar = open_sidebar()
      assert.are.equal("  - dir|", shown(bar, line_of(bar, "dir")))
      assert.are.equal("  : . renamed.txt ← nested.txt|R", shown(bar, line_of(bar, "dir/renamed.txt")))
    end)

    it("reports an empty file list", function()
      open_session(fixture.ids.edit)
      local review = assert(opened)
      review.files = {}
      local bar = assert(sidebar.open())
      assert.are.equal("  no changed files", bar.panel:lines()[HEAD + 1])
      assert.is_nil(bar.panel:data(HEAD + 1))
    end)

    it("renders again after a refresh of the session", function()
      local bar = open_sidebar()
      local review = assert(opened)
      review.files = { { path = "only.txt", status = "added" } }
      api.nvim_exec_autocmds("User", { pattern = "CodeViewSessionRefreshed", data = { id = review.id } })
      assert.are.equal("    only.txt|A", shown(bar, HEAD + 1))
    end)
  end)

  describe("the marks at the right edge", function()
    it("puts the marks at the right edge of the window", function()
      local bar = open_sidebar()
      local lnum = line_of(bar, "a.txt")
      local found = vim.tbl_filter(function(mark)
        return mark[4].virt_text ~= nil
      end, marks_of(bar, lnum))
      assert.are.equal(1, #found)
      assert.are.equal("right_align", found[1][4].virt_text_pos)
      -- The mark is not part of the text, so the line data stays the node.
      assert.are.equal("    a.txt", text_of(bar, lnum))
      assert.are.equal("a.txt", bar.panel:data(lnum).path)
    end)

    it("cuts a long name and keeps the mark", function()
      open_session(fixture.ids.edit)
      local review = assert(opened)
      review.files = { { path = "a-file-with-a-very-long-name.txt", status = "added" } }
      local bar = assert(sidebar.open())
      local lnum = HEAD + 1
      assert.are.equal("    a-file-with-a…|A", shown(bar, lnum))
      -- 20 columns: 18 for the text, 1 blank column, 1 for the mark.
      assert.are.equal(18, vim.fn.strdisplaywidth(text_of(bar, lnum)))
      assert.are.equal("CodeViewAdded", hl_of(bar, lnum, "…"))
    end)

    it("cuts a long commit title, which has no status mark", function()
      config.setup({ quit = "never", comments = { dir = fixtures.tempdir("codeview-mark") } })
      open_session()
      local review = assert(opened)
      local message = require("codeview.message")
      local commit = vim.deepcopy(review.commits[1])
      commit.subject = "Move the files to a new directory and keep the old names"
      review.files = message.entries({ commit })
      local bar = assert(sidebar.open())
      local lnum = line_of(bar, message.path_of(commit.id))
      local text = text_of(bar, lnum)
      -- Without a mark, the title takes the full width.
      assert.are.equal(20, vim.fn.strdisplaywidth(text))
      assert.are.equal("…", vim.fn.strcharpart(text, vim.fn.strchars(text) - 1))
      assert.are.equal("|", shown(bar, lnum):sub(-1))

      assert(require("codeview.comments").create(review, {
        file = commit and message.path_of(commit.id),
        start_line = 1,
        end_line = 1,
        side = "new",
        commit = fixture.ids.shuffle,
        body = "a note",
      }))
      text = text_of(bar, lnum)
      -- 20 columns: 18 for the title, 1 blank column, 1 for the comment mark.
      assert.are.equal(18, vim.fn.strdisplaywidth(text))
      assert.are.equal("|C", shown(bar, lnum):sub(-2))
    end)

    it("keeps the columns of a collapsed directory with several marks", function()
      config.setup({ commit_message = false, quit = "never", comments = { dir = fixtures.tempdir("codeview-mark") } })
      open_session(fixture.ids.edit)
      local review = assert(opened)
      review.files = {
        { path = "lib/one.txt", status = "added" },
        { path = "lib/two.txt", status = "modified" },
        { path = "lib/three.txt", status = "deleted" },
        { path = "root.txt", status = "modified" },
        { path = "zed.txt", status = "renamed", old_path = "old.txt" },
      }
      local bar = assert(sidebar.open())
      assert(require("codeview.comments").create(review, {
        file = "lib/two.txt",
        start_line = 1,
        end_line = 1,
        side = "new",
        commit = fixture.ids.edit,
        body = "a note",
      }))
      bar:collapse_all()
      -- The status column is three columns wide, for the marks of lib. The
      -- comment column follows after one blank column. Blanks fill the
      -- columns that a line does not use.
      assert.are.same({
        "  ▸ lib|AMD C",
        "    root.txt|M    ",
        "    zed.txt ←…|R    ",
      }, rows(bar))
    end)

    it("renders again for a new width", function()
      local bar = open_sidebar()
      local win = assert(bar.panel:window())
      local lnum = line_of(bar, "dir/renamed.txt")
      assert.are.equal("  │   renamed.txt…|R", shown(bar, lnum))

      api.nvim_win_set_width(win, 40)
      -- Neovim runs WinResized from the main loop, which a headless test
      -- does not reach. The test runs the event itself.
      api.nvim_exec_autocmds("WinResized", {})
      assert.are.equal("  │   renamed.txt ← nested.txt|R", shown(bar, lnum))

      api.nvim_win_set_width(win, 12)
      api.nvim_exec_autocmds("WinResized", {})
      assert.are.equal("  │   ren…|R", shown(bar, lnum))
      assert.are.equal("    a.txt|M", shown(bar, line_of(bar, "a.txt")))
    end)

    it("keeps the mark visible in a window that is too narrow", function()
      local bar = open_sidebar()
      api.nvim_win_set_width(assert(bar.panel:window()), 2)
      api.nvim_exec_autocmds("WinResized", {})
      -- The text has no room left, but the mark stays.
      assert.are.equal("|R", shown(bar, line_of(bar, "dir/renamed.txt")))
      assert.are.equal(" …|", shown(bar, line_of(bar, "dir")))
    end)
  end)

  describe("expand and collapse", function()
    ---A session with two files in one directory.
    ---@return codeview.Sidebar
    local function nested()
      open_session(fixture.ids.edit)
      local review = assert(opened)
      review.files = {
        { path = "dir/one.txt", status = "added" },
        { path = "dir/two.txt", status = "deleted" },
        { path = "root.txt", status = "modified" },
      }
      return assert(sidebar.open())
    end

    it("hides the children of a directory", function()
      local bar = nested()
      assert.is_true(bar:toggle_node(bar.tree.children[1]))
      -- The collapsed directory shows two marks, so the status column is two
      -- columns wide.
      assert.are.same({ "  ▸ dir|AD", "    root.txt|M " }, rows(bar))
      assert.is_false(bar.expanded["dir"])
    end)

    it("shows the children again", function()
      local bar = nested()
      bar:toggle_node(bar.tree.children[1])
      bar:toggle_node(bar.tree.children[1])
      assert.are.equal(HEAD + 4, #bar.panel:lines())
      assert.are.equal("  ▾ dir", bar.panel:lines()[HEAD + 1])
    end)

    it("keeps the state over a render", function()
      local bar = nested()
      bar:toggle_node(bar.tree.children[1])
      bar:render()
      assert.are.equal("  ▸ dir|AD", shown(bar, HEAD + 1))
    end)

    it("acts on the directory of a file line", function()
      local bar = nested()
      bar.panel:set_cursor(line_of(bar, "dir/one.txt"))
      assert.is_true(bar:toggle_node())
      assert.are.equal("  ▸ dir|AD", shown(bar, HEAD + 1))
      local win = assert(bar.panel:window())
      assert.are.equal(line_of(bar, "dir"), api.nvim_win_get_cursor(win)[1])
    end)

    it("keeps a file of the top level", function()
      local bar = nested()
      bar.panel:set_cursor(line_of(bar, "root.txt"))
      assert.is_false(bar:toggle_node())
    end)

    it("collapses and expands every directory", function()
      local bar = nested()
      bar:collapse_all()
      assert.are.same({ "  ▸ dir|AD", "    root.txt|M " }, rows(bar))

      bar:expand_all()
      assert.are.equal(HEAD + 4, #bar.panel:lines())
      assert.are.same({}, bar.expanded)
    end)

    it("toggles a directory with <CR> and <Tab>", function()
      local bar = nested()
      bar:focus()
      bar.panel:set_cursor(line_of(bar, "dir"))
      press("<CR>")
      assert.are.equal("  ▸ dir|AD", shown(bar, HEAD + 1))
      press("<Tab>")
      assert.are.equal("  ▾ dir|", shown(bar, HEAD + 1))
      assert.is_nil(view.current())
    end)

    it("collapses and expands with zM and zR", function()
      local bar = nested()
      bar:focus()
      press("zM")
      assert.are.equal("  ▸ dir|AD", shown(bar, HEAD + 1))
      press("zR")
      assert.are.equal("  ▾ dir|", shown(bar, HEAD + 1))
    end)
  end)

  describe("the commits group", function()
    local message

    ---Open a session with the commit documents, as a pull request review or
    ---as a review of a local range.
    ---@param pr boolean True for a pull request review.
    ---@return codeview.Session
    local function open_review(pr)
      local review, err = session_mod.open(fixture.ids.init .. ".." .. fixture.ids.shuffle, {
        dir = fixture.dir,
        pr = pr and {
          repo = "codeview/sidebar-spec",
          number = 5,
          title = "Shuffle the files",
          author = "ada",
          head_ref = "shuffle",
          base_ref = "main",
          state = "OPEN",
          url = "https://github.com/codeview/sidebar-spec/pull/5",
          body = "",
          head_sha = fixture.ids.shuffle,
        } or nil,
      })
      assert.is_nil(err)
      opened = assert(review)
      return opened
    end

    ---Report whether the sidebar shows a line for one path.
    ---@param bar codeview.Sidebar
    ---@param path string
    ---@return boolean
    local function shows(bar, path)
      return bar.panel:find(function(node)
        return node.path == path
      end) ~= nil
    end

    before_each(function()
      config.setup({ quit = "never" })
      message = require("codeview.message")
    end)

    it("starts collapsed in a pull request review", function()
      local review = open_review(true)
      local bar = assert(sidebar.open())
      assert.is_false(bar.expanded[message.group_path])
      assert.is_true(shows(bar, message.group_path))
      assert.is_false(shows(bar, message.path_of(review.commits[1].id)))
      -- The other entries stay visible.
      assert.is_true(shows(bar, message.pr_path(5)))
      assert.is_true(shows(bar, "dir/renamed.txt"))
    end)

    it("starts expanded in a review of a local range", function()
      local review = open_review(false)
      local bar = assert(sidebar.open())
      assert.is_nil(bar.expanded[message.group_path])
      for _, commit in ipairs(review.commits) do
        assert.is_true(shows(bar, message.path_of(commit.id)))
      end
    end)

    it("expands with <Tab> and keeps the state over a render", function()
      local review = open_review(true)
      local bar = assert(sidebar.open({ focus = true }))
      bar.panel:set_cursor(line_of(bar, message.group_path))
      press("<Tab>")
      assert.is_true(shows(bar, message.path_of(review.commits[1].id)))
      bar:render()
      assert.is_true(shows(bar, message.path_of(review.commits[1].id)))
      press("<Tab>")
      assert.is_false(shows(bar, message.path_of(review.commits[1].id)))
    end)

    it("steps from the pull request to the first file and back", function()
      open_review(true)
      sidebar.open({ focus = true })
      press("]f")
      wait_for(function()
        return view.current() ~= nil
      end, "the pull request did not open")
      assert.are.equal(message.pr_path(5), assert(view.current()).path)

      press("]f")
      wait_for(function()
        return assert(view.current()).path == "dir/renamed.txt"
      end, "the first file did not open")

      press("[f")
      wait_for(function()
        return assert(view.current()).path == message.pr_path(5)
      end, "the pull request did not open again")
      -- The step opens no commit, so the group stays collapsed.
      assert.is_false(assert(sidebar.get()).expanded[message.group_path])
    end)

    it("steps through the commits again after an expand", function()
      local review = open_review(true)
      local bar = assert(sidebar.open())
      bar:toggle_node(bar.tree.children[2])
      assert.is_true(bar.expanded[message.group_path])

      assert(view.open(review, assert(review:index_of(message.pr_path(5)))))
      assert.are.equal(review:index_of(message.path_of(review.commits[1].id)), view.step(review, 1))

      assert(view.open(review, assert(review:index_of("dir/renamed.txt"))))
      local oldest = review.commits[#review.commits]
      assert.are.equal(review:index_of(message.path_of(oldest.id)), view.step(review, -1))
    end)

    it("does not skip the files of a collapsed directory", function()
      local review = open_review(true)
      local bar = assert(sidebar.open())
      bar:toggle_node(bar.tree.children[3])
      assert.is_false(bar.expanded["dir"])

      assert(view.open(review, assert(review:index_of(message.pr_path(5)))))
      local first = assert(review:index_of("dir/renamed.txt"))
      assert.are.equal(first, view.step(review, 1))
      assert(view.next(review))
      assert.are.equal(first, assert(view.current()).index)
      -- The directory of the file opens, as before.
      assert.is_nil(bar.expanded["dir"])
    end)

    it("uses the start state without a sidebar", function()
      local review = open_review(true)
      assert.are.equal(review:index_of(message.pr_path(5)), view.step(review, 1))
      assert(view.next(review))
      assert.are.equal(review:index_of("dir/renamed.txt"), view.step(review, 1))
      review:close()

      review = open_review(false)
      assert.are.equal(review:index_of(message.path_of(review.commits[1].id)), view.step(review, 1))
    end)

    it("leaves a hidden commit for the closest entry that is not a commit", function()
      local review = open_review(true)
      -- No sidebar: the group stays collapsed while the commit is open.
      assert(view.open(review, assert(review:index_of(message.path_of(review.commits[1].id)))))
      assert.are.equal(review:index_of("dir/renamed.txt"), view.step(review, 1))
      assert.are.equal(review:index_of(message.pr_path(5)), view.step(review, -1))
    end)

    it("marks the collapsed group, and the comment keys go over it", function()
      config.setup({ quit = "never", comments = { dir = fixtures.tempdir("codeview-mark") } })
      local review = open_review(true)
      local bar = assert(sidebar.open())
      local comments = require("codeview.comments")
      for _, path in ipairs({ message.path_of(review.commits[1].id), "dir/renamed.txt" }) do
        assert(comments.create(review, {
          file = path,
          start_line = 1,
          end_line = 1,
          side = "new",
          commit = fixture.ids.shuffle,
          body = "a note",
        }))
      end
      assert.are.equal("  ▸ Commits|C", shown(bar, line_of(bar, message.group_path)))

      local _, err = await(function(cb)
        view.next_comment(review, cb)
      end)
      assert.is_nil(err)
      assert.are.equal("dir/renamed.txt", assert(view.current()).path)
      _, err = await(function(cb)
        view.prev_comment(review, cb)
      end)
      assert.are.equal("no comment before this one", err and err.message)

      -- Expand the group, and the comment of the commit is a stop again.
      bar:toggle_node(bar.panel:data(line_of(bar, message.group_path)))
      _, err = await(function(cb)
        view.prev_comment(review, cb)
      end)
      assert.is_nil(err)
      assert.are.equal(message.path_of(review.commits[1].id), assert(view.current()).path)
    end)

    it("opens the group of a commit that the view shows", function()
      local review = open_review(true)
      local bar = assert(sidebar.open())
      assert(view.open(review, assert(review:index_of(message.path_of(review.commits[1].id)))))
      assert.is_nil(bar.expanded[message.group_path])
      -- The commits are stops of the step again.
      assert.are.equal(review:index_of(message.path_of(review.commits[2].id)), view.step(review, 1))
    end)
  end)

  describe("the current file", function()
    it("marks the file that the view shows", function()
      local bar = open_sidebar()
      local _, err = await(function(cb)
        view.open(assert(opened), 2, cb)
      end)
      assert.is_nil(err)

      assert.are.equal(2, bar.current)
      local lnum = line_of(bar, "added.txt")
      assert.are.equal("▸   added.txt|A", shown(bar, lnum))
      assert.are.equal("CodeViewCurrent", marks_of(bar, lnum)[1][4].line_hl_group)
      assert.are.equal("CodeViewMarker", hl_at(bar, lnum, 0))
    end)

    it("moves the marker to the next file", function()
      local bar = open_sidebar()
      await(function(cb)
        view.open(assert(opened), 1, cb)
      end)
      await(function(cb)
        view.open(assert(opened), 3, cb)
      end)

      assert.are.equal("    a.txt|M", shown(bar, line_of(bar, "a.txt")))
      assert.are.equal(3, bar.current)
      assert.are.equal("▸ │   renamed.txt…|R", shown(bar, line_of(bar, "dir/renamed.txt")))
    end)

    it("moves the cursor to the file of the view", function()
      local bar = open_sidebar()
      await(function(cb)
        view.open(assert(opened), 4, cb)
      end)
      local win = assert(bar.panel:window())
      assert.are.equal(line_of(bar, "keep.txt"), api.nvim_win_get_cursor(win)[1])
    end)

    it("shows the directory of the current file again", function()
      local bar = open_sidebar()
      bar:toggle_node(bar.tree.children[1])
      assert.are.equal("  ▸ dir|R", shown(bar, HEAD + 1))

      local _, err = await(function(cb)
        view.open(assert(opened), 3, cb)
      end)
      assert.is_nil(err)

      assert.are.equal(3, bar.current)
      local lnum = line_of(bar, "dir/renamed.txt")
      assert.are.equal("▸ │   renamed.txt…|R", shown(bar, lnum))
      assert.are.equal("CodeViewCurrent", marks_of(bar, lnum)[1][4].line_hl_group)
      assert.is_nil(bar.expanded["dir"])
      local win = assert(bar.panel:window())
      assert.are.equal(lnum, api.nvim_win_get_cursor(win)[1])
    end)

    it("clears the marker", function()
      local bar = open_sidebar()
      await(function(cb)
        view.open(assert(opened), 1, cb)
      end)
      bar:set_current(nil)
      assert.are.equal("    a.txt|M", shown(bar, line_of(bar, "a.txt")))
    end)
  end)

  describe("the keymaps", function()
    it("opens the file under the cursor with <CR>", function()
      local bar = open_sidebar({ focus = true })
      bar.panel:set_cursor(line_of(bar, "added.txt"))
      press("<CR>")
      wait_for(function()
        return view.current() ~= nil
      end, "the file did not open")

      local state = assert(view.current())
      assert.are.equal("added.txt", state.path)
      assert.are.equal(2, state.index)
      assert.are.same({ "@@ -0,0 +1 @@", "+added" }, api.nvim_buf_get_lines(state.buf, 0, -1, false))
      assert.is_false(panel.is_panel_win(state.win))
    end)

    it("does nothing on a header line", function()
      local bar = open_sidebar({ focus = true })
      bar.panel:set_cursor(1)
      assert.is_false(bar:open_cursor())
      press("<CR>")
      assert.is_nil(view.current())
    end)

    it("walks the file list with ]f and [f", function()
      local bar = open_sidebar({ focus = true })
      press("]f")
      wait_for(function()
        return view.current() ~= nil
      end, "the first file did not open")
      assert.are.equal("dir/renamed.txt", assert(view.current()).path)

      press("]f")
      wait_for(function()
        return assert(view.current()).path == "a.txt"
      end, "the next file did not open")

      press("[f")
      wait_for(function()
        return assert(view.current()).path == "dir/renamed.txt"
      end, "the previous file did not open")
      assert.are.equal(3, bar.current)
    end)

    it("walks the file list from the view buffer", function()
      local bar = open_sidebar()
      await(function(cb)
        view.open(assert(opened), 3, cb)
      end)
      api.nvim_set_current_win(assert(view.current()).win)
      press("]f")
      wait_for(function()
        return assert(view.current()).index == 1
      end, "the next file did not open")
      assert.are.equal(1, bar.current)
    end)

    it("closes the session with q", function()
      local bar = open_sidebar({ focus = true })
      local win = assert(bar.panel:window())
      press("q")

      assert.is_true(assert(opened).closed)
      assert.is_nil(session_mod.current())
      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_nil(sidebar.get())
    end)

    it("skips a keymap that the configuration disables", function()
      config.setup({ commit_message = false, keymaps = { close = false } })
      local bar = open_sidebar()
      local names = vim.tbl_map(function(map)
        return map.lhs
      end, api.nvim_buf_get_keymap(assert(bar.panel:buffer()), "n"))
      assert.is_false(vim.tbl_contains(names, "q"))
      assert.is_true(vim.tbl_contains(names, "]f"))
    end)

    it("takes a list of keys for one action", function()
      config.setup({ commit_message = false, keymaps = { open_file = { "<CR>", "o" } } })
      local bar = open_sidebar()
      local names = vim.tbl_map(function(map)
        return map.lhs
      end, api.nvim_buf_get_keymap(assert(bar.panel:buffer()), "n"))
      assert.is_true(vim.tbl_contains(names, "<CR>"))
      assert.is_true(vim.tbl_contains(names, "o"))
    end)
  end)

  describe("close", function()
    it("closes the window but keeps the session", function()
      local bar = open_sidebar()
      local win = assert(bar.panel:window())
      assert.is_true(sidebar.close())

      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_nil(sidebar.get())
      assert.is_false(assert(opened).closed)
      assert.is_false(sidebar.close())
    end)

    it("toggles the sidebar", function()
      open_session()
      assert.is_true(sidebar.toggle())
      assert.is_true(sidebar.is_open())
      assert.is_false(sidebar.toggle())
      assert.is_false(sidebar.is_open())
    end)

    it("opens a sidebar for a new session", function()
      local first = open_sidebar()
      local win = assert(first.panel:window())

      open_session(fixture.ids.edit)
      local second = assert(sidebar.open())
      assert.are_not.equal(first, second)
      assert.is_false(api.nvim_win_is_valid(win))
      assert.are.equal(2, #assert(opened).files)
    end)

    it("leaves no autocmd of the sidebar behind", function()
      local bar = open_sidebar()
      local group = assert(opened):augroup()
      assert.are.equal(2, #api.nvim_get_autocmds({ group = group, event = "User" }))
      bar:close()
      assert.are.equal(0, #api.nvim_get_autocmds({ group = group, event = "User" }))
    end)
  end)

  describe("the command", function()
    it("opens the sidebar with the session", function()
      local command = require("codeview.command")
      command.run({ args = fixture.ids.edit, dir = fixture.dir })
      wait_for(function()
        return session_mod.current() ~= nil
      end, "the session did not open")
      opened = session_mod.current()

      wait_for(function()
        return sidebar.is_open()
      end, "the sidebar did not open")
      assert.are.equal(2, #assert(sidebar.get()).session.files)
    end)

    it("keeps the sidebar closed when auto_open is off", function()
      config.setup({ commit_message = false, sidebar = { auto_open = false } })
      local command = require("codeview.command")
      command.run({ args = fixture.ids.edit, dir = fixture.dir })
      wait_for(function()
        return session_mod.current() ~= nil
      end, "the session did not open")
      opened = session_mod.current()

      assert.is_false(sidebar.is_open())
      command.files()
      assert.is_true(sidebar.is_open())
      command.files()
      assert.is_false(sidebar.is_open())
    end)

    it("knows :Codeview files", function()
      local command = require("codeview.command")
      assert.is_truthy(api.nvim_get_commands({}).Codeview)
      assert.are.equal(command.files, command.subcommands.files.run)
    end)
  end)

  it("leaves no windows behind", function()
    assert.are.equal(1, #api.nvim_tabpage_list_wins(0))
  end)

  describe("the comment mark", function()
    local comments, events, remote

    ---Add one local comment to the store of the session.
    ---@param review codeview.Session
    ---@param path string Path of the file of the comment.
    ---@return codeview.store.Comment
    local function add_comment(review, path)
      return assert(comments.create(review, {
        file = path,
        start_line = 1,
        end_line = 1,
        side = "new",
        commit = fixture.ids.shuffle,
        body = "a note",
      }))
    end

    before_each(function()
      -- The comments of one range share a file, so every test takes its own
      -- directory.
      config.setup({ commit_message = false, quit = "never", comments = { dir = fixtures.tempdir("codeview-mark") } })
      comments = require("codeview.comments")
      events = require("codeview.events")
      remote = require("codeview.remote")
    end)

    it("shows no mark without comments", function()
      local bar = open_sidebar()
      assert.are.equal("    a.txt|M", shown(bar, line_of(bar, "a.txt")))
    end)

    it("marks a file with a local comment", function()
      local bar, review = open_sidebar()
      add_comment(review, "a.txt")
      local lnum = line_of(bar, "a.txt")
      assert.are.equal("    a.txt|M C", shown(bar, lnum))
      assert.are.equal("CodeViewCommentMark", right_hl(bar, lnum, "C"))
      assert.are.equal("CodeViewModified", right_hl(bar, lnum, "M"))
      -- A file without comments keeps its status mark in the same column.
      assert.are.equal("    added.txt|A  ", shown(bar, line_of(bar, "added.txt")))
    end)

    it("removes the mark with the last comment of the file", function()
      local bar, review = open_sidebar()
      local first = add_comment(review, "a.txt")
      local second = add_comment(review, "a.txt")
      local store = assert(comments.store(review))
      for _, comment in ipairs({ first, second }) do
        assert.is_truthy(store:remove(comment.id))
        events.emit("comment_deleted", { id = comment.id, file = comment.file, session = review.id })
        local expected = comment == first and "    a.txt|M C" or "    a.txt|M"
        assert.are.equal(expected, shown(bar, line_of(bar, "a.txt")))
      end
    end)

    it("marks a directory that hides a file with comments", function()
      local bar, review = open_sidebar()
      add_comment(review, "dir/renamed.txt")
      assert.are.equal("  ▾ dir|", shown(bar, line_of(bar, "dir")))
      assert.are.equal("  │   renamed.t…|R C", shown(bar, line_of(bar, "dir/renamed.txt")))
      bar:toggle_node(bar.panel:data(line_of(bar, "dir")))
      local lnum = line_of(bar, "dir")
      assert.are.equal("  ▸ dir|R C", shown(bar, lnum))
      assert.are.equal("CodeViewCommentMark", right_hl(bar, lnum, "C"))
    end)

    it("marks a file with a comment of GitHub", function()
      local bar, review = open_sidebar()
      remote.attach(review, {
        {
          id = 501,
          file = "added.txt",
          start_line = 1,
          end_line = 1,
          side = "new",
          commit = fixture.ids.shuffle,
          author = "grace",
          body = "this line needs a test",
          url = "https://github.com/ada/demo/pull/12#discussion_r501",
          created_at = 0,
          outdated = false,
        },
      })
      assert.are.equal("    added.txt|A C", shown(bar, line_of(bar, "added.txt")))
      remote.clear(review)
      assert.are.equal("    added.txt|A", shown(bar, line_of(bar, "added.txt")))
    end)

    it("takes the mark from the configuration", function()
      config.setup({
        commit_message = false,
        quit = "never",
        comments = { dir = fixtures.tempdir("codeview-mark") },
        sidebar = { icons = { comment = "*" } },
      })
      local bar, review = open_sidebar()
      add_comment(review, "a.txt")
      assert.are.equal("    a.txt|M *", shown(bar, line_of(bar, "a.txt")))
      config.options.sidebar.icons.comment = ""
      bar:render()
      -- No mark gives no comment column: the status marks stand at the edge.
      assert.are.equal("    a.txt|M", shown(bar, line_of(bar, "a.txt")))
      assert.are.equal("    added.txt|A", shown(bar, line_of(bar, "added.txt")))
    end)

    it("links the highlight group to the color of the comments", function()
      open_sidebar()
      assert.are.equal("DiagnosticInfo", api.nvim_get_hl(0, { name = "CodeViewCommentMark" }).link)
    end)
  end)

  describe("the comments line", function()
    it("opens the comment overview", function()
      local bar = open_sidebar()
      local overview = require("codeview.overview")
      local row = nil
      for index = 1, #bar.panel:lines() do
        local data = bar.panel:data(index)
        if type(data) == "table" and data.kind == "action" then
          row = index
        end
      end
      assert.is_truthy(row, "no action line in the sidebar")
      assert.is_truthy(bar.panel:lines()[row]:find("Comments", 1, true), bar.panel:lines()[row])

      api.nvim_set_current_win(bar.panel:window())
      api.nvim_win_set_cursor(bar.panel:window(), { row, 0 })
      assert.is_nil(overview.get())
      assert.is_true(bar:open_cursor())
      assert.is_truthy(overview.get(), "the line opened no overview")
      overview.close()
    end)

    it("opens no file", function()
      local bar = open_sidebar()
      local view_mod = require("codeview.view")
      local row = nil
      for index = 1, #bar.panel:lines() do
        local data = bar.panel:data(index)
        if type(data) == "table" and data.kind == "action" then
          row = index
        end
      end
      api.nvim_set_current_win(bar.panel:window())
      api.nvim_win_set_cursor(bar.panel:window(), { row, 0 })
      bar:open_cursor()
      assert.is_nil(view_mod.current())
      require("codeview.overview").close()
    end)
  end)

  describe("the mouse", function()
    it("maps a double click to the open action", function()
      local bar = open_sidebar()
      ---@type table<string, boolean>
      local keys = {}
      for _, map in ipairs(api.nvim_buf_get_keymap(bar.panel:buffer(), "n")) do
        if type(map.desc) == "string" and map.desc:find("^codeview: ") then
          keys[map.lhs] = true
        end
      end
      assert.is_true(keys["<2-LeftMouse>"], "the sidebar takes no double click")
    end)

    it("drops the double click when the user sets one key", function()
      config.setup({ commit_message = false, keymaps = { open_file = "<CR>" } })
      local bar = open_sidebar()
      for _, map in ipairs(api.nvim_buf_get_keymap(bar.panel:buffer(), "n")) do
        assert.are_not.equal("<2-LeftMouse>", map.lhs)
      end
    end)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
