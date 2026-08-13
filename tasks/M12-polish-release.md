# M12 — Polish and release

Goal: a plugin other people can install.
Done when: a stranger can install, configure, and use the plugin from the README alone.

## Tasks

- [x] **T12.1 — Vimdoc**
  Write `doc/codeview.txt`: commands, config options, keymaps, and the comment file format.

- [x] **T12.2 — README**
  Write the full README: features, screenshots, install, config examples for git, jj, and PR review.
  The Screenshots section holds text captures of the buffers. Image captures of a demo
  session (colors, signs, window layout) stay open. This machine runs Neovim headless
  only, so it records no image.

- [x] **T12.3 — Keymap audit**
  List every default keymap. Make each one overridable through the config. Document them in T12.1.

- [x] **T12.4 — Performance pass**
  Load file diffs lazily. Add a line limit for large diffs with a manual override.
  Profile the sidebar and diff rendering on a large fixture range.

- [ ] **T12.5 — Release**
  Add a changelog. Tag `v0.1.0`. Write a short announcement post.
  The changelog (`CHANGELOG.md`), the version (`codeview.version = "0.1.0"`), the
  license (`LICENSE`), and the announcement (`ANNOUNCEMENT.md`) are done.
  Three steps stay open, because each one needs a human:
  1. Publish the repository as `chaosteil/codeview`, the name of `README.md`.
  2. Add the `origin` remote. The repository holds no remote now.
  3. Tag `v0.1.0` and push the tag. Run the steps at the end of `CHANGELOG.md`.
     A plugin manager resolves `version = "*"` against a tag, and not a bookmark.
     jj 0.44 creates no git tag, so the tag comes from git in the colocated repository.
  Then open the GitHub release and paste the 0.1.0 section of `CHANGELOG.md`.

## Measurements

Reference machine: Apple Silicon, Neovim 0.13.0-dev. Fixture: 400 changed files in
nested directories, plus `big.txt` with 8000 lines that changes every second line.
`tests/perf_spec.lua` builds the same fixture, so the numbers repeat from the repository.

| Step                              | Before  | After   |
| --------------------------------- | ------- | ------- |
| session open, 401 files           | 29 ms   | 29 ms   |
| sidebar open and first render     | 6 ms    | 6 ms    |
| sidebar render, 501 rows          | 2 ms    | 2 ms    |
| diff of `big.txt`, 4000 hunks     | 279 ms  | 14 ms   |
| view open of `big.txt`            | 296 ms  | 36 ms   |
| switch to the side-by-side style  | 25 ms   | 23 ms   |
| async open, per file              | 8 ms    | 8 ms    |

The comparison of a file was the only hot spot. `vim.diff()` with the histogram
algorithm costs 264 ms at 8000 lines per side and 1267 ms at 16000, because its cost
grows with the square of the number of hunks. The myers algorithm costs 1 ms and 2 ms
on the same input. `codeview.diff.algorithm()` therefore takes myers above 4000 lines
per side. `tests/perf_spec.lua` holds the guard.

The file diffs were lazy already: a session reads the file list and the log, and the
view reads one file when you open it.
