# M9 — Export

Goal: get comments out via copy+paste.
Done when: one command puts a pasteable review into the clipboard.

## Tasks

- [x] **T9.1 — Markdown renderer**
  Render all session comments to markdown: file, line or range, commit, body.
  Group by file, in diff order.

- [x] **T9.2 — `:CodeViewExport` command**
  Put the result in a scratch buffer and in a register (`+` by default, configurable).

- [x] **T9.3 — Template option**
  Accept a user template function in the config. The function gets the session and returns the text.

- [x] **T9.4 — Tests**
  Snapshot test of the default export for a fixture session.
