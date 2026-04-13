---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2031: fix(pulse-dep-graph): respect non-dep blocks when auto-unblocking

## Origin

- **Created:** 2026-04-13
- **Session:** Claude Code:interactive
- **Created by:** marcusquinn (ai-interactive, triage of real-world dispatch waste)
- **Parent task:** none
- **Conversation context:** awardsapp#2273 (`t222: Build MCP server adapter`) was correctly marked `status:blocked` by a worker on 2026-04-11 after the worker exited BLOCKED with evidence that cited THREE reasons: (1) open `blocked-by:t215,t219,t220` chain, (2) the issue body's explicit defer gate ("Defer until Phase 1-6 are working end-to-end @alexey"), and (3) missing implementation context. On 2026-04-13 the pulse's `refresh_blocked_status_from_graph` removed `status:blocked` and re-queued the issue — because it saw the `blocked-by:` chain had resolved (all three blockers closed). The pulse then dispatched workers that had to exit BLOCKED again, wasting cycles. Root cause: the dep-graph refresh assumes any `status:blocked` label means "blocked because of open deps", but the label is also applied by worker BLOCKED exits, watchdog thrash kills, terminal-blocker detection, and manual human holds — none of which are resolved by closing the dep chain.

## What

Harden `refresh_blocked_status_from_graph` in `.agents/scripts/pulse-dep-graph.sh` so it only auto-unblocks an issue when it can prove the current block is attributable to the dep chain alone. Specifically, do NOT auto-unblock when:

1. **The issue body contains a defer/hold marker** (`defer until`, `do not dispatch`, `on hold`, etc.) — the body itself signals a human-imposed hold that the dep-graph does not model.
2. **Recent comments contain a non-dep BLOCKED marker** — a worker `**BLOCKED**` exit, a `Worker Watchdog Kill`, a `Terminal blocker detected`, an `ACTION REQUIRED` escalation, or an explicit `HUMAN_UNBLOCK_REQUIRED` tag — all of which indicate human intervention is required and that auto-unblock would discard evidence.

When either signal is present, the refresh logs the skip reason and leaves the label in place. When neither signal is present AND all blockers are resolved, it unblocks as before.

## Why

The current behaviour silently discards evidence written by workers and watchdogs. In the awardsapp#2273 case:

- A worker spent tokens collecting evidence, wrote a structured BLOCKED comment, and correctly applied `status:blocked`.
- Two days later the dep chain happened to resolve for unrelated reasons.
- The dep-graph refresh removed the label with no inspection of the prior BLOCKED comment or the body's defer gate.
- A fresh worker was dispatched, hit the same blockers, and had to exit BLOCKED again.
- A second dispatch followed within minutes (stale-recovery tick, then re-queue), each costing token budget.

Every one of those dispatches was preventable with a single additional check. The fix is a hotfix because the broken path runs every 2-minute pulse cycle across every pulse-enabled repo, so the waste compounds. Conservative-by-default is the right posture: if we're not sure the block is dep-only, leave it in place and let a human re-queue.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 2: `pulse-dep-graph.sh` + new test file `test-pulse-dep-graph-non-dep-block.sh`.
- [x] **Complete code blocks for every edit?** — yes, full diff below.
- [x] **No judgment or design decisions?** — the fix is a straightforward guard; marker regexes are enumerated, fallbacks are explicit.
- [x] **No error handling or fallback logic to design?** — `|| true` fallbacks preserved; new API call wrapped in `2>/dev/null || true`.
- [x] **Estimate 1h or less?** — ~45 minutes.
- [x] **4 or fewer acceptance criteria?** — 4.

**Selected tier:** `tier:simple` (mechanical edit + test + version bump).

**Tier rationale:** This is an interactive session, full-loop in-session. I am executing the fix myself, not dispatching. Tier label is informational for the brief — not a dispatch signal.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dep-graph.sh` — add `has_defer_marker` to cache entries, add `_should_defer_auto_unblock` helper, gate the unblock edit behind it.
- `NEW: .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh` — regression tests for: (a) defer marker blocks unblock, (b) worker BLOCKED comment blocks unblock, (c) thrash kill comment blocks unblock, (d) terminal blocker comment blocks unblock, (e) clean issue (no markers, deps resolved) unblocks normally.
- `EDIT: VERSION` — bump patch.

### Implementation Steps

**Step 1 — Cache body defer markers** (during `build_dependency_graph_cache`):

For each issue, after the existing blocked-by extraction, compute a boolean `has_defer_marker` and store it in the cache entry for that issue. Markers detected (case-insensitive):

- `defer until`
- `do not dispatch`
- `do-not-dispatch`
- `on hold` / `on-hold` / `ON HOLD`
- `paused`
- `hold for`
- `HUMAN_UNBLOCK_REQUIRED` (explicit machine marker; see step 2)

The detection runs whether or not the body has `blocked-by:`, so the defer flag is authoritative on its own. The cache schema grows one field per existing blocked_by entry — new shape: `{"task_ids":[...],"issue_nums":[...],"has_defer_marker":true|false}`. Backward compatible (old readers ignore the new field).

Also record a top-level `defer_flags: {"<num>": true, ...}` map keyed by issue number, so the refresh can consult defer flags for issues that don't have any `blocked-by:` — the bug doesn't strictly require this case but consistency matters.

**Step 2 — Add `_should_defer_auto_unblock` helper**:

```bash
_should_defer_auto_unblock() {
  local repo_slug="$1"
  local issue_num="$2"
  local has_defer_flag="$3"   # "true" or "false" from cache

  # (a) Body defer marker (from cache, zero API cost)
  if [[ "$has_defer_flag" == "true" ]]; then
    echo "body-defer"
    return 0
  fi

  # (b) Recent comments: look for non-dep BLOCKED markers.
  # Single API call per unblock candidate. Candidates are rare
  # (0-5 per pulse cycle), so cost is acceptable.
  local comments_json recent_bodies
  comments_json=$(gh issue view "$issue_num" --repo "$repo_slug" \
    --json comments --jq '[.comments[-10:][] | .body] | join("\n---\n")' \
    2>/dev/null) || comments_json=""

  recent_bodies="$comments_json"
  if [[ -n "$recent_bodies" ]]; then
    if printf '%s' "$recent_bodies" | grep -qE '\*\*BLOCKED\*\*.*cannot proceed|Worker Watchdog Kill|Terminal blocker detected|ACTION REQUIRED|HUMAN_UNBLOCK_REQUIRED'; then
      echo "comment-marker"
      return 0
    fi
  fi

  return 1
}
```

**Step 3 — Gate the unblock edit**:

In `refresh_blocked_status_from_graph`, replace the block that confirms `status:blocked` and calls `gh issue edit --remove-label` with:

```bash
if [[ ",${current_labels}," == *",status:blocked,"* ]]; then
  local skip_reason=""
  skip_reason=$(_should_defer_auto_unblock "$slug" "$issue_num" "$defer_flag") || skip_reason=""
  if [[ -n "$skip_reason" ]]; then
    echo "[pulse-wrapper] dep-graph-cache: NOT unblocking #${issue_num} in ${slug} — ${skip_reason} (t2031)" >>"$LOGFILE"
    continue
  fi
  gh issue edit "$issue_num" --repo "$slug" \
    --remove-label "status:blocked" --add-label "status:available" 2>/dev/null || true
  echo "[pulse-wrapper] dep-graph-cache: unblocked #${issue_num} in ${slug} — all blockers resolved (t1935, verified non-dep markers absent t2031)" >>"$LOGFILE"
  unblocked_count=$((unblocked_count + 1))
fi
```

**Step 4 — Regression test** at `.agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh`:

Test harness replicates `_should_defer_auto_unblock` (body part — the comment part requires network, so the comment path is tested via a mock stub). Covers:

1. Body contains `Defer until Phase 1-6 are working` → defer flag true → skip.
2. Body contains `do not dispatch` → skip.
3. Body contains `ON HOLD` → skip.
4. Body has neither → defer flag false.
5. Mocked `gh issue view` returns a `**BLOCKED**` comment → skip.
6. Mocked `gh issue view` returns a `Worker Watchdog Kill` comment → skip.
7. Mocked `gh issue view` returns a `Terminal blocker detected` comment → skip.
8. Mocked `gh issue view` returns clean comments → proceed.

**Step 5 — Bump VERSION** and update CHANGELOG.md if it exists.

### Verification

```bash
# Syntax
shellcheck .agents/scripts/pulse-dep-graph.sh
shellcheck .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh

# Regression tests — new + existing parse test
bash .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh
bash .agents/scripts/tests/test-pulse-dep-graph-parse.sh

# Smoke: rebuild cache and check defer flags are present
rm -f ~/.aidevops/.agent-workspace/supervisor/dep-graph-cache.json
bash -c 'source .agents/scripts/shared-constants.sh 2>/dev/null || true
         source .agents/scripts/pulse-dep-graph.sh
         DEP_GRAPH_CACHE_FILE=/tmp/test-graph.json
         DEP_GRAPH_CACHE_TTL_SECS=1
         LOGFILE=/tmp/test-pulse.log
         build_dependency_graph_cache'
jq '.repos[].blocked_by // {} | to_entries[] | {num: .key, has_defer: .value.has_defer_marker}' /tmp/test-graph.json | head
```

## Acceptance Criteria

- [ ] `pulse-dep-graph.sh` adds a `has_defer_marker` field to every `blocked_by` cache entry AND a top-level `defer_flags` map, computed from the issue body.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh"
  ```

- [ ] `refresh_blocked_status_from_graph` skips auto-unblock when the body has a defer marker OR recent comments contain a non-dep BLOCKED marker (logged with reason).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh"
  ```

- [ ] Both files pass `shellcheck` with zero violations.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-dep-graph.sh .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh"
  ```

- [ ] VERSION bumped (patch) and changelog entry added.

  ```yaml
  verify:
    method: bash
    run: "diff <(git show HEAD:VERSION) VERSION || true"
  ```

## Context & Decisions

- **Why conservative-by-default:** The broken behaviour wastes token budget on EVERY pulse cycle across every pulse-enabled repo. A false positive (leaving an issue blocked that could be unblocked) costs nothing — a human trivially re-queues. A false negative (unblocking an issue that should stay blocked) costs a worker session + context window each time. Asymmetric cost → default to blocked.
- **Why body markers + comment markers (not just one):** A defer gate in the body is the primary signal for human-imposed holds. But some BLOCKED origins (worker exit, thrash, terminal) only leave evidence in comments. Checking both covers all paths without requiring retroactive changes to every labeller.
- **Why comment fetch per candidate, not pre-cached:** Unblock candidates are rare (typical cycle has 0-5 cache hits). Fetching 10 comments per candidate is a few API calls at most, much cheaper than caching all comment text across all repos on every build.
- **Why not introduce a `blocked:deps` subtype label:** Would require retroactive labelling of every existing `status:blocked` issue. Markers-in-comments achieves the same discrimination without a migration.
- **Non-goals:** no change to `is_blocked_by_unresolved` (the dispatch-time gate — orthogonal), no refactor of `build_dependency_graph_cache`, no change to the dep-graph cache TTL.

## Relevant Files

- `.agents/scripts/pulse-dep-graph.sh:186-281` — `refresh_blocked_status_from_graph` (the buggy path).
- `.agents/scripts/pulse-dep-graph.sh:55-174` — `build_dependency_graph_cache` (where defer flags are computed).
- `.agents/scripts/pulse-dispatch-core.sh:1425-1465` — `_apply_terminal_blocker` (one of the non-dep labellers we need to respect).
- `.agents/scripts/worker-watchdog.sh:867-938` — thrash-kill `status:blocked` label path.
- awardsapp#2273 — the real-world case this fix addresses.

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing structurally, but every in-flight task whose `blocked-by:` chain resolves while a defer gate or worker BLOCKED evidence still applies is at risk until this ships.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/context | 10m | Already done during triage. |
| Implementation | 15m | 2-file edit, straightforward. |
| Testing | 15m | Write harness with stubbed `gh`, run shellcheck. |
| Version bump + PR | 5m | Normal release flow. |
| **Total** | **~45m** | |
