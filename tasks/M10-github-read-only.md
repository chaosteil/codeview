# M10 — GitHub PRs, read-only

Goal: inspect a PR as if it were local.
Done when: you can review a PR offline-style, with the full M2–M9 feature set.

## Tasks

- [x] **T10.1 — gh wrapper**
  Wrap the `gh` CLI in one async module with JSON parsing and the T1.3 error shape.
  Add a `gh auth status` check to `:checkhealth codeview`.

- [x] **T10.2 — PR metadata**
  Fetch title, author, branches, state, and commits with `gh pr view --json`.

- [x] **T10.3 — PR refs without checkout**
  Fetch the PR head and base into local refs (`git fetch origin pull/<n>/head`).
  Build the review range `base...head` without a change to the working copy.

- [x] **T10.4 — `:CodeView pr <number>`**
  Wire the PR range into the normal session. Show the PR title in the sidebar header.
  The session key for the store is `pr-<number>` plus the head commit.

- [x] **T10.5 — Remote comments**
  Fetch existing review comments with `gh api`. Map them to file and line from their diff position data.

- [x] **T10.6 — Remote comment display**
  Show remote comments inline, marked as remote and read-only, next to local anchors.
  List them in the overview under a remote section.

- [x] **T10.7 — Tests**
  Record `gh` JSON fixtures. Mock the exec helper and test the mapping and session wiring.
