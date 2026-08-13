# M1 — VCS core: interface and git backend

Goal: one backend interface, implemented for git.
Done when: Lua code can list the changed files and file contents for any git revision range, with tests.

## Tasks

- [x] **T1.1 — Backend interface**
  Define the interface in `lua/codeview/vcs/init.lua` with LuaCATS types.
  Functions: `detect(dir)`, `resolve_rev(rev)`, `log(opts)`, `changed_files(range)`, `file_content(rev, path)`.

- [x] **T1.2 — Async exec helper**
  Wrap `vim.system` in one helper: run a command, collect stdout and stderr, return a result or a structured error.
  All backend calls go through this helper.

- [x] **T1.3 — Error type**
  Define one error shape: code, message, command, stderr.
  Return errors as values. Do not throw from backend functions.

- [x] **T1.4 — Git: repo detection**
  Detect the repo root with `git rev-parse --show-toplevel`. Return nil outside a repo.

- [x] **T1.5 — Git: resolve and log**
  Resolve a revision with `git rev-parse`. List commits with `git log` and a stable `--format` string.
  Parse into commit records: id, subject, author, date.

- [x] **T1.6 — Git: changed files**
  List changed files for a range with `git diff --name-status -M`.
  Parse the statuses: added, modified, deleted, renamed (with old path).

- [x] **T1.7 — Git: file content**
  Read file content at a revision with `git show <rev>:<path>`.
  Return empty content for the missing side of added and deleted files.

- [x] **T1.8 — Fixture repo builder**
  Write a test helper that builds a temporary git repo with known commits.
  (Needs: nothing. Used by T1.9.)

- [x] **T1.9 — Backend test suite**
  Write the interface tests against the fixture repo: detection, log, changed files, content, errors.
  Write the suite backend-agnostic, so M6 can reuse it for jj.
