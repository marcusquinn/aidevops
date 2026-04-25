# GH-20835: diagnose pre-push hook 60s timeout

## Session Origin

Worker dispatch from issue #20835. Phase 1 investigation only — no code changes.

## What

Timed all four pre-push guards against a realistic diff (1 modified `.sh` file, ahead of `origin/main`).

## Findings

| Guard | Wall time |
|-------|-----------|
| `privacy-guard-pre-push.sh` | 104ms |
| `scope-guard-pre-push.sh` | 11ms |
| `pre-push-dup-todo-guard.sh` | 1.1s |
| `complexity-regression-pre-push.sh` | **1m 38s** ← slow guard |

Root cause: `nesting-depth` metric in `complexity-regression-helper.sh` scans all 949 `.sh` files in the repo (via `shfmt --to-json | jq` AST walk, ~50ms/file) × 2 worktrees = 97s. Exceeds the 60s timeout in `full-loop-helper.sh`.

Phase 2 filed as #20842 (change-scoped scan fix).

## Files Scope

- `todo/tasks/GH-20835-brief.md` (this file)
