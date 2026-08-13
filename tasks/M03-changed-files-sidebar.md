# M3 — Changed-files sidebar

Goal: browse the changed files of the session.
Done when: you can walk through all changed files of a range from the sidebar.

## Tasks

- [ ] **T3.1 — Sidebar component**
  Create a reusable sidebar module: scratch buffer, own filetype, fixed width from the config, `winfixwidth`.
  M8 reuses this component for the comment overview.

- [ ] **T3.2 — File list rendering**
  Render one line per changed file with a status mark: `A`, `M`, `D`, `R`.
  Add highlight groups per status, linked to standard groups.

- [ ] **T3.3 — Header**
  Show the selected range and the file count at the top of the sidebar.

- [ ] **T3.4 — Keymaps**
  `<CR>` opens the diff for the file under the cursor. `q` closes the session.
  Add `]f` and `[f` for next and previous file, also from the diff view.

- [ ] **T3.5 — Current file marker**
  Highlight the file that is open in the diff view. Update the marker on file change.

- [ ] **T3.6 — Tests**
  Assert the rendered lines and highlights for a fixture session.
