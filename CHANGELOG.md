# Changelog

All notable changes of codeview go into this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The plugin follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- **Comment store location.** The default of `comments.dir` moved from
  `stdpath("config") .. "/review"` to `stdpath("data") .. "/codeview/review"`.
  The plugin writes the comment files, so they do not belong in the
  configuration directory. To read an old review, move its directory over, or
  set `comments.dir` to the old path.

## 0.1.0 — 2026-08-13

The first release. It holds the full review loop: select a range, browse the
files, read the diffs, write comments, and send them out.

### Added

- **Revision selection.** `:CodeView {rev}`, `:CodeView {rev}..{rev}`, and
  `:CodeView {rev}...{rev}` open a review session. `:CodeView` alone opens a
  commit picker, and `:CodeView!` picks a range. `:CodeViewClose` closes the
  session.
- **git backend.** The backend resolves a revision, lists the commits and the
  changed files of a range, and reads a file at a revision. Every call runs
  with `vim.system`.
- **jj backend.** The same interface on a jj repository, with revsets such as
  `trunk()..@`. Every call runs with `--ignore-working-copy`, so no call
  snapshots the working copy. codeview detects a colocated repository and takes
  the jj backend there.
- **Changed-files sidebar.** `:CodeViewFiles` shows the changed files as a
  tree, with a status mark per file and rolled-up marks on a collapsed
  directory. The marker of the current file follows the diff view.
- **Inline diff view.** A unified diff of the two revisions, with hunk
  navigation (`]h`, `[h`), word-level highlights, and collapsed unchanged
  sections that `za`, `zR`, and `zM` open again.
- **Side-by-side diff view.** Two aligned windows with filler rows, bound
  scrolling, and bound cursors. `<leader>ct` switches the style and keeps the
  line of the cursor.
- **Inline comments.** The diff buffer stays read-only, so the insert keys
  (`i`, `a`, `o`, `O`, and `I`, `A`, `c` in the visual mode) open a comment
  editor. A comment anchors to a file, a line range, a side, and a commit, and
  it shows as extmarks only.
- **Comment storage.** All comments of a session live in one markdown file,
  named by a hash of the repository root and of the range. A reopen of the same
  range loads the comments again. The write is atomic.
- **Comment overview.** `:CodeViewComments` lists every comment of the session
  as a tree. `<CR>` jumps to the anchor in the diff. Keys edit, delete, and
  resolve a comment.
- **Export.** `:CodeViewExport` renders the comments as markdown into a scratch
  buffer and into a register. The `export.template` option replaces the
  renderer.
- **GitHub pull requests.** `:CodeView pr {number}` reviews a pull request
  through the `gh` CLI. The command fetches two refs and checks out no branch.
  The diff shows the review comments that the pull request already holds,
  marked as read-only.
- **GitHub submit.** `:CodeViewSubmit` sends the comments of the session as one
  pull request review, with `comment`, `approve`, or `request-changes`. The
  command maps every line to a position of the diff of GitHub, reports the
  comments that stay local, and posts only after a confirmation. A sent comment
  carries its sync state, so no comment goes out twice.
- **Health check.** `:checkhealth codeview` reports the Neovim version, the
  plugin version, the configuration, the `git`, `jj`, and `gh` executables, and
  the login state of `gh`.
- **Documentation.** `:help codeview` holds the commands, the options, the
  keymaps, the Lua API, and the comment file format.
- **Line limit for a large diff.** The `diff.max_lines` option stops the
  comparison of a file that holds more lines than the limit. The view then
  shows the count, the limit, and the key that renders the file anyway. Set the
  option to 0 to remove the limit.
- **Configurable comment editor keys.** The `editor_save` option and the
  `editor_cancel` option name the keys of the comment editor.

### Performance

- The diff of a file loads when you open that file, and never before. A range
  of 400 files opens in about 30 ms.
- The comparison picks the algorithm from the size of the file. The histogram
  algorithm reads better, but its cost grows with the square of the number of
  hunks. A file above 4000 lines per side therefore takes the myers algorithm.
  A file of 16000 lines that changes every second line went from 1300 ms to
  2 ms.

## Release steps

The tag is a manual step. jj 0.44 creates no git tag, so the tag comes from git,
in the colocated repository:

```sh
git tag -a v0.1.0 -m "codeview 0.1.0" $(jj log --no-graph -r @- -T commit_id)
git push origin v0.1.0
```

A plugin manager resolves `version = "*"` against the tags of the repository. A
jj bookmark becomes a git branch, so a bookmark answers no version request.

Then open a GitHub release for the tag. Paste the section of this file into the
release. `ANNOUNCEMENT.md` holds the post for r/neovim and for the Neovim
Discourse.
