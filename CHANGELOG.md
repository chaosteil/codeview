# Changelog

All notable changes of codeview are in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the plugin
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Another tool can send chosen comments of a pull request as one review. It
  runs `require('codeview.bridge').submit_file('<path>')` in a headless
  Neovim, with a JSON request and a JSON result. See `:help codeview-bridge`.
  The help file also gives the session file format as a read interface.
- `submit.run` takes `ids`, to send only the chosen comments, and
  `confirm = false`, to ask nothing.
- A commit document and the pull request document load as markdown. Their
  buffer has the `markdown` filetype, and the message and the description
  have no indent. Your markdown tools then work on them, for example the
  treesitter highlighter of Neovim, render-markdown.nvim, or markview.nvim.
  The buffer shows no diagnostics. `diff.syntax = false` keeps the filetype
  of a diff. See `:help codeview-commit-message`.
- The pr-agent documents load as markdown too. The key issues of a review,
  the new body of a describe result, and the answers of ask have no indent.
- The sidebar marks a file with comments with a `C` right of its status
  mark. The local comments and the comments of GitHub count. A collapsed
  directory shows the mark when a file below it has comments. The mark
  follows each change of a comment at once. The `sidebar.icons.comment`
  option sets the text, and the highlight group `CodeViewCommentMark` sets
  the color. See `:help codeview-sidebar-comment-mark`.
- `]c` and `[c` jump to the next and the previous comment, in the diff view
  and in the sidebar. The local comments and the threads of GitHub are
  stops. After the last comment of a file, `]c` opens the next file with
  comments, in the order of `]f`. At the last comment of the review, the key
  stays and shows a message. The diff view sets no `'diff'` option, so the
  `]c` of Neovim does nothing there. `codeview.next_comment()` and
  `codeview.prev_comment()` do the same from Lua. See
  `:help codeview-diff-comment-keys`.

### Changed

- The status marks and the comment mark of the sidebar stand in fixed
  columns at the right edge of the window. A long name or a long commit
  title gets cut and ends with "…", so the marks stay visible at every width
  of the sidebar. The sidebar draws the lines again when its width changes.
  See `:help codeview-sidebar-columns`.
- In a pull request review, the Commits group of the sidebar starts
  collapsed. The document of the pull request lists the commits already.
  Press `<Tab>` on the group to show them. A review of a local range still
  shows the commits. See `:help codeview-github-document`.
- `]f` and `[f` go over the commits while the Commits group is collapsed. In
  a pull request review, `]f` on the pull request document opens the first
  file. Expand the group, and the keys step through the commits again. A
  collapsed directory does not change the keys. See
  `:help codeview-sidebar-keymaps`.
- `:Codeview pr` reads the pull request without its commits, so the answer
  of GitHub comes about 0.1 seconds faster. The review reads the commits
  from the repository, as before. The table of `codeview.pr()` has no
  `commits` field any more. Read the `commits` field of the session.

### Fixed

- The sign of a comment stays visible on a row that also has the sign of
  another plugin, for example the sign of a heading of markview.nvim in a
  commit document. The sign of a comment now has a priority above the
  default priority of an extmark.
- The inline comment editor no longer covers the other boxes of its row. An
  edit takes the place of the box that it edits, and a new comment comes
  after the boxes of the row.
- In the side-by-side style, the two sides stay in line while the inline
  comment editor is open. The other side takes blank lines of the same
  height as the editor, the same as for a comment box.
- `i` on a line with more than one comment asks which comment to edit, as the
  help says. Before, it took the first comment. A line with one comment
  still opens it at once.
- A comment box keeps the same colors after each save. Before, a save from
  the inline editor read the colors of the editor window, so each save put a
  new tint on top of the last one. A new comment and an edit then had boxes
  of different colors.
- The frame of a comment box stays visible on a dark box. When the
  foreground of `FloatBorder` has a contrast of less than 3:1 with the box,
  the frame takes the color of the tint.
- A save keeps the sent marks that another Neovim wrote to the session file.
  Before, an open session wrote its old copy over them, and a later submit
  sent the comments again. An open session also watches its session file
  and shows such comments as sent.
- A submit and a send take a lock file, so two Neovim processes never send
  the same comments at the same time.

- A comment box has a background on a transparent colorscheme. When
  `Normal` and `NormalFloat` have no background, the tint goes on black for a
  dark 'background' and on white for a light one. The inline comment editor
  takes the colors of the box.
- A save of an edit with an empty body deletes the comment. Before, the save
  kept the old text.
- A file with few but very long lines no longer blocks the editor. The new
  `diff.max_bytes` limit stops it, and the load key lifts the limit.
- Syntax highlighting skips a side of more than 1 MB and a line of more than
  10000 bytes. A broken highlights query no longer stops the render.
- A change of `diff.context` reaches the next render, also of the file that
  is open.
- A side without a final line break shows "\ No newline at end of file". A
  change of the line endings only (CRLF and LF) shows one note, not a change
  of every line.
- The inline comment editor no longer covers the line numbers of the diff.
  A window wider than the space next to the numbers went past the edge of
  the screen, and Neovim moved it to the left.
- A virtual line in a diff, for example a comment under a row, no longer
  shows the line numbers of the row above it again.
- A second open of the comment editor asks "Discard the comment?" before it
  drops typed text.
- The inline comment editor closes with its diff window. With typed text it
  asks first, and "No" moves the editor to a float.
- A delete of a comment that the editor holds closes the editor.
- An edit of a comment of another file opens the editor as a float.
- A discard of the comment editor after a refresh shows the comment in the
  diff again.
- The export puts a comment body with a heading line in a fenced block, so it
  cannot start a new section. An old-side comment on a renamed file names the
  old path.
- The export puts the path of a file heading in backticks, so a path such as
  `pkg/__init__.py` keeps its underscores.
- A pull request review fetches from the remote whose URL names the
  repository of the pull request. The open stops when the fetched head is not
  the head that GitHub reports.
- A pull request on a GitHub Enterprise host uses the token of its own host.
- Only HTTP 401 reports a missing login. A used-up rate limit has its own
  message.
- A comment that went to GitHub and then got a new text changes the comment on
  GitHub. The submit no longer posts it a second time.
- A submit that the time limit stopped, but that reached GitHub, posts no
  second review on the next try. One session runs one submit at a time.
- An outdated GitHub comment shows on the lines that the current file holds,
  or on no line. The comment overview lists it as "outdated", without line
  numbers. A comment over both sides keeps its last line.
- The review warns when a pull request holds more comments than
  `github.max_comments`.
- The git backend reads no revision as an option. A revision that starts with
  `-` gives an error. The `rex-codeview` skill script rejects it too.
- The `rex-codeview` skill script finds rex in `REX_BIN_DIR`, which Rex sets
  in its panes. Without it, the script uses the rex on PATH.
- The git and the jj backends give the same answer for the table forms of a
  range, for a root commit, and for the log of named commits.
- In a colocated jj repository, a `git commit` reaches the review.
- `:Codeview refresh`, `:Codeview back`, the refresh key, the back key, the
  sidebar `<CR>`, and the watcher no longer block the editor.
- The sidebar and the overview keep the cursor on the same item after a
  render. A `:q` on them clears `codeview.sidebar()` and
  `codeview.overview()`.
- A style switch no longer writes the `diff.style` option. A `setup()` call
  sets the style of the next file back to the option.
- The key hint row no longer draws again on every cursor move.
- A second review in the pane of the `rex-codeview` skill no longer quits
  Neovim.

### Changed

- A new comment, an edit, and a reply open the editor through one call, and
  they end the same way. The inline editor holds the id of the comment that
  it edits, so the box of that comment comes back after every kind of close.
  The float editor no longer hides the box of the comment that it edits.
- A comment in the diff shows as a box with a frame and a blue tint, the same
  as the inline editor. The header goes into the top border. The box is as
  wide as the editor, wraps long body lines, and takes the new width when a
  window changes size. The frame follows `comments.border`. A GitHub comment
  takes the same box with a grey tint. The sign no longer goes in front of
  each line of the comment.
- New highlight groups `CodeViewCommentBox`, `CodeViewCommentBorder`,
  `CodeViewRemoteBox`, and `CodeViewRemoteBorder`. The plugin computes their
  colors from the colorscheme.
- The inline comment editor has a frame. It uses the `comments.border`
  option, the same as the float. The title and the key hint go into the
  frame. With `border = "none"` they stay in the winbar.
- The jj backend needs jj 0.45 or later. An older jj does not see a git
  commit on the current branch of a colocated repository.
  `:checkhealth codeview` warns about such a version.
- Every message goes through one wrapper that reads the `log_level` option.
  The default INFO keeps every report of before. Set
  `log_level = vim.log.levels.WARN` to see warnings and errors only.
- The comment overview shows commit ids with 8 characters, not 7.
- The session file holds the new field `remote_id`. A file of an older
  release still reads.
- The diff record of `codeview.view()` has no `context` field. It has the new
  fields `byte_count`, `max_bytes`, `old_eol`, `new_eol`, and `line_endings`.
- `codeview.submit()` gives `result.existing`.
- The stable Lua API is `setup`, `open`, `review`, `open_pr`, `close`,
  `session`, `comments`, `export`, `export_text`, `submit`, and `refresh`.
  Every other call can change before version 1.0.

### Added

- A review of a pull request reads the pr-agent results of chaoshub. The new
  `github.agent_dir` option names their root. See `:help codeview-agent`.
  codeview does nothing for a pull request without results: no directory, no
  watcher without the root, no event, no key, and no hint.
- The sidebar lists the pr-agent review, describe, and ask results under
  the node "Agent".
- The diff and the comment overview show the pr-agent suggestions and key
  issues, read-only, with the sign of the new `comments.agent_sign` option.
  In the diff an item shows as a box with its own tint, from the new groups
  `CodeViewAgentBox` and `CodeViewAgentBorder`.
- `<leader>ca` (the new `adopt` key) takes a pr-agent item as a local
  comment, with a `suggestion` block for a suggestion. The key exists only
  while the review holds pr-agent items.
- The `rex-codeview` skill starts when the user asks to review the changes,
  for example "I want to review this". It does not start when the user asks
  an agent to review the code.
- The Neovim of the `rex-codeview` skill quits when the review closes, so a
  close of the review also closes the pane.
- `:Codeview reopen` and the stable call `codeview.reopen()` open the last
  closed session again, on the same file, line, and diff style.
- The `close.confirm` option makes the close key ask before it closes the
  review.
- The `diff.max_bytes` option.
- The session calls `session:counts()`, `session:position_of()`, and
  `session:off_close()`, and the `range` option of `session:refresh()`.
- The internal modules `codeview.anchor`, `codeview.marks`,
  `codeview.position`, and `codeview.notify`.
- `CHANGELOG.md`.
- A CI test job on macOS, and a fixed stylua version in CI.
- `codeview.review()` takes `quit = true`. Neovim then quits when the review
  ends, the same as `++quit`.

## 0.1.0

The first release.
