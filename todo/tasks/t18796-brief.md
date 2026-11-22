## What

`full-loop-helper.sh commit-and-pr` treats any diff confined to `TODO.md` and `todo/**` as planning-only and writes `For #N` (`_diff_is_planning_only`, `.agents/scripts/full-loop-helper.sh:196-209`, applied at `:242-246`). Data deliverables that a repository keeps under `todo/` (for example JSON/JSONL worklogs and specs) are not planning, so their PRs should use `Resolves #N`.

## Why

A managed repository stores award-enrichment worklogs and published specs under `todo/award-enrichment/log/**.jsonl` and `todo/award-enrichment/specs/**.json`. Every batch worker's data PR is entirely under `todo/`, so the helper writes `For #N`:

- 49 batch data PRs merged 2026-10-27 22:00 to 2026-10-29 22:30 UTC: 43 ended with `Resolves`, 6 with `For`. PR body edit history shows the `Resolves` ones were created with `For`/`Ref`/no keyword and hand-corrected by the worker after creation; the other 6 were not.
- Each uncorrected PR leaves its batch issue open after merge. Observed result: a "Partial Parent Closeout" comment on a non-parent issue and `worker_post_pr_handoff_unverified` cascade escalation `tier:standard → tier:thinking`, i.e. a second, more expensive dispatch for finished work.

PR #33990 (t18616) intended `For` only for planning diffs (`TODO.md`, briefs, plans). All planning artifacts under aidevops' own `todo/` are markdown (1071 `.md`; the only others are 2 `.sh`, 1 `.sql`, 1 `.gitkeep`).

## How

1. In `_diff_is_planning_only`, qualify only `TODO.md` and markdown under `todo/` (`todo/*.md` in a `case` pattern matches nested paths). Any other file under `todo/` (JSON, JSONL, CSV, scripts, etc.) makes the diff non-planning, so the default `Resolves` applies and the issue is labelled `status:in-review` as for any deliverable.
2. Keep the existing precedence: `--allow-parent-close` forces `Resolves`; parent-task and completion-bookkeeping still use `For`; empty diffs still do not qualify.
3. Extend the existing planning-only coverage in `.agents/scripts/tests/test-full-loop-runtime-risk.sh` (it already exercises `_diff_is_planning_only`): `todo/x/y.jsonl` only → not planning; `todo/x/y.json` + `TODO.md` → not planning; `todo/tasks/t1-brief.md` + `TODO.md` → planning.

## Acceptance

- A diff of only `todo/**/*.jsonl`/`.json` produces `Resolves #N`; markdown-only `todo/**` and `TODO.md` diffs still produce `For #N`.
- `bash .agents/scripts/tests/test-full-loop-runtime-risk.sh` and `bash .agents/scripts/tests/test-full-loop-closed-issue-bookkeeping.sh` pass; ShellCheck clean on changed files.

### Files Scope

- `.agents/scripts/full-loop-helper.sh`
- `.agents/scripts/tests/test-full-loop-runtime-risk.sh`
