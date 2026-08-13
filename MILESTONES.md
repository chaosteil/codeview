# codeview — Milestones

codeview is a Neovim plugin for code review. It shows the changes of a commit or a range of commits. You browse the changed files in a sidebar, read diffs inline or side-by-side, and leave comments. You can export the comments, and later send them to GitHub.

## Decisions

- Language: Lua. The only external dependency is plenary.nvim (tests). The runtime uses the Neovim standard library (`vim.system`, `vim.diff`, `vim.ui`, extmarks).
- VCS: a backend interface from the start. The git backend comes first, the jj backend second.
- Comment storage: one markdown file per review session, in `~/.config/nvim/review/<repo-slug>/`. The slug comes from the repo path. The file name is a deterministic session key: a short hash of the repo root and the resolved range. A reopen of the same range finds the file directly, without a directory scan. The file holds all comments of the session.
- GitHub: read-only inspection and export first. Two-way sync is a later milestone.

## M0 — Plugin skeleton

Goal: a plugin that loads, with a test and CI loop.

- Standard layout: `lua/codeview/`, `plugin/`, `doc/`.
- `setup()` with a config table and defaults.
- `:checkhealth codeview` reports the git, jj, and gh executables.
- Test harness with plenary.nvim. One CI workflow that runs the tests and a Lua linter.

Done when: the plugin loads in a clean Neovim, and the test suite runs in CI.

## M1 — VCS core: interface and git backend

Goal: one backend interface, implemented for git.

- Interface: detect repo, resolve a revision, list commits, list changed files for a range, get file content at a revision.
- Git implementation with `vim.system` (async).
- Structured errors for bad revisions and missing repos.
- Unit tests against a fixture repo.

Done when: Lua code can list the changed files and file contents for any git revision range, with tests.

## M2 — Revision selection

Goal: select what to review.

- `:CodeView <rev>` and `:CodeView <rev>..<rev>` open a review session.
- A picker (`vim.ui.select` first) that shows the commit log. Support single-commit and range selection.
- A session object holds the selected range and drives all later UI.

Done when: you can pick a commit or range from the log and the session reports its changed files.

## M3 — Changed-files sidebar

Goal: browse the changed files of the session.

- A sidebar window that lists the changed files with status marks (added, modified, deleted, renamed).
- `<CR>` opens the diff for the file. Keys for next/previous file.
- The sidebar shows the selected range in its header.

Done when: you can walk through all changed files of a range from the sidebar.

## M4 — Inline diff view

Goal: a unified diff with clear colors.

- One buffer per file: removals in red, additions in green, via `vim.diff` hunks and extmarks.
- Hunk navigation (`]h`, `[h`) and fold of unchanged sections with context lines.
- Correct highlights on light and dark backgrounds through standard highlight groups.

Done when: opening a file from the sidebar shows a readable inline diff.

## M5 — Side-by-side diff view

Goal: a second diff style and a fast switch.

- Two aligned windows: old version left, new version right, with filler lines for alignment.
- Synchronized scrolling and cursor movement.
- One key toggles between inline and side-by-side. The style persists in the config.

Done when: you can toggle the diff style in one keypress and both styles show the same hunks.

## M6 — jj backend

Goal: the same review flow on jj repos.

- Implement the M1 interface with `jj` commands. Support revsets in `:CodeView`.
- Detect colocated repos and prefer the jj backend there.
- Reuse the M1 test suite against a jj fixture repo.

Done when: all M2–M5 features work in a jj repo without code changes outside the backend.

## M7 — Inline comments

Goal: leave comments in the diff.

- A key opens a small edit window to write a comment on the current line, or on a line range via visual selection — like the GitHub UI.
- Comments anchor to file, start line, end line, side (old/new), and commit, with extmark signs across the full range in the diff.
- All comments of a session persist in one file, named by the session key. The frontmatter holds the session data (repo, range, timestamp). Each comment is one section with its own fields (file, start line, end line, side, commit) and a markdown body.
- Comments load again when you reopen a session on the same range. Edit and delete work.

Done when: a comment survives a Neovim restart and shows at the correct line.

## M8 — Comment overview sidebar

Goal: see all comments of the session in one place.

- A second sidebar lists every comment with file, line or line range, commit, and a body preview.
- `<CR>` jumps to the comment location in the diff view.
- Keys for edit, delete, and resolve state.

Done when: you can review and manage all comments of a session from the overview.

## M9 — Export

Goal: get comments out via copy+paste.

- `:CodeViewExport` renders all session comments to markdown: file, line, commit, body.
- The result goes to a scratch buffer and to a register (`+` by default).
- The format is configurable through one template function.

Done when: one command puts a pasteable review into the clipboard.

## M10 — GitHub PRs, read-only

Goal: inspect a PR as if it were local.

- `:CodeView pr <number>` fetches the PR via the `gh` CLI: branches, commits, metadata.
- The PR diff opens in the same sidebar and diff views. Local comments and export work on it.
- Show existing PR review comments inline, marked as remote.

Done when: you can review a PR offline-style, with the full M2–M9 feature set.

## M11 — GitHub two-way sync

Goal: send local comments to the PR.

- `:CodeViewSubmit` posts session comments as one PR review via `gh api`, with approve/comment/request-changes.
- Map local line anchors to PR diff positions, including multi-line comments (`start_line`/`line` in the GitHub API). Report lines that no longer map.
- Mark submitted comments as synced in the store, to prevent double posts.

Done when: a local review lands on the PR as one review with correct line positions.

## M12 — Polish and release

Goal: a plugin other people can install.

- Vimdoc (`:help codeview`), README with screenshots, and a default keymap reference.
- Performance pass: lazy file loading, large-diff limits, async everywhere.
- Version tag, changelog, and an announcement post.

Done when: a stranger can install, configure, and use the plugin from the README alone.
