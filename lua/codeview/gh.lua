---@brief The `gh` command-line interface of GitHub.
---
--- Every GitHub call of codeview runs through this module. It starts `gh` with
--- |codeview.exec|, reads the JSON answer, and gives a value or a
--- |codeview.Error| back. It never throws, and it never asks for a password:
--- `gh` holds the credentials of the user.
---
--- The module reports four failures with their own error code, so that a
--- caller can show one clear line:
---
--- - `unsupported`: `gh` is not in $PATH.
--- - `not_authenticated`: `gh` has no valid token for the host (HTTP 401).
--- - `offline`: the call did not reach the host.
--- - `rate_limited`: GitHub refused the call, because the rate limit is used
---   up (HTTP 403).
---
--- Another HTTP 403 is a `command_failed` error with the message of GitHub.
---
--- The module owns two policies of the API calls:
---
--- - The host. |codeview.gh.host()| reads the host from the address of a pull
---   request. `gh api` gets it with `--hostname`, so that a GitHub Enterprise
---   repository gets the token of its own host.
--- - The time limit. A call that writes gets |codeview.gh.write_timeout|.
---
--- Each function takes an optional callback as its last argument. Without a
--- callback the call blocks and returns `value, err`. With a callback the call
--- returns at once and the callback gets `value, err` on the main loop.

local config = require("codeview.config")
local errors = require("codeview.error")
local exec = require("codeview.exec")
local util = require("codeview.util")

local done = util.done

local M = {}

---Number of items that one page of a list call asks for.
---@type integer
M.per_page = 100

---Host of a pull request address that names no host.
---@type string
M.default_host = "github.com"

---Time limit of an API call that writes, in milliseconds.
---
--- A review with many comments takes GitHub more time than the default time
--- limit of |codeview.exec|. A write that the plugin kills can still reach
--- GitHub, so a write gets more time.
---@type integer
M.write_timeout = 120000

---HTTP methods that write on GitHub.
---@type table<string, boolean>
local WRITES = { POST = true, PATCH = true, PUT = true, DELETE = true }

---Environment of every gh call.
---
--- With the empty pager, `gh` does not start `less`. With the two prompt
--- variables, it does not ask a question that nobody can answer.
---@type table<string, string>
local GH_ENV = {
  GH_PAGER = "",
  PAGER = "",
  GH_PROMPT_DISABLED = "1",
  GH_NO_UPDATE_NOTIFIER = "1",
  NO_COLOR = "1",
  CLICOLOR = "0",
}

---Text of a failure, in lowercase, and the code that it stands for.
---
--- The order matters. The first list that matches gives the code.
---@type { code: codeview.ErrorCode, patterns: string[] }[]
local SIGNS = {
  {
    code = errors.codes.NOT_AUTHENTICATED,
    patterns = {
      "gh auth login",
      "not logged in",
      "no authentication token",
      "authentication token",
      "requires authentication",
      "bad credentials",
      "http 401",
    },
  },
  {
    code = errors.codes.OFFLINE,
    patterns = {
      "no such host",
      "could not resolve host",
      "temporary failure in name resolution",
      "dial tcp",
      "connection refused",
      "connection reset",
      "network is unreachable",
      "i/o timeout",
      "tls handshake timeout",
      "server misbehaving",
    },
  },
  {
    code = errors.codes.NOT_FOUND,
    patterns = {
      "http 404",
      "could not resolve to",
      "no pull requests found",
      "not found",
    },
  },
}

---@class codeview.gh.Opts
---@field cwd string? Working directory of the call.
---@field timeout integer? Milliseconds before the plugin kills the command.
---@field env table<string, string>? Extra environment variables.
---@field stdin string? Text for the standard input of gh.

---@class codeview.gh.ApiOpts: codeview.gh.Opts
---@field hostname string? Host of the GitHub server, for `--hostname`. See |codeview.gh.host()|.
---@field method string? HTTP method. GET by default.
---@field fields string[]? `name=value` pairs for `--field`.
---@field headers string[]? `Name: value` pairs for `--header`.
---@field input string? Source of the request body for `--input`. `-` reads the `stdin` text.
---@field per_page integer? Number of items of one page in a list call.
---@field max_pages integer? Highest number of pages that a list call reads.
---@field max integer? Highest number of items that a list call keeps.

---Name or path of the gh executable, from the configuration.
---@return string binary
function M.binary()
  return config.get().github.binary
end

---Report whether gh is in $PATH.
---@return boolean
function M.available()
  return vim.fn.executable(M.binary()) == 1
end

---Error for a missing executable.
---@return codeview.Error
local function missing()
  return errors.new(errors.codes.UNSUPPORTED, "the gh CLI is not in $PATH", {
    stderr = "install gh from https://cli.github.com and log in with `gh auth login`",
  })
end

---@class codeview.gh.Response
---@field status integer? HTTP status code. Nil when the text holds no head.
---@field headers table<string, string> Headers of the answer, by lowercase name.
---@field body string Body of the answer.

---Split the output of `gh api --include` into the head and the body.
---
--- A text without a head is the body alone.
---@param text string? Standard output of a gh call.
---@return codeview.gh.Response response
function M.response(text)
  text = text or ""
  if not text:match("^HTTP/") then
    return { status = nil, headers = {}, body = text }
  end
  local head, body = text:match("^(.-)\r?\n\r?\n(.*)$")
  if not head then
    head, body = text, ""
  end
  local lines = vim.split(head, "\r?\n")
  local headers = {}
  for index = 2, #lines do
    local name, value = lines[index]:match("^([^:]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return { status = tonumber(lines[1]:match("^HTTP/%S+%s+(%d+)")), headers = headers, body = body }
end

---Message of GitHub in a failed call.
---@param result codeview.ExecResult
---@param response codeview.gh.Response
---@return string message
local function github_message(result, response)
  local ok, value = pcall(vim.json.decode, response.body, { luanil = { object = true, array = true } })
  if ok and type(value) == "table" and type(value.message) == "string" and value.message ~= "" then
    return value.message
  end
  local line = vim.split(vim.trim(result.stderr or ""), "\n", { plain = true })[1] or ""
  line = vim.trim((line:gsub("^gh:%s*", "")))
  return line ~= "" and line or string.format("gh exited with code %d", result.code)
end

---Read the reason of a failed call.
---@param result codeview.ExecResult
---@return codeview.Error
local function classify(result)
  local text = ((result.stderr or "") .. "\n" .. (result.stdout or "")):lower()
  local response = M.response(result.stdout)
  local status = response.status or tonumber((result.stderr or ""):match("%(HTTP (%d+)%)"))
  if status == 403 then
    if response.headers["x-ratelimit-remaining"] == "0" or text:find("rate limit", 1, true) then
      return errors.new(errors.codes.RATE_LIMITED, "gh: " .. M.reason(errors.codes.RATE_LIMITED), {
        command = result.command,
        stderr = result.stderr,
      })
    end
    return errors.new(errors.codes.COMMAND_FAILED, "gh: " .. github_message(result, response), {
      command = result.command,
      stderr = result.stderr,
    })
  end
  for _, sign in ipairs(SIGNS) do
    for _, pattern in ipairs(sign.patterns) do
      if text:find(pattern, 1, true) then
        return errors.new(sign.code, "gh: " .. M.reason(sign.code), {
          command = result.command,
          stderr = result.stderr,
        })
      end
    end
  end
  return errors.new(errors.codes.COMMAND_FAILED, string.format("gh exited with code %d", result.code), {
    command = result.command,
    stderr = result.stderr,
  })
end

---One line that says what a failure code means for gh.
---@param code codeview.ErrorCode
---@return string
function M.reason(code)
  if code == errors.codes.NOT_AUTHENTICATED then
    return "no valid GitHub credentials. Run `gh auth login`"
  end
  if code == errors.codes.OFFLINE then
    return "cannot reach github.com"
  end
  if code == errors.codes.NOT_FOUND then
    return "GitHub does not know this object"
  end
  if code == errors.codes.RATE_LIMITED then
    return "the rate limit of GitHub is used up. Wait, then try again"
  end
  return "the call failed"
end

---Run one gh command.
---@param args string[] Arguments after `gh`.
---@param opts? codeview.gh.Opts
---@param cb? fun(result: codeview.ExecResult?, err: codeview.Error?) Callback for the async form.
---@return codeview.ExecResult? result Nil after any failure.
---@return codeview.Error? err
function M.run(args, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
  if type(args) ~= "table" or #args == 0 then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the call needs gh arguments"))
  end
  if not M.available() then
    return done(cb, nil, missing())
  end

  local cmd = vim.list_extend({ M.binary() }, args)
  local exec_opts = {
    cwd = opts.cwd,
    timeout = opts.timeout,
    stdin = opts.stdin,
    env = vim.tbl_extend("force", GH_ENV, opts.env or {}),
  }

  ---@param result codeview.ExecResult?
  ---@param err codeview.Error?
  ---@return codeview.ExecResult?, codeview.Error?
  local function handle(result, err)
    if not result then
      return nil, err
    end
    if result.code ~= 0 then
      return nil, classify(result)
    end
    return result, nil
  end

  if cb then
    exec.capture(cmd, exec_opts, function(result, err)
      cb(handle(result, err))
    end)
    return nil, nil
  end
  return handle(exec.capture(cmd, exec_opts))
end

---Read the JSON text of a gh answer.
---@param text string? Standard output of a gh call.
---@return any? value Nil after a decode error. An empty text gives nil without an error.
---@return codeview.Error? err
function M.decode(text)
  local trimmed = vim.trim(text or "")
  if trimmed == "" then
    return nil, nil
  end
  -- `luanil` maps a JSON null to nil, so a missing line reads as nil and not
  -- as `vim.NIL`.
  local ok, value = pcall(vim.json.decode, trimmed, { luanil = { object = true, array = true } })
  if not ok then
    return nil,
      errors.new(errors.codes.COMMAND_FAILED, "gh: the answer is not JSON", { stderr = tostring(value):sub(1, 200) })
  end
  return value, nil
end

---Run one gh command and read its JSON answer.
---@param args string[] Arguments after `gh`.
---@param opts? codeview.gh.Opts
---@param cb? fun(value: any?, err: codeview.Error?) Callback for the async form.
---@param body? fun(stdout: string): string Reads the JSON text out of the standard output.
---@return any? value
---@return codeview.Error? err
local function run_json(args, opts, cb, body)
  ---@param result codeview.ExecResult?
  ---@param err codeview.Error?
  ---@return any?, codeview.Error?
  local function handle(result, err)
    if not result then
      return nil, err
    end
    local text = result.stdout or ""
    local value, decode_err = M.decode(body and body(text) or text)
    if decode_err then
      return nil, decode_err
    end
    if value == nil then
      return nil, errors.new(errors.codes.NOT_FOUND, "gh: the answer is empty", { command = result.command })
    end
    return value, nil
  end

  if cb then
    M.run(args, opts, function(result, err)
      cb(handle(result, err))
    end)
    return nil, nil
  end
  return handle(M.run(args, opts))
end

---Run one gh command and read its JSON answer.
---@param args string[] Arguments after `gh`.
---@param opts? codeview.gh.Opts
---@param cb? fun(value: any?, err: codeview.Error?) Callback for the async form.
---@return any? value
---@return codeview.Error? err
function M.json(args, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  return run_json(args, opts, cb)
end

---Host of an address of GitHub.
---
--- A GitHub Enterprise server holds its pull requests under its own name, so
--- the host of the pull request address decides the host of every API call.
---@param url string? Address, for example of a pull request.
---@return string host Lowercase. |codeview.gh.default_host| when the address names no host.
function M.host(url)
  local host = tostring(url or ""):match("^%a[%w+.-]*://([^/?#]+)")
  if not host then
    return M.default_host
  end
  host = host:gsub("^.*@", ""):gsub(":%d+$", ""):lower()
  return host ~= "" and host or M.default_host
end

---Arguments of one `gh api` call.
---
--- `--include` puts the head of the answer before the body, so that a failure
--- can read the rate limit headers.
---@param path string Path of the endpoint, for example `repos/o/n/pulls/1`.
---@param opts codeview.gh.ApiOpts
---@return string[] args
local function api_args(path, opts)
  local args = { "api", path, "--include" }
  if opts.hostname and opts.hostname ~= "" then
    vim.list_extend(args, { "--hostname", opts.hostname })
  end
  if opts.method and opts.method ~= "" then
    vim.list_extend(args, { "--method", opts.method:upper() })
  end
  for _, header in ipairs(opts.headers or {}) do
    vim.list_extend(args, { "--header", header })
  end
  for _, field in ipairs(opts.fields or {}) do
    vim.list_extend(args, { "--field", field })
  end
  if opts.input and opts.input ~= "" then
    vim.list_extend(args, { "--input", opts.input })
  end
  return args
end

---Call one endpoint of the GitHub API.
---
--- A call that writes gets |codeview.gh.write_timeout| when `opts.timeout` is
--- not set.
---@param path string Path of the endpoint, for example `repos/o/n/pulls/1`.
---@param opts? codeview.gh.ApiOpts
---@param cb? fun(value: any?, err: codeview.Error?) Callback for the async form.
---@return any? value Decoded JSON answer.
---@return codeview.Error? err
function M.api(path, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
  if type(path) ~= "string" or vim.trim(path) == "" then
    return done(cb, nil, errors.new(errors.codes.INVALID_ARG, "the call needs an API path"))
  end
  if opts.timeout == nil and WRITES[(opts.method or ""):upper()] then
    opts = vim.tbl_extend("force", opts, { timeout = M.write_timeout })
  end
  return run_json(api_args(path, opts), opts, cb, function(stdout)
    return M.response(stdout).body
  end)
end

---Add a query parameter to a path.
---@param path string
---@param name string
---@param value string|integer
---@return string
local function with_query(path, name, value)
  local sep = path:find("?", 1, true) and "&" or "?"
  return string.format("%s%s%s=%s", path, sep, name, tostring(value))
end

---Read every page of a list endpoint.
---
--- The call asks for one page after the other and stops at the first short
--- page. It does not use `--paginate`, because that option writes one JSON
--- document per page.
---@param path string Path of the endpoint.
---@param opts? codeview.gh.ApiOpts
---@param cb? fun(items: any[]?, err: codeview.Error?) Callback for the async form.
---@return any[]? items Entries of every page, in the order of the answer.
---@return codeview.Error? err
function M.api_list(path, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
  local per_page = math.max(math.min(opts.per_page or M.per_page, 100), 1)
  local max_pages = math.max(opts.max_pages or 10, 1)
  local max = opts.max

  local items = {}

  ---Keep the entries of one page.
  ---@param value any Answer of one page.
  ---@return boolean more True while another page can hold entries.
  local function keep(value)
    if type(value) ~= "table" or not vim.islist(value) then
      return false
    end
    for _, item in ipairs(value) do
      if max and #items >= max then
        return false
      end
      items[#items + 1] = item
    end
    return #value >= per_page
  end

  ---@param page integer
  ---@return string
  local function page_path(page)
    return with_query(with_query(path, "per_page", per_page), "page", page)
  end

  if not cb then
    for page = 1, max_pages do
      local value, err = M.api(page_path(page), opts)
      if not value then
        return nil, err
      end
      if not keep(value) then
        return items, nil
      end
    end
    return items, nil
  end

  local page = 0
  local function step()
    page = page + 1
    if page > max_pages then
      cb(items, nil)
      return
    end
    M.api(page_path(page), opts, function(value, err)
      if not value then
        cb(nil, err)
        return
      end
      if keep(value) then
        step()
      else
        cb(items, nil)
      end
    end)
  end
  step()
  return nil, nil
end

---@class codeview.gh.Auth
---@field ok boolean True when gh holds a valid token.
---@field host string Host that the token belongs to. Empty when unknown.
---@field account string Name of the account. Empty when unknown.
---@field text string First line of the report of gh.

---Read the login state of gh.
---
--- The call runs `gh auth status`. A failure is not an error of the plugin, so
--- the answer reports `ok = false` with the text of gh, and the error value
--- carries the reason.
---@param opts? codeview.gh.Opts
---@param cb? fun(auth: codeview.gh.Auth?, err: codeview.Error?) Callback for the async form.
---@return codeview.gh.Auth? auth Nil when gh is not in $PATH.
---@return codeview.Error? err Set when gh reports no valid login.
function M.auth_status(opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  opts = opts or {}
  if not M.available() then
    return done(cb, nil, missing())
  end

  local cmd = { M.binary(), "auth", "status" }
  local exec_opts = {
    cwd = opts.cwd,
    timeout = opts.timeout,
    env = vim.tbl_extend("force", GH_ENV, opts.env or {}),
  }

  ---@param result codeview.ExecResult?
  ---@param err codeview.Error?
  ---@return codeview.gh.Auth?, codeview.Error?
  local function handle(result, err)
    if not result then
      return nil, err
    end
    -- `gh auth status` writes its report to stdout, and older versions write
    -- it to stderr. Read both.
    local text = vim.trim((result.stdout or "") .. "\n" .. (result.stderr or ""))
    local first = vim.split(text, "\n", { plain = true })[1] or ""
    local account = text:match("Logged in to [%w%.%-]+ account ([%w%-_%.]+)") or ""
    local host = text:match("Logged in to ([%w%.%-]+) account") or vim.trim(first)
    ---@type codeview.gh.Auth
    local auth = {
      ok = result.code == 0,
      host = result.code == 0 and host or "",
      account = account,
      text = vim.trim(first),
    }
    if result.code ~= 0 then
      return auth, classify(result)
    end
    return auth, nil
  end

  if cb then
    exec.capture(cmd, exec_opts, function(result, err)
      cb(handle(result, err))
    end)
    return nil, nil
  end
  return handle(exec.capture(cmd, exec_opts))
end

return M
