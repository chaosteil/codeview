# M2 — Revision selection

Goal: select what to review.
Done when: you can pick a commit or range from the log and the session reports its changed files.

## Tasks

- [ ] **T2.1 — Session module**
  Create `lua/codeview/session.lua`. A session holds the backend, the range, and the changed files.
  Keep one active session. Provide `open(range)` and `close()`.

- [ ] **T2.2 — `:CodeView` command**
  Register the command with argument parsing: `<rev>` reviews one commit, `<rev>..<rev>` reviews a range.
  No argument opens the picker (T2.3).

- [ ] **T2.3 — Commit picker**
  Show the commit log with `vim.ui.select`. Format each entry: short id, subject, relative date.
  Selection of one commit opens a session for it.

- [ ] **T2.4 — Range selection in the picker**
  Add a two-step flow: pick the start commit, then pick the end commit.
  Build the range from the two picks.

- [ ] **T2.5 — Session lifecycle**
  Close all session windows on `close()`. Clean up autocmds and buffers.
  A second `open()` closes the previous session first.

- [ ] **T2.6 — Tests**
  Test the argument parsing and the session state for fixture ranges.
