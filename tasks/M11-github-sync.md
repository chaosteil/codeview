# M11 — GitHub two-way sync

Goal: send local comments to the PR.
Done when: a local review lands on the PR as one review with correct line positions.

## Tasks

- [ ] **T11.1 — Position mapping**
  Map a local anchor (file, start line, end line, side) to the GitHub review API fields (`side`, `start_line`, `line`).
  Detect anchors that do not map to the PR diff and collect them.

- [ ] **T11.2 — Review payload**
  Collect all unsynced comments into one `gh api` payload for `POST /pulls/<n>/reviews`.
  Support the events: approve, comment, request changes.

- [ ] **T11.3 — `:CodeViewSubmit`**
  Show a summary before the post: comment count, unmappable lines, event choice.
  Post only after confirmation.

- [ ] **T11.4 — Sync state**
  After a successful post, mark each comment as synced in the session file.
  Skip synced comments on the next submit.

- [ ] **T11.5 — Failure handling**
  On an API error, mark nothing as synced. Report the error with the server message.
  Report unmappable comments and keep them local.

- [ ] **T11.6 — Tests**
  Test the position mapping, the payload, and the sync-state transitions with mocked `gh`.
