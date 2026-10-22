---
name: rex-codeview
description: Hand finished code changes to a human for review in codeview
  (Neovim) in a Rex pane beside the agent, wait until they quit, and read
  their review comments as markdown. Use when work must get a human code
  review in codeview before it continues.
compatibility: Needs Rex (REX_BLOCK set), Neovim with the codeview plugin,
  and git or jj.
---

# Review in codeview through Rex

This skill opens codeview in a Rex pane beside you. Rex is a terminal
multiplexer: it splits your terminal into panes. The user reads your changes
in codeview, writes comments, and quits Neovim. You then get the comments as
markdown, and you do what they ask.

## When to use it

Use this skill when your work must get a human code review before you
continue.

If `REX_BLOCK` is not set, you do not run in a Rex pane, and the skill does
not work. Tell the user to do the review by hand:

1. Run `nvim -c "Codeview <rev>"`.
2. Write the comments.
3. Run `:Codeview export`, and paste the markdown into the chat.

## Pick the revision

Give the range of your own work, and no other commits.

- jj: for example `trunk()..@-` when `@` is empty, or the stack that you
  built. On jj, `@` holds the working copy, so the review can show it.
- git: for example `main..HEAD`. On git, the review shows committed work
  only. Commit your work first.

## Procedure

The script path is relative to the directory of this skill.

1. Run `scripts/codeview-review open REVISION`. Add `-C DIR` before
   `REVISION` if the repository is not the current directory.
   - The command prints a handle (a directory). Keep it for step 2.
   - Tell the user in one line that the review is open in the pane on the
     right.
2. Run `scripts/codeview-review wait HANDLE`.
   - Claude Code: run it as a background command (`run_in_background`),
     without a DURATION. You get a notice when the user quits Neovim.
   - Other agents: give a DURATION below the time limit of your tool, for
     example `scripts/codeview-review wait HANDLE 9m`. If the exit status is
     2, the review is still open. Run `wait` again.
3. Read the output. It is the codeview export.
   - The prompt at the top tells you what to do.
   - Do each comment. Skip a comment that is marked resolved.
   - If the export has zero comments, the user approved the work.

Do not open a second review for the same handle.

## Exit status of wait

- `0`: The review is done. The markdown is on stdout. The script removed the
  handle.
- `1`: The review did not open, for example because of a bad revision. The
  message is on stderr.
- `2`: The review is still open. Run `wait` again.
