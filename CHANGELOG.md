# Changelog

All notable changes of codeview are in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the plugin
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed

- A file with few but very long lines no longer blocks the editor. The new
  `diff.max_bytes` limit stops it, and the load key lifts the limit.
- Syntax highlighting skips a side of more than 1 MB and a line of more than
  10000 bytes. A broken highlights query no longer stops the render.
- A change of `diff.context` reaches the next render, also of the file that
  is open.
- A side without a final line break shows "\ No newline at end of file". A
  change of the line endings only (CRLF and LF) shows one note, not a change
  of every line.
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

### Changed

- Every message goes through one wrapper that reads `log_level`. The default
  WARN hides the INFO reports, for example of a submit or an export. Set
  `log_level = vim.log.levels.INFO` to see them.
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

- The `diff.max_bytes` option.
- The session calls `session:counts()`, `session:position_of()`, and
  `session:off_close()`, and the `range` option of `session:refresh()`.
- The internal modules `codeview.anchor`, `codeview.marks`,
  `codeview.position`, and `codeview.notify`.
- `CHANGELOG.md`.
- A CI test job on macOS, and a fixed stylua version in CI.

## 0.1.0

The first release.
