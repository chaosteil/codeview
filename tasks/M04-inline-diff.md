# M4 — Inline diff view

Goal: a unified diff with clear colors.
Done when: opening a file from the sidebar shows a readable inline diff.

## Tasks

- [ ] **T4.1 — Diff computation**
  Create `lua/codeview/diff.lua`. Load the old and new content from the backend and run `vim.diff`.
  Produce a hunk list with old and new line numbers.

- [ ] **T4.2 — Unified buffer rendering**
  Build the buffer lines from hunks and context.
  Keep a line map: buffer line to old line and new line. All later features use this map.

- [ ] **T4.3 — Highlights**
  Define highlight groups for added and removed lines, linked to `DiffAdd` and `DiffDelete`.
  Apply them with extmark line highlights. Test on a light and a dark background.

- [ ] **T4.4 — Line numbers**
  Show the old and new line numbers per row, through the status column or virtual text.

- [ ] **T4.5 — Hunk navigation**
  Add `]h` and `[h` to jump to the next and previous hunk.

- [ ] **T4.6 — Context folding**
  Collapse unchanged sections to a configurable number of context lines.
  A key expands a collapsed section.

- [ ] **T4.7 — Tests**
  Assert the rendered lines, the line map, and the highlight positions for fixture diffs.
  Include added, deleted, and renamed files.
