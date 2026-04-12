<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2000: Phase 12 — split `dispatch_triage_reviews()` (303 lines)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** t1962 Phase 12 follow-up (plan §6, candidate #2)
- **Function location:** `.agents/scripts/pulse-ancillary-dispatch.sh:35` (extracted in Phase 10, t1978 / #18392)

## What

Split `dispatch_triage_reviews()` (303 lines) into:
1. **`_build_triage_review_prompt()`** — pure prompt construction (read state, format issue context, build the LLM prompt body). No side effects.
2. **`_dispatch_triage_review_worker()`** — actual worker dispatch + comment posting + state update. All side effects.
3. Parent shrinks to a thin orchestrator (<60 lines).

The seam is the prompt-building portion, which currently inlines ~150 lines of context formatting into the dispatch flow. Extracting it makes the prompt easy to test independently and easy to inspect when debugging triage failures.

## Why

- 303 lines, second-largest function in the codebase post-decomposition.
- The 3 pre-existing test failures in `test-pulse-wrapper-worker-count.sh` (observed during Phase 8) are all on `dispatch_triage_reviews` slot-counting — extracting the prompt-building lets the test target the dispatch logic alone, which may unblock those failures.
- Triage prompt drift is hard to diagnose today because the prompt body is buried in dispatch logic.

## Tier

`tier:standard`. Brief has explicit split target, file path with line number, regression net (existing pulse tests), tier checklist 4/6 fail = standard not simple.

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-ancillary-dispatch.sh:35-337` — `dispatch_triage_reviews()` body
- **VERIFY:** `.agents/scripts/tests/test-pulse-wrapper-worker-count.sh` — currently has 3 failing assertions (pre-existing on main, see PR #18388 notes). After this split, **investigate** whether the failures are still present and either fix them or document why they're unrelated to the split.

### Recommended split

1. Read function end-to-end. Identify where the prompt body is constructed vs where the worker is launched.
2. Extract the prompt-building section into `_build_triage_review_prompt()`. It should be a pure function: takes issue metadata + state, returns the prompt as a string on stdout.
3. Extract the dispatch section into `_dispatch_triage_review_worker()`. It should call the new prompt builder and then perform the launch/comment/state-record sequence.
4. Parent function becomes: gather candidates → for each → call prompt builder → call worker dispatch.

Target shape:
```bash
dispatch_triage_reviews() {
    local candidates
    candidates=$(...)  # selection logic stays here, ~30 lines
    for issue in $candidates; do
        local prompt
        prompt=$(_build_triage_review_prompt "$issue") || continue
        _dispatch_triage_review_worker "$issue" "$prompt" || continue
    done
}
```

### Verification

```bash
bash -n .agents/scripts/pulse-ancillary-dispatch.sh
.agents/scripts/pulse-wrapper.sh --self-check
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
bash .agents/scripts/tests/test-pulse-wrapper-worker-count.sh  # check whether the 3 pre-existing failures still hit
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-ancillary-dispatch.sh
# Sandbox dry-run pattern from t1999
```

## Acceptance Criteria

- [ ] `dispatch_triage_reviews()` reduced to under 80 lines
- [ ] 2 new helper functions extracted, neither over 180 lines
- [ ] External interface unchanged (no caller updates needed in `pulse-wrapper.sh`)
- [ ] All existing pulse tests pass (excluding the 3 pre-existing failures in worker-count)
- [ ] `--self-check` reports 28 canonical fns + 23 module guards
- [ ] `shellcheck` clean (no new findings)
- [ ] Investigation note in PR body: are the 3 worker-count failures still present? If yes, why is that out of scope; if no, link the fix.

## Relevant Files

- `.agents/scripts/pulse-ancillary-dispatch.sh:35`
- `.agents/scripts/tests/test-pulse-wrapper-worker-count.sh`
- `todo/plans/pulse-wrapper-decomposition.md` §6 Phase 12

## Dependencies

- **Related:** t1999 (sibling — dispatch_with_dedup split, same module family)
- **Investigates:** the 3 pre-existing worker-count test failures (decide whether to fix in this PR or split off a separate task)

## Estimate

~2h. Slightly less than t1999 because the seam is more obvious (prompt body is a coherent unit).
