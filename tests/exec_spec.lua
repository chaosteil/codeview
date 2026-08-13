local helpers = require("tests.helpers")

describe("codeview.error", function()
  local errors

  before_each(function()
    helpers.unload()
    errors = require("codeview.error")
  end)

  after_each(function()
    helpers.unload()
  end)

  it("holds the four fields of the shape", function()
    local err = errors.new(errors.codes.COMMAND_FAILED, "git failed", {
      command = { "git", "log" },
      stderr = "fatal: bad object",
    })
    assert.are.equal("command_failed", err.code)
    assert.are.equal("git failed", err.message)
    assert.are.same({ "git", "log" }, err.command)
    assert.are.equal("fatal: bad object", err.stderr)
  end)

  it("works without a command context", function()
    local err = errors.new(errors.codes.INVALID_ARG, "bad argument")
    assert.is_nil(err.command)
    assert.is_nil(err.stderr)
  end)

  it("renders one line with tostring()", function()
    local err = errors.new(errors.codes.COMMAND_FAILED, "git failed", { stderr = "fatal: bad object\nmore\n" })
    assert.are.equal("git failed: fatal: bad object", tostring(err))
  end)

  it("does not repeat the stderr that is already in the message", function()
    local err = errors.new(errors.codes.NOT_A_REPO, "no repo: /tmp", { stderr = "/tmp" })
    assert.are.equal("no repo: /tmp", tostring(err))
  end)

  it("recognizes its own values", function()
    assert.is_true(errors.is(errors.new(errors.codes.TIMEOUT, "slow")))
    assert.is_false(errors.is({ code = "timeout", message = "slow" }))
    assert.is_false(errors.is("timeout"))
  end)
end)

describe("codeview.exec", function()
  local exec, errors

  before_each(function()
    helpers.unload()
    exec = require("codeview.exec")
    errors = require("codeview.error")
  end)

  after_each(function()
    helpers.unload()
  end)

  ---@param fn fun(cb: fun(result: any?, err: codeview.Error?))
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

  it("collects stdout", function()
    local result, err = exec.run({ "printf", "hello" })
    assert.is_nil(err)
    assert.are.equal(0, result.code)
    assert.are.equal("hello", result.stdout)
    assert.are.equal("", result.stderr)
    assert.are.same({ "printf", "hello" }, result.command)
  end)

  it("runs in the given directory", function()
    local dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    local result = assert(exec.run({ "pwd" }, { cwd = dir }))
    -- `pwd` reports the real path. On macOS the temporary directory is a link.
    assert.are.equal(vim.uv.fs_realpath(dir), vim.trim(result.stdout))
    vim.fn.delete(dir, "rf")
  end)

  it("passes stdin", function()
    local result = assert(exec.run({ "cat" }, { stdin = "from stdin" }))
    assert.are.equal("from stdin", result.stdout)
  end)

  it("keeps a non-zero exit code in capture()", function()
    local result, err = exec.capture({ "sh", "-c", "echo oops >&2; exit 3" })
    assert.is_nil(err)
    assert.are.equal(3, result.code)
    assert.are.equal("oops\n", result.stderr)
  end)

  it("turns a non-zero exit code into an error in run()", function()
    local result, err = exec.run({ "sh", "-c", "echo oops >&2; exit 3" })
    assert.is_nil(result)
    assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
    assert.are.equal("oops\n", err.stderr)
    assert.is_truthy(tostring(err):find("oops", 1, true), tostring(err))
  end)

  it("reports a missing executable", function()
    local result, err = exec.run({ "codeview-no-such-command" })
    assert.is_nil(result)
    assert.are.equal(errors.codes.SPAWN_FAILED, err.code)
  end)

  it("reports a missing working directory", function()
    local result, err = exec.run({ "pwd" }, { cwd = "/codeview/no/such/directory" })
    assert.is_nil(result)
    assert.are.equal(errors.codes.SPAWN_FAILED, err.code)
  end)

  it("reports a timeout", function()
    local result, err = exec.run({ "sleep", "5" }, { timeout = 200 })
    assert.is_nil(result)
    assert.are.equal(errors.codes.TIMEOUT, err.code)
  end)

  it("reports a command that a signal stopped", function()
    local result, err = exec.capture({ "sh", "-c", "kill -9 $$" })
    assert.is_nil(result)
    assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
    assert.is_truthy(tostring(err):find("signal 9", 1, true), tostring(err))
  end)

  it("passes extra environment variables", function()
    local result = assert(exec.run({ "sh", "-c", 'printf %s "$CODEVIEW_TEST"' }, { env = { CODEVIEW_TEST = "set" } }))
    assert.are.equal("set", result.stdout)
  end)

  it("does not throw for any failure", function()
    for _, cmd in ipairs({ { "codeview-no-such-command" }, { "sh", "-c", "exit 1" } }) do
      local ok = pcall(exec.run, cmd)
      assert.is_true(ok)
    end
  end)

  it("runs asynchronously", function()
    local result, err = await(function(cb)
      exec.run({ "printf", "async" }, nil, cb)
    end)
    assert.is_nil(err)
    assert.are.equal("async", result.stdout)
  end)

  it("reports an async failure to the callback", function()
    local result, err = await(function(cb)
      exec.run({ "sh", "-c", "exit 7" }, nil, cb)
    end)
    assert.is_nil(result)
    assert.are.equal(errors.codes.COMMAND_FAILED, err.code)
  end)

  it("reports an async spawn failure to the callback", function()
    local result, err = await(function(cb)
      exec.run({ "codeview-no-such-command" }, nil, cb)
    end)
    assert.is_nil(result)
    assert.are.equal(errors.codes.SPAWN_FAILED, err.code)
  end)

  it("splits output into lines", function()
    assert.are.same({ "a", "b" }, exec.lines("a\nb\n"))
    assert.are.same({ "a", "b" }, exec.lines("a\nb"))
    assert.are.same({}, exec.lines(""))
    assert.are.same({}, exec.lines(nil))
  end)
end)
