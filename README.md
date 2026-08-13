# codeview

codeview is a Neovim plugin for code review. It shows the changes of a commit,
or of a range of commits. You browse the changed files in a sidebar, read the
diffs inline or side by side, and write comments on the lines. You can export
the comments as markdown, and later send them to GitHub.

> Status: early development. This release selects the revisions of a review,
> lists the changed files in a sidebar, shows the diff of each file inline or
> side by side, and holds the comments of the review. The export and the GitHub
> calls come with the next milestones. See `MILESTONES.md`.

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

On a jj repository the argument is a revset:

```vim
:CodeView @              " the working-copy commit
:CodeView ::@            " the whole history of the working copy
:CodeView trunk()..@     " the commits that trunk does not hold
```

codeview sends the argument to jj as it is. The head of the revset is the new
side of the review. The parent of the roots of the revset is the base.

A colocated repository has a `.jj` directory and a `.git` directory. codeview
takes the jj backend there. codeview always takes the repository with the
deepest root, so a git clone inside a jj repository keeps the git backend. To
force one backend, set the `backend` option to `"git"` or `"jj"`.

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
the new file.

## Side-by-side diff

`<leader>ct` switches between the inline diff and the side-by-side diff. The
side-by-side style shows the old version at the left and the new version at
the right:

```
@@ -1,4 @@              @@ +1,6 @@
one                     one
two                     two changed
three                   three
four                    four
                        five
                        six
```

Both sides hold the same number of rows, so a change sits on the same screen
row in both windows. A change with more lines on one side gets a filler row on
the other side. The two windows scroll and move the cursor together. The
switch keeps the diff and the line of the cursor.

The new style also becomes the `diff.style` option. To start every review side
by side, set the option:

```lua
require("codeview").setup({ diff = { style = "split" } })
```

## Diff keys

These keys work in the diff buffer:

| Key          | Action                                    |
| ------------ | ----------------------------------------- |
| `]h`         | jump to the next hunk                     |
| `[h`         | jump to the previous hunk                 |
| `za`         | show or hide the section under the cursor |
| `zR`         | show every hidden line                    |
| `zM`         | hide every section again                  |
| `]f`         | open the next file                        |
| `[f`         | open the previous file                    |
| `<leader>ct` | switch the diff style                     |
| `i` `a` `o` `O` | comment on the line under the cursor   |
| `I` `A` `c`  | comment on the selected lines (visual)    |
| `<leader>cc` | comment on the line or on the selection   |
| `<leader>ce` | edit the comment under the cursor         |
| `<leader>cd` | delete the comment under the cursor       |
| `K`          | show the comment under the cursor         |
| `q`          | close the review session                  |

## Comments

The diff buffer is read-only, so the insert keys are free. They open the
comment editor instead: `i`, `a`, `o`, and `O` comment on the line under the
cursor. In the visual mode `I`, `A`, and `c` comment on the selected lines,
like the GitHub review UI. The visual mode keeps `i` free, so `vi(` still
selects a text object.

The editor is a float with its own markdown buffer. `:w` saves the comment,
and `q` or `<Esc><Esc>` discards it. The diff buffer never becomes modifiable.
A comment shows as extmarks only: a sign on every covered line, and virtual
lines below the range.

A comment anchors to a file, a line range, a side of the diff, and a commit.
The line map of the render gives the anchor, so a comment keeps its line in
both diff styles. A removed line anchors to the old side, and an added or
unchanged line to the new side.

All comments of a session live in one markdown file, under
`~/.config/nvim/review/<repo>/<session-key>.md`. The key is a hash of the
repository root and of the resolved range, so a reopen of the same range shows
the comments again. codeview writes the file atomically, and it writes no
other file.

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
    border = "rounded",
    width = 72,
    height = 10,
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
    comment_insert = { "i", "a", "o", "O" },
    comment_visual = { "I", "A", "c" },
    edit_comment = "<leader>ce",
    delete_comment = "<leader>cd",
    show_comment = "K",
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
