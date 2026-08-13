# M8 — Comment overview sidebar

Goal: see all comments of the session in one place.
Done when: you can review and manage all comments of a session from the overview.

## Tasks

- [ ] **T8.1 — Overview window**
  Build the overview on the sidebar component from T3.1, as a second panel.

- [ ] **T8.2 — Rendering**
  Group comments by file. Show file, line or line range, commit, state, and a one-line body preview.

- [ ] **T8.3 — Jump to comment**
  `<CR>` opens the file diff and moves the cursor to the comment anchor.

- [ ] **T8.4 — Manage from the overview**
  Add keys for edit, delete, and resolve. Store the resolve state in the comment fields.

- [ ] **T8.5 — Refresh events**
  Add a small internal event: comment added, changed, deleted.
  The overview and the diff anchors subscribe and re-render.

- [ ] **T8.6 — Tests**
  Assert the rendered overview and the jump targets for a fixture session with comments.
