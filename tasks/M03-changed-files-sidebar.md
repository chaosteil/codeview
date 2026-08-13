# M3 — Changed-files sidebar

Goal: browse the changed files of the session.
Done when: you can walk through all changed files of a range from the sidebar.

## Tasks

- [x] **T3.1 — Sidebar component**
  Create a reusable sidebar module: scratch buffer, own filetype, fixed width from the config, `winfixwidth`.
  M8 reuses this component for the comment overview.

- [x] **T3.2 — Tree model**
  Build a tree from the changed file paths: directory nodes and file nodes.
  Each node keeps its name, full path, depth, children, and expanded state.
  Collapse a chain of single-child directories into one node (`lua/codeview/vcs`), like neo-tree.

- [x] **T3.3 — Tree rendering**
  Render the tree, not a flat list. Show indent guides, a directory icon or arrow for the
  expanded state, and the file name. Show the status mark (`A`, `M`, `D`, `R`) per file.
  Roll the child statuses up to the directory node when the directory is collapsed.
  Add highlight groups per status and for directories, linked to standard groups.
  Do not depend on a devicons plugin. Use text icons from the config, with plain fallbacks.

- [x] **T3.4 — Expand and collapse**
  Keys to toggle a directory, expand all, and collapse all.
  Keep the expanded state per session, so a re-render does not reset it.
  Expand every directory by default.

- [x] **T3.5 — Header**
  Show the selected range and the file count at the top of the sidebar.

- [x] **T3.6 — Keymaps**
  `<CR>` opens the diff for the file under the cursor, or toggles a directory node.
  `q` closes the session. Add `]f` and `[f` for next and previous file, also from the diff view.
  File navigation steps over directory nodes.

- [x] **T3.7 — Current file marker**
  Highlight the file that is open in the diff view. Update the marker on file change.

- [x] **T3.8 — Tests**
  Assert the tree model for a fixture set of paths: nesting, collapsed chains, sort order.
  Assert the rendered lines, the indent guides, and the highlights for a fixture session.
  Assert that expand and collapse change the render and keep the state.
