# codeview

codeview is a Neovim plugin for code review. It shows the changes of a commit,
or of a range of commits. You browse the changed files in a sidebar, read the
diffs inline or side by side, and write comments on the lines. You can export
the comments as markdown, and later send them to GitHub.

> Status: early development. This release selects the revisions of a review,
> lists the changed files in a sidebar, and shows an inline diff of each file.
> The side-by-side diff and the comments come with the next milestones.
> See `MILESTONES.md`.

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

## Usage

Select what to review:

```vim
:CodeView HEAD             " one commit
:CodeView HEAD~3..HEAD     " a range of commits
:CodeView main...feature   " the changes since the merge base
:CodeView                  " pick one commit from the log
:CodeView!                 " pick the first and the last commit of a range
:CodeViewClose             " close the session
```

The session reports the range, the commits, and the changed files. From Lua:

```lua
local codeview = require("codeview")

codeview.open("HEAD~1..HEAD", nil, function(session, err)
  if err then
    return
  end
  print(session:summary())
  for _, file in ipairs(session:changed_files()) do
    print(file.status, file.path)
  end
end)
```

## Diff view

`<CR>` in the sidebar opens the diff of the file under the cursor. The diff
view shows a unified diff of the two revisions:

```diff
@@ -1,6 +1,6 @@
 line 01
 line 02
-line 03
+line 03 changed
 line 04
 line 05
 line 06
⋯ 20 unchanged lines
```

The status column shows the line number of the old file and the line number of
the new file. These keys work in the diff buffer:

| Key  | Action                                        |
| ---- | --------------------------------------------- |
| `]h` | jump to the next hunk                         |
| `[h` | jump to the previous hunk                     |
| `za` | show or hide the section under the cursor     |
| `zR` | show every hidden line                        |
| `zM` | hide every section again                      |
| `]f` | open the next file                            |
| `[f` | open the previous file                        |
| `q`  | close the review session                      |

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
    icons = {
      expanded = "▾",
      collapsed = "▸",
      file = " ",
      guide = "│",
      current = "▸",
    },
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
    toggle_node = "<Tab>",
    expand_all = "zR",
    collapse_all = "zM",
    next_file = "]f",
    prev_file = "[f",
    next_hunk = "]h",
    prev_hunk = "[h",
    expand_context = "za",
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
