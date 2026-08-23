---@brief Helpers that more than one module needs.
---
--- The module holds no state, and it requires no other module of the plugin.
--- Every module therefore loads it without a cycle.
---
--- `done()` and `chain()` serve the calls that come in a sync form and in an
--- async form. A call without a callback returns `value, err`. A call with a
--- callback returns at once, and sends the same pair to the callback on the
--- main loop.

local M = {}

---Return a value in the sync form, or send it to the callback.
---@generic T
---@param cb? fun(value: T?, err: codeview.Error?) Callback of the async form.
---@param value any? Result of the call.
---@param err codeview.Error? Error of the call.
---@return any? value Result in the sync form. Nil with a callback.
---@return codeview.Error? err Error in the sync form. Nil with a callback.
function M.done(cb, value, err)
  if not cb then
    return value, err
  end
  vim.schedule(function()
    cb(value, err)
  end)
  return nil, nil
end

---@alias codeview.util.Step fun(cb?: fun(value: any?, err: codeview.Error?)): any?, codeview.Error?

---Run steps one after the other. The first error stops the run.
---@param steps codeview.util.Step[] Steps in the order of the run.
---@param cb? fun(ok: boolean?, err: codeview.Error?) Callback of the async form.
---@return boolean? ok True after the last step. Nil with a callback.
---@return codeview.Error? err Error of the step that failed. Nil with a callback.
function M.chain(steps, cb)
  if not cb then
    for _, step in ipairs(steps) do
      local _, err = step()
      if err then
        return nil, err
      end
    end
    return true, nil
  end

  local index = 0
  local function run()
    index = index + 1
    if not steps[index] then
      cb(true, nil)
      return
    end
    steps[index](function(_, err)
      if err then
        cb(nil, err)
        return
      end
      run()
    end)
  end
  run()
  return nil, nil
end

---Short form of a revision id.
---
--- A long hexadecimal id gets its first 8 characters. Every other text stays
--- as it is, because a branch name or a `@` reads better in full.
---@param rev string? Revision id. Nil gives an empty text.
---@return string text
function M.short(rev)
  rev = rev or ""
  if #rev >= 12 and rev:match("^%x+$") then
    return rev:sub(1, 8)
  end
  return rev
end

---Order two comments of one file: by line, then by side, then by age.
---@param a codeview.store.Comment
---@param b codeview.store.Comment
---@return boolean first True when `a` comes before `b`.
function M.comment_before(a, b)
  if a.start_line ~= b.start_line then
    return a.start_line < b.start_line
  end
  if a.side ~= b.side then
    return a.side == "old"
  end
  if a.created_at ~= b.created_at then
    return a.created_at < b.created_at
  end
  return a.id < b.id
end

return M
