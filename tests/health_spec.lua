local helpers = require("tests.helpers")

---Run `:checkhealth codeview` and read the report.
---
--- Neovim 0.13 runs the checks after the command returns, and writes the
--- lines later. The report buffer is modifiable until the checks are done, so
--- the call waits for that on every version.
---@return string
local function report()
  vim.cmd("checkhealth codeview")
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(10000, function()
    return not vim.bo[buf].modifiable
  end, 10)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  vim.cmd("bwipeout!")
  return text
end

describe("codeview.health", function()
  ---Answer the login check without a call to GitHub.
  ---@param auth codeview.gh.Auth?
  ---@param err codeview.Error?
  local function stub_auth(auth, err)
    local gh = require("codeview.gh")
    gh.available = function() ---@diagnostic disable-line: duplicate-set-field
      return true
    end
    gh.auth_status = function() ---@diagnostic disable-line: duplicate-set-field
      return auth, err
    end
  end

  before_each(function()
    helpers.unload()
    -- The report must never reach the network. Every test answers the login
    -- check itself.
    stub_auth({ ok = true, host = "github.com", account = "ada", text = "github.com" })
  end)

  after_each(function()
    helpers.unload()
  end)

  it("provides a check function", function()
    assert.are.equal("function", type(require("codeview.health").check))
  end)

  it("reports the Neovim version", function()
    local text = report()
    assert.is_truthy(text:find("codeview", 1, true), text)
    local v = vim.version()
    local expected = string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch)
    assert.is_truthy(text:find(expected, 1, true), text)
  end)

  it("reports the state of setup()", function()
    local text = report()
    assert.is_truthy(text:find("setup()", 1, true), text)
    assert.is_truthy(text:find("configuration is valid", 1, true), text)
  end)

  it("reports git, jj, and gh", function()
    local text = report()
    for _, tool in ipairs({ "git", "jj", "gh" }) do
      assert.is_truthy(text:find(tool, 1, true), "missing " .. tool .. " in:\n" .. text)
    end
  end)

  it("names the configured executable of a tool", function()
    -- The names are in no $PATH, so the report says so for each of them. The
    -- test asserts the name only, because CI has no gh.
    assert(require("codeview.config").setup({
      git = { binary = "codeview-git-custom" },
      jj = { binary = "codeview-jj-custom" },
      github = { binary = "codeview-gh-custom" },
    }))
    local text = report()
    for _, name in ipairs({ "codeview-git-custom", "codeview-jj-custom", "codeview-gh-custom" }) do
      assert.is_truthy(text:find(name, 1, true), "missing " .. name .. " in:\n" .. text)
    end
  end)

  it("reports the version of an installed tool", function()
    local text = report()
    if vim.fn.executable("git") == 1 then
      assert.is_truthy(text:find("git version", 1, true), text)
    end
  end)

  it("reads the version number of a version line", function()
    local health = require("codeview.health")
    ---@param line string
    ---@return integer[]
    local function parts(line)
      local v = assert(health.version_of(line))
      return { v.major, v.minor, v.patch }
    end
    assert.are.same({ 0, 44, 0 }, parts("jj 0.44.0-af45d57de7163cc5f17f3df178a31577e4951ea3"))
    assert.are.same({ 2, 47, 1 }, parts("git version 2.47.1"))
    assert.is_nil(health.version_of("jj"))
    assert.is_nil(health.version_of(nil))
  end)

  it("warns about a jj that is older than the minimum", function()
    -- A script in place of jj reports an old version. The report must warn,
    -- and say what that version does not do.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local script = vim.fs.joinpath(dir, "codeview-old-jj")
    assert(vim.fn.writefile({ "#!/bin/sh", 'echo "jj 0.44.0-af45d57de7163cc5f17f3df178a31577e4951ea3"' }, script) == 0)
    assert(vim.uv.fs_chmod(script, 493))
    assert(require("codeview.config").setup({ jj = { binary = script } }))

    local text = report()
    vim.fn.delete(dir, "rf")
    assert.is_truthy(text:find("0.44.0", 1, true), text)
    assert.is_truthy(text:find("older than 0.45.0", 1, true), text)
    assert.is_truthy(text:find("colocated repository", 1, true), text)
  end)

  it("reports the account of the gh login", function()
    local text = report()
    assert.is_truthy(text:find("gh auth: logged in to github.com as ada", 1, true), text)
  end)

  it("reports a gh that is not logged in", function()
    local errors = require("codeview.error")
    stub_auth(
      { ok = false, host = "", account = "", text = "not logged in" },
      errors.new(errors.codes.NOT_AUTHENTICATED, "gh: no valid GitHub credentials. Run `gh auth login`")
    )
    local text = report()
    assert.is_truthy(text:find("gh auth: not logged in", 1, true), text)
    assert.is_truthy(text:find("gh auth login", 1, true), text)
  end)

  it("reports a gh that cannot reach GitHub", function()
    local errors = require("codeview.error")
    stub_auth(
      { ok = false, host = "", account = "", text = "" },
      errors.new(errors.codes.OFFLINE, "gh: cannot reach github.com")
    )
    local text = report()
    assert.is_truthy(text:find("cannot reach GitHub", 1, true), text)
  end)

  it("says nothing about the login without gh", function()
    local gh = require("codeview.gh")
    gh.available = function() ---@diagnostic disable-line: duplicate-set-field
      return false
    end
    local text = report()
    assert.is_falsy(text:find("gh auth:", 1, true), text)
  end)
end)
