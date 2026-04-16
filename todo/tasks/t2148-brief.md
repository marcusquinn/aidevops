<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2148: scan-stale — detect and auto-recover stampless `origin:interactive` claims

## Origin

- **Created:** 2026-04-16
- **Session:** Claude Code:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** User asked why the remaining open issues weren't being dispatched. Investigation surfaced #19346 and #19347: both carried `origin:interactive` + owner assignee but had no live interactive session, no stamp in `CLAIM_STAMP_DIR`, and no running process. They blocked pulse dispatch indefinitely because `_has_active_claim` in `dispatch-dedup-helper.sh` treats the `origin:interactive` label alone as an active claim. `scan-stale` Phase 1 only detects stamp-based claims, so it couldn't surface them. Manual `gh issue edit --remove-assignee` was the only way out.

## What

Close the stampless interactive-claim recovery gap so pulse dispatch cannot be blocked forever by `origin:interactive` labels whose interactive session never ran the claim helper.

Two recovery paths (both required):

1. **Discovery path (for interactive sessions):** extend `interactive-session-helper.sh scan-stale` with a new Phase 1a that scans all pulse-enabled repos and surfaces open issues where `origin:interactive` is present, the runner (current `gh api user`) is assigned, and no stamp file exists in `CLAIM_STAMP_DIR`. Output must list `#N in slug`, issue updatedAt age, and the release command, so the agent driving the interactive session can prompt the user at session start (the existing scan-stale contract).

2. **Autonomous recovery path (for the pulse):** add `_normalize_unassign_stampless_interactive` to `pulse-issue-reconcile.sh`, wired into the existing `normalize_active_issue_assignments` coordinator. It must iterate pulse-enabled repos, find stampless origin:interactive + self-assigned issues whose `updatedAt` is older than 24h, and unassign the runner (keep the `origin:interactive` label — it's historical fact, not a claim). No status label changes. No force-close. The long 24h threshold protects genuine long-running interactive work.

Both paths share the same detection primitive (`gh issue list --label origin:interactive --assignee <runner>` + local stamp-file absence check). Extract that primitive into one helper rather than duplicating the logic across modules.

## Why

Concrete evidence from this session:
- #19346 (`refactor(pulse-triage)`) and #19347 (`investigate: issue-consolidation cascade`) were both created from an interactive session via `claim-task-id.sh`, which per t1970 auto-assigned the owner when `origin:interactive` was set. The interactive session then moved on without touching either issue and without calling `interactive-session-helper.sh claim` (no stamp was ever written).
- Pulse log showed them repeatedly blocked: `Dedup: #19346 ... already assigned — ASSIGNED: issue #19346 is assigned to marcusquinn`, then `Dedup guard blocked`.
- `scan-stale` returned 9 stale claims but NONE of them were #19346/#19347 — because no stamps exist for stampless claims.
- The memory system already knows this failure mode (recall: "claim-task-id.sh auto-assigns marcusquinn when origin is interactive ... triggers the GH#18352 dispatch-dedup block ... Workaround: `gh issue edit N --remove-assignee marcusquinn`").

Without an automated path, every future `origin:interactive` issue filed from an interactive session that doesn't formally claim becomes a permanent dispatch block until a human notices and runs `gh issue edit --remove-assignee` by hand. This is a slow leak — the cost grows with every filed issue, and the symptoms (backlog not moving) are invisible unless someone digs into the pulse log.

## Tier

### Tier checklist (verify before assigning)

- [x] 2 or fewer files to modify? (3 files + 1 test — over the cap)
- [x] Every target file under 500 lines? (interactive-session-helper.sh=857, pulse-issue-reconcile.sh=1300 — over cap)
- [ ] Exact `oldString`/`newString` for every edit? (new function bodies — skeleton only)
- [ ] No judgment or design decisions? (24h threshold, detection edge cases)
- [ ] No error handling or fallback logic to design? (offline `gh`, empty repos, jq failures)
- [x] No cross-package or cross-module changes?
- [x] Estimate 1h or less? (no — expect 2-3h)
- [ ] 4 or fewer acceptance criteria? (6 criteria below)

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file change with new helper functions, failure-mode handling, and test-harness extension. Not purely transcription — the implementer makes judgement calls on detection filter, age threshold, and offline-gh behaviour. Standard sonnet tier is the correct fit; simple tier would fail on the error-handling dimensions.

## PR Conventions

Leaf task, not parent-tagged. PR body uses `Resolves #<issue-number>` as normal.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/interactive-session-helper.sh` — add `_isc_list_stampless_interactive_claims` helper (shared primitive) and extend `_isc_cmd_scan_stale` Phase 1a block before the existing "No stale interactive claims." print.
- `EDIT: .agents/scripts/pulse-issue-reconcile.sh` — add `_normalize_unassign_stampless_interactive` helper + wire it into `normalize_active_issue_assignments` coordinator.
- `EDIT: .agents/scripts/tests/test-interactive-session-claim.sh` — add Test 8 covering Phase 1a detection (stampless claim surfaced) and Test 9 covering non-detection (stamp present → not surfaced).
- `EDIT: .agents/AGENTS.md` "Interactive issue ownership" bullet block — add a one-line note that scan-stale now has three phases (stamp-based stale + stampless interactive + closed-PR orphans) and normalize auto-recovers stampless claims after 24h.

### Implementation Steps

1. **Extract the shared detection primitive in `interactive-session-helper.sh`.** Add `_isc_list_stampless_interactive_claims` after the existing internal helpers (around line 150). Signature: `_isc_list_stampless_interactive_claims <runner_user> <slug>` — emits newline-separated JSON lines `{"number":N,"updated_at":"..."}` to stdout for each open issue in `<slug>` where:
   - `.labels[].name` contains `origin:interactive`
   - `.assignees[].login` contains `<runner_user>`
   - Local stamp file `$(\_isc_stamp_path "$number" "$slug")` does NOT exist
   One `gh issue list --repo <slug> --assignee <runner_user> --label origin:interactive --state open --json number,updatedAt,assignees,labels --limit "$PULSE_QUEUED_SCAN_LIMIT"` per repo, pipe through `jq` to emit rows, filter via `[[ ! -f "$stamp" ]]` in shell. Handle jq/gh failures by emitting nothing (fail-open for discovery).

2. **Extend `_isc_cmd_scan_stale` Phase 1a.** Between the existing Phase 1 (stamp-based stale claims) and Phase 2 (closed-PR orphans), insert a new block that iterates pulse-enabled repos from `~/.config/aidevops/repos.json`, calls `_isc_list_stampless_interactive_claims` per slug, and prints findings with the same visual format Phase 1 uses. Summary line at the end mirrors Phase 1: `Total: N stampless claim(s). Release via 'gh issue edit N --repo SLUG --remove-assignee USER' or via aidevops approve issue <N>.`

3. **Add `_normalize_unassign_stampless_interactive` to `pulse-issue-reconcile.sh`.** Place it after `_normalize_unassign_stale` (around line 313). Signature: `_normalize_unassign_stampless_interactive <runner_user> <repos_json> <now_epoch> <age_threshold_seconds>`. Per pulse repo, run `gh issue list --label origin:interactive --assignee <runner_user> --state open --json number,updatedAt --limit ...`, filter in jq for `updatedAt < (now - age_threshold)`, then for each candidate check stamp absence via the flattened slug pattern used by `_isc_stamp_path` (inline it — avoid sourcing interactive-session-helper from the pulse hot path). Call `gh issue edit <N> --repo <slug> --remove-assignee <runner_user>` for each qualifying issue. Log: `[pulse-wrapper] Stampless interactive claim auto-release: unassigned runner from #N in slug (updated NNN seconds ago, no stamp)`. Summary line at end: `[pulse-wrapper] Stampless interactive claim cleanup: released M issues`.

4. **Wire into coordinator.** Update `normalize_active_issue_assignments` (around pulse-issue-reconcile.sh:612) to call `_normalize_unassign_stampless_interactive "$runner_user" "$repos_json" "$now_epoch" "$STAMPLESS_INTERACTIVE_AGE_THRESHOLD"` after the existing `_normalize_unassign_stale`. Define `STAMPLESS_INTERACTIVE_AGE_THRESHOLD=${STAMPLESS_INTERACTIVE_AGE_THRESHOLD:-86400}` (24h) at the top of the helper, env-overridable.

5. **Tests.** Extend `tests/test-interactive-session-claim.sh`:
   - Test 8: simulate an issue with `origin:interactive` + self-assigned + no stamp → `scan-stale` output must include `#<N> in <slug>` and the updated-age line.
   - Test 9: same issue but with stamp present → scan-stale MUST NOT list it as stampless (may still list it under Phase 1 if PID is dead).
   Use the existing fixture harness (fake `gh` wrapper, tempdir stamps). Both tests MUST mock `gh issue list --label origin:interactive` output.

6. **Docs.** Update `.agents/AGENTS.md` "Interactive issue ownership" bullet for scan-stale phases + add a note that stampless claims auto-release at 24h. Keep it to one sentence — existing block is already dense.

### Verification

```bash
# 1. Shellcheck the two modified scripts:
shellcheck ~/Git/aidevops-feature-t2148-scan-stale-stampless-interactive/.agents/scripts/interactive-session-helper.sh
shellcheck ~/Git/aidevops-feature-t2148-scan-stale-stampless-interactive/.agents/scripts/pulse-issue-reconcile.sh

# 2. Run the updated test harness:
bash ~/Git/aidevops-feature-t2148-scan-stale-stampless-interactive/.agents/scripts/tests/test-interactive-session-claim.sh

# 3. Manual smoke — scan-stale Phase 1a should now surface stampless claims.
# With the running pulse paused (or via --dry-run mode), invoke scan-stale:
~/.aidevops/agents/scripts/interactive-session-helper.sh scan-stale 2>&1 | grep -A2 "Stampless"

# 4. Negative smoke — ensure no false positives when stamp is present:
#    Claim an issue properly (writes stamp) then run scan-stale — must not list it.
```

## Acceptance Criteria

- [ ] `_isc_list_stampless_interactive_claims` helper exists in interactive-session-helper.sh and emits one JSON line per matching issue.
  ```yaml
  verify:
    method: codebase
    pattern: "_isc_list_stampless_interactive_claims"
    path: ".agents/scripts/interactive-session-helper.sh"
  ```
- [ ] `scan-stale` output includes a "Stampless interactive claims" section between Phase 1 and Phase 2.
  ```yaml
  verify:
    method: bash
    run: "grep -q 'Stampless' .agents/scripts/interactive-session-helper.sh"
  ```
- [ ] `_normalize_unassign_stampless_interactive` exists in pulse-issue-reconcile.sh and is called from `normalize_active_issue_assignments`.
  ```yaml
  verify:
    method: codebase
    pattern: "_normalize_unassign_stampless_interactive"
    path: ".agents/scripts/pulse-issue-reconcile.sh"
  ```
- [ ] `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` defaults to 86400 seconds and is env-overridable.
  ```yaml
  verify:
    method: codebase
    pattern: "STAMPLESS_INTERACTIVE_AGE_THRESHOLD:-86400"
    path: ".agents/scripts/pulse-issue-reconcile.sh"
  ```
- [ ] Test harness covers both positive (stampless → detected) and negative (stamp present → not listed) cases.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-interactive-session-claim.sh 2>&1 | grep -q 'scan-stale flags stampless'"
  ```
- [ ] Shellcheck passes with zero violations on both modified helpers.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/interactive-session-helper.sh .agents/scripts/pulse-issue-reconcile.sh"
  ```

## Context

- **Root cause file:** `.agents/scripts/dispatch-dedup-helper.sh:513-522` — `_has_active_claim` treats `origin:interactive` as sufficient for active-claim status.
- **Existing gap confirmation:** `.agents/scripts/interactive-session-helper.sh:700-768` — `_isc_cmd_scan_stale` iterates `CLAIM_STAMP_DIR` stamps only.
- **Existing normalize flow:** `.agents/scripts/pulse-issue-reconcile.sh:265-312` — `_normalize_unassign_stale` handles the stamp/PID-based recovery path but requires `status:queued`/`in-progress` in scope.
- **Auto-assign source:** `claim-task-id.sh` assigns `marcusquinn` on `origin:interactive` issue creation (memory: "t1970 feature, originally to protect interactive PR filing from maintainer-gate failures").
- **Related rule:** GH#18352 / t1996 — `(active status label OR origin:interactive) AND (non-self assignee)` blocks dispatch. This fix does NOT change the rule; it adds a cleanup path so the rule's input state eventually becomes safe to dispatch.

## Test Plan

1. **Unit:** test-interactive-session-claim.sh Tests 8 and 9 (positive + negative detection).
2. **Integration:** deploy to `~/.aidevops/agents/scripts/` via `setup.sh --non-interactive`, run `interactive-session-helper.sh scan-stale` against real repo state. Verify #19346/#19347-class issues (if any remain) are surfaced under "Stampless" section.
3. **Autonomous recovery smoke:** manually create a test issue with `origin:interactive` + self-assigned + no stamp, backdate it via `gh issue edit` (can't directly, so skip or use a 10-second `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` override), trigger the normalize pass once (`normalize_active_issue_assignments "$RUNNER_USER" "$REPOS_JSON"`), verify assignee is removed.
