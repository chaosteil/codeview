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
  cmd = "Codeview",
}
```
To set options, set the opts:

```lua
{
  "chaosteil/codeview",
  cmd = "Codeview",
  opts = {,
    diff = { style = "split" },
    sidebar = { position = "right", width = 50 },
  },
}
```

`:help codeview-config` shows every option and its default value.

## Quick start

1. Run `:Codeview HEAD~3..HEAD` in a repository.
2. Walk the files in the sidebar. Press `<CR>` to open a diff.
3. Press `i` on a line to write a comment. Save it with `:w`. Press `i` again
   to edit it.
4. Press `<leader>co` to see all comments of the review.
5. Press `<leader>cx` there to read the review as markdown.
6. Press `<leader>cy` to put the review into your clipboard.

`:Codeview export` runs the same export from any window of the session.

On a jj repository the argument is a revset, for example
`:Codeview trunk()..@`. For a GitHub pull request, run `:Codeview pr 128`.

## Commands

```vim
:Codeview HEAD             " one commit
:Codeview HEAD~3..HEAD     " a range of commits
:Codeview main...feature   " the changes since the merge base
:Codeview pr 128           " review a GitHub pull request
:Codeview                  " pick one commit from the log
:Codeview close            " close the session
:Codeview files            " open or close the changed-files sidebar
:Codeview comments         " open or close the comment overview
:Codeview back             " back to the review from a file
:Codeview export           " render the comments as markdown
:Codeview submit           " send the comments to the pull request
```

## Documentation

Run `:help codeview` for the full documentation: the diff view, the comment
workflow, the keymaps (`:help codeview-keymaps`), export, submit, and the Lua
API (`:help codeview-api`).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the project conventions, the test
harness, and the lint setup.

## License

MIT. Read [LICENSE](LICENSE) for the text.
