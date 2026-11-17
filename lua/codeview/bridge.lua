---@brief Send chosen comments of a pull request for another tool.
---
--- Another tool, for example chaoshub, shows the comments of codeview and lets
--- the user choose some of them. The tool then runs codeview in a headless
--- Neovim, in the repository: >
---
---     nvim --headless -c "lua require('codeview.bridge').submit_file('<path>')"
--- <
--- The file at `<path>` holds the request, as JSON. Version 2 names the
--- chosen comments per push of the head: >json
---
---     {
---       "version": 2,
---       "repo": "owner/name",
---       "number": 14,
---       "pushes": [{ "head": "<sha>", "ids": ["..."] }],
---       "event": "comment",
---       "body": "...",
---       "out": "<result path>"
---     }
--- <
--- Version 1 has `head` and `ids` in place of `pushes`, for one push. With
--- version 1, the call stops with an error when the head of the pull request
--- is not `head`, because the comments then belong to another push.
---
--- `event` is "comment", "approve", or "request-changes". The call opens the
--- pull request session without the layout. It sends the comments without
--- questions, because the tool asked the user already.
---
--- The comments of an older push go out first. GitHub takes one commit for
--- each review, so each older push gets its own review of the comment event,
--- on the head commit of that push. That review has no text, because the
--- call adds no text that the user did not write. Each comment then stays on
--- the lines that it was written for, and GitHub shows it as outdated when a
--- later push changed these lines. When GitHub refuses such a review, the
--- call stops, and the review with the event does not go out.
---
--- The comments of the current head then go out with |codeview.submit.run()|,
--- in the review with the event and the text. When that review did not go
--- out, but other comments did, the call posts the review with only the
--- event and the text. So an approval never stays behind.
---
--- A comment goes out once. Before each push, the call reads the session file
--- of the push and keeps every chosen comment with a sent mark out of the
--- send. |codeview.submit.run()| also finds a comment that GitHub holds
--- already. When no chosen comment goes out because every one went out
--- already, the call posts the review with only the event and the text, the
--- same as above.
---
--- The call writes the result atomically to `out`, as JSON: >json
---
---     {
---       "version": 2,
---       "ok": true,
---       "posted": 3,
---       "older": 1,
---       "skipped": [{ "id": "...", "reason": "..." }],
---       "already_sent": ["..."],
---       "reviewed": true,
---       "url": "...",
---       "error": ""
---     }
--- <
--- `version` is the version of the request. A chosen draft reply goes into its
--- thread on GitHub, and `posted` counts it. `older` is the part of `posted`
--- that went out on older pushes. `skipped` holds the comments that stay
--- local, with the reason. `already_sent` holds the chosen comments that went
--- out already. `reviewed` is true when the review with the event went out.
--- When every chosen comment went out already, the call posts no comment, and
--- the result has `ok = true` and `posted = 0`. When another
--- codeview holds the lock of the comments, the result has `ok = false` and
--- the error of the lock.
---
--- The call then closes the session and quits Neovim. The exit code is 0 when
--- `ok` is true, else 1. Every error, also a Lua error, writes a result with
--- `ok = false` and the text of the error.

local fsutil = require("codeview.fsutil")
local store_mod = require("codeview.store")

local M = {}

---Newest version of the request and of the result.
---@type integer
M.version = 2

---Versions of the request that the call reads.
---@type table<integer, boolean>
M.versions = { [1] = true, [2] = true }

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

---@class codeview.bridge.Push
---@field head string Head commit of the push.
---@field ids string[] Ids of the comments of the push to send.

---@class codeview.bridge.Request
---@field version integer
---@field repo string Repository as `owner/name`.
---@field number integer Number of the pull request.
---@field head string? Version 1: head commit that the comments belong to.
---@field ids string[]? Version 1: ids of the comments to send.
---@field pushes codeview.bridge.Push[]? Version 2: the chosen comments per push.
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

---Check a head commit and a list of ids.
---@param head any
---@param ids any
---@param where string Name of the part of the request, for the error.
---@return string? err Nil for a valid pair.
local function check_push(head, ids, where)
  if type(head) ~= "string" or head == "" then
    return where .. " needs the head commit"
  end
  if type(ids) ~= "table" then
    return where .. " needs a list of ids"
  end
  for _, id in ipairs(ids) do
    if type(id) ~= "string" then
      return "every id of " .. where .. " must be a string"
    end
  end
  return nil
end

---Check the fields of a request.
---@param request table
---@return string? err Nil for a valid request.
local function check(request)
  if not M.versions[request.version] then
    return "the request has version " .. tostring(request.version) .. ", not 1 or " .. M.version
  end
  if type(request.repo) ~= "string" or not request.repo:match("^[^/]+/[^/]+$") then
    return "the request needs repo as owner/name"
  end
  if type(request.number) ~= "number" or request.number < 1 then
    return "the request needs the number of the pull request"
  end
  if request.version == 1 then
    local push_err = check_push(request.head, request.ids, "the request")
    if push_err then
      return push_err
    end
  else
    if type(request.pushes) ~= "table" then
      return "the request needs a list of pushes"
    end
    for index, push in ipairs(request.pushes) do
      if type(push) ~= "table" then
        return "every push of the request must be an object"
      end
      local push_err = check_push(push.head, push.ids, "push " .. index)
      if push_err then
        return push_err
      end
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

---The chosen comments of a request, per push.
---@param request table A checked request.
---@return codeview.bridge.Push[] pushes
local function pushes_of(request)
  if request.version == 1 then
    return { { head = request.head, ids = request.ids } }
  end
  return request.pushes
end

---First 7 characters of a commit id.
---@param sha string
---@return string
local function short(sha)
  return sha:sub(1, 7)
end

---Split the chosen ids of a push into the ids to send and the ids that went
---out already.
---
--- A comment with a sent mark in the session file never goes out again. An id
--- that the store does not hold stays in the ids to send, so that the submit
--- reports it.
---@param store codeview.store.Store? Comment store of the push. Nil sends every id.
---@param ids string[]
---@return string[] unsent
---@return string[] sent
local function split_sent(store, ids)
  local unsent, sent = {}, {}
  for _, id in ipairs(ids) do
    local comment = store and store:get(id)
    if comment and store_mod.is_synced(comment) then
      sent[#sent + 1] = id
    else
      unsent[#unsent + 1] = id
    end
  end
  return unsent, sent
end

---`1 comment` or `N comments`.
---@param count integer
---@return string
local function comments_text(count)
  return string.format("%d %s", count, count == 1 and "comment" or "comments")
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
  local version = M.version
  ---Sums of the sends so far.
  local sums = { posted = 0, older = 0, skipped = {}, already_sent = {} }

  ---Add the result of one send to the sums.
  ---@param result codeview.submit.Result
  ---@param older boolean True for a send of an older push.
  local function add(result, older)
    sums.posted = sums.posted + (result.posted or 0)
    if older then
      sums.older = sums.older + (result.posted or 0)
    end
    vim.list_extend(sums.skipped, result.stays_local or {})
    vim.list_extend(sums.already_sent, result.already_sent or {})
  end

  ---Write the result, close the session, and quit.
  ---@param fields table
  local function finish(fields)
    if finished then
      return
    end
    finished = true
    local result = {
      version = version,
      ok = fields.ok == true,
      posted = sums.posted,
      older = sums.older,
      skipped = sums.skipped,
      already_sent = sums.already_sent,
      reviewed = fields.reviewed == true,
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
    if M.versions[request.version] then
      version = request.version
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

    local pr = require("codeview.pr")
    local session_mod = require("codeview.session")
    local submit = require("codeview.submit")
    local event = submit.normalize_event(request.event) --[[@as string]]
    local body = request.body or ""

    ---Send the comments of the current head, then the review with the event
    ---when it did not go out yet.
    ---@param current codeview.Session Session of the current head.
    ---@param ids string[] Ids of the comments of the current head.
    local function send_current(current, ids)
      session = current
      local info = current.pr --[[@as codeview.pr.Info]]

      ---@param result codeview.submit.Result?
      local function after(result)
        if result then
          add(result, false)
          if result.unsaved then
            fail(
              string.format(
                "%s went out, but codeview did not mark them as sent: %s",
                comments_text(sums.posted),
                result.unsaved
              )
            )
            return
          end
        end
        local reviewed = result ~= nil and result.review ~= nil
        local wanted = event ~= "comment" or vim.trim(body) ~= ""
        -- No chosen comment went out, because every one went out already.
        local all_sent = sums.posted == 0 and #sums.already_sent > 0 and #sums.skipped == 0
        if reviewed or not wanted or (sums.posted == 0 and not all_sent) then
          finish({ ok = true, reviewed = reviewed, url = result and result.url or "" })
          return
        end
        -- Comments went out, or went out before, but no review with the
        -- event. A post of the event and the text alone completes the review.
        submit.post(
          {
            pr = info,
            dir = current.repo.root,
            event = event,
            body = body,
            entries = {},
            notes = {},
          },
          guard(function(review, post_err)
            if not review then
              fail(
                string.format(
                  "%s went out, but the %s review did not: %s",
                  comments_text(sums.posted),
                  event,
                  post_err and submit.error_text(post_err) or "GitHub gave no answer"
                )
              )
              return
            end
            finish({ ok = true, reviewed = true, url = type(review.html_url) == "string" and review.html_url or "" })
          end)
        )
      end

      local store = require("codeview.comments").store(current)
      local unsent, sent = split_sent(store, ids)
      vim.list_extend(sums.already_sent, sent)
      if #unsent == 0 then
        after(nil)
        return
      end
      submit.run(
        {
          session = current,
          ids = unsent,
          event = event,
          body = body,
          confirm = false,
          notify = false,
        },
        guard(function(result, run_err)
          if not result then
            local text = run_err and submit.error_text(run_err) or "the submit gave no answer"
            if sums.older > 0 then
              text = string.format("%s. %s of older pushes went out before", text, comments_text(sums.older))
            end
            fail(text)
            return
          end
          after(result)
        end)
      )
    end

    local opts = { dir = vim.uv.cwd(), repo = request.repo, comments = false }
    pr.open(
      math.floor(request.number),
      opts,
      guard(function(opened, open_err)
        if not opened then
          fail(tostring(open_err or "the pull request did not open"))
          return
        end
        session = opened
        local info = opened.pr --[[@as codeview.pr.Info]]
        local head = tostring((info or {}).head_sha or "")
        if request.version == 1 and head ~= request.head then
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

        local ids, older = {}, {}
        for _, push in ipairs(pushes_of(request)) do
          if push.head:lower() == head:lower() then
            vim.list_extend(ids, push.ids)
          elseif #push.ids > 0 then
            older[#older + 1] = push
          end
        end
        if #older == 0 then
          send_current(opened, ids)
          return
        end

        -- One session runs at a time. The sessions of the older pushes open
        -- after the session of the current head closes, and that session
        -- opens again at the end.
        local current_range = opened.range
        local current_opts = {
          repo = opened.repo,
          label = pr.label(info),
          store_key = pr.store_key(info),
          pr = info,
          pr_opts = opened.pr_opts,
        }
        local base = pr.refs(info.number).base
        opened:close()
        session = nil

        local index = 0
        local function next_push()
          index = index + 1
          local push = older[index]
          if not push then
            session_mod.open(
              current_range,
              current_opts,
              guard(function(current, reopen_err)
                if not current then
                  fail(
                    string.format(
                      "%s of older pushes went out, but the pull request did not open again: %s",
                      comments_text(sums.older),
                      tostring(reopen_err)
                    )
                  )
                  return
                end
                send_current(current, ids)
              end)
            )
            return
          end

          local old_info = vim.tbl_extend("force", info, { head_sha = push.head })
          local unsent, sent =
            split_sent(store_mod.load({ repo = current_opts.repo.root, range = pr.store_key(old_info) }), push.ids)
          vim.list_extend(sums.already_sent, sent)
          if #unsent == 0 then
            next_push()
            return
          end
          ---Keep every comment of the push local, with one reason.
          ---@param reason string
          local function skip_push(reason)
            for _, id in ipairs(unsent) do
              sums.skipped[#sums.skipped + 1] = { id = id, reason = reason }
            end
            next_push()
          end

          session_mod.open(
            { kind = "triple", from = base, to = push.head, spec = pr.store_key(old_info) },
            {
              repo = current_opts.repo,
              label = pr.label(old_info),
              store_key = pr.store_key(old_info),
              pr = old_info,
              pr_opts = current_opts.pr_opts,
            },
            guard(function(old_session, old_err)
              if not old_session then
                skip_push(
                  string.format("cannot read the diff of the older push %s: %s", short(push.head), tostring(old_err))
                )
                return
              end
              session = old_session
              submit.run(
                {
                  session = old_session,
                  ids = unsent,
                  event = "comment",
                  -- The review holds the comments only. The call adds no
                  -- text that the user did not write.
                  body = "",
                  confirm = false,
                  notify = false,
                },
                guard(function(result, run_err)
                  pcall(old_session.close, old_session)
                  session = nil
                  if not result then
                    local text = string.format(
                      "GitHub did not take the comments of the older push %s: %s",
                      short(push.head),
                      run_err and submit.error_text(run_err) or "the submit gave no answer"
                    )
                    if sums.older > 0 then
                      text = string.format("%s. %s of older pushes went out before", text, comments_text(sums.older))
                    end
                    fail(text .. ". The review did not go out")
                    return
                  end
                  add(result, true)
                  if result.unsaved then
                    fail(
                      string.format(
                        "%s went out, but codeview did not mark them as sent: %s. The review did not go out",
                        comments_text(sums.posted),
                        result.unsaved
                      )
                    )
                    return
                  end
                  next_push()
                end)
              )
            end)
          )
        end
        next_push()
      end)
    )
  end)()
end

return M
