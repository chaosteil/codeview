# M12 — Polish and release

Goal: a plugin other people can install.
Done when: a stranger can install, configure, and use the plugin from the README alone.

## Tasks

- [ ] **T12.1 — Vimdoc**
  Write `doc/codeview.txt`: commands, config options, keymaps, and the comment file format.

- [ ] **T12.2 — README**
  Write the full README: features, screenshots, install, config examples for git, jj, and PR review.

- [ ] **T12.3 — Keymap audit**
  List every default keymap. Make each one overridable through the config. Document them in T12.1.

- [ ] **T12.4 — Performance pass**
  Load file diffs lazily. Add a line limit for large diffs with a manual override.
  Profile the sidebar and diff rendering on a large fixture range.

- [ ] **T12.5 — Release**
  Add a changelog. Tag `v0.1.0`. Write a short announcement post.
