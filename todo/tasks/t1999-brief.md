<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1999: Phase 12 — split `dispatch_with_dedup()` (370 lines, largest function in codebase)

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn
- **Parent context:** Phase 12 follow-up to t1962 pulse-wrapper decomposition. Plan §6 explicitly listed `dispatch_with_dedup` as the #1 simplification candidate after Phase 10. Now lives in `pulse-dispatch-core.sh` (extracted in Phase 9, t1977 / #18390).
- **Why interactively-created vs auto-discovered:** the function was deferred from t1962 by design (byte-preserving extraction only); not yet in the simplification queue.

## What

Split `dispatch_with_dedup()` (currently 370 lines, the largest function in the codebase) into a **decision function + action function** pair. Preserve external interface byte-for-byte at the call site — only the internals change.

- **External signature unchanged.** Callers continue to invoke `dispatch_with_dedup` with the same arguments and get the same return codes.
- **Two new internal helpers** (or three) extracted:
  - `_dispatch_dedup_check_layers` — runs the 7-layer dedup check, returns the first layer that flagged a duplicate (or empty for "safe to dispatch")
  - `_dispatch_launch_worker` — performs the actual worker launch + comment posting once dedup is cleared
- **Optionally a third helper** for the post-launch state recording if it's substantial.

The intent: separate "should we dispatch?" (pure decision logic) from "do the dispatch" (side effects). This is the canonical decision-vs-action split pattern.

## Why

- **370 lines** is the worst single complexity violation in the codebase post-decomposition. The complexity threshold (currently 46) only stays high because of this and 1-2 others.
- **Hard to test** — the current monolithic function combines 7 dedup layers + lock acquisition + comment posting + worker launch + state recording. Each is independently testable but currently cannot be.
- **Hard to reason about** — the GH#11141 / GH#12141 / GH#17700-17702 dispatch-loop incidents all involved subtle interactions inside this function. Splitting decision from action makes the dedup decision auditable in isolation.
- **t1701 comment makes this explicit:** "wrap dedup+assign+launch in single dispatch_with_dedup() function so LLM cannot skip dedup layers" — that was the right move at the time, but the function has grown to the point where the wrapper itself is opaque.

## Tier

### Tier checklist

- [ ] **2 or fewer files to modify?** — 1-2 files (`pulse-dispatch-core.sh` + maybe a new `pulse-dispatch-decision.sh` if we choose to extract sub-helpers to a sibling module). Likely just 1.
- [ ] **Complete code blocks for every edit?** — partial. Worker must read the current 370 lines and design the split.
- [ ] **No judgment or design decisions?** — moderate judgment: where exactly to draw the decision/action boundary; whether to extract 2 vs 3 helpers; whether to use a sibling module or just internal helpers.
- [x] **No error handling or fallback logic to design?** — correct (preserve current handling)
- [ ] **Estimate 1h or less?** — estimated 2-3h
- [ ] **4 or fewer acceptance criteria?** — 6 criteria below

Five checkboxes failed → `tier:standard` (Sonnet) is sufficient for this work because the design pattern is clear (decision-vs-action split is well-known) and the existing tests + characterization harness will catch any behavioural drift. `tier:reasoning` would be overkill.

**Selected tier:** `tier:standard`

## How (Approach)

### Files to modify

- **EDIT:** `.agents/scripts/pulse-dispatch-core.sh:814-1183` — `dispatch_with_dedup()` body
- **VERIFY:** `.agents/scripts/pulse-wrapper.sh` — call site (no changes expected)
- **VERIFY:** any test that exercises dispatch — characterization test, terminal-blockers test

### Recommended split

Read the function end-to-end first. The 7 dedup layers are clearly delimited by `# Layer N:` comments around lines 100-300 of the function. The post-clearance launch logic is in the bottom third.

**Step 1: extract `_dispatch_dedup_check_layers()`**

Move the 7 layer checks (Layer 1 through Layer 7) into this helper. It should:
- Take the same args as the parent (`issue_number`, `repo_slug`, `title`, `self_login`, etc.)
- Return 0 if dispatch is safe; return 1 with stdout reason if blocked
- Print a structured reason on stdout (e.g. `LAYER_3_TITLE_MATCH`, `LAYER_6_ASSIGNED`, `PARENT_TASK_BLOCKED`)
- Be the ONLY caller of `dispatch-dedup-helper.sh is-duplicate / has-open-pr / has-dispatch-comment / is-assigned`
- Handle the t1927 STALE_RECOVERED fast-fail recording

**Step 2: extract `_dispatch_launch_worker()`**

Move the worker launch + claim acquisition + comment posting + state recording into this helper. It should:
- Take the args needed for launch
- Return 0 on successful launch, non-zero on failure
- Be the ONLY caller of the actual worker spawn (`headless-runtime-helper.sh run` or whatever the current launch pattern is)

**Step 3: shrink `dispatch_with_dedup()` to a thin orchestrator**

```bash
dispatch_with_dedup() {
    local issue_number="$1" repo_slug="$2" title="$3" self_login="$4" ...
    local dedup_reason
    if dedup_reason=$(_dispatch_dedup_check_layers "$issue_number" "$repo_slug" "$title" "$self_login"); then
        echo "[pulse-wrapper] Dedup clear for #${issue_number} — proceeding to launch" >>"$LOGFILE"
    else
        echo "[pulse-wrapper] Dedup blocked for #${issue_number}: ${dedup_reason}" >>"$LOGFILE"
        return 0  # blocked, but not a failure
    fi
    _dispatch_launch_worker "$issue_number" "$repo_slug" "$title" ...
}
```

Target: parent function under 80 lines. Both helpers under 200 lines each. Net result: 370 → ~80 + ~150 + ~140 = same total but auditable units.

### Verification

```bash
# 1. Syntax + self-check
bash -n .agents/scripts/pulse-dispatch-core.sh
.agents/scripts/pulse-wrapper.sh --self-check  # must still report 28 canonical fns + 23 module guards

# 2. All pulse tests pass — these are the regression net
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
bash .agents/scripts/tests/test-pulse-wrapper-terminal-blockers.sh  # exercises check_terminal_blockers which is called from dispatch_with_dedup
bash .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh  # exercises _is_task_committed_to_main
bash .agents/scripts/tests/test-parent-task-guard.sh  # 20/20 — exercises is_assigned which dispatch_with_dedup calls

# 3. Sandbox dry-run — exercises the full pulse loop
SANDBOX=$(mktemp -d); OLDHOME="$HOME"; export HOME="$SANDBOX/home"
mkdir -p "$HOME/.aidevops/logs" "$HOME/.aidevops/.agent-workspace/supervisor" "$HOME/.config/aidevops"
printf '{"initialized_repos":[]}\n' > "$HOME/.config/aidevops/repos.json"
PULSE_JITTER_MAX=0 PULSE_DRY_RUN=1 .agents/scripts/pulse-wrapper.sh
export HOME="$OLDHOME"; rm -rf "$SANDBOX"

# 4. Shellcheck — 4 pre-existing findings only, 0 new
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-dispatch-core.sh

# 5. Complexity — dispatch_with_dedup should drop OFF the violation list (was 370, target <100)
.github/workflows/code-quality.yml awk pattern run locally to confirm
```

After this PR, `FUNCTION_COMPLEXITY_THRESHOLD` can be ratcheted down by 1 (one violation removed). Track in `complexity-thresholds-history.md`.

## Acceptance Criteria

- [ ] `dispatch_with_dedup()` reduced to under 80 lines (orchestrator only)
- [ ] 2 new helper functions extracted, each under 200 lines
- [ ] External interface byte-identical (callers in `pulse-wrapper.sh` unchanged)
- [ ] All existing pulse tests pass (characterization 26/26, terminal-blockers 11/11, main-commit-check 8/8, parent-task-guard 20/20)
- [ ] `--self-check` still reports 28 canonical functions + 23 module guards
- [ ] `PULSE_DRY_RUN=1` sandboxed → rc=0
- [ ] `shellcheck` clean (0 new findings beyond the 4 pre-existing)
- [ ] `FUNCTION_COMPLEXITY_THRESHOLD` ratcheted down by 1 in same PR

## Context & Decisions

- **Why not extract to a new sibling module?** The 2 new helpers are private (`_dispatch_*`) and only called by `dispatch_with_dedup()`. Keeping them in `pulse-dispatch-core.sh` preserves locality. If they grow to be reused, extract later.
- **Why decision-vs-action and not 7 separate layer functions?** Each layer is short (10-30 lines) and they're tightly sequenced. Extracting 7 functions would explode the call graph without clarity gain. The decision/action boundary is the natural seam.
- **Why preserve return codes byte-identically?** `pulse-wrapper.sh` and other dispatchers depend on 0=blocked-not-failure vs other codes. Don't refactor return semantics during this split.

## Relevant Files

- `.agents/scripts/pulse-dispatch-core.sh:814` — `dispatch_with_dedup` definition
- `.agents/scripts/dispatch-dedup-helper.sh` — the underlying CLI helpers it calls
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` — regression net
- `todo/plans/pulse-wrapper-decomposition.md` §6 Phase 12 — original deferral rationale

## Dependencies

- **Blocked by:** none
- **Blocks:** future complexity threshold ratchet-down (depends on this + the other 7 Phase 12 splits)
- **Related:** t2000-t2006 (sibling per-function splits), t1987 (Phase 12 module sub-split)

## Estimate

~2.5h: 30m read + design, 1h extract + iterate, 30m verify, 30m PR cycle.
