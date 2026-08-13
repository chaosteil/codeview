# M7 — Inline comments

Goal: leave comments in the diff.
Done when: a comment survives a Neovim restart and shows at the correct line.

## Tasks

- [ ] **T7.1 — Data model**
  Define LuaCATS types. Session file: key, repo, range, timestamp, comments.
  Comment: id, file, start line, end line, side (old/new), commit, timestamp, state, body.

- [ ] **T7.2 — Session key**
  Derive the store directory from the repo path (slug). Derive the file name from a short hash of the repo root and the resolved range.
  A reopen of the same range computes the same key and finds the file directly.

- [ ] **T7.3 — Store: write and parse**
  Write the session file as markdown: session frontmatter, one section per comment with a fields block and a body.
  Parse it back without loss. Write atomically (temp file, then rename).

- [ ] **T7.4 — Comment editor**
  A key opens a small floating window with a markdown buffer. Save on write, discard on quit.
  In normal mode the comment targets the current line. In visual mode it targets the selected range, like the GitHub UI.

- [ ] **T7.5 — Anchors in the diff**
  Place an extmark over the comment range. Show a sign on each covered line.
  Map diff-buffer lines to file lines through the M4 line map, for both sides.

- [ ] **T7.6 — Comment display**
  Show the comment body at the cursor position: a float on hover key, or virtual lines below the range.
  Pick one as default and make it configurable.

- [ ] **T7.7 — Load on reopen**
  On session open, compute the key (T7.2), load the file, and place all anchors.

- [ ] **T7.8 — Edit and delete**
  Reopen the editor for the comment under the cursor. Delete with a confirm step.
  Persist every change to the session file.

- [ ] **T7.9 — Tests**
  Round-trip test for the store. Key stability test across reopens. Anchor position tests on fixture diffs.
