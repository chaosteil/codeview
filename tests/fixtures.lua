-- Fixture repositories for the backend tests.
--
-- `M.commits` is the history as data. Each backend builder walks the same list,
-- so the backend-agnostic suite can run against git and, from M6, against jj.

local M = {}

---@class tests.FixtureCommit
---@field name string Key of the commit in `fixture.commits`.
---@field message string Commit message. The first line is the subject.
---@field write table<string, string> Files to write, path to content.
---@field remove string[] Files to delete.
---@field rename table<string, string> Files to rename, old path to new path.

---History of the fixture repository, oldest commit first.
---@type tests.FixtureCommit[]
M.commits = {
  {
    name = "init",
    message = "init: add the first files",
    write = {
      ["a.txt"] = "one\ntwo\nthree\n",
      ["keep.txt"] = "keep me\n",
      ["dir/nested.txt"] = "nested one\nnested two\n",
    },
    remove = {},
    rename = {},
  },
  {
    name = "edit",
    message = "edit: change a.txt and add added.txt",
    write = {
      ["a.txt"] = "one\ntwo changed\nthree\nfour\n",
      ["added.txt"] = "added\n",
    },
    remove = {},
    rename = {},
  },
  {
    name = "shuffle",
    message = "shuffle: delete, rename, and modify",
    write = {
      ["a.txt"] = "one\ntwo changed\nthree\nfour\nfive\n",
    },
    remove = { "keep.txt" },
    rename = { ["dir/nested.txt"] = "dir/renamed.txt" },
  },
}

---@class tests.Fixture
---@field root string Repository root, as the backend reports it.
---@field dir string Directory that the builder created.
---@field ids table<string, string> Commit id of each commit name.
---@field names string[] Commit names, oldest first.
---@field branch string Name of the default branch.
---@field cleanup fun() Delete the repository.

---Run a command and stop the test when it fails.
---@param cmd string[]
---@param cwd string
---@param env? table<string, string>
---@return string stdout
local function run(cmd, cwd, env)
  local res = vim.system(cmd, { cwd = cwd, text = true, env = env }):wait(30000)
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout or ""
end

---@param path string
---@param content string
local function write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local handle = assert(io.open(path, "wb"))
  handle:write(content)
  handle:close()
end

---Make an empty temporary directory.
---@param suffix string
---@return string dir
function M.tempdir(suffix)
  local dir = vim.fn.tempname() .. "-" .. suffix
  vim.fn.mkdir(dir, "p")
  return dir
end

---Environment of a git fixture. It keeps the user configuration out.
---@param dir string
---@return table<string, string>
local function git_env(dir)
  return {
    GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_SYSTEM = "/dev/null",
    GIT_AUTHOR_NAME = "Ada Lovelace",
    GIT_AUTHOR_EMAIL = "ada@example.com",
    GIT_COMMITTER_NAME = "Ada Lovelace",
    GIT_COMMITTER_EMAIL = "ada@example.com",
    HOME = dir,
  }
end

---Start a git repository with a fixed configuration.
---@param dir string
---@param branch string Name of the first branch.
---@param env table<string, string>
local function git_init(dir, branch, env)
  run({ "git", "init", "--quiet", "--initial-branch=" .. branch, "." }, dir, env)
  run({ "git", "config", "user.name", "Ada Lovelace" }, dir, env)
  run({ "git", "config", "user.email", "ada@example.com" }, dir, env)
  run({ "git", "config", "commit.gpgsign", "false" }, dir, env)
end

---Environment with a fixed commit date.
---@param env table<string, string>
---@param date string ISO 8601 timestamp.
---@return table<string, string>
local function at_date(env, date)
  return vim.tbl_extend("force", env, { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date })
end

---Build a git repository with the history of `M.commits`.
---@return tests.Fixture
function M.git()
  local dir = M.tempdir("codeview-git")
  local branch = "main"
  local env = git_env(dir)

  git_init(dir, branch, env)

  local ids, names = {}, {}
  for index, commit in ipairs(M.commits) do
    for old, new in pairs(commit.rename) do
      vim.fn.mkdir(vim.fs.dirname(vim.fs.joinpath(dir, new)), "p")
      run({ "git", "mv", old, new }, dir, env)
    end
    for _, path in ipairs(commit.remove) do
      run({ "git", "rm", "--quiet", path }, dir, env)
    end
    for path, content in pairs(commit.write) do
      write_file(vim.fs.joinpath(dir, path), content)
      run({ "git", "add", "--", path }, dir, env)
    end

    -- A fixed date per commit keeps the log order stable.
    local commit_env = at_date(env, string.format("2024-01-0%dT10:00:00+00:00", index))
    run({ "git", "commit", "--quiet", "-m", commit.message }, dir, commit_env)

    ids[commit.name] = vim.trim(run({ "git", "rev-parse", "HEAD" }, dir, env))
    names[#names + 1] = commit.name
  end

  local root = vim.trim(run({ "git", "rev-parse", "--show-toplevel" }, dir, env))

  return {
    root = vim.fs.normalize(root),
    dir = dir,
    ids = ids,
    names = names,
    branch = branch,
    cleanup = function()
      vim.fn.delete(dir, "rf")
    end,
  }
end

---Build a git repository with two branches and a merge.
---
--- The history is:
---
---     base (day 1) -> main_one (day 3) -> merge (day 5)
---     base (day 1) -> feature_one (day 2) -> feature_two (day 4) -> merge
---
--- The dates put `main_one` between the two feature commits. The log in date
--- order is [merge, feature_two, main_one, feature_one, base]. `main_one` is
--- newer than `feature_one`, but it is not a descendant of it.
---@return tests.Fixture
function M.git_branched()
  local dir = M.tempdir("codeview-branched")
  local env = git_env(dir)
  git_init(dir, "main", env)

  ---Write one file and commit it.
  ---@param path string
  ---@param day integer Day of the commit date.
  ---@param message string
  ---@return string id
  local function commit(path, day, message)
    write_file(vim.fs.joinpath(dir, path), path .. "\n")
    run({ "git", "add", "--", path }, dir, env)
    run(
      { "git", "commit", "--quiet", "-m", message },
      dir,
      at_date(env, string.format("2024-02-0%dT10:00:00+00:00", day))
    )
    return vim.trim(run({ "git", "rev-parse", "HEAD" }, dir, env))
  end

  local ids = {}
  ids.base = commit("a.txt", 1, "base: add a.txt")
  run({ "git", "checkout", "--quiet", "-b", "feature" }, dir, env)
  ids.feature_one = commit("c.txt", 2, "feature one: add c.txt")
  run({ "git", "checkout", "--quiet", "main" }, dir, env)
  ids.main_one = commit("b.txt", 3, "main one: add b.txt")
  run({ "git", "checkout", "--quiet", "feature" }, dir, env)
  ids.feature_two = commit("d.txt", 4, "feature two: add d.txt")
  run({ "git", "checkout", "--quiet", "main" }, dir, env)
  run(
    { "git", "merge", "--quiet", "--no-ff", "-m", "merge: feature into main", "feature" },
    dir,
    at_date(env, "2024-02-05T10:00:00+00:00")
  )
  ids.merge = vim.trim(run({ "git", "rev-parse", "HEAD" }, dir, env))

  local root = vim.trim(run({ "git", "rev-parse", "--show-toplevel" }, dir, env))

  return {
    root = vim.fs.normalize(root),
    dir = dir,
    ids = ids,
    names = { "base", "feature_one", "main_one", "feature_two", "merge" },
    branch = "main",
    cleanup = function()
      vim.fn.delete(dir, "rf")
    end,
  }
end

---Text of a file with numbered lines.
---@param count integer Number of lines.
---@param mark? table<integer, string> Text to put after the number of one line.
---@return string
function M.numbered(count, mark)
  mark = mark or {}
  local lines = {}
  for index = 1, count do
    lines[index] = string.format("line %02d%s", index, mark[index] or "")
  end
  return table.concat(lines, "\n") .. "\n"
end

---Build a git repository for the diff tests.
---
--- The range `base..change` holds one file of every shape that the diff view
--- must render:
---
---     long.txt        two hunks with 26 unchanged lines between them
---     gone.txt        deleted
---     new/name.txt    renamed, with the same content
---     added.txt       added
---     empty.txt       added, with no content
---     bin.dat         binary, changed
---@return tests.Fixture
function M.git_diff()
  local dir = M.tempdir("codeview-diff")
  local env = git_env(dir)
  git_init(dir, "main", env)

  ---Commit every file of a table.
  ---@param files table<string, string>
  ---@param day integer
  ---@param message string
  ---@return string id
  local function commit(files, day, message)
    for path, content in pairs(files) do
      write_file(vim.fs.joinpath(dir, path), content)
      run({ "git", "add", "--", path }, dir, env)
    end
    run(
      { "git", "commit", "--quiet", "--allow-empty", "-m", message },
      dir,
      at_date(env, string.format("2024-03-0%dT10:00:00+00:00", day))
    )
    return vim.trim(run({ "git", "rev-parse", "HEAD" }, dir, env))
  end

  local ids = {}
  ids.base = commit({
    ["long.txt"] = M.numbered(40),
    ["gone.txt"] = "gone one\ngone two\n",
    ["old/name.txt"] = "same one\nsame two\n",
    ["bin.dat"] = "\0\1\2 binary \3\0",
  }, 1, "base: add the files")

  run({ "git", "rm", "--quiet", "gone.txt" }, dir, env)
  vim.fn.mkdir(vim.fs.joinpath(dir, "new"), "p")
  run({ "git", "mv", "old/name.txt", "new/name.txt" }, dir, env)
  ids.change = commit({
    ["long.txt"] = M.numbered(40, { [3] = " changed", [30] = " changed" }),
    ["added.txt"] = "added one\nadded two\n",
    ["empty.txt"] = "",
    ["bin.dat"] = "\0\4\5 binary again \6\0",
  }, 2, "change: edit, add, delete, and rename")

  local root = vim.trim(run({ "git", "rev-parse", "--show-toplevel" }, dir, env))

  return {
    root = vim.fs.normalize(root),
    dir = dir,
    ids = ids,
    names = { "base", "change" },
    branch = "main",
    cleanup = function()
      vim.fn.delete(dir, "rf")
    end,
  }
end

---Content of a file after a commit, as the history describes it.
---@param upto string Name of the last commit to apply.
---@param path string
---@return string? content Nil when the commit does not hold the file.
function M.content_at(upto, path)
  local state = {}
  for _, commit in ipairs(M.commits) do
    for old, new in pairs(commit.rename) do
      state[new], state[old] = state[old], nil
    end
    for _, removed in ipairs(commit.remove) do
      state[removed] = nil
    end
    for file, content in pairs(commit.write) do
      state[file] = content
    end
    if commit.name == upto then
      break
    end
  end
  return state[path]
end

return M
