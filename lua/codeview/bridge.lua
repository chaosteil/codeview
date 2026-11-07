---@brief Send chosen comments of a pull request for another tool.
---
--- Another tool, for example chaoshub, shows the comments of codeview and lets
--- the user choose some of them. The tool then runs codeview in a headless
--- Neovim, in the repository: >
---
---     nvim --headless -c "lua require('codeview.bridge').submit_file('<path>')"
--- <
--- The file at `<path>` holds the request, as JSON: >json
---
---     {
---       "version": 1,
---       "repo": "owner/name",
---       "number": 14,
---       "head": "<sha>",
---       "ids": ["..."],
---       "event": "comment",
---       "body": "...",
---       "out": "<result path>"
---     }
--- <
--- `event` is "comment", "approve", or "request-changes". The call opens the
--- pull request session without the layout. It stops with an error when the
--- head of the pull request is not `head`, because the comments then belong
--- to another push. It then runs |codeview.submit.run()| with `ids`, without
--- questions. The tool asked the user already.
---
--- The call writes the result atomically to `out`, as JSON: >json
---
---     {
---       "version": 1,
---       "ok": true,
---       "posted": 3,
---       "skipped": [{ "id": "...", "reason": "..." }],
---       "already_sent": ["..."],
---       "url": "...",
---       "error": ""
---     }
--- <
--- A chosen draft reply goes into its thread on GitHub, and `posted` counts
--- it. `skipped` holds the comments that stay local, with the reason.
--- `already_sent` holds the chosen comments that went out already. When every
--- chosen comment went out already, the call posts nothing, and the result has
--- `ok = true` and `posted = 0`. When another codeview holds the lock of the
--- comments, the result has `ok = false` and the error of the lock.
---
--- The call then closes the session and quits Neovim. The exit code is 0 when
--- `ok` is true, else 1. Every error, also a Lua error, writes a result with
--- `ok = false` and the text of the error.

local fsutil = require("codeview.fsutil")

local M = {}

---Version of the request and of the result.
---@type integer
M.version = 1

---Quit Neovim with an exit code.
---
--- Replace the function only in a test.
---@param code integer 0 or 1.
function M.exit(code)
  if code == 0 then
    vim.cmd("qall!")
  else
    vim.cmd("cquit 1")
  end
end

---@class codeview.bridge.Request
---@field version integer
---@field repo string Repository as `owner/name`.
---@field number integer Number of the pull request.
---@field head string Head commit that the comments belong to.
---@field ids string[] Ids of the comments to send.
---@field event string Event of the review.
---@field body string Text of the review.
---@field out string Path of the result file.

---Read the request file.
---@param path string
---@return table? request
---@return string? err
local function read_request(path)
  local handle, open_err = io.open(path, "rb")
  if not handle then
    return nil, "cannot read the request " .. tostring(path) .. ": " .. tostring(open_err)
  end
  local text = handle:read("*a") or ""
  handle:close()
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(value) ~= "table" then
    return nil, "the request is no JSON object: " .. tostring(path)
  end
  return value, nil
end

---Check the fields of a request.
---@param request table
---@return string? err Nil for a valid request.
local function check(request)
  if request.version ~= M.version then
    return "the request has version " .. tostring(request.version) .. ", not " .. M.version
  end
  if type(request.repo) ~= "string" or not request.repo:match("^[^/]+/[^/]+$") then
    return "the request needs repo as owner/name"
  end
  if type(request.number) ~= "number" or request.number < 1 then
    return "the request needs the number of the pull request"
  end
  if type(request.head) ~= "string" or request.head == "" then
    return "the request needs the head commit"
  end
  if type(request.ids) ~= "table" then
    return "the request needs a list of ids"
  end
  for _, id in ipairs(request.ids) do
    if type(id) ~= "string" then
      return "every id of the request must be a string"
    end
  end
  if type(request.event) ~= "string" or not require("codeview.submit").normalize_event(request.event) then
    return "the request needs an event: comment, approve, or request-changes"
  end
  if request.body ~= nil and type(request.body) ~= "string" then
    return "the body of the request must be a string"
  end
  return nil
end

---Send the comments of a request file, write the result, and quit.
---
--- The call returns at once. The work runs on the main loop, and the call
--- quits Neovim at the end with |codeview.bridge.exit()|.
---@param request_path string Path of the request file.
function M.submit_file(request_path)
  ---@type string?
  local out
  ---@type codeview.Session?
  local session
  local finished = false

  ---Write the result, close the session, and quit.
  ---@param fields table
  local function finish(fields)
    if finished then
      return
    end
    finished = true
    local result = {
      version = M.version,
      ok = fields.ok == true,
      posted = fields.posted or 0,
      skipped = fields.skipped or {},
      already_sent = fields.already_sent or {},
      url = fields.url or "",
      error = fields.error or "",
    }
    if session then
      pcall(session.close, session)
    end
    local written, write_err = false, nil
    if out then
      written, write_err = fsutil.write_atomic(out, vim.json.encode(result) .. "\n")
    end
    if not written then
      io.stderr:write(
        "codeview: "
          .. (result.error ~= "" and result.error or "no result file")
          .. (write_err and ("\ncodeview: " .. tostring(write_err)) or "")
          .. "\n"
      )
      result.ok = false
    end
    M.exit(result.ok and 0 or 1)
  end

  ---@param text string
  local function fail(text)
    finish({ ok = false, error = text })
  end

  ---Run a function, and turn a Lua error into a failed result.
  ---@param fn function
  ---@return function
  local function guard(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then
        fail(tostring(err))
      end
    end
  end

  guard(function()
    local request, read_err = read_request(request_path)
    if not request then
      fail(read_err --[[@as string]])
      return
    end
    if type(request.out) == "string" and request.out ~= "" then
      out = request.out
    end
    local check_err = check(request)
    if check_err then
      fail(check_err)
      return
    end
    if not out then
      fail("the request needs the path of the result file")
      return
    end

    local opts = { dir = vim.uv.cwd(), repo = request.repo, comments = false }
    require("codeview.pr").open(
      math.floor(request.number),
      opts,
      guard(function(opened, open_err)
        if not opened then
          fail(tostring(open_err or "the pull request did not open"))
          return
        end
        session = opened
        local head = tostring((opened.pr or {}).head_sha or "")
        if head ~= request.head then
          fail(
            string.format(
              "the head of PR #%d is %s, not %s. The comments belong to another push",
              request.number,
              head,
              request.head
            )
          )
          return
        end
        local submit = require("codeview.submit")
        submit.run(
          {
            session = opened,
            ids = request.ids,
            event = request.event,
            body = request.body or "",
            confirm = false,
            notify = false,
          },
          guard(function(result, run_err)
            if not result then
              fail(run_err and submit.error_text(run_err) or "the submit gave no answer")
              return
            end
            finish({
              ok = true,
              posted = result.posted,
              skipped = result.stays_local,
              already_sent = result.already_sent,
              url = result.url,
            })
          end)
        )
      end)
    )
  end)()
end

return M
