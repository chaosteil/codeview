---
name: rex-codeview
description: Hand finished code changes, or files that no repository tracks,
  to a human for review in codeview (Neovim) in a Rex pane beside the agent,
  wait until they quit, and read their review comments as markdown. Use when
  the user wants to review the changes or a file themselves, also when they
  do not name the skill, for example "I want to review this", "let me review
  it", "let me look at the diff", or "let me review the plan file". Also use
  when work must get a human code review before it continues. Do not use
  when the user asks the agent or a subagent to review the code, for example
  "review your code" or "/code-review".
compatibility: Needs Rex (REX_BLOCK set, rex in REX_BIN_DIR or on PATH) and
  Neovim with the codeview plugin. A review of a revision also needs git or
  jj.
---

# Review in codeview through Rex

This skill opens codeview in a Rex pane beside you. Rex is a terminal
multiplexer: it splits your terminal into panes. The user reads your changes
in codeview, writes comments, and closes the review. Neovim then quits. You
then get the comments as markdown, and you do what they ask.

codeview reviews one of two things:

- A revision: the commits of your work, as a diff. This is the normal
  review. Use it for every change that a repository tracks.
- Files with `--file`: the plain files, with no diff. Use it ONLY for files
  that no repository tracks, for example a plan that you wrote outside a
  repository, or an untracked file.

## When to use it

Use this skill when the user wants to read and comment on the changes
themselves. The user does not have to name the skill. For example:

- "I want to review this."
- "Let me review it."
- "Let me look at the diff."
- "Open it in codeview."
- "Let me review the plan file."

Also use this skill when your work must get a human code review before you
continue.

Do not use this skill when the user asks you or another agent to do the
review. For example:

- "Review your code."
- "Look for bugs in your changes."
- "Have a subagent review this."
- "/code-review"

If you cannot tell who must do the review, ask the user.

If `REX_BLOCK` is not set, you do not run in a Rex pane, and the skill does
not work. Tell the user to do the review by hand:

1. Run `nvim -c "Codeview <rev>"`. For untracked files, run
   `nvim -c "Codeview file <path>"`.
2. Write the comments.
3. Run `:Codeview export`, and paste the markdown into the chat.

## Revision or files

Review a revision when a repository tracks the change. Review files with
`--file` only when no repository tracks them:

- A file outside every repository: use `--file`.
- An untracked file in a git repository, for example a scratch file that
  you do not plan to commit, or a file that `.gitignore` ignores: use
  `--file`. If the file belongs to your work, commit it and review the
  revision.
- A file that git tracks, also with changes that you did not commit: do not
  use `--file`. Commit the work and review the revision.
- A file in a jj repository: jj tracks every new file of the working copy
  that no ignore rule ignores, at its next command. Review `@` or your stack
  instead. Use `--file` only for a file that an ignore rule ignores.

The script refuses a path that git tracks, or that the last jj snapshot of
`@` holds. If you are not sure, review the revision.

## Pick the revision

Give the range of your own work, and no other commits. The revision must not
start with `-`. The script refuses such a revision.

- jj: for example `trunk()..@-` when `@` is empty, or the stack that you
  built. On jj, `@` holds the working copy, so the review can show it.
- git: for example `main..HEAD`. On git, the review shows committed work
  only. Commit your work first.

## Pick the files

Give each file or directory after `--file`. A relative path starts at the
current directory, or at `-C DIR`. A directory gives every file below it,
without the hidden, ignored, binary, and large files.

## Procedure

The script path is relative to the directory of this skill.

1. Run `scripts/codeview-review open REVISION`. Add `-C DIR` before
   `REVISION` if the repository is not the current directory.
   - For untracked files, run
     `scripts/codeview-review open --file PATH...` instead. Add `-C DIR`
     before `--file` to start the relative paths at `DIR`.
   - The command prints a handle (a directory). Keep it for step 2.
   - Tell the user in one line that the review is open in the pane on the
     right.
2. Run `scripts/codeview-review wait HANDLE`.
   - Claude Code: run it as a background command (`run_in_background`),
     without a DURATION. You get a notice when the user closes the review.
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
- `1`: The review did not open, for example because of a bad revision or a
  missing file. The message is on stderr. The script removed the handle.
- `2`: The review is still open. Run `wait` again.
