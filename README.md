# codeview

codeview is a Neovim plugin for code review. It shows the changes of a commit,
or of a range of commits. You browse the changed files in a sidebar, read the
diffs inline or side by side, and write comments on the lines. You can export
the comments as markdown, and later send them to GitHub.

> Status: early development. This release contains the plugin skeleton only.
> The review commands come with the next milestones. See `MILESTONES.md`.

## Requirements

- Neovim 0.11 or later.
- `git` for the git backend.
- `jj` for the jj backend (optional).
- `gh` for GitHub pull request review (optional).

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "chaosteil/codeview",
  ---@module "codeview"
  ---@type codeview.Config
  opts = {},
}
```

The plugin also works without options. To set options without `lazy.nvim`,
call `setup()`:

```lua
require("codeview").setup({
  diff = { style = "split" },
  sidebar = { position = "right", width = 50 },
})
```

## Configuration

The defaults are:

```lua
{
  backend = "auto", -- "auto" | "git" | "jj"
  diff = {
    style = "inline", -- "inline" | "split"
    context = 3,
    max_lines = 20000,
    word_diff = true,
  },
  sidebar = {
    position = "left", -- "left" | "right"
    width = 40,
    auto_open = true,
  },
  comments = {
    dir = vim.fs.joinpath(vim.fn.stdpath("config"), "review"),
    display = "virtual", -- "virtual" | "float"
    sign = "▌",
  },
  export = {
    register = "+",
    template = false, -- false uses the built-in renderer
  },
  keymaps = {
    open_file = "<CR>",
    next_file = "]f",
    prev_file = "[f",
    next_hunk = "]h",
    prev_hunk = "[h",
    toggle_style = "<leader>ct",
    comment = "<leader>cc",
    delete_comment = "<leader>cd",
    close = "q",
  },
  log_level = vim.log.levels.WARN,
}
```

Set a keymap to `false` to disable it.

## Health check

Run `:checkhealth codeview`. The report shows the Neovim version, the state of
the configuration, and the `git`, `jj`, and `gh` executables.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the project conventions, the test
harness, and the lint setup.

## License

MIT
