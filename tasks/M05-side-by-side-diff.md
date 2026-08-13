# M5 — Side-by-side diff view

Goal: a second diff style and a fast switch.
Done when: you can toggle the diff style in one keypress and both styles show the same hunks.

## Tasks

- [ ] **T5.1 — Two-window layout**
  Open two vertical windows: old version left, new version right.
  Both windows belong to the session and close with it.

- [ ] **T5.2 — Alignment**
  Compute filler lines from the hunk data, so that matching lines sit on the same row.
  Render fillers as virtual lines.

- [ ] **T5.3 — Synchronized movement**
  Bind scrolling and cursor movement between the two windows (`scrollbind`, `cursorbind`).
  Make sure that fillers do not break the alignment during scrolling.

- [ ] **T5.4 — Highlights on both sides**
  Apply removal highlights on the left and addition highlights on the right, from the shared hunk data.

- [ ] **T5.5 — Style toggle**
  One key switches between inline and side-by-side. Keep the cursor on the same content line through the line map.
  Store the default style in the config.

- [ ] **T5.6 — Word-level diff (stretch)**
  Highlight changed words inside modified lines, in both styles.

- [ ] **T5.7 — Tests**
  Assert the alignment (filler positions) and the toggle round-trip for fixture diffs.
