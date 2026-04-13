<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2061: complete t2046 Deliverable A audit — fail-closed mode for remaining guards

## Origin

- **Created:** 2026-04-13, claude-code:interactive
- **Parent context:** t2046 (`todo/tasks/t2046-brief.md`, GH#18599) Deliverable A. Implementation shipped in PR #18663 + #18664 but only covered the most critical case. Two parts of Deliverable A's acceptance criteria did not actually ship:
  1. *"Switch is_assigned() to detect jq, gh, **and helper-script failures** explicitly via local rc capture instead of `2>/dev/null || true` swallowing"* — only the gh API failure case (empty `issue_meta_json`) was hardened. Internal jq calls inside `is_assigned()` still use `2>/dev/null || empty` patterns.
  2. *"Other guard functions in dispatch-dedup-helper.sh audited; either fixed in this PR or filed as follow-up tasks via findings-to-tasks-helper.sh"* — none of `_check_db_entry`, `is_duplicate`, `_is_stale_assignment`, `_check_cost_budget`, `_is_dispatch_comment_active` got `GUARD_UNCERTAIN` treatment, no documented findings, no follow-up tasks filed.
- **Why now:** the architectural fail-closed contract is half-installed. The most catastrophic case (gh API failure → empty issue_meta_json → can't parse anything) is covered, but any *internal* jq failure (a future filter that doesn't include null-fallback, an arithmetic error, a regex that fails to compile) still falls through to the dispatch-allowed path. This is the same shape of bug as the GH#18458 incident — just one layer deeper.

## What

Complete the t2046 Deliverable A audit as originally promised. Two parts:

### Part 1 — close the internal-jq gap in `is_assigned()`

Audit every `jq` call inside `is_assigned()` (lines 1051-1145) and switch each one to explicit local rc capture. On any `jq` non-zero exit, emit `GUARD_UNCERTAIN (reason=jq-failure ...)` and return 0 (block). Same pattern as the existing gh-api-failure path at line 1067.

Same treatment for any helper-script call inside `is_assigned()` (e.g. `_get_repo_owner`, `_get_repo_maintainer`, `_has_active_claim`). If any helper returns non-zero or empty when it shouldn't, treat as uncertainty and block.

### Part 2 — audit and document the other 5 guard functions

For each of `_check_db_entry`, `is_duplicate`, `_is_stale_assignment`, `_check_cost_budget`, `_is_dispatch_comment_active`:

1. **Read the function.** Document its current behaviour on each error mode (jq failure, file read failure, gh API failure, helper failure).
2. **Classify each error path** as one of:
    - **Appropriately fail-open** — e.g. `_check_db_entry` returning "no entry" on a missing/unreadable DB file is correct: no entry means no prior dispatch claim, which is genuinely the right answer to "is this a duplicate?". Document the rationale in a function-level comment with `t2061: fail-open is intentional because ...`.
    - **Inappropriately fail-open** — needs the `GUARD_UNCERTAIN` treatment. Apply it.
    - **Already fail-closed** — confirm and document.
3. **Add a function-level audit comment** to each guard documenting the classification. This makes the audit findings part of the code so future maintainers can see what was decided and why.

## Why

See "Origin" above. Plus:

- The t2046 architectural principle is "guards meant to prevent harmful dispatches should fail closed". Half-installing the principle leaves the same shape of bug latent in 5 other guard functions.
- Future jq filter additions will hit this gap. Every new filter must remember to add null-fallbacks (the GH#18537 specific patch). A fail-closed default removes the requirement to remember.
- The audit deliverable was explicitly promised in t2046's acceptance criteria but did not ship. This task closes that loop.

## Tier

`tier:standard` — sonnet. Mechanical implementation following the existing `GUARD_UNCERTAIN` pattern (now in `dispatch-dedup-helper.sh:1062-1068`).

### Tier checklist

- [x] **>2 files?** Yes (1 helper, 1 test, 1 doc edit) — disqualifies `tier:simple`.
- [ ] Skeleton code blocks? No — every change uses the verbatim pattern from t2046's gh-api-failure path.
- [ ] Error/fallback logic to design? No — the `GUARD_UNCERTAIN` signal pattern is fully specified and live.
- [x] Estimate >1h? Yes (~3-4h) — disqualifies `tier:simple`.
- [ ] >4 acceptance criteria? 6 criteria, each a single mechanical check.
- [ ] Judgment keywords? Some — Part 2 requires classifying each error path as "appropriately fail-open" vs "needs hardening". This is judgment but bounded: the function is small and the classification rules are explicit (does fail-open answer the question correctly, or does it default to a harmful action?).

`tier:standard` is correct. Do NOT escalate to `tier:reasoning` — there are 6 functions to audit and each follows a deterministic process.

## How (Approach)

### Files to modify

- **EDIT:** `.agents/scripts/dispatch-dedup-helper.sh`
  - Lines 1051-1145 (`is_assigned()` body): audit each `jq` and helper call, wrap with explicit rc capture, emit `GUARD_UNCERTAIN` on internal failure
  - Function 241 `_check_db_entry`: audit + classify + comment
  - Function 331 `is_duplicate`: audit + classify + comment (this is layered, classify each layer separately)
  - Function 445 `_is_stale_assignment`: audit + classify + comment
  - Function 867 `_check_cost_budget`: audit + classify + comment (probably already fail-closed per t2007 — confirm)
  - Function 1351 `_is_dispatch_comment_active`: audit + classify + comment
- **EDIT:** `.agents/scripts/tests/test-dispatch-dedup-fail-closed.sh` — add cases for any newly hardened functions. Also add a test that injects a jq failure mid-`is_assigned()` (e.g. by mocking gh to return malformed JSON that parses but fails on a downstream filter) and asserts `GUARD_UNCERTAIN`.
- **NEW (optional):** `todo/investigations/t2061-guard-audit-findings.md` — the per-function audit table. Optional because the function-level comments serve the same purpose; the investigation doc is only useful if the audit surfaces non-trivial design decisions.

### Reference patterns

- **`.agents/scripts/dispatch-dedup-helper.sh:1062-1068`** — the canonical `GUARD_UNCERTAIN` emit-and-return pattern that t2046 introduced. Copy verbatim, just change the reason string.
- **`.agents/scripts/dispatch-dedup-helper.sh:1058-1075`** — the `PARENT_TASK_BLOCKED` short-circuit, which uses the same emit-and-return shape.
- **`.agents/scripts/dispatch-dedup-helper.sh:1077-1093`** — the `_check_cost_budget` invocation site, which already uses explicit local rc capture (`_t2007_rc=$?`). Same pattern for the new wrapping.
- **`.agents/scripts/tests/test-dispatch-dedup-fail-closed.sh`** — the existing t2046 test file. Add new cases at the same level as the existing ones.

### Implementation steps

1. **Read t2046's PR #18663 in full** to understand exactly what shipped and what didn't. Don't re-derive the shipped pattern.
2. **Part 1 first.** Read every line of `is_assigned()` lines 1051-1145. Find every `jq` and helper call. For each one:
    - Wrap in explicit local rc capture: `result=$(jq ... "$input") || rc=$?`
    - On non-zero rc, emit `GUARD_UNCERTAIN (reason=jq-failure call=<short-name> issue=$issue_number repo=$repo_slug)` to stdout
    - Return 0 (block)
3. **Add a regression test for Part 1.** Mock `gh issue view` to return JSON that's well-formed at the top level but causes a downstream jq filter to fail (e.g. labels is an object instead of an array). Assert `GUARD_UNCERTAIN`, exit 0.
4. **Part 2: read each of the 5 other guard functions.** For each one, walk through every error path and classify it. Add a comment block above the function explaining the classification:

    ```bash
    #######################################
    # _check_db_entry — checks dedup DB for prior dispatch claim
    #
    # t2061 audit (2026-04-13):
    #   - Missing DB file: fail-open (no entry = no prior claim = correct answer)
    #   - Unreadable DB file: fail-open (same rationale)
    #   - jq parse error on entry: fail-CLOSED (added GUARD_UNCERTAIN)
    #   - PID file race: fail-open (PID race is non-fatal here)
    #
    # Rationale: this guard answers "is this a duplicate dispatch?" and the
    # default for "I don't know" depends on the question. For "is there a
    # prior claim?" the safe default is "no, dispatch is allowed" because a
    # genuine duplicate would have the dedup DB entry; absence is evidence.
    # For "is the entry itself parseable?" the safe default is "block" because
    # a corrupt entry could be hiding a real claim.
    #######################################
    ```

5. **For each function classified as "needs hardening":** apply the `GUARD_UNCERTAIN` pattern. Add a regression test in `test-dispatch-dedup-fail-closed.sh`.
6. **For each function classified as "appropriately fail-open":** add ONLY the comment block. No code changes.
7. **For each function classified as "already fail-closed":** add the comment block confirming the audit ran. No code changes.
8. **Run the full test suite.** ShellCheck. Run `dispatch-dedup-helper.sh is-assigned 18458 marcusquinn/aidevops` and confirm it still returns `PARENT_TASK_BLOCKED` (the existing happy path must still work).

### Verification

```bash
# Part 1
bash .agents/scripts/tests/test-dispatch-dedup-fail-closed.sh         # all cases pass, including new internal-jq cases
shellcheck .agents/scripts/dispatch-dedup-helper.sh                    # clean

# Live happy path still works (sanity check)
~/.aidevops/agents/scripts/dispatch-dedup-helper.sh is-assigned 18458 marcusquinn/aidevops
# Expected: PARENT_TASK_BLOCKED (label=parent-task), exit 0

# Part 2 — every guard function should have a t2061 audit comment block
for fn in _check_db_entry is_duplicate _is_stale_assignment _check_cost_budget _is_dispatch_comment_active; do
    grep -B 5 "^${fn}()" .agents/scripts/dispatch-dedup-helper.sh | grep -q "t2061 audit" || echo "MISSING: $fn audit comment"
done
# Expected: no MISSING output
```

## Acceptance Criteria

- [ ] Every `jq` call inside `is_assigned()` (lines 1051-1145) uses explicit local rc capture and emits `GUARD_UNCERTAIN` on non-zero exit
- [ ] Every helper-script call inside `is_assigned()` is similarly wrapped
- [ ] Each of `_check_db_entry`, `is_duplicate`, `_is_stale_assignment`, `_check_cost_budget`, `_is_dispatch_comment_active` has a `t2061 audit (YYYY-MM-DD)` comment block above it documenting the classification
- [ ] Functions classified as "needs hardening" have the `GUARD_UNCERTAIN` pattern applied + regression tests added
- [ ] `tests/test-dispatch-dedup-fail-closed.sh` covers internal jq failure and helper-script failure modes, plus any new fail-closed paths from Part 2
- [ ] ShellCheck clean on `dispatch-dedup-helper.sh`
- [ ] Live happy-path test against GH#18458 still returns `PARENT_TASK_BLOCKED` (no regressions)
- [ ] PR body uses `For #18599` (t2046 parent reference, never `Resolves`/`Closes`/`Fixes`) — eat the dogfood

## Relevant Files

- `todo/tasks/t2046-brief.md` — the parent brief whose audit deliverable this task completes
- `.agents/scripts/dispatch-dedup-helper.sh` — the file being audited
  - `is_assigned()` at line 1035 — Part 1 target
  - `_check_db_entry` at line 241
  - `is_duplicate` at line 331
  - `_is_stale_assignment` at line 445
  - `_check_cost_budget` at line 867
  - `_is_dispatch_comment_active` at line 1351
- `.agents/scripts/tests/test-dispatch-dedup-fail-closed.sh` — t2046's test file, gets new cases
- PR #18663 (t2046 implementation) — read for context on what was already done

## Dependencies

- **Blocked by:** none (t2046 is merged)
- **Blocks:** nothing critical, but completes the t2046 architectural commitment
- **Related:** t2046 (parent), t2047 (sibling — task-id collision guard), GH#18537 (the original specific-bug fix that sparked the architectural conversation)

## Estimate

~3-4h:

- Part 1 (is_assigned internal jq + helpers): ~1.5h
- Part 2 (audit + classify + comment 5 functions, harden any that need it): ~1.5-2h
- Tests + shellcheck + verification: ~30m

## Out of scope

- Auditing guards in helpers OTHER than `dispatch-dedup-helper.sh` (separate task if surfaced)
- Refactoring guard function signatures or splitting them (this is a hardening pass, not a refactor)
- Replacing `GUARD_UNCERTAIN` with a different signal name (use the existing one)
- Removing any of the 5 guard functions even if classified as redundant (out of scope; file separately if needed)
