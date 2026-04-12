<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1998: fix(pulse-dispatch-core) — simplification re-eval neutered by skip-if-already-labeled short-circuit

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (user-flagged while reviewing #18346)
- **Parent task:** none (supports t1962 decomposition work indirectly)
- **Conversation context:** Issue #18346 was the trigger for this entire session — it's labeled `needs-simplification` because it referenced `pulse-wrapper.sh` back when that file was 13,797 lines. After the t1962 phased decomposition work landed (Phases 1–12 via PRs #18392, #18405, and others), `pulse-wrapper.sh` is now **1,352 lines** — well under the 2000-line `LARGE_FILE_LINE_THRESHOLD`. The `needs-simplification` label should have been auto-cleared by `_reevaluate_simplification_labels()` in `pulse-triage.sh`, which runs on every pulse cycle at `pulse-dispatch-engine.sh:732`. It wasn't.

## What

Fix a short-circuit bug in `_issue_targets_large_files()` at `pulse-dispatch-core.sh:592-594` that prevents `_reevaluate_simplification_labels()` from ever clearing a stale `needs-simplification` label:

```bash
# Skip if already labeled (avoid re-checking every cycle)
if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
    return 0
fi
```

This short-circuit was intended as a perf optimization on the **normal dispatch path** (where the label is already on the issue because we just gated it — no need to re-check file sizes). But `_reevaluate_simplification_labels()` iterates over `needs-simplification`-labeled issues specifically, calls this function on each, and relies on it returning 1 when files are now under threshold. The short-circuit means the function always returns 0 (still-gated) for labeled issues — the re-eval never sees a cleared case, and labels stay forever even when the target files have been simplified.

**Fix:** add a 5th `force_recheck` parameter to `_issue_targets_large_files()`. Default false (preserves the perf optimization for the normal dispatch path). The re-eval function passes true, bypassing the short-circuit and getting an honest re-evaluation. Auto-clear at `pulse-dispatch-core.sh:761-765` then fires correctly.

## Why

**Evidence from the session:**

- #18346 references `pulse-wrapper.sh` in its body via `EDIT: \`.agents/scripts/pulse-wrapper.sh\``
- Current `wc -l .agents/scripts/pulse-wrapper.sh` → 1352 lines
- `LARGE_FILE_LINE_THRESHOLD=2000`
- 1352 < 2000, so the gate should be cleared
- `_reevaluate_simplification_labels()` runs every pulse cycle (per `pulse-dispatch-engine.sh:732`)
- #18346 still has `needs-simplification` label (confirmed: `gh issue view 18346 --json labels`)

Manual trace of the code path proves the short-circuit is the culprit:

1. Re-eval calls `_issue_targets_large_files "$num" "$slug" "$body" "$rpath"`
2. Function fetches `issue_labels` (line 569)
3. Function checks `simplification` / `simplification-debt` label special case (line 577) — #18346 doesn't have either, skip
4. Function checks `needs-simplification` short-circuit at line 593 — **HIT, returns 0**
5. Function NEVER reaches the file-path extraction or size check (lines 620+)
6. Function NEVER reaches the auto-clear branch at line 761
7. Re-eval sees return 0, doesn't count as cleared, moves on
8. Label persists forever

**Impact:** every `needs-simplification` issue whose target files have since been simplified stays labeled forever. Over the course of t1962's 12-phase decomposition, multiple issues likely got stuck. On this session's audit, only #18346 is in this state, but the bug would have affected every previous cleared case and will affect every future one.

**Today's stuck-issues scan:** 3 issues labeled `needs-simplification`; of those, only #18346 is incorrectly stuck (others legitimately target files still over threshold).

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 2 (`pulse-dispatch-core.sh`, `pulse-triage.sh`)
- [x] **Complete code blocks for every edit?** — yes, diffs below
- [x] **No judgment or design decisions?** — contract is straightforward (new flag parameter)
- [x] **No error handling or fallback logic to design?** — no
- [x] **Estimate 1h or less?** — ~30m
- [x] **4 or fewer acceptance criteria?** — 3

**Selected tier:** `tier:simple`

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-core.sh:559-594` — add `force_recheck` parameter, skip the short-circuit when it's "true"
- `EDIT: .agents/scripts/pulse-triage.sh:388-394` — re-eval passes `"true"` as the 5th arg

### Implementation

```bash
# pulse-dispatch-core.sh — _issue_targets_large_files signature
_issue_targets_large_files() {
    local issue_number="$1"
    local repo_slug="$2"
    local issue_body="$3"
    local repo_path="$4"
    local force_recheck="${5:-false}"   # t1998: re-eval path bypasses skip-if-already-labeled

    # ... existing early-return checks ...

    # Skip if already labeled (avoid re-checking every cycle)
    # EXCEPT when called from _reevaluate_simplification_labels, which
    # needs an honest re-check to decide if the label can be cleared.
    if [[ "$force_recheck" != "true" ]] \
        && [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
        return 0
    fi

    # ... rest of function unchanged ...
}
```

```bash
# pulse-triage.sh — _reevaluate_simplification_labels call site
# t1998: pass force_recheck=true to bypass the skip-if-already-labeled
# short-circuit in _issue_targets_large_files. Without this flag, the
# re-eval can never see a cleared case because the function returns 0
# immediately on any already-labeled issue.
if ! _issue_targets_large_files "$num" "$slug" "$body" "$rpath" "true"; then
    total_cleared=$((total_cleared + 1))
fi
```

### Verification

1. **Isolated trace** — manually run the re-eval loop after the fix and confirm #18346 clears:

    ```bash
    source .agents/scripts/pulse-dispatch-core.sh
    body=$(gh issue view 18346 --repo marcusquinn/aidevops --json body --jq .body)
    _issue_targets_large_files 18346 marcusquinn/aidevops "$body" /Users/marcusquinn/Git/aidevops "true"
    # Expected: return 1, stderr contains "Simplification gate cleared for #18346"
    ```

2. **Non-regression test** — confirm #18348 and #18418 remain gated (their files really are still large):

    ```bash
    for n in 18348 18418; do
        body=$(gh issue view $n --repo marcusquinn/aidevops --json body --jq .body)
        if _issue_targets_large_files $n marcusquinn/aidevops "$body" /Users/marcusquinn/Git/aidevops "true"; then
            echo "#$n still gated (expected)"
        else
            echo "#$n unexpectedly cleared"
        fi
    done
    ```

3. **Shellcheck** — clean on both modified files.

## Acceptance Criteria

- [ ] `_issue_targets_large_files` accepts a 5th `force_recheck` parameter that defaults to `false`. When true, the skip-if-already-labeled short-circuit is bypassed.
- [ ] `_reevaluate_simplification_labels` passes `"true"` as the 5th argument so the re-eval path gets an honest file-size check.
- [ ] Manual verification on #18346: after the fix, running the function with `force_recheck=true` removes the `needs-simplification` label. #18348 and #18418 still retain the label (their files are still large).
- [ ] `shellcheck` clean on both modified files.

## Context & Decisions

- **Why a force_recheck flag instead of moving the check elsewhere:** the short-circuit is useful on the normal dispatch path (avoids redundant `wc -l` + `gh issue view` on every single dispatch). Keeping the flag preserves that benefit while letting the re-eval path opt into the full check. One-line signature change, minimal blast radius.
- **Why not just remove the short-circuit entirely:** would regress dispatch performance (every dispatched issue would re-run the file-size scan). The optimisation exists for a reason; the re-eval path just needs to opt out.
- **Why not a broader daily routine to scan all `needs-simplification` issues:** the existing re-eval loop runs on every pulse cycle (every ~2 minutes). Adding a daily routine on top would be redundant. The fix here makes the existing loop work correctly, which is strictly better than adding a second mechanism.
- **Why also manually clear #18346 in the same session:** the issue has been sitting incorrectly gated for weeks. The session was triggered by a request to finally address it. Manually clearing it unblocks it immediately; the fix ensures the same thing doesn't happen again on the next stuck issue.

## Relevant Files

- `.agents/scripts/pulse-dispatch-core.sh:559-594` — `_issue_targets_large_files` signature + short-circuit
- `.agents/scripts/pulse-dispatch-core.sh:759-767` — auto-clear branch (fires after fix)
- `.agents/scripts/pulse-triage.sh:366-402` — `_reevaluate_simplification_labels` (call site to update)
- `.agents/scripts/pulse-dispatch-engine.sh:732` — re-eval call site on every pulse cycle
- Issue #18346 — the visible symptom that triggered this session

## Dependencies

- **Blocked by:** none
- **Blocks:** #18346 dispatch (can proceed after fix + manual clear)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research | done | (this session) |
| Implementation | 10m | 2-file surgical change |
| Testing | 10m | Isolated trace + non-regression on #18348/#18418 |
| Manual clear #18346 | 5m | Post-merge one-off |
| PR | 5m | |

**Total estimate:** ~30m
