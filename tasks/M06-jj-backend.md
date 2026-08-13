# M6 — jj backend

Goal: the same review flow on jj repos.
Done when: all M2–M5 features work in a jj repo without code changes outside the backend.

## Tasks

- [x] **T6.1 — jj detection**
  Detect a jj repo by the `.jj` directory. In a colocated repo, prefer the jj backend.
  Add a config option to force one backend.

- [x] **T6.2 — jj: resolve and log**
  Resolve revsets with `jj log --no-graph -T` and a stable template.
  Parse commit records with both change id and commit id. Use the change id in the UI.

- [x] **T6.3 — jj: changed files**
  List changed files for a range with `jj diff --summary`.
  Map the output to the same status records as git.

- [x] **T6.4 — jj: file content**
  Read file content at a revision with `jj file show -r <rev> <path>`.
  Handle the working copy (`@`) and missing sides of added and deleted files.

- [x] **T6.5 — Revsets in `:CodeView`**
  Accept a revset argument when the jj backend is active. Pass it through without git-style parsing.

- [x] **T6.6 — Shared test suite on jj**
  Add a jj fixture repo builder. Run the backend-agnostic suite from T1.9 against it.
  CI installs jj. Without jj in $PATH the jj specs are pending, not failed.

## Review notes

The review of the milestone found these points. Every point is fixed:

- Detection takes the repository with the deepest root. A git clone inside a jj
  repository keeps the git backend. The backend order decides only between two
  repositories with the same root.
- A forced backend without its executable reports the missing executable.
- A revset that names no commit reports that the revset holds no commits. Only
  a revset that jj rejects gives `bad_revision`.
- The virtual root commit is not a valid head. `root()` and `trunk()` without a
  trunk bookmark report that the root commit holds no content.
- `file_content()` returns the target of a symbolic link. `jj file show`
  refuses such a path, so the backend reads the target from a git-format diff.
- The picker writes the label of a range with the syntax of the backend: `^..`
  for git, `-..` for jj.
