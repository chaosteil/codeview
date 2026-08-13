# M7 — Inline comments

Goal: leave comments in the diff.
Done when: a comment survives a Neovim restart and shows at the correct line.

## Hard constraints

These rules hold for every task in this milestone. A review that finds a violation
must report it as high severity.

1. The diff buffer stays `nomodifiable` at all times. Never set `modifiable = true` on a
   diff buffer to insert comment text, not even for one moment.
2. A comment never becomes a real line. Show comments only as extmark decorations:
   `virt_lines`, `virt_text`, `sign_text`, and highlights. The line count of the diff
   buffer never changes when you add, edit, or delete a comment.
3. Comment input happens in a separate floating scratch buffer with its own modifiable
   buffer. The user never types into the diff buffer.
4. The comment file is the only write target. Never write to the reviewed source files,
   never write to the diff buffers, never touch the working copy of the repository.
5. The M4 line map stays correct after a comment appears. Virtual lines must not shift
   the mapping between buffer rows and file lines.

## Tasks

- [x] **T7.1 — Data model**
  Define LuaCATS types. Session file: key, repo, range, timestamp, comments.
  Comment: id, file, start line, end line, side (old/new), commit, timestamp, state, body.

- [x] **T7.2 — Session key**
  Derive the store directory from the repo path (slug). Derive the file name from a short hash of the repo root and the resolved range.
  A reopen of the same range computes the same key and finds the file directly.

- [x] **T7.3 — Store: write and parse**
  Write the session file as markdown: session frontmatter, one section per comment with a fields block and a body.
  Parse it back without loss. Write atomically (temp file, then rename).

- [x] **T7.4 — Comment editor**
  A key opens a small floating window with its own markdown scratch buffer. Save on write, discard on quit.
  In normal mode the comment targets the current line. In visual mode it targets the selected range, like the GitHub UI.
  The diff buffer stays read-only through the whole flow. The float holds the only modifiable buffer.

- [x] **T7.4a — Insert keys open the comment editor**
  The diff buffer is read-only, so the insert commands do nothing there. Map them to the
  comment editor instead, because that is the one thing a reviewer wants to type into.
  In normal mode, `i`, `a`, `o`, and `O` open the editor for the line under the cursor.
  In visual mode, `I`, `A`, and `c` open the editor for the selected line range.
  Do not map `i` in visual mode. It is the prefix for the text objects, and `vi(` must still work.
  Keep an explicit keymap (`<leader>cc` by default) that does the same thing in both modes.
  Every one of these keys comes from the config and the user can change or disable it.
  These maps are buffer-local to the diff buffers. They never apply to a normal file buffer.
  In the editor float, `:w` saves the comment and `q` or `<Esc><Esc>` discards it.

- [x] **T7.5 — Anchors in the diff**
  Place an extmark over the comment range. Show a sign on each covered line.
  Map diff-buffer lines to file lines through the M4 line map, for both sides.

- [x] **T7.6 — Comment display**
  Show the comment body at the cursor position: a float on hover key, or virtual lines below the range.
  Pick one as default and make it configurable.

- [x] **T7.7 — Load on reopen**
  On session open, compute the key (T7.2), load the file, and place all anchors.

- [x] **T7.8 — Edit and delete**
  Reopen the editor for the comment under the cursor. Delete with a confirm step.
  Persist every change to the session file.

- [x] **T7.9 — Tests**
  Round-trip test for the store. Key stability test across reopens. Anchor position tests on fixture diffs.

- [x] **T7.10 — Keymap tests**
  Assert that `i`, `a`, `o`, and `O` in the diff buffer open the editor and do not start insert mode.
  Assert that `I`, `A`, and `c` in visual mode open the editor with the correct line range.
  Assert that `vi(` still selects a text object in the diff buffer.
  Assert that the maps are buffer-local and absent from a normal file buffer.

- [x] **T7.11 — Read-only guarantee tests**
  Assert that the diff buffer keeps `modifiable = false` before, during, and after the comment flow.
  Assert that the line count and the text of the diff buffer do not change when a comment is
  added, edited, and deleted. Assert that only extmarks change.
  Assert that the reviewed source files on disk do not change during a comment flow.
