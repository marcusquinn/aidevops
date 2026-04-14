# t2091 — fix dispatch-dedup self-login bypass + worker closed-issue guard + process docs

**Session origin:** interactive, root cause analysis of GH#18956 (wasted worker session)
**Tier:** `tier:standard`
**GitHub issue:** GH#18961

## What

Three-part fix for the race condition that caused PR #18956 (wasted worker session):

1. `dispatch-dedup-helper.sh` — skip self-login exemption when `active_claim == "true"`
2. `full-loop-helper.sh` — abort `commit-and-pr` if issue is already CLOSED
3. `AGENTS.md` — document mandatory `interactive-session-helper.sh claim` for `#auto-dispatch` tasks

## Why

PR #18956 was a full Sonnet session (~8 min) that implemented the same work already done
interactively. Root cause: `_is_assigned_compute_blocking()` self-login exemption fires before
the `active_claim` check. In single-user setups (pulse runner login == interactive user login),
`origin:interactive` is never consulted — the pulse sees the assignee as "self" and dispatches.

## How

- EDIT: `.agents/scripts/dispatch-dedup-helper.sh:718` — add `&& "$active_claim" != "true"` guard
- EDIT: `.agents/scripts/full-loop-helper.sh` — add closed-issue pre-flight in `cmd_commit_and_pr()`
- EDIT: `.agents/AGENTS.md` — Auto-Dispatch section addition
- EDIT: `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` — Tests 9 & 10

## Acceptance criteria

- [x] Test 9 (single-user: self-assigned + origin:interactive blocks) passes
- [x] Test 10 (self-assigned + no active label is still passive — GH#10521 regression) passes
- [x] All 10 tests pass
- [x] Shellcheck clean
- [x] AGENTS.md documents mandatory claim call
