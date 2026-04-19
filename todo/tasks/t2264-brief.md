<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2264: PR scope-leak — rebase can silently revert unrelated merged changes

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code (interactive, t2249 session)
- **Observation:** Rebasing onto a post-#19789-merge `origin/main` silently reverted PR #19789's changes to 3 unrelated files (`pre-commit-hook.sh`, `validate-version-consistency.sh`, `test-pre-commit-hook-duplicate-ids.sh`). Caught during final diff review before push — would have shipped a regression otherwise. Conflict resolution on `.task-counter` appears to have confused git about concurrent change scope.

## What

**Parent task — needs design pass. Do NOT auto-dispatch.**

A pre-push guard that enforces PR scope against an explicit file list would have caught this silent-revert class of bug. Current guards (privacy, complexity) check content/metrics but not which files are in the diff vs the brief's declared scope.

## Why

Silent reverts are the most dangerous class of regression — no CI red, no reviewer flag, merges cleanly, breaks something in production days later. A mechanical check at push-time (files in diff ⊆ files declared in brief) closes the hole with near-zero cognitive overhead and catches the exact class of rebase pathology that hit t2249.

## How — decomposition candidates

This is a thinking-tier parent task. Children should be filed separately after design review:

### Child A — brief schema

Add a `files_scope` field to the brief template (`templates/brief-template.md`) where a worker explicitly declares the files they intend to touch. Must be:

- Parsable (simple list of paths, one per line, glob-optional).
- Optional for backwards compat with existing briefs (guard skips if absent).
- Part of the tier checklist.

### Child B — scope guard script

New `.agents/hooks/scope-guard-pre-push.sh`:

- Read the PR's file list from `git diff --name-only origin/main...HEAD`.
- Read the brief's `files_scope` from `todo/tasks/$TASK_ID-brief.md`.
- Block on any file in the diff that isn't in the declared scope.
- Bypass via `SCOPE_GUARD_DISABLE=1` or a `scope-ok` PR label (handled at CI layer).
- Emit actionable message: "File `foo/bar.sh` in diff but not in brief scope. Update the brief OR remove the change OR set `SCOPE_GUARD_DISABLE=1`."

### Child C — integration

Wire the scope guard into `install-pre-push-guards.sh` with `--guard scope` subflag. Mirror the existing privacy/complexity integration pattern.

### Child D — regression fixture

Test harness that simulates a rebase-introduced scope creep:

- Two files modified in PR brief.
- Rebase introduces a change to a third file.
- Scope guard must block the push.

### Design questions (why this is thinking-tier)

1. How strict is the match? Literal path, glob, directory-prefix? Probably glob to match how briefs actually reference files.
2. How does the guard behave when no brief exists (task IDs for quick-fix `GH#NNN` PRs without briefs)? Skip, or require a brief? Leaning "skip with warning" but worth debating.
3. Interaction with `parent-task` issues — parent PRs touch planning files only; their `files_scope` should be obvious (TODO.md, todo/tasks/*).
4. CI-side variant — should the same check run in GitHub Actions as a required check? Server-side enforcement is stronger but adds CI latency.
5. What about legitimate out-of-scope changes (fixing a typo noticed in passing)? The bypass env var handles it, but maybe a nicer `--scope-extend` interactive flow is worth considering.

## Tier

Tier:thinking. Design decisions required before any child can be dispatched. `#parent` blocks dispatch of this issue itself — only children execute.

## Acceptance

- [ ] Parent remains open while children land.
- [ ] At least Child A (brief schema) and Child B (guard script) merged.
- [ ] Pre-push blocks a push where files outside the brief's declared scope are modified.
- [ ] Bypass path documented (env var + label).
- [ ] Design questions above resolved in a design note (can live in this brief or a sibling doc).

## Relevant files

- `templates/brief-template.md` — target for Child A
- `.agents/hooks/` — target for Child B (new file)
- `.agents/scripts/install-pre-push-guards.sh` — target for Child C
- `.agents/scripts/complexity-regression-helper.sh` — pattern reference for Child B
- `.agents/hooks/privacy-guard-pre-push.sh` — pattern reference for Child B
- `.agents/hooks/complexity-regression-pre-push.sh` — pattern reference for Child B
