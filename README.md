# codeview

codeview is a Neovim plugin for code review. It shows the changes of a commit,
or of a range of commits. You browse the changed files in a sidebar, read the
diffs inline or side by side, and write comments on the lines. You export the
comments as markdown, and you send them to a GitHub pull request.

- Works on git and on [jj](https://github.com/jj-vcs/jj), through one backend
  interface.
- Reviews a GitHub pull request without a checkout, through the `gh` CLI.
- Writes nothing in your repository. The comments live in one markdown file per
  review.
- No runtime dependency. The plugin uses the standard library of Neovim.

Version 0.1.0. See [CHANGELOG.md](CHANGELOG.md).

## Screenshots

The plugin renders text only, so a capture of the buffers reads like the
screen. The examples come from a small demo repository.

The changed-files sidebar, with one node per directory and a status mark per
file:

```
main~1..main
4 files, 1 commit

  ▾ doc
  │   demo.txt D
  ▾ lua/demo
  │   config.lua A
  │   init.lua M
  │   store.lua M
```

The inline diff, with a collapsed section at the head of the file:

```diff
⋯ 3 unchanged lines
@@ -4,4 +4,8 @@
   return M.items[id]
 end

+function M.put(id, item)
+  M.items[id] = item
+end
+
 return M
```

A comment on three lines. The sign marks every covered row, and the body shows
in virtual lines below the range. The buffer itself stays read-only:

```
  ⋯ 3 unchanged lines
  @@ -4,4 +4,8 @@
     return M.items[id]
   end

▌ +function M.put(id, item)
▌ +  M.items[id] = item
▌ +end
  ▌ comment L7-9 (new)
  ▌ this needs a test for the empty id
  +
   return M
```

The comment overview, with the comments as children of their file:

```
main~1..main
3 comments, 1 resolved

  ▾ lua/demo 3
  │ ▾ config.lua 1
  │ │ ✓ L3 new b65909e name the options here
  │ ▾ init.lua 1
  │ │ ▌ L4 new b65909e the default is fine, dro…
▸ │ ▾ store.lua 1
  │ │ ▌ L7-9 new b65909e this needs a test for …
```

The side-by-side diff. Two windows hold the same number of rows, so a change
sits on the same screen row on both sides:

```
⋯ 3 unchanged lines            ⋯ 3 unchanged lines
@@ -4,4 @@                     @@ +4,8 @@
  return M.items[id]             return M.items[id]
end                            end

                               function M.put(id, item)
                                 M.items[id] = item
                               end

return M                       return M
```

## Requirements

- Neovim 0.11 or later.
- `git` for the git backend.
- `jj` for the jj backend (optional).
- `gh` for GitHub pull request review (optional).

Run `:checkhealth codeview` to see what your system has.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "chaosteil/codeview",
  cmd = {
    "CodeView",
    "CodeViewClose",
    "CodeViewFiles",
    "CodeViewComments",
    "CodeViewExport",
    "CodeViewSubmit",
  },
  ---@module "codeview"
  ---@type codeview.Config
  opts = {},
}
```

With [mini.deps](https://github.com/nvim-mini/mini.deps):

```lua
MiniDeps.add({ source = "chaosteil/codeview" })
require("codeview").setup({})
```

Without a plugin manager, put the repository on your `runtimepath` and run
`:helptags doc`. The plugin works without a `setup()` call. Every option then
holds its default value.

To set options, call `setup()`:

```lua
require("codeview").setup({
  diff = { style = "split" },
  sidebar = { position = "right", width = 50 },
})
```

You can also set `vim.g.codeview` before the plugin loads:

```lua
vim.g.codeview = { sidebar = { position = "right" } }
```

## Quick start

1. Run `:CodeView HEAD~3..HEAD` in a repository.
2. Walk the files in the sidebar. Press `<CR>` to open a diff.
3. Press `i` on a line to write a comment. Save it with `:w`. Press `i` again
   to edit it.
4. Press `<leader>co` to see all comments of the review.
5. Run `:CodeViewExport` to put the review in your clipboard.

## Commands

```vim
:CodeView HEAD             " one commit
:CodeView HEAD~3..HEAD     " a range of commits
:CodeView main...feature   " the changes since the merge base
:CodeView pr 128           " review a GitHub pull request
:CodeView                  " pick one commit from the log
:CodeView!                 " pick the first and the last commit of a range
:CodeViewClose             " close the session
:CodeViewFiles             " open or close the changed-files sidebar
:CodeViewComments          " open or close the comment overview
:CodeViewExport            " render the comments as markdown
:CodeViewSubmit            " send the comments to the pull request
```

## Review a git range

```vim
:CodeView v0.2.0..v0.3.0
:CodeView main...my-feature
:CodeView 4f1c0a2
```

The plugin sends the argument to git as it is, so `main@{2 days ago}` works
too. A single revision reviews that commit against its parent.

```lua
require("codeview").setup({
  backend = "git",             -- skip the detection
  diff = { style = "inline" },
  sidebar = { position = "left", width = 24 },
})
```

## Review a jj revset

On a jj repository the argument is a revset:

```vim
:CodeView @              " the working-copy commit
:CodeView ::@            " the whole history of the working copy
:CodeView trunk()..@     " the commits that trunk does not hold
```

codeview sends the argument to jj as it is. The head of the revset is the new
side of the review. The parent of the roots of the revset is the base. Every jj
call runs with `--ignore-working-copy`, so no call snapshots your working copy.

A colocated repository has a `.jj` directory and a `.git` directory. codeview
takes the jj backend there. codeview always takes the repository with the
deepest root, so a git clone inside a jj repository keeps the git backend. To
force one backend, set the `backend` option:

```lua
require("codeview").setup({
  backend = "jj",
})
```

## Review a GitHub pull request

```vim
:CodeView pr 128   " one pull request
:CodeView pr       " the pull request of the branch of the repository
```

The command needs the `gh` CLI and a login (`gh auth login`). The working copy
never changes: the command fetches two refs of the plugin and checks out no
branch.

```lua
require("codeview").setup({
  github = {
    remote = "upstream",   -- "" takes origin, or the first remote
    comments = true,       -- show the review comments of the pull request
    max_comments = 500,
  },
})
```

The review range is `base...head`, so it holds the changes of the "Files
changed" tab. Every key of a local review works. `:CodeViewSubmit` sends your
comments back as one review.

## Commits

The commits of the range come before the files in the sidebar, under one group
node. Each entry shows the short id and the subject, and the oldest commit
reads first.

```
main~2..main
7 files, 2 commits

  ▾ Commits
  │   4f1c0a2 feat(store): keep the items of a session
  │   9ab21cd fix(store): drop an item that has no id
  ▾ lua/demo
  │   store.lua M
```

Open an entry like a file. The document holds the id, the author, the date,
the message, and the files that the commit changes:

```
commit 9ab21cd8f0b3e2a1c7d5e4f6a8b9c0d1e2f3a4b5
Author: Ada Lovelace <ada@example.com>
Date:   2026-08-12T09:14:02+02:00

    fix(store): drop an item that has no id

    An item without an id never reads back, so the put call
    rejects it now.

2 changed files:

    M  lua/demo/store.lua
    M  tests/store_spec.lua
```

Comment on it like on a line of code. The comment takes the commit of the
document, so every comment stays with its own commit. GitHub takes no comment
on a commit message, so `:CodeViewSubmit` keeps such a comment local and
reports it. Set `commit_message = false` to leave the commits out.

## Sidebar

The first line of the sidebar is **Comments**, with the number of comments of
the review. Press `<CR>` on it, or double-click it, to open the comment
overview. A double click on a file opens its diff, and a double click on a
directory folds it.

The sidebar shows the changed files as a tree. A chain of directories with one
child each becomes one node. Each file line ends with a status mark: `A` added,
`M` modified, `D` deleted, `R` renamed, `C` copied, `T` type changed, `U`
unmerged. A directory that hides its children shows the marks of the files
below it.

## Layout

The sidebar keeps its width. A file that opens takes the window of the file
that was open, so the windows of the tab page stay as they are. Resize the
sidebar by hand and the next file keeps your width.

## Diff view

`<CR>` in the sidebar opens the diff of the file under the cursor. The status
column shows the line number of the old file and the line number of the new
file. The view hides an unchanged section of more than three lines behind one
row. Press `za` to show those lines.

`<leader>ct` switches between the inline diff and the side-by-side diff. The
switch keeps the diff and the line of the cursor, so the backend reads no file
again. The new style also becomes the `diff.style` option:

```lua
require("codeview").setup({ diff = { style = "split" } })
```

### Large diffs

The view reads the file of one row of the sidebar, and no other file. A range
of 400 files opens as fast as a range of four.

A file can still be too large to compare. The `diff.max_lines` option holds the
highest number of lines that the two sides may hold together. Above that number
the view shows two rows:

```
The diff holds 48210 lines. The limit diff.max_lines is 20000.
Press <CR> to show it.
```

`<CR>` reads the file again, without the limit. The key maps on such a diff
only. Set `diff.max_lines` to 0 to remove the limit for every file.

## Key hints

A row at the bottom of the screen shows the keys of the window that has the
cursor, the way a terminal tool does. It holds the keys that you do not guess
from the window, so `i` and `<CR>` stay out of it:

```
 ]h next hunk  ]f next file  za unfold  <space>ct style  K read comment
```

The row follows your keymaps, so it names the keys that you set. Set
`hints.enabled = false` to leave it out, or `hints.actions` to name the actions
of a surface yourself:

```lua
require("codeview").setup({
  hints = {
    enabled = true,
    actions = {
      view = {
        { action = "toggle_style", text = "style" },
        { action = "toggle_overview", text = "comments" },
      },
    },
  },
})
```

## Colors

The diff keeps the colors of the code. codeview parses each side of the file
with treesitter and writes the captures into the diff buffer, so a Lua file
reads like Lua. The diff itself then colors the background only: green behind
an added row, red behind a removed row.

The plugin needs a treesitter parser for the language of the file. A file
without one keeps the plain diff colors. Set `diff.syntax = false` to turn the
whole layer off, which also gives the row colors their foreground back.

## Edit the file

`gf` leaves the review and opens the real file. The window of the diff takes
the file of your working copy, with the cursor on the line that the diff shows.
From there you write and save it like any other file.

The file holds the state of your working copy, and not the revision of the
review, so the line is the line of the change and the text around it can
differ. The sidebar stays open: press `<CR>` on the file to read its diff
again. A close of the session leaves the file window alone.

`gf` also works on a file line of the sidebar, and it reports a commit
document or a file that the working copy does not hold.

## Comments

The diff buffer is read-only, so the insert keys are free. They open the
comment editor instead. `i` and `a` read the line first: a line that already
holds a comment opens that comment, the way `i` changes the text of a normal
buffer, and a line without one starts a new comment. `o` and `O` always start a
new comment, so a second comment on the same line stays one keypress away. In
the visual mode `I`, `A`, and `c` comment on the selected lines, like the
GitHub review UI. The visual mode keeps `i` free, so `vi(` still selects a text
object.

The editor opens inline by default, under the commented row and in the width of
the diff. The space comes from virtual lines, so the rows below move down while
you type and move back when you finish. It starts in insert mode. Set
`comments.editor = "float"` for a float in the middle of the screen, or
`comments.start_insert = false` to start in normal mode.

`:w` saves the comment, and `q` or `<Esc><Esc>` discards it. The diff buffer
never becomes modifiable. A comment shows as extmarks only: a sign on every
covered line, and virtual lines below the range.

A comment anchors to a file, a line range, a side of the diff, and a commit. A
removed line anchors to the old side, and an added or unchanged line to the new
side. A comment keeps its line in both diff styles.

All comments of a session live in one markdown file, under
`~/.config/nvim/review/<repo>/<session-key>.md`. The key is a hash of the
repository root and of the resolved range, so a reopen of the same range shows
the comments again. codeview writes the file atomically, and it writes no other
file.

## Comment overview

`:CodeViewComments`, or `<leader>co`, opens a second sidebar with every comment
of the session. `<CR>` opens the diff of the file and moves the cursor to the
anchor of the comment. A collapsed section that hides the line shows its lines
again.

Every change of a comment sends an event, so the overview and the diff stay in
step: a delete in the overview clears the signs in the diff at once. The events
also run the `User` autocmds `CodeViewCommentAdded`, `CodeViewCommentChanged`,
`CodeViewCommentDeleted`, and `CodeViewReviewSubmitted`.

## Export

`:CodeViewExport` renders the comments of the session as markdown. The text
goes into a scratch buffer and into the `+` register, so you paste the review
into a chat window or into a pull request description:

```markdown
# codeview review: main~1..main

- range: `80f26999..b65909e1`
- commits: 1
- comments: 3 on 3 files, 1 resolved

## lua/demo/config.lua

### L3 · new · b65909e1 · resolved

name the options here

## lua/demo/store.lua

### L7-9 · new · b65909e1

this needs a test for the empty id
```

Each comment holds its line range, its side, and the commit of the lines, so a
reader finds the code without the plugin. The files come in the order of the
sidebar, and the comments of one file come in line order.

`:CodeViewExport z` writes the register `z` instead of the register of the
`export.register` option. `:CodeViewExport!` writes the register only, without
the scratch buffer.

The `export.template` option replaces the renderer. The function gets the
session and the data of the export, and returns the text:

```lua
require("codeview").setup({
  export = {
    register = "z",
    template = function(session, data)
      return string.format("%s: %d comments", session:label(), data.count)
    end,
  },
})
```

## Submit

`:CodeViewSubmit` sends the comments of the session to the pull request. The
comments go out as one review, so the pull request shows one entry with all the
lines.

The command asks for the event of the review and for its text. Then it shows a
summary:

```
codeview: submit 2 comments to PR #128 of ada/demo as request-changes
  lua/codeview/store.lua L12-14 new  the id must stay stable here
  lua/codeview/view.lua L88 new      this branch needs a test
1 comment stays local:
  lua/codeview/init.lua L4 new: the diff of the pull request does not hold new line 4
```

Nothing reaches GitHub before you pick `submit`. No autocommand, no write of a
file, and no keymap posts by itself.

`:CodeViewSubmit request-changes` skips the question about the event. The
events are `comment`, `approve`, and `request-changes`. `:CodeViewSubmit!`
skips the question about the text of the review.

GitHub takes a comment only on a line of its diff. A comment on another line
stays local, and the summary names it with the reason. Each comment carries its
sync state in the session file, so no comment goes out twice.

## Keymaps

Every key is buffer-local. The plugin sets no global map, and it maps no key in
a file buffer of your own.

| Action            | Default          | Where     | What it does                       |
| ----------------- | ---------------- | --------- | ---------------------------------- |
| `open_file`       | `<CR>` `2-click` | S O       | open the file, or toggle the node  |
| `toggle_node`     | `<Tab>`          | S O       | show or hide the children          |
| `expand_all`      | `zR`             | S O D     | show every hidden line or node     |
| `collapse_all`    | `zM`             | S O D     | hide every section or node         |
| `next_file`       | `]f`             | S D       | open the next file                 |
| `prev_file`       | `[f`             | S D       | open the previous file             |
| `next_hunk`       | `]h`             | D         | jump to the next hunk              |
| `prev_hunk`       | `[h`             | D         | jump to the previous hunk          |
| `expand_context`  | `za`             | D         | show or hide the section           |
| `load_diff`       | `<CR>`           | D\*       | render a diff above the limit      |
| `toggle_style`    | `<leader>ct`     | S D       | switch inline and side by side     |
| `edit_file`       | `gf`             | S D       | edit the file in the working copy  |
| `comment`         | `<leader>cc`     | D         | edit or write the comment          |
| `comment_insert`  | `i` `a`          | D         | edit or write the comment          |
| `comment_add`     | `o` `O`          | D         | write another comment on the line  |
| `comment_visual`  | `I` `A` `c`      | D         | comment on the selected lines      |
| `edit_comment`    | `<leader>ce`     | O D       | edit the comment                   |
| `delete_comment`  | `<leader>cd`     | O D       | delete the comment                 |
| `resolve_comment` | `<leader>cr`     | O D       | resolve the comment, or reopen it  |
| `show_comment`    | `K`              | D         | show the comment in a float        |
| `toggle_overview` | `<leader>co`     | S O D     | open or close the overview         |
| `editor_save`     | `ZZ`             | E         | save the comment                   |
| `editor_cancel`   | `q` `<Esc><Esc>` | E         | discard the comment                |
| `close`           | `q`              | S O D X   | close the session or the panel     |

`S` sidebar, `D` diff view, `O` comment overview, `E` comment editor, `X`
export buffer. The comment editor also saves with `:w`.

\* The load key maps on a diff that the `diff.max_lines` limit stopped, and on
no other diff. `<CR>` keeps its own action in every diff that the view shows.

Set an entry to `false` to disable it. A list holds more than one key for one
action, and a list of yours replaces the default list:

```lua
require("codeview").setup({
  keymaps = {
    show_comment = "gh",
    comment_insert = { "i", "a" },
    comment_visual = false,
  },
})
```

## Configuration

The defaults are:

```lua
{
  backend = "auto", -- "auto" | "git" | "jj"
  commit_message = true,
  diff = {
    style = "inline", -- "inline" | "split"
    context = 3,
    max_lines = 20000, -- lines of both sides, 0 removes the limit
    word_diff = true,
    syntax = true,
  },
  sidebar = {
    position = "left", -- "left" | "right"
    width = 20,
    auto_open = true,
    icons = {
      expanded = "▾",
      collapsed = "▸",
      file = " ",
      guide = "│",
      current = "▸",
    },
  },
  overview = {
    position = "right", -- "left" | "right"
    width = 48,
    auto_open = false,
  },
  comments = {
    dir = vim.fs.joinpath(vim.fn.stdpath("config"), "review"),
    display = "virtual", -- "virtual" | "float"
    sign = "▌",
    resolved_sign = "✓",
    remote_sign = "▏",
    border = "rounded",
    width = 72,
    height = 10,
    editor = "inline", -- "inline" | "float"
    start_insert = true,
  },
  hints = {
    enabled = true,
    actions = false,
  },
  export = {
    register = "+",
    template = false, -- false uses the built-in renderer
  },
  github = {
    remote = "", -- git remote of the pull request refs, "" takes origin
    comments = true, -- read the review comments of the pull request
    max_comments = 500,
  },
  keymaps = {
    open_file = { "<CR>", "<2-LeftMouse>" },
    toggle_node = "<Tab>",
    expand_all = "zR",
    collapse_all = "zM",
    next_file = "]f",
    prev_file = "[f",
    next_hunk = "]h",
    prev_hunk = "[h",
    expand_context = "za",
    load_diff = "<CR>",
    toggle_style = "<leader>ct",
    edit_file = "gf",
    comment = "<leader>cc",
    comment_insert = { "i", "a" },
    comment_add = { "o", "O" },
    comment_visual = { "I", "A", "c" },
    edit_comment = "<leader>ce",
    delete_comment = "<leader>cd",
    resolve_comment = "<leader>cr",
    show_comment = "K",
    toggle_overview = "<leader>co",
    editor_save = "ZZ",
    editor_cancel = { "q", "<Esc><Esc>" },
    close = "q",
  },
  log_level = vim.log.levels.WARN,
}
```

`setup()` rejects an unknown option and names it.

## Highlights

Every group of codeview links to a standard group, with `default = true`, so
your colorscheme wins. To change one color, set the group after your
colorscheme:

```lua
vim.api.nvim_set_hl(0, "CodeViewCurrent", { link = "Visual" })
```

`:help codeview-highlights` holds the full list.

## Lua API

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

`:help codeview-api` holds every call.

## Health check

Run `:checkhealth codeview`. The report shows the Neovim version, the plugin
version, the state of the configuration, the `git`, `jj`, and `gh` executables,
and the login state of `gh`.

## Documentation

Run `:help codeview`.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the project conventions, the test
harness, and the lint setup.

## License

MIT. Read [LICENSE](LICENSE) for the text.
