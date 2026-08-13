# M11 — GitHub two-way sync

Goal: send local comments to the PR.
Done when: a local review lands on the PR as one review with correct line positions.

## Tasks

- [x] **T11.1 — Position mapping**
  Map a local anchor (file, start line, end line, side) to the GitHub review API fields (`side`, `start_line`, `line`).
  Detect anchors that do not map to the PR diff and collect them.
  The map and the coverage run on the diff settings of git (myers, indent heuristic), because GitHub takes only the lines of the diff of git.

- [x] **T11.2 — Review payload**
  Collect all unsynced comments into one `gh api` payload for `POST /pulls/<n>/reviews`.
  Support the events: approve, comment, request changes.

- [x] **T11.3 — `:CodeViewSubmit`**
  Show a summary before the post: comment count, unmappable lines, event choice.
  Post only after confirmation.

- [x] **T11.4 — Sync state**
  After a successful post, mark each comment as synced in the session file.
  Skip synced comments on the next submit.

- [x] **T11.5 — Failure handling**
  On an API error, mark nothing as synced. Report the error with the server message.
  Report unmappable comments and keep them local. The report runs on a failed post too, not only on a post that GitHub took.

- [x] **T11.6 — Tests**
  Test the position mapping, the payload, and the sync-state transitions with mocked `gh`.

## Notes

- The coverage of a file comes from a local diff with the settings of git. A
  measurement over 44 file revisions of this repository gives the same lines as
  `git diff -U3`. A later milestone can read `GET /pulls/<n>/files` instead and
  parse the `@@` headers of the patch that GitHub itself validates against.
- An edit of a synced comment clears the sync mark. The next submit sends the
  new text as a new comment, because the review API writes no comment twice.
