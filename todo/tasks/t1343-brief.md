---
mode: subagent
---
# t1343: Fix worker PR lookup race condition in issue lifecycle

## Origin

- **Created:** 2026-02-27
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human + ai-interactive)
- **Conversation context:** User investigated issue #2250 (t1327.6 opsec agent) which was correctly closed by the supervisor with merged PR #2268, but a worker subsequently added `needs-review` label with "No merged PR on record" — a false positive caused by a race condition between supervisor and worker issue lifecycle transitions.

## What

Fix the race condition where a worker's issue lifecycle transition overwrites a supervisor's correct closure. When a worker transitions a task to a terminal state (`deployed`/`verified`), it must:

1. Check if the GitHub issue is already closed before attempting any label/comment changes
2. If already closed, check if a merged PR exists on the issue (via `gh pr list --search` or issue timeline) rather than relying solely on its own DB
3. Never add `needs-review` to an already-closed issue that has a linked merged PR

This is an AI guidance fix (update supervisor/worker docs), not a bash script fix, per the "Intelligence Over Scripts" principle.

## Why

False-positive `needs-review` labels on correctly-closed issues create noise for human reviewers. In the observed case (#2250), the supervisor correctly closed the issue at 19:29 with PR #2268 evidence, but the worker added `needs-review` at 19:55 and 19:59 because its own PR lookup failed. This pattern will recur for any task where the PR was created by a different session than the one running the lifecycle transition.

The root causes are:
1. **No issue-state check**: Workers don't check if the issue is already closed before modifying it
2. **Single-source PR lookup**: Workers only check their own DB for PR URLs, missing PRs created by other sessions
3. **No supervisor-worker coordination**: No guard against a worker modifying an issue the supervisor already resolved

## How (Approach)

Update the AI guidance docs that control worker and supervisor behavior during issue lifecycle transitions:

1. **`.agents/scripts/commands/pulse.md`** — Add a rule to Step 2a (Observe Outcomes) or a new lifecycle section: "Before modifying any issue labels or adding comments, check `gh issue view <number> --json state` — if already CLOSED, do not add `needs-review` or modify labels unless reopening for a valid reason."

2. **`.agents/reference/planning-detail.md`** — Add a PR lookup fallback rule: "When checking for a merged PR, don't rely solely on the task DB. Also check `gh pr list --repo <slug> --search '<task_id>' --state merged` to find PRs created by other sessions."

3. **`.agents/workflows/full-loop.md`** (if exists) or equivalent worker guidance — Add: "Before transitioning a task to a terminal state, verify the GitHub issue's current state. If the issue is already closed with a merged PR, skip the transition and log that the supervisor already handled it."

Key patterns from the archived `issue-sync.sh` (`.agents/scripts/supervisor-archived/issue-sync.sh:409-447`) show the deterministic logic that was replaced by AI reasoning — the AI guidance must cover the same edge cases.

## Acceptance Criteria

- [ ] Worker guidance docs include "check issue state before modifying" rule
  ```yaml
  verify:
    method: codebase
    pattern: "already.*(closed|CLOSED)|issue.*state.*before"
    path: ".agents/"
  ```
- [ ] PR lookup guidance includes fallback to `gh pr list --search` when DB lookup fails
  ```yaml
  verify:
    method: codebase
    pattern: "gh pr list.*search|fallback.*PR.*lookup"
    path: ".agents/"
  ```
- [ ] The specific scenario from #2250 is documented as an example in the guidance
  ```yaml
  verify:
    method: codebase
    pattern: "race.*condition|supervisor.*already.*closed"
    path: ".agents/"
  ```
- [ ] No new bash scripts created (guidance-only fix)
  ```yaml
  verify:
    method: manual
    prompt: "Confirm no new .sh files were created — only .md guidance files were modified"
  ```

## Context & Decisions

- **Why guidance, not script**: The archived `issue-sync.sh` had deterministic PR lookup logic (lines 409-447) but it was archived as part of the "Intelligence Over Scripts" migration (t1335-t1337). The replacement is AI-guided reasoning in pulse.md and worker docs. The fix must follow the same pattern.
- **Why not just fix the DB**: The worker's DB not having the PR URL is a symptom, not the root cause. Multiple sessions can work on the same task (supervisor closes, worker transitions). The fix must handle cross-session state.
- **Observed instance**: Issue #2250, PR #2268, supervisor closed at 19:29, worker flagged at 19:55/19:59 on 2026-02-26.

## Relevant Files

- `.agents/scripts/commands/pulse.md` — Primary supervisor guidance (Step 2a: Observe Outcomes)
- `.agents/reference/planning-detail.md` — Task completion and PR verification rules
- `.agents/scripts/supervisor-archived/issue-sync.sh:409-447` — Archived deterministic logic (reference for edge cases)
- `.agents/workflows/full-loop.md` — Worker lifecycle guidance (if exists)

## Dependencies

- **Blocked by:** None
- **Blocks:** None (but reduces false-positive noise for all future task completions)
- **External:** None

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review current pulse.md and planning-detail.md guidance |
| Implementation | 45m | Add lifecycle guard rules to 2-3 guidance docs |
| Testing | 30m | Verify guidance is clear by tracing the #2250 scenario through the updated docs |
| **Total** | **~1.5h** | |
