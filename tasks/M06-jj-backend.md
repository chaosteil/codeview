# M6 — jj backend

Goal: the same review flow on jj repos.
Done when: all M2–M5 features work in a jj repo without code changes outside the backend.

## Tasks

- [ ] **T6.1 — jj detection**
  Detect a jj repo by the `.jj` directory. In a colocated repo, prefer the jj backend.
  Add a config option to force one backend.

- [ ] **T6.2 — jj: resolve and log**
  Resolve revsets with `jj log --no-graph -T` and a stable template.
  Parse commit records with both change id and commit id. Use the change id in the UI.

- [ ] **T6.3 — jj: changed files**
  List changed files for a range with `jj diff --summary`.
  Map the output to the same status records as git.

- [ ] **T6.4 — jj: file content**
  Read file content at a revision with `jj file show -r <rev> <path>`.
  Handle the working copy (`@`) and missing sides of added and deleted files.

- [ ] **T6.5 — Revsets in `:CodeView`**
  Accept a revset argument when the jj backend is active. Pass it through without git-style parsing.

- [ ] **T6.6 — Shared test suite on jj**
  Add a jj fixture repo builder. Run the backend-agnostic suite from T1.9 against it.
