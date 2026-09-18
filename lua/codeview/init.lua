---@brief codeview — review commits and ranges of commits inside Neovim.
---
--- The public API of the plugin. Every call of this table is stable. The
--- modules under `codeview.*` hold the work.

local config = require("codeview.config")

local M = {}

---Plugin version.
---@type string
M.version = "0.1.0"

---True after a successful `setup()` call.
---@type boolean
M.did_setup = false

---Configure the plugin.
---
--- The plugin also works without this call. Every option then holds its
--- default value.
---@param opts? table User options. See |codeview-config|.
---@return codeview.Config? config The active configuration, or nil after an error.
---@return string? err The reason why the options are invalid.
function M.setup(opts)
  local merged, err = config.setup(opts)
  if err then
    vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    return nil, err
  end
  M.did_setup = true
  return merged, nil
end

---Read the active configuration.
---@return codeview.Config
function M.config()
  return config.get()
end

---Open a review session.
---
--- The argument is user text (`a`, `a..b`, `a...b`) or a range table. Without
--- a callback the call blocks. The command `:Codeview` calls this function.
---@param spec string|codeview.vcs.Range|codeview.vcs.RangeSpec Revision argument.
---@param opts? codeview.session.OpenOpts
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session
---@return codeview.Error? err
function M.open(spec, opts, cb)
  return require("codeview.session").open(spec, opts, cb)
end

---Open the commit picker.
---@param opts? codeview.picker.Opts `mode = "range"` asks for two picks.
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Nil session and nil error mean cancel.
function M.pick(opts, cb)
  require("codeview.picker").pick(opts, cb)
end

---Open a review session for a GitHub pull request.
---
--- The call reads the pull request with the gh CLI, fetches its commits into
--- the refs of the plugin, and opens the range `base...head`. The working copy
--- does not change. The command `:Codeview pr <number>` calls this function.
---@param number integer? Number of the pull request. Nil takes the pull request of the branch.
---@param opts? { dir?: string, repo?: string, remote?: string, comments?: boolean }
---@param cb? fun(session: codeview.Session?, err: codeview.Error?) Callback for the async form.
---@return codeview.Session? session
---@return codeview.Error? err
function M.open_pr(number, opts, cb)
  return require("codeview.pr").open(number, opts, cb)
end

---Read the pull request that the session reviews.
---@return codeview.pr.Info? info Nil for a session of a local range.
function M.pr()
  return require("codeview.pr").current()
end

---Review comments that the pull request of the session already holds.
---@return codeview.remote.Comment[] comments
function M.remote_comments()
  return require("codeview.remote").list()
end

---Read the session that runs.
---@return codeview.Session? session Nil when no session runs.
function M.session()
  return require("codeview.session").current()
end

---Close the session that runs.
---@return boolean closed False when no session runs.
function M.close()
  return require("codeview.session").close()
end

---Read the changed-files sidebar.
---@return codeview.Sidebar? sidebar Nil when no sidebar runs.
function M.sidebar()
  return require("codeview.sidebar").get()
end

---Open the changed-files sidebar for the session that runs.
---@param opts? { session?: codeview.Session, focus?: boolean }
---@return codeview.Sidebar? sidebar
---@return codeview.Error? err
function M.open_sidebar(opts)
  return require("codeview.sidebar").open(opts)
end

---Close the changed-files sidebar. The session stays open.
---@return boolean closed False when no sidebar is open.
function M.close_sidebar()
  return require("codeview.sidebar").close()
end

---Close the sidebar when it is open, and open it when it is closed.
---@param opts? { session?: codeview.Session, focus?: boolean }
---@return boolean open State after the call.
function M.toggle_sidebar(opts)
  return require("codeview.sidebar").toggle(opts)
end

---Read the comment overview.
---@return codeview.Overview? overview Nil when no overview runs.
function M.overview()
  return require("codeview.overview").get()
end

---Open the comment overview for the session that runs.
---@param opts? { session?: codeview.Session, focus?: boolean }
---@return codeview.Overview? overview
---@return codeview.Error? err
function M.open_overview(opts)
  return require("codeview.overview").open(opts)
end

---Close the comment overview. The session stays open.
---@return boolean closed False when no overview is open.
function M.close_overview()
  return require("codeview.overview").close()
end

---Close the overview when it is open, and open it when it is closed.
---@param opts? { session?: codeview.Session, focus?: boolean }
---@return boolean open State after the call.
function M.toggle_overview(opts)
  return require("codeview.overview").toggle(opts)
end

---Read the file view of the session that runs.
---@return codeview.view.State? view Nil when no file is open.
function M.view()
  return require("codeview.view").current()
end

---Open one changed file of the session in the diff view.
---@param index integer Position of the file in the file list of the session.
---@param opts? { session?: codeview.Session, force?: boolean } `force = true` renders a diff above the `diff.max_lines` limit.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?) Callback for the async form.
---@return codeview.view.State? view
---@return codeview.Error? err
function M.open_file(index, opts, cb)
  opts = opts or {}
  local session = opts.session or require("codeview.session").current()
  if not session then
    local errors = require("codeview.error")
    local err = errors.new(errors.codes.INVALID_ARG, "no review session")
    if cb then
      cb(nil, err)
      return nil, nil
    end
    return nil, err
  end
  return require("codeview.view").open(session, index, { force = opts.force }, cb)
end

---Render the diff that the `diff.max_lines` limit stopped.
---@param cb? fun(view: codeview.view.State?, err: codeview.Error?) Callback for the async form.
---@return boolean started False when the view shows no limited diff.
function M.load_diff(cb)
  return require("codeview.view").load_diff(cb)
end

---Move the cursor to the first row of the next hunk.
---@param opts? { wrap?: boolean } `wrap = true` continues at the first hunk.
---@return integer? row Nil when no hunk follows.
function M.next_hunk(opts)
  return require("codeview.view").next_hunk(opts)
end

---Move the cursor to the first row of the previous hunk.
---@param opts? { wrap?: boolean } `wrap = true` continues at the last hunk.
---@return integer? row Nil when no hunk is above the cursor.
function M.prev_hunk(opts)
  return require("codeview.view").prev_hunk(opts)
end

---Open the file of the review in the working copy.
---
--- The call leaves the review: the window of the diff takes the real file,
--- with the cursor on the line of the diff. See |codeview.view.edit()|.
---@param opts? { path?: string, line?: integer, win?: integer }
---@return boolean opened
function M.edit_file(opts)
  return require("codeview.view").edit(opts)
end

---Read the diff style of the view, or the style of the next file.
---@return "inline"|"split" style
function M.style()
  return require("codeview.view").style()
end

---Change the diff style.
---
--- The call keeps the cursor on the same line of the file. The new style also
--- becomes the `diff.style` option.
---@param style "inline"|"split"? Style to set. The other style by default.
---@return "inline"|"split"? style Style after the call. Nil for an invalid name.
function M.set_style(style)
  return require("codeview.view").set_style(style)
end

---Switch between the inline style and the side-by-side style.
---@return "inline"|"split"? style Style after the call.
function M.toggle_style()
  return require("codeview.view").toggle_style()
end

---Show or hide the lines of the collapsed section under the cursor.
---@param id integer? Number of the section. The section under the cursor by default.
---@param expanded boolean? State to set. The other state by default.
---@return boolean changed False without a section.
function M.toggle_context(id, expanded)
  return require("codeview.view").toggle_context(id, expanded)
end

---Comment on the line under the cursor, or on the selected lines.
---
--- The call opens the comment editor. The diff buffer stays read-only.
---@param opts? { visual?: boolean, first?: integer, last?: integer }
---@return boolean opened False when the row holds no line of the file.
function M.comment(opts)
  return require("codeview.comments").add(opts)
end

---Open the editor for the comment under the cursor.
---@param opts? { id?: string }
---@return boolean opened False when no comment covers the cursor.
function M.edit_comment(opts)
  return require("codeview.comments").edit(opts)
end

---Delete the comment under the cursor, after a question.
---@param opts? { id?: string, confirm?: boolean } `confirm = false` skips the question.
---@return boolean removed
function M.delete_comment(opts)
  return require("codeview.comments").remove(opts)
end

---Set the state of the comment under the cursor.
---@param opts? { id?: string, state?: "open"|"resolved" } Without a state the call takes the other state.
---@return codeview.store.Comment? comment The comment after the change.
function M.resolve_comment(opts)
  return require("codeview.comments").set_state(opts)
end

---Show the comment under the cursor in a float.
---@return integer? buf
---@return integer? win
function M.show_comment()
  return require("codeview.comments").show()
end

---Comments of the session that runs.
---@return codeview.store.Comment[] comments
function M.comments()
  return require("codeview.comments").list()
end

---Comment store of the session that runs.
---@return codeview.store.Store? store Nil when no session runs.
---@return codeview.Error? err
function M.store()
  return require("codeview.comments").store()
end

---Export the comments of the session that runs.
---
--- The call renders the markdown, writes it into the register of the
--- `export.register` option, and shows it in a scratch buffer. The command
--- `:Codeview export` calls this function.
---@param opts? codeview.export.Opts
---@return codeview.export.Result? result
---@return codeview.Error? err
function M.export(opts)
  return require("codeview.export").run(opts)
end

---Render the comments of the session that runs as markdown.
---
--- The call writes no register and opens no buffer.
---@param opts? codeview.export.Opts Only `session` matters here.
---@return string? text
---@return codeview.Error? err
function M.export_text(opts)
  return require("codeview.export").render(opts)
end

---Send the comments of the session that runs to the pull request.
---
--- The call shows a summary and posts only after the user confirms it. The
--- command `:Codeview submit` calls this function.
---@param opts? codeview.submit.Opts
---@param cb? fun(result: codeview.submit.Result?, err: codeview.Error?) Handler of the answer.
function M.submit(opts, cb)
  return require("codeview.submit").run(opts, cb)
end

---Send one comment to the pull request.
---
--- The send key of the comment editor calls this function.
---@param opts codeview.submit.SendOpts
---@param cb? fun(result: codeview.submit.Result?, err: codeview.Error?) Handler of the answer.
function M.send(opts, cb)
  return require("codeview.submit").send(opts, cb)
end

---Read the review again from the repository.
---
--- The call resolves the range of the session again, so the review follows a
--- new commit, an amend, or a rebase. On jj it writes the working copy into
--- `@` first. The open file stays open, on the same line. The command
--- `:Codeview refresh` calls this function.
---@return boolean refreshed False with a message when there is no session, or when the call failed.
function M.refresh()
  return require("codeview.view").refresh()
end

---Run the health check of the plugin.
---
--- The same report comes from `:checkhealth codeview`.
function M.health()
  vim.cmd.checkhealth("codeview")
end

return M
