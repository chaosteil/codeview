local fixtures = require("tests.fixtures")
local suite = require("tests.vcs_backend_suite")

-- Every block below builds a jj fixture. Without jj the whole file is pending,
-- so a machine without jj still runs the rest of the suite.
if vim.fn.executable("jj") ~= 1 then
  describe("codeview.vcs.jj", function()
    pending("needs jj in $PATH")
  end)
  return
end

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

---Write a file whose path holds a space.
---@param dir string Repository root.
local function write_spaced(dir)
  local handle = assert(io.open(vim.fs.joinpath(dir, "dir", "with space.txt"), "wb"))
  handle:write("spaced\n")
  handle:close()
end

suite({
  name = "jj",
  backend = require("codeview.vcs.jj"),
  fixture = fixtures.jj,
  -- `@` is the working-copy commit. The builder leaves the newest commit there.
  head_rev = "@",
  detects_renames = true,
})

describe("codeview.vcs.jj", function()
  local jj = require("codeview.vcs.jj")
  local fixture = fixtures.jj()
  local repo = assert(jj.detect(fixture.dir))

  it("reports that jj is available", function()
    assert.is_true(jj.available())
  end)

  it("reports a repository that is not colocated", function()
    assert.is_false(repo.colocated)
    assert.are.equal(0, vim.fn.isdirectory(vim.fs.joinpath(fixture.root, ".git")))
  end)

  it("resolves the working-copy commit and its parent", function()
    assert.are.equal(fixture.ids.shuffle, assert(repo:resolve_rev("@")))
    assert.are.equal(fixture.ids.edit, assert(repo:resolve_rev("@-")))
  end)

  it("resolves a change id", function()
    local commits = assert(repo:log({ limit = 1 }))
    assert.are.equal(fixture.ids.shuffle, assert(repo:resolve_rev(commits[1].change_id)))
  end)

  it("reports the change id and the commit id of a record", function()
    local commit = assert(repo:log({ limit = 1 }))[1]
    assert.are.equal(fixture.ids.shuffle, commit.id)
    assert.are.equal(32, #commit.change_id)
    assert.is_truthy(commit.change_id:match("^[k-z]+$"), commit.change_id)
    -- The user interface shows the change id, not the commit id.
    assert.are.equal(commit.change_id:sub(1, 8), commit.short_id)
  end)

  it("lists only the commits that touch a path", function()
    local commits = assert(repo:log({ paths = { "keep.txt" } }))
    assert.are.equal(2, #commits)
    assert.are.equal(fixture.ids.shuffle, commits[1].id)
    assert.are.equal(fixture.ids.init, commits[2].id)

    local nested = assert(repo:log({ paths = { "dir" } }))
    assert.are.equal(2, #nested)
  end)

  it("leaves the virtual root commit out of the log", function()
    for _, commit in ipairs(assert(repo:log())) do
      assert.are_not.equal(string.rep("0", 40), commit.id)
    end
    assert.are.same({}, assert(repo:log({ limit = 1, revs = { fixture.ids.init } }))[1].parents)
  end)

  describe("revsets", function()
    it("reviews the whole history with `::@`", function()
      local range = assert(repo:resolve_range("::@"))
      assert.are.equal(fixture.ids.shuffle, range.to)
      assert.is_nil(range.from)
    end)

    it("reviews one commit with `@-`", function()
      local range = assert(repo:resolve_range("@-"))
      assert.are.equal(fixture.ids.edit, range.to)
      assert.are.equal(fixture.ids.init, range.from)
    end)

    it("reads a revset that holds an operator", function()
      local range = assert(repo:resolve_range("@- | @"))
      assert.are.equal(fixture.ids.shuffle, range.to)
      assert.are.equal(fixture.ids.init, range.from)
    end)

    it("reads a revset with a function call", function()
      local range = assert(repo:resolve_range("descendants(" .. fixture.ids.edit .. ")"))
      assert.are.equal(fixture.ids.shuffle, range.to)
      assert.are.equal(fixture.ids.init, range.from)
    end)

    it("keeps the revset text as the label", function()
      assert.are.equal("::@", assert(repo:resolve_range("::@")).spec)
    end)

    it("rejects a revset with a syntax error", function()
      local range, err = repo:resolve_range("heads(")
      assert.is_nil(range)
      assert.are.equal("bad_revision", err.code)
    end)

    it("rejects an empty revset", function()
      local range, err = repo:resolve_range("   ")
      assert.is_nil(range)
      assert.are.equal("invalid_arg", err.code)
    end)

    it("reports a revset that names no commit", function()
      local range, err = repo:resolve_range("@..@")
      assert.is_nil(range)
      assert.are.equal("not_found", err.code)
      assert.is_truthy(tostring(err):find("no commits", 1, true), tostring(err))
    end)

    it("rejects the virtual root commit", function()
      local range, err = repo:resolve_range("root()")
      assert.is_nil(range)
      assert.are.equal("bad_revision", err.code)

      local id, rev_err = repo:resolve_rev("root()")
      assert.is_nil(id)
      assert.are.equal("bad_revision", rev_err.code)
    end)

    it("rejects trunk() without a trunk bookmark", function()
      -- The fixture has no remote, so `trunk()` falls back to the root commit.
      local range, err = repo:resolve_range("trunk()")
      assert.is_nil(range)
      assert.are.equal("bad_revision", err.code)
      assert.is_truthy(tostring(err):find("root commit", 1, true), tostring(err))
    end)

    it("lists the changed files of a revset range", function()
      local range = assert(repo:resolve_range("@- | @"))
      local files = assert(repo:changed_files(range))
      local paths = vim.tbl_map(function(file)
        return file.path
      end, files)
      table.sort(paths)
      assert.are.same({ "a.txt", "added.txt", "dir/renamed.txt", "keep.txt" }, paths)
    end)
  end)

  it("reads a file from the working-copy commit", function()
    assert.are.equal(fixtures.content_at("shuffle", "a.txt"), repo:file_content("@", "a.txt"))
  end)

  it("reports an unknown path as empty content", function()
    assert.are.equal("", assert(repo:file_content("@", "no-such-file.txt")))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview.vcs.jj on a changed working copy", function()
  local jj = require("codeview.vcs.jj")
  local fixture = fixtures.jj()
  local repo = assert(jj.detect(fixture.dir))

  ---Run a jj command in the fixture.
  ---
  --- `jj describe` rewrites the working-copy commit, so these tests get their
  --- own fixture. The commit ids of the other tests stay valid that way.
  ---@param cmd string[]
  local function jj_run(cmd)
    local res = vim.system(cmd, { cwd = fixture.dir, env = fixture.env, text = true }):wait(30000)
    assert.are.equal(0, res.code, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
  end

  it("keeps the body of a commit message", function()
    jj_run({ "jj", "--no-pager", "describe", "-m", "subject line\n\nbody one\nbody two" })
    local commit = assert(repo:log({ limit = 1 }))[1]
    assert.are.equal("subject line", commit.subject)
    assert.are.equal("body one\nbody two", commit.body)
  end)

  it("keeps the bytes of a file with CRLF line endings", function()
    local path = vim.fs.joinpath(fixture.dir, "crlf.txt")
    local handle = assert(io.open(path, "wb"))
    handle:write("one\r\ntwo\r\n")
    handle:close()
    jj_run({ "jj", "--no-pager", "describe", "-m", "crlf: add crlf.txt" })

    assert.are.equal("one\r\ntwo\r\n", assert(repo:file_content("@", "crlf.txt")))
  end)

  it("reads a path that holds a space", function()
    write_spaced(fixture.dir)
    jj_run({ "jj", "--no-pager", "describe", "-m", "space: add a path with a space" })

    local range = assert(repo:resolve_range("@"))
    local files = assert(repo:changed_files(range))
    local seen = false
    for _, file in ipairs(files) do
      if file.path == "dir/with space.txt" then
        seen = true
      end
    end
    assert.is_true(seen)
    assert.are.equal("spaced\n", assert(repo:file_content("@", "dir/with space.txt")))
  end)

  it("reads a symbolic link as its target", function()
    assert(vim.uv.fs_symlink("a.txt", vim.fs.joinpath(fixture.dir, "link.txt")))
    jj_run({ "jj", "--no-pager", "describe", "-m", "link: add a symbolic link" })

    -- `jj file show` refuses a link. The content is the target of the link,
    -- which is what the git backend returns.
    assert.are.equal("a.txt", assert(repo:file_content("@", "link.txt")))
  end)

  it("keeps the working-copy commit until a snapshot", function()
    local before = assert(repo:working_rev())
    local path = vim.fs.joinpath(fixture.dir, "a.txt")
    local handle = assert(io.open(path, "ab"))
    handle:write("six\n")
    handle:close()

    -- Every other call runs with `--ignore-working-copy`, so the new line is
    -- not in the repository yet.
    assert.are.equal(before, assert(repo:working_rev()))
    assert.is_nil(assert(repo:file_content("@", "a.txt")):find("six", 1, true))

    local after = assert(repo:snapshot())
    assert.are_not.equal(before, after)
    assert.are.equal(after, assert(repo:working_rev()))
    assert.is_truthy(assert(repo:file_content("@", "a.txt")):find("six", 1, true))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview on a jj repository", function()
  local fixture = fixtures.jj()
  local session_mod = require("codeview.session")
  local sidebar = require("codeview.sidebar")
  local view = require("codeview.view")
  ---@type codeview.Session?
  local opened

  ---Open a session for the whole history of the fixture.
  ---@param spec? string
  ---@return codeview.Session
  local function open_session(spec)
    opened = assert(session_mod.open(spec or "::@", { dir = fixture.dir }))
    return opened
  end

  after_each(function()
    view.close()
    sidebar.close()
    session_mod.close()
    opened = nil
  end)

  it("lists the changed files in the sidebar", function()
    local review = open_session("@- | @")
    local bar = assert(sidebar.open({ session = review }))
    local text = table.concat(bar.panel:lines(), "\n")
    for _, path in ipairs({ "a.txt", "added.txt", "keep.txt", "renamed.txt" }) do
      assert.is_truthy(text:find(path, 1, true), text)
    end
    assert.is_truthy(text:find("@- | @", 1, true), text)
  end)

  it("shows the inline diff of a file", function()
    local review = open_session(fixture.ids.init .. ".." .. fixture.ids.shuffle)
    local state = assert(view.open(review, assert(review:index_of("a.txt"))))
    assert.are.same({
      "@@ -1,3 +1,5 @@",
      " one",
      "-two",
      "+two changed",
      " three",
      "+four",
      "+five",
    }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
  end)

  it("shows a deleted file and a renamed file", function()
    local review = open_session(fixture.ids.init .. ".." .. fixture.ids.shuffle)
    local deleted = assert(view.open(review, assert(review:index_of("keep.txt"))))
    assert.are.equal("deleted", deleted.status)
    assert.are.same({ "@@ -1 +0,0 @@", "-keep me" }, vim.api.nvim_buf_get_lines(deleted.buf, 0, -1, false))

    local renamed = assert(view.open(review, assert(review:index_of("dir/renamed.txt"))))
    assert.are.equal("dir/nested.txt", renamed.diff.old_path)
  end)

  it("shows the whole file of the first commit", function()
    local review = open_session(fixture.ids.init)
    assert.is_nil(review.range.from)
    local state = assert(view.open(review, assert(review:index_of("a.txt"))))
    assert.are.same({
      "@@ -0,0 +1,3 @@",
      "+one",
      "+two",
      "+three",
    }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
  end)

  it("switches to the side-by-side style", function()
    local review = open_session(fixture.ids.init .. ".." .. fixture.ids.shuffle)
    view.open(review, assert(review:index_of("a.txt")))
    assert.are.equal("split", view.set_style("split"))
    local state = assert(view.current())
    assert.are.equal("split", state.style)
    assert.is_truthy(state.old_win)
    view.set_style("inline")
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview.session reload on a jj repository", function()
  local fixture = fixtures.jj()
  local session_mod = require("codeview.session")

  ---Write a file of the working copy.
  ---@param name string Path from the repository root.
  ---@param text string Content of the file.
  local function write(name, text)
    local handle = assert(io.open(vim.fs.joinpath(fixture.dir, name), "wb"))
    handle:write(text)
    handle:close()
  end

  after_each(function()
    session_mod.close()
  end)

  it("takes the new state of the working copy", function()
    local review = assert(session_mod.open("@", { dir = fixture.dir }))
    local before = review.range.to
    write("fresh.txt", "fresh\n")

    local same, err = review:reload()
    assert.is_nil(err)
    assert.are.equal(review, same)
    -- The snapshot gives `@` a new commit id, and the new file is a change of
    -- the range.
    assert.are_not.equal(before, review.range.to)
    assert.is_truthy(review:index_of("fresh.txt"))
  end)

  it("sends the refresh event", function()
    local review = assert(session_mod.open("@", { dir = fixture.dir }))
    local seen = 0
    local group = vim.api.nvim_create_augroup("codeview.test.reload", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "CodeViewSessionRefreshed",
      callback = function()
        seen = seen + 1
      end,
    })

    write("second.txt", "second\n")
    assert(review:reload())
    vim.api.nvim_del_augroup_by_id(group)
    assert.are.equal(1, seen)
  end)

  it("keeps a review that does not hold the working-copy commit", function()
    local review = assert(session_mod.open("@-", { dir = fixture.dir }))
    local before = review.range.to
    write("third.txt", "third\n")

    local same, err = review:reload()
    assert.is_nil(err)
    assert.are.equal(review, same)
    assert.are.equal(before, review.range.to)
    assert.is_nil(review:index_of("third.txt"))
  end)

  it("keeps the comments of the session", function()
    local review = assert(session_mod.open("@", { dir = fixture.dir }))
    local comments = require("codeview.comments")
    local store = assert(comments.attach(review))
    write("fifth.txt", "fifth\n")

    assert(review:reload())

    -- The comment file follows the session, so the new head of the range does
    -- not move the comments to another file.
    local after = assert(comments.attach(review))
    assert.are.equal(store, after)
    assert.are.equal(store.path, after.path)
  end)

  it("reloads asynchronously", function()
    local review = assert(session_mod.open("@", { dir = fixture.dir }))
    local before = review.range.to
    write("fourth.txt", "fourth\n")

    local same, err = await(function(cb)
      review:reload(cb)
    end)
    assert.is_nil(err)
    assert.are.equal(review, same)
    assert.are_not.equal(before, review.range.to)
    assert.is_truthy(review:index_of("fourth.txt"))
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview back to a review of the working copy", function()
  local fixture = fixtures.jj()
  local session_mod = require("codeview.session")
  local view = require("codeview.view")

  ---Open a review of `@` and edit one file of it in the working copy.
  ---@param name string Path of the file from the repository root.
  ---@param text string Line that the editor adds to the file.
  local function edit_file(name, text)
    local review = assert(session_mod.open("@", { dir = fixture.dir }))
    local state = assert(view.open(review, assert(review:index_of(name))))
    vim.api.nvim_set_current_win(state.win)
    assert.is_true(view.edit())

    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { text })
    vim.cmd.write()
  end

  ---Text of the diff that the view shows.
  ---@return string
  local function diff_text()
    local state = assert(view.current())
    return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  end

  after_each(function()
    view.close()
    session_mod.close()
    require("codeview.config").setup({})
  end)

  it("shows the line that the editor added", function()
    edit_file("a.txt", "from the editor")

    assert.is_true(view.back())
    assert.is_truthy(diff_text():find("+from the editor", 1, true), diff_text())
  end)

  it("keeps the old diff when auto_reload is off", function()
    require("codeview.config").setup({ auto_reload = false })
    -- The write does not reach the repository, because the reload is off.
    edit_file("a.txt", "not in the review")

    assert.is_true(view.back())
    assert.is_nil(diff_text():find("not in the review", 1, true), diff_text())
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview.picker on a jj repository", function()
  local picker = require("codeview.picker")
  local session = require("codeview.session")
  local fixture = fixtures.jj()

  after_each(function()
    session.close()
  end)

  it("labels a picked range with jj syntax", function()
    -- The log is newest first. The first list picks the middle commit, the
    -- second list picks the newest commit.
    local picks = { 2, 1 }
    local calls = 0
    local function select(items, _, on_choice)
      calls = calls + 1
      on_choice(items[picks[calls]], picks[calls])
    end

    local out, finished = {}, false
    picker.pick_range({ dir = fixture.dir, select = select }, function(opened, err)
      out.session, out.err, finished = opened, err, true
    end)
    assert.is_true(vim.wait(20000, function()
      return finished
    end, 10))

    assert.is_nil(out.err)
    local review = assert(out.session)
    assert.are.equal("jj", review.repo.backend)
    assert.are.equal(fixture.ids.init, review.range.from)
    assert.are.equal(fixture.ids.shuffle, review.range.to)

    -- The label must stay valid input for `:Codeview`. jj writes the parent of
    -- a commit as `<rev>-`, not as `<rev>^`.
    local label = review:label()
    assert.is_truthy(label:find("-..", 1, true), label)
    assert.is_nil(label:find("^", 1, true))
    local range = assert(review.repo:resolve_range(label))
    assert.are.equal(fixture.ids.init, range.from)
    assert.are.equal(fixture.ids.shuffle, range.to)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview.vcs detection of nested repositories", function()
  local vcs = require("codeview.vcs")
  local fixture = fixtures.jj()
  local nested = vim.fs.joinpath(fixture.dir, "vendor", "clone")

  ---Root of the nested repository, without symbolic links.
  ---@return string
  local function nested_root()
    return vim.fs.normalize(assert(vim.uv.fs_realpath(nested)))
  end

  -- A git clone inside a jj repository, for example a vendored dependency.
  vim.fn.mkdir(nested, "p")
  local init = vim
    .system(
      { "git", "init", "--quiet", "--initial-branch=main", "." },
      { cwd = nested, text = true, env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null" } }
    )
    :wait(30000)
  assert(init.code == 0, init.stderr)

  it("takes the git repository inside the jj repository", function()
    local repo = assert(vcs.detect(nested, { backend = "auto" }))
    assert.are.equal("git", repo.backend)
    assert.are.equal(nested_root(), repo.root)
  end)

  it("takes the same repository asynchronously", function()
    local out, finished = {}, false
    vcs.detect(nested, { backend = "auto" }, function(repo, err)
      out.repo, out.err, finished = repo, err, true
    end)
    assert.is_true(vim.wait(20000, function()
      return finished
    end, 10))
    assert.is_nil(out.err)
    assert.are.equal("git", out.repo.backend)
    assert.are.equal(nested_root(), out.repo.root)
  end)

  it("takes the jj repository around it", function()
    local repo = assert(vcs.detect(fixture.dir, { backend = "auto" }))
    assert.are.equal("jj", repo.backend)
    assert.are.equal(fixture.root, repo.root)
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)

describe("codeview.vcs.jj in a colocated repository", function()
  local vcs = require("codeview.vcs")
  local fixture = fixtures.jj({ colocate = true })

  it("has both a .jj and a .git directory", function()
    assert.are.equal(1, vim.fn.isdirectory(vim.fs.joinpath(fixture.root, ".jj")))
    assert.are.equal(1, vim.fn.isdirectory(vim.fs.joinpath(fixture.root, ".git")))
  end)

  it("reports the colocation on the handle", function()
    local repo = assert(require("codeview.vcs.jj").detect(fixture.dir))
    assert.is_true(repo.colocated)
  end)

  it("prefers the jj backend with the automatic detection", function()
    local repo = assert(vcs.detect(fixture.dir, { backend = "auto" }))
    assert.are.equal("jj", repo.backend)
    assert.are.equal(fixture.root, repo.root)
  end)

  it("uses the git backend when the configuration forces it", function()
    local repo = assert(vcs.detect(fixture.dir, { backend = "git" }))
    assert.are.equal("git", repo.backend)
  end)

  it("uses the jj backend when the configuration forces it", function()
    local config = require("codeview.config")
    config.setup({ backend = "jj" })
    local repo = assert(vcs.detect(fixture.dir))
    config.reset()
    assert.are.equal("jj", repo.backend)
  end)

  it("opens a session on a revset", function()
    local session = require("codeview.session")
    local opened = assert(session.open("::@", { dir = fixture.dir }))
    assert.are.equal("jj", opened.repo.backend)
    assert.are.equal(fixture.ids.shuffle, opened.range.to)
    assert.is_nil(opened.range.from)
    assert.are.equal(3, #opened.commits)
    assert.are.equal("::@", opened:label())
    opened:close()
  end)

  it("opens a session through :Codeview with a revset", function()
    local command = require("codeview.command")
    local session = require("codeview.session")
    local out, finished = {}, false
    command.run({
      args = "@- | @",
      dir = fixture.dir,
      on_open = function(opened, err)
        out.session, out.err, finished = opened, err, true
      end,
    })
    assert.is_true(vim.wait(20000, function()
      return finished
    end, 10))
    assert.is_nil(out.err)
    assert.are.equal(fixture.ids.shuffle, out.session.range.to)
    assert.are.equal(fixture.ids.init, out.session.range.from)
    session.close()
  end)

  it("removes the fixture", function()
    fixture.cleanup()
    assert.are.equal(0, vim.fn.isdirectory(fixture.dir))
  end)
end)
