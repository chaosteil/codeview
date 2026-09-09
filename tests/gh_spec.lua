local helpers = require("tests.helpers")

describe("codeview.gh", function()
  local exec, gh, errors
  ---@type { cmd: string[], opts: table }[]
  local calls

  ---Answer every gh call with one scripted result.
  ---@param fn fun(cmd: string[], index: integer): table
  local function respond(fn)
    exec.capture = function(cmd, opts, cb) ---@diagnostic disable-line: duplicate-set-field
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      local answer = fn(cmd, #calls)
      local result = {
        command = cmd,
        code = answer.code or 0,
        signal = 0,
        stdout = answer.stdout or "",
        stderr = answer.stderr or "",
      }
      if cb then
        vim.schedule(function()
          cb(result, nil)
        end)
        return nil, nil
      end
      return result, nil
    end
  end

  ---Wait for the answer of an async call.
  ---@param fn fun(cb: fun(value: any?, err: any?))
  ---@return any value
  ---@return any err
  local function await(fn)
    local out, finished = {}, false
    fn(function(value, err)
      out.value, out.err, finished = value, err, true
    end)
    assert.is_true(
      vim.wait(5000, function()
        return finished
      end, 5),
      "the gh call did not answer"
    )
    return out.value, out.err
  end

  before_each(function()
    helpers.unload()
    exec = require("codeview.exec")
    gh = require("codeview.gh")
    errors = require("codeview.error")
    calls = {}
    -- The tests never run gh itself. They only check the command line and the
    -- answer, so the check for the executable always says yes.
    gh.available = function() ---@diagnostic disable-line: duplicate-set-field
      return true
    end
  end)

  after_each(function()
    helpers.unload()
  end)

  describe("run", function()
    it("puts gh in front of the arguments", function()
      respond(function()
        return { stdout = "ok\n" }
      end)
      local result = assert(gh.run({ "pr", "view", "12" }))
      assert.are.same({ "gh", "pr", "view", "12" }, calls[1].cmd)
      assert.are.equal("ok\n", result.stdout)
    end)

    it("takes the name of the executable from the configuration", function()
      assert(require("codeview.config").setup({ github = { binary = "gh-custom" } }))
      respond(function()
        return { stdout = "ok\n" }
      end)
      assert(gh.run({ "pr", "view", "12" }))
      assert.are.equal("gh-custom", calls[1].cmd[1])
    end)

    it("keeps the pager out of the environment", function()
      respond(function()
        return {}
      end)
      gh.run({ "pr", "list" })
      assert.are.equal("", calls[1].opts.env.GH_PAGER)
      assert.are.equal("1", calls[1].opts.env.GH_PROMPT_DISABLED)
    end)

    it("rejects a call without arguments", function()
      local result, err = gh.run({})
      assert.is_nil(result)
      assert.are.equal(errors.codes.INVALID_ARG, err.code)
    end)

    it("reports a missing executable", function()
      gh.available = function() ---@diagnostic disable-line: duplicate-set-field
        return false
      end
      local result, err = gh.run({ "pr", "view" })
      assert.is_nil(result)
      assert.are.equal(errors.codes.UNSUPPORTED, err.code)
      assert.is_truthy(tostring(err):find("gh", 1, true))
    end)

    it("reports a missing login", function()
      respond(function()
        return { code = 4, stderr = "To get started with GitHub CLI, please run:  gh auth login\n" }
      end)
      local result, err = gh.run({ "pr", "view", "12" })
      assert.is_nil(result)
      assert.are.equal(errors.codes.NOT_AUTHENTICATED, err.code)
      assert.is_truthy(tostring(err):find("gh auth login", 1, true))
    end)

    it("reports a host that it cannot reach", function()
      respond(function()
        return { code = 1, stderr = "error connecting to api.github.com: dial tcp: lookup api.github.com: no such host" }
      end)
      local _, err = gh.run({ "api", "repos/o/n" })
      assert.are.equal(errors.codes.OFFLINE, err.code)
    end)

    it("reports an object that GitHub does not know", function()
      respond(function()
        return { code = 1, stderr = "gh: Not Found (HTTP 404)" }
      end)
      local _, err = gh.run({ "api", "repos/o/n/pulls/9999" })
      assert.are.equal(errors.codes.NOT_FOUND, err.code)
    end)

    it("reports another failure with the exit code", function()
      respond(function()
        return { code = 3, stderr = "unknown flag: --nope" }
      end)
      local _, err = gh.run({ "pr", "view", "--nope" })
      assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
      assert.is_truthy(tostring(err):find("unknown flag", 1, true))
    end)

    it("answers through a callback", function()
      respond(function()
        return { stdout = "async\n" }
      end)
      local result, err = await(function(cb)
        gh.run({ "pr", "view" }, cb)
      end)
      assert.is_nil(err)
      assert.are.equal("async\n", result.stdout)
    end)
  end)

  describe("json", function()
    it("reads the answer", function()
      respond(function()
        return { stdout = '{"number":12,"title":"a title"}' }
      end)
      local value = assert(gh.json({ "pr", "view", "12", "--json", "number" }))
      assert.are.equal(12, value.number)
      assert.are.equal("a title", value.title)
    end)

    it("maps a JSON null to nil", function()
      local value = assert(gh.decode('{"line":null,"path":"a.lua"}'))
      assert.is_nil(value.line)
      assert.are.equal("a.lua", value.path)
    end)

    it("reports text that is not JSON", function()
      respond(function()
        return { stdout = "not json" }
      end)
      local value, err = gh.json({ "pr", "view" })
      assert.is_nil(value)
      assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
    end)

    it("reports an empty answer", function()
      respond(function()
        return { stdout = "" }
      end)
      local value, err = gh.json({ "pr", "view" })
      assert.is_nil(value)
      assert.are.equal(errors.codes.NOT_FOUND, err.code)
    end)
  end)

  describe("api", function()
    it("builds the call of one endpoint", function()
      respond(function()
        return { stdout = "{}" }
      end)
      gh.api("repos/o/n/pulls/12", { method = "get", headers = { "Accept: application/json" }, fields = { "a=b" } })
      assert.are.same({
        "gh",
        "api",
        "repos/o/n/pulls/12",
        "--method",
        "GET",
        "--header",
        "Accept: application/json",
        "--field",
        "a=b",
      }, calls[1].cmd)
    end)

    it("rejects a call without a path", function()
      local value, err = gh.api("")
      assert.is_nil(value)
      assert.are.equal(errors.codes.INVALID_ARG, err.code)
    end)
  end)

  describe("api_list", function()
    it("reads one page after the other", function()
      respond(function(cmd)
        local path = cmd[3]
        if path:find("page=1", 1, true) then
          return { stdout = '[{"id":1},{"id":2}]' }
        end
        return { stdout = '[{"id":3}]' }
      end)
      local items = assert(gh.api_list("repos/o/n/pulls/12/comments", { per_page = 2 }))
      assert.are.equal(3, #items)
      assert.are.equal(3, items[3].id)
      assert.are.equal(2, #calls)
      assert.is_truthy(calls[1].cmd[3]:find("per_page=2", 1, true))
    end)

    it("stops at the first short page", function()
      respond(function()
        return { stdout = '[{"id":1}]' }
      end)
      local items = assert(gh.api_list("repos/o/n/pulls/12/comments", { per_page = 2 }))
      assert.are.equal(1, #items)
      assert.are.equal(1, #calls)
    end)

    it("keeps no more items than the limit", function()
      respond(function()
        return { stdout = '[{"id":1},{"id":2}]' }
      end)
      local items = assert(gh.api_list("repos/o/n/pulls/12/comments", { per_page = 2, max = 1 }))
      assert.are.equal(1, #items)
      assert.are.equal(1, #calls)
    end)

    it("adds the page to a path that holds a query", function()
      respond(function()
        return { stdout = "[]" }
      end)
      gh.api_list("repos/o/n/pulls/12/comments?sort=created", { per_page = 2 })
      assert.is_truthy(calls[1].cmd[3]:find("?sort=created&per_page=2&page=1", 1, true), calls[1].cmd[3])
    end)

    it("answers through a callback", function()
      respond(function()
        return { stdout = '[{"id":7}]' }
      end)
      local items, err = await(function(cb)
        gh.api_list("repos/o/n/pulls/12/comments", { per_page = 2 }, cb)
      end)
      assert.is_nil(err)
      assert.are.equal(7, items[1].id)
    end)
  end)

  describe("auth_status", function()
    it("reads the account of a login", function()
      respond(function()
        return { stdout = "github.com\n  ✓ Logged in to github.com account ada (keyring)\n" }
      end)
      local auth, err = gh.auth_status()
      assert.is_nil(err)
      assert.is_true(auth.ok)
      assert.are.equal("github.com", auth.host)
      assert.are.equal("ada", auth.account)
      assert.are.same({ "gh", "auth", "status" }, calls[1].cmd)
    end)

    it("reports that nobody is logged in", function()
      respond(function()
        return { code = 1, stderr = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n" }
      end)
      local auth, err = gh.auth_status()
      assert.is_false(auth.ok)
      assert.are.equal(errors.codes.NOT_AUTHENTICATED, err.code)
    end)

    it("reports a missing executable", function()
      gh.available = function() ---@diagnostic disable-line: duplicate-set-field
        return false
      end
      local auth, err = gh.auth_status()
      assert.is_nil(auth)
      assert.are.equal(errors.codes.UNSUPPORTED, err.code)
    end)
  end)
end)
