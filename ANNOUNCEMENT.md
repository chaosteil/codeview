# Announcement post for v0.1.0

Post this text on r/neovim, on the Neovim Discourse, and in the release notes.
Keep the code blocks. They read as text on every site.

---

## codeview 0.1.0 — code review inside Neovim, on git, jj, and GitHub

I wrote codeview because I read most pull requests in Neovim already, and I
missed the review part: the file list, the comments, and one text that I can
paste back.

codeview shows the changes of a commit, or of a range of commits. You browse
the changed files in a sidebar, read the diffs inline or side by side, and
write comments on the lines. You export the comments as markdown, or you send
them to a GitHub pull request as one review.

```vim
:CodeView HEAD~3..HEAD     " a range of commits
:CodeView main...feature   " the changes since the merge base
:CodeView trunk()..@       " a jj revset
:CodeView pr 128           " a GitHub pull request
```

What it does:

- **A sidebar of the changed files**, as a tree, with a status mark per file.
- **Two diff styles.** `<leader>ct` switches between the unified diff and the
  side-by-side diff. The switch keeps your line.
- **Comments on the lines.** The diff buffer stays read-only, so `i`, `a`, `o`,
  and `O` open a comment editor instead. In the visual mode `I`, `A`, and `c`
  comment on a range of lines, like the GitHub UI.
- **One file per review.** The comments live in
  `~/.config/nvim/review/<repo>/<key>.md`. Reopen the same range and they come
  back. Nothing goes into your repository.
- **git and jj.** The backend is an interface. On a colocated repository
  codeview takes jj, and it never snapshots your working copy.
- **GitHub, read and write.** `:CodeView pr 128` fetches two refs and checks
  out no branch. The diff shows the review comments that the pull request
  already holds. `:CodeViewSubmit` sends yours back as one review, with
  `approve` or `request-changes`.

What it does not do: it never writes a file of your repository, it never posts
to GitHub without your confirmation, and it needs no plugin at runtime.

Install with lazy.nvim:

```lua
{ "chaosteil/codeview", opts = {} }
```

Then run `:CodeView HEAD~1..HEAD` and press `<CR>` on a file.

Requirements: Neovim 0.11 or later, `git`, and `jj` or `gh` when you want
those. Run `:checkhealth codeview`.

Docs: `:help codeview`. The README holds the screenshots and the full keymap
list.

This is a first release. Issues and ideas are welcome, in particular from
people who review in a different order than I do.
