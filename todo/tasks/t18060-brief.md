# t18060: Harden SIGPIPE-safe pulse emits and LLM retry state

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `issue 26333 review SIGPIPE LLM attempt success dispatch brief` → 0 hits — no relevant reusable lessons found.
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h for `GH#26333 pulse SIGPIPE llm_trigger_mode stale lock`.
- [x] File refs verified: 4 refs checked, present at HEAD (`pulse-wrapper.sh:72`, `pulse-wrapper-cycle.sh:255-306`, `pulse-dispatch-engine.sh:575-646`, `worker-lifecycle-common.sh:1473-1477`).
- [x] Tier: `tier:thinking` — review suggested `tier:standard`, but dispatch-path classification touches pulse/self-hosting supervisor files and retry semantics.
- [x] Seeded draft PR decision recorded: skipped — implementation needs current-worker design judgment across supervisor state and SIGPIPE-safe helper patterns.

## Origin

- **Created:** 2026-07-02
- **Session:** opencode:ses_0dcc9b92bffeyOArLYjh00Obom
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** GH#26333 was reviewed as a real pulse reliability bug. The review approved the issue but rejected a blanket `trap '' PIPE`-only fix and requested a worker-ready brief/TODO/task ID before dispatch.

## What

Make pulse supervisor execution resilient to normal early-closing pipe consumers without hiding real failures, and make failed LLM supervisor runs retryable instead of recording ambiguous success-like state. The finished change should keep the pulse wrapper running when stdout-returning helpers encounter expected broken pipes, while preserving explicit failure signals for genuinely failed dispatch/LLM runs.

## Why

GH#26333 reports pulse crash-loop symptoms on v3.31.19: stale lock recovery repeats after broken-pipe write errors, and LLM supervisor state can blur failed attempts with successful daily sweeps. Pulse is core automation infrastructure; a wrapper-level crash loop blocks worker dispatch, burns API/runtime budget, and makes diagnostics noisy. A broad global `trap '' PIPE` is too blunt because bash builtins and `pipefail` can still surface write failures, and global signal changes make rollback/debugging harder.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** Likely no: wrapper, cycle/dispatch state, emit helpers, and tests.
- [ ] **Every target file under 500 lines?** No: `pulse-wrapper.sh`, `pulse-dispatch-engine.sh`, and `worker-lifecycle-common.sh` exceed 500 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No: worker must design localized state handling.
- [ ] **No judgment or design decisions?** No: must distinguish expected SIGPIPE from real helper failures.
- [ ] **No error handling or fallback logic to design?** No: retry/backoff semantics are part of the fix.
- [ ] **No cross-package or cross-module changes?** No: multiple pulse/lifecycle helpers and tests.
- [ ] **Estimate 1h or less?** No.
- [ ] **4 or fewer acceptance criteria?** No.
- [x] **Dispatch-path classification (t2821/t2920):** Yes, target files include pulse supervisor/self-hosting paths, so use `tier:thinking` despite the review's baseline `tier:standard` suggestion.

**Selected tier:** `tier:thinking`

**Tier rationale:** This touches long-running pulse supervisor control flow, self-hosting dispatch reliability, and failure-state semantics. The worker should reason about localized emit handling and LLM attempt/success state instead of copying a literal patch.

## PR Conventions

Leaf task: the implementation PR should use a closing keyword for GH#26333.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The review established direction and verified file locations, but seeding a draft patch would risk anchoring workers to an incomplete global-trap approach. A design-aware implementation is safer.
- **Status:** not-created
- **Freshness evidence:** memory recall returned no hits; prework discovery returned no recent commits/merged PRs/open PRs for the target files; file refs above were read from current HEAD.
- **Verification run:** UNVERIFIED — planning-only brief creation, no implementation tests run.
- **Stale-assumption warning:** Re-check target files and any recent pulse reliability PRs before implementation; line numbers may drift quickly in pulse supervisor code.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-wrapper.sh`
  - Current state: `set -euo pipefail` at line 72 with no wrapper-level SIGPIPE policy.
  - Do not solve this by only adding a global `trap '' PIPE`; if a trap is needed, keep it localized/restored around known expected broken-pipe emit contexts.
- EDIT: `.agents/scripts/pulse-wrapper-cycle.sh`
  - Current state: `_pulse_maybe_run_llm_supervisor()` reads `llm_trigger_mode`, calls `run_pulse`, then unconditionally writes `last_llm_run_epoch` after a successful return path at lines 294-302.
  - Add explicit attempt/success semantics so failed `run_pulse` attempts do not look like successful daily sweeps.
- EDIT: `.agents/scripts/pulse-dispatch-engine.sh`
  - Current state: `_should_run_llm_supervisor()` writes `llm_trigger_mode` for `daily_sweep`, `first_run`, and `stall` at lines 587-640.
  - Review how trigger-mode writes interact with attempt/success timestamps and cooldowns.
- EDIT: `.agents/scripts/worker-lifecycle-common.sh`
  - Current example stdout emitter: `count_active_workers()` uses `echo "$count"` at lines 1473-1477.
  - Prefer guarded `printf '%s\n' "$count" 2>/dev/null || return 0` only where an early-closing consumer is expected and non-fatal.
- EDIT/ADD: `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` or a new focused test under `.agents/scripts/tests/`.
  - Include a regression for early-closing consumers and one for failed LLM supervisor retry state.

### Implementation Steps

1. Reproduce the shell failure mode in a tiny focused test fixture before editing production code:
   - A helper that emits multiple lines under `set -euo pipefail` into an early-closing consumer such as `sed -n '1p'` or equivalent.
   - Assert the pulse-safe wrapper/helper path does not abort the whole script when the consumer closes normally.
2. Audit pulse helpers that intentionally return data on stdout and are consumed by early-exiting commands. Start from the review evidence:
   - `worker-lifecycle-common.sh:1473-1477` (`count_active_workers`).
   - `pulse-wrapper-cycle.sh:288-292` (`_compute_initial_underfill` output consumed by line selectors).
   - Any helper in the dispatch/prefetch path that writes status/count data to stdout while the caller only needs the first line or a bounded subset.
3. Implement localized SIGPIPE-safe emit handling:
   - Use `printf`, not `echo`, for data returns.
   - Redirect expected broken-pipe write noise where the early consumer closing is normal.
   - Return the intended helper status explicitly; do not blanket-ignore all failures from the helper body.
   - If a temporary `trap '' PIPE` is used, restore the previous trap before returning.
4. Split LLM supervisor attempt and success state:
   - Record an attempt timestamp before `run_pulse` starts (for cooldown/backoff and diagnostics).
   - Record successful completion separately only when `run_pulse` exits successfully.
   - Ensure a failed `daily_sweep` attempt remains eligible for retry after a controlled cooldown/backoff instead of suppressing daily sweeps for a full interval.
   - Preserve `stall` as a valid trigger mode; do not treat the string alone as dispatch-disabled state.
5. Add failure-path logging that is diagnostic but not noisy:
   - Include trigger mode, attempt timestamp, success/failure, and next retry/cooldown when applicable.
   - Avoid logging private local paths beyond existing pulse log conventions.
6. Keep function complexity gates in mind:
   - Prefer small helper functions for emit and LLM state updates.
   - Every new shell function must use `local var="$1"` style for arguments and end with explicit `return 0` or `return 1`.

### Complexity Impact

- Likely growth targets: `_pulse_maybe_run_llm_supervisor()` in `.agents/scripts/pulse-wrapper-cycle.sh` and `_should_run_llm_supervisor()` in `.agents/scripts/pulse-dispatch-engine.sh`.
- Avoid growing either function past the shell complexity gate; extract helpers such as `_pulse_record_llm_attempt`, `_pulse_record_llm_success`, and `_pulse_emit_count_safely` if the patch adds more than a small guard.
- Target delta: keep each touched existing function under +25 lines by extracting helpers and testing helpers directly where practical.

### Verification

Run from the repository root after implementation:

```bash
shellcheck .agents/scripts/pulse-wrapper.sh \
  .agents/scripts/pulse-wrapper-cycle.sh \
  .agents/scripts/pulse-dispatch-engine.sh \
  .agents/scripts/worker-lifecycle-common.sh
```

```bash
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

If adding a new focused test file, run it directly too:

```bash
bash .agents/scripts/tests/test-pulse-sigpipe-llm-state.sh
```

Before opening the PR, also run the local framework gate if the focused checks pass:

```bash
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Normal early-closing stdout consumers in pulse helper paths no longer abort the wrapper under `set -euo pipefail`.
- [ ] The implementation does not rely only on a permanent global `trap '' PIPE`; SIGPIPE handling is localized, restored, or expressed as guarded emits at expected broken-pipe boundaries.
- [ ] Failed LLM supervisor attempts are recorded separately from successful completions, with retry/cooldown behavior that permits future daily sweep attempts.
- [ ] `stall` remains a valid trigger mode and is not treated as permanent dispatch-disable state.
- [ ] Focused regression tests cover early-closing consumer behavior and failed-run retry state.
- [ ] ShellCheck passes for every changed shell file.
- [ ] Relevant focused tests pass, and broader `linters-local.sh` is run or explicitly reported with blockers.

## Context

- Source issue: GH#26333.
- Review comment posted at GH#26333 approved the issue as real but requested implementation guidance rather than a blanket global SIGPIPE trap.
- Related prior work cited by the report/review: GH#24430/GH#24429, GH#23738/GH#23722, GH#23719, GH#18830, GH#20613. Treat these as related narrow fixes, not superseding work.
- Safety gates touched: pulse dispatch dedup/worker dispatch reliability and diagnostics. No maintainer-approval bypass is expected.
- Trade-off: a broad signal trap is simpler but hides context and may not address bash builtin write failures under `pipefail`; localized emits plus explicit LLM state is more work but preserves debuggability and root-cause behavior.
