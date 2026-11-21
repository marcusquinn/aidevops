## What

Extend the existing "implementation PRs do not edit `TODO.md`" rule to interactive implementation PRs. Interactive sessions should publish TODO rows and briefs through `planning-commit-helper.sh`, which opens its own small auto-merge planning PR, and keep `TODO.md` out of code PRs.

## Why

- `.agents/reference/task-lifecycle.md:255` says only "Implementation workers do not edit `TODO.md` as part of code fixes". Interactive sessions get no matching guidance, and they do add TODO rows to their code PRs.
- `TODO.md` rows are backups, not dispatch input (`.agents/reference/planning-publication-lifecycle.md:22-28`: issue-first, with orphan rows seeded by Pulse TODO sync). A code PR gains nothing from carrying them.
- Cost observed on 2026-11-21 in one interactive session: PRs #39596 and #39617 both carried new TODO rows at the section anchor where every planning PR inserts, just before `## In Progress`. Each conflicted with `main` after green checks. That cost two extra rebase and CI cycles of about 10-25 minutes each. On one of them, `pull_request` CI never started while it conflicted (tracked separately as GH#39626). The final fix was to drop `TODO.md` from the code PR and publish the rows via `planning-commit-helper.sh`.

## How

- In `.agents/reference/task-lifecycle.md` line 255, make the rule cover interactive implementation PRs too. Add one sentence: publish TODO rows and briefs with `planning-commit-helper.sh "plan: ..."` from a linked worktree. It opens a separate planning PR that carries `allow-auto-merge`. A code PR that edits `TODO.md` re-conflicts with concurrent planning PRs at the same anchor.
- In `.agents/workflows/full-loop.md`, add a one-line pointer to that rule next to the existing headless "no TODO.md edits" note (around line 128). Keep it short; full-loop.md is loaded often.
- No code change. Do not touch always-loaded `AGENTS.md` files.

## Files Scope

- `.agents/reference/task-lifecycle.md`
- `.agents/workflows/full-loop.md`

## Acceptance

- Both files state that interactive implementation PRs keep `TODO.md` out of the code PR and use `planning-commit-helper.sh` instead.
- No other behaviour or guidance changes.

## Verification

- `.agents/scripts/markdownlint-diff-helper.sh --base "$(git merge-base origin/main HEAD)"` reports 0 new violations.
- `rg -n "planning-commit-helper" .agents/reference/task-lifecycle.md .agents/workflows/full-loop.md` shows the new references.
