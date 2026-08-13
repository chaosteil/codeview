# M0 — Plugin skeleton

Goal: a plugin that loads, with a test and CI loop.
Done when: the plugin loads in a clean Neovim, and the test suite runs in CI.

## Tasks

- [ ] **T0.1 — Plugin layout**
  Create the standard directories: `lua/codeview/`, `plugin/`, `doc/`, `tests/`.
  Add `plugin/codeview.lua` with a load guard and `lua/codeview/init.lua` with an empty API table.

- [ ] **T0.2 — Config module**
  Create `lua/codeview/config.lua` with a defaults table and a deep merge for user options.
  Document each option with a LuaCATS annotation.

- [ ] **T0.3 — `setup()` entry point**
  Implement `require("codeview").setup(opts)`. Validate the options and store the merged config.
  Make sure that the plugin also works without a `setup()` call.

- [ ] **T0.4 — Health check**
  Create `lua/codeview/health.lua` for `:checkhealth codeview`.
  Report the Neovim version and the `git`, `jj`, and `gh` executables with their versions.

- [ ] **T0.5 — Test harness**
  Add plenary.nvim as a dev dependency and a `tests/minimal_init.lua`.
  Write one smoke test: the plugin loads and `setup()` accepts a table.

- [ ] **T0.6 — Lint and format**
  Add stylua and luacheck configuration files.
  Add a `Makefile` with `test`, `lint`, and `fmt` targets.

- [ ] **T0.7 — CI workflow**
  Add a GitHub Actions workflow. Run the tests on stable and nightly Neovim. Run the linter.

- [ ] **T0.8 — README stub**
  Write a short README: what the plugin does, and an install example for lazy.nvim.
