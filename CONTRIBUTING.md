# Contributing to codeview

## Quick start

```sh
make test       # run the test suite (downloads plenary.nvim on the first run)
make lint       # run luacheck, when it is installed
make fmt        # format the Lua files with stylua
make fmt-check  # fail when a file needs formatting
make clean      # remove the .tests sandbox
make            # fmt-check, lint, and test
```

The test harness clones plenary.nvim into `.tests/site` on the first run. The
`.tests/` directory also holds isolated XDG directories, so a test run does not
touch your Neovim configuration. Git ignores the whole directory.

Read `MILESTONES.md` for the plan, and `tasks/` for the task breakdown of each
milestone.

## CONVENTIONS

These rules apply to all code in this repository. Later milestones build on
them. Do not change a rule without a change to this file.

### Language and dependencies

- Lua only. The runtime uses the Neovim standard library.
- plenary.nvim is a test dependency. It is not a runtime dependency.
- The minimum Neovim version is 0.11. `config.validate()` uses the 0.11 form of
  `vim.validate()`.

### Module layout

- One module per file, in `lua/codeview/<module>.lua`.
- Backends live in `lua/codeview/vcs/<backend>.lua`.
- Each module builds a table `M`, and returns it at the end of the file.
- Put the `local` aliases of the standard library at the top of the file, for
  example `local api = vim.api`.
- `plugin/codeview.lua` holds the load guard only. It must stay small, because
  it runs at startup. All other code loads on demand.
- `lua/codeview/init.lua` holds the public API. A user calls only functions
  from this module.

### Naming

- Modules, functions, and variables use `snake_case`.
- LuaCATS classes use the prefix `codeview.`, for example `codeview.Config`.
- A private function is a file-local function. It has no `M.` prefix.

### Annotations

- Write a LuaCATS annotation for every public function: `---@param`,
  `---@return`, and a one-line description above them.
- Give each returned value a name, for example `---@return string? err`.
- Declare a data structure with `---@class` before its first use.

### Configuration

- `lua/codeview/config.lua` owns the defaults, the merge, and the validation.
- Every option has a concrete default value. No default is `nil`. The defaults
  table is therefore the full list of valid keys.
- Read the active configuration with `require("codeview.config").get()`. Do not
  cache the table, because `setup()` replaces it.
- `setup()` is optional. Every module must work with the defaults.
- Add a new option to the defaults, to the validation, to the LuaCATS class, to
  the README, and to `doc/codeview.txt`, in the same commit.

### Errors

- Backend and IO code returns errors as values. It does not throw them.
- The order of the returned values is `result, err`. On success `err` is `nil`.
  On failure `result` is `nil`.
- The error value is a `codeview.Error` table with these fields:

  ```lua
  ---@class codeview.Error
  ---@field code string    -- stable identifier, for example "not_a_repo"
  ---@field message string -- one sentence for the user
  ---@field command? string[] -- the command that failed
  ---@field stderr? string    -- the output of the failed command
  ```

- `config.setup()` returns a plain message string, because it runs before the
  error module is useful.
- Show an error to the user with `vim.notify` and a `vim.log.levels` value.
  Respect `config.get().log_level`.

### Asynchronous work

- Run external commands with `vim.system`. Prefer the callback form.
- Do not block the user interface. Use `vim.schedule` before an API call from a
  callback.

### Tests

- All tests live in `tests/` and end with `_spec.lua`.
- Use the plenary busted style: `describe`, `it`, `assert`.
- Shared code lives in `tests/helpers.lua`. Load it with
  `require("tests.helpers")`.
- Call `helpers.unload()` in `after_each`, because the modules hold state.
- A test must not touch the Neovim configuration of the user. Use the XDG
  directories from the Makefile, or a temporary directory.
- Fixture repositories go into a temporary directory. Git commands inside a
  fixture are correct and expected.

### Format and lint

- stylua owns the format. The configuration is `.stylua.toml`.
- Run `make fmt` before a commit.
- luacheck configuration is `.luacheckrc`. luacheck is optional locally, but CI
  runs it.

### Documentation

- Write in Simplified Technical English. Short sentences, active voice, and an
  imperative for each step. One instruction per sentence.
- Do not use marketing words.

### Version control

This repository uses jj (jujutsu). Do not use git for versioning here. Write
the commit messages in the conventional commit style, for example
`feat(config): add the diff style option`.
