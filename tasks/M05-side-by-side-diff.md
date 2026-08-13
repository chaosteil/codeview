# M5 — Side-by-side diff view

Goal: a second diff style and a fast switch.
Done when: you can toggle the diff style in one keypress and both styles show the same hunks.

## Tasks

- [x] **T5.1 — Two-window layout**
  Open two vertical windows: old version left, new version right.
  Both windows belong to the session and close with it.

- [x] **T5.2 — Alignment**
  Compute filler lines from the hunk data, so that matching lines sit on the same row.
  Render fillers as virtual lines.
  Note: a filler is a buffer row without text, with a highlight and virtual text on it.
  A virtual line moves one side down during a scroll, because `scrollbind` counts buffer
  lines. A real row keeps the two sides aligned at every top line.

- [x] **T5.3 — Synchronized movement**
  Bind scrolling and cursor movement between the two windows (`scrollbind`, `cursorbind`).
  Make sure that fillers do not break the alignment during scrolling.

- [x] **T5.4 — Highlights on both sides**
  Apply removal highlights on the left and addition highlights on the right, from the shared hunk data.

- [x] **T5.5 — Style toggle**
  One key switches between inline and side-by-side. Keep the cursor on the same content line through the line map.
  Store the default style in the config.

- [x] **T5.6 — Word-level diff (stretch)**
  Highlight changed words inside modified lines, in both styles.

- [x] **T5.7 — Tests**
  Assert the alignment (filler positions) and the toggle round-trip for fixture diffs.
