# codeview

codeview is a Neovim plugin for code review. It shows the changes of a commit,
or of a range of commits. You browse the entries in a sidebar, read the diffs
inline or side by side, and write comments on the lines. The sidebar also holds
the message of each commit, and you comment on it in the same way. You export
the comments as markdown, and you send them to a GitHub pull request.

- Works on git and on [jj](https://github.com/jj-vcs/jj), through one backend
  interface. A review of the jj commit `@` snapshots the working copy, so the
  diff holds the writes of your editor.
- Follows the repository. The review reads itself again when you commit, amend,
  or rebase in another terminal, and `<leader>cR` reads it again by hand.
- Reviews a GitHub pull request without a checkout. The `gh` CLI reads the pull
  request and posts your review. git fetches its two commits into refs of the
  plugin. The diff also shows the review comments that the pull request already
  holds.
- Writes no file in your project. The comments live in one markdown file per
  review, in the data directory of Neovim.
- No runtime dependency. The plugin uses the standard library of Neovim.

## Requirements

- Neovim 0.11 or later.
- `git` for the git backend, and for every pull request review.
- `jj` for the jj backend (optional).
- `gh` for GitHub pull request review (optional).

`:checkhealth codeview` reports the state of these tools.

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
  opts = {
    diff = { style = "split" },
    sidebar = { position = "right", width = 50 },
  },
}
```

`:help codeview-config` shows every option and its default value.

## Quick start

1. Run `:Codeview HEAD~3..HEAD` in a repository.
2. Walk the entries in the sidebar. The message of each commit reads first,
   then the changed files. Press `<CR>` to open a diff.
3. Press `i` on a line to write a comment. Save it with `:w`. Press `i` again
   to edit it.
4. Press `gf` to edit the real file. Press `<leader>cb` to come back.
5. Press `<leader>cR` to read the review again after a new commit or an amend.
6. Go to the sidebar. Press `<leader>co` to see all comments of the review.
7. Press `<leader>cx` there to read the review as markdown.
8. Press `<leader>cy` to put the review into the `+` register.

`:Codeview export` runs the same export from any window.

The text starts with a prompt that tells an agent what to do with the
comments. The `export.prompt` option replaces the prompt, and an empty text
removes it.

On a jj repository the argument is a revset, for example
`:Codeview trunk()..@`. For a GitHub pull request, run `:Codeview pr 128`.
`:Codeview submit` then sends your comments to GitHub.

## Commands

```vim
:Codeview HEAD             " one commit
:Codeview HEAD~3..HEAD     " a range of commits
:Codeview main...feature   " the changes since the merge base
:Codeview pr 128           " review a GitHub pull request
:Codeview pr               " review the pull request of the branch
:Codeview                  " pick one commit from the log
:Codeview!                 " pick two commits for a range
:Codeview close            " close the session
:Codeview files            " open or close the changed-files sidebar
:Codeview comments         " open or close the comment overview
:Codeview back             " back to the review from a file
:Codeview refresh          " read the review again from the repository
:Codeview export [reg]     " render the comments as markdown
:Codeview submit [event]   " send the comments to the pull request
```

## Documentation

Run `:help codeview` for the full documentation: the diff view, the comment
workflow, the keymaps (`:help codeview-keymaps`), pull requests, export,
submit, and the Lua API (`:help codeview-api`).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the project conventions, the test
harness, and the lint setup.

## License

MIT. Read [LICENSE](LICENSE) for the text.
