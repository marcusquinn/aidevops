<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2046: parent-task lifecycle hardening — fail-closed guard + PR keyword guard

## Origin

- **Created:** 2026-04-13, claude-code:interactive
- **Incident:** GH#18458 (t2010), 2026-04-12 23:08 - 2026-04-13 04:18 UTC
- **Plan:** `todo/plans/parent-task-incident-hardening.md` (this PR)
- **Why now:** the t2010 dispatch loop and subsequent auto-close exposed two systemic gaps. The immediate jq null-handling bug was patched independently by GH#18537, but the deeper architectural defaults (guards fail-open, PRs auto-close parent issues with default keywords) need belt-and-braces hardening before the same pattern bites again.

## What

Two related fixes in one PR (or split into two child PRs at worker discretion):

### Deliverable A — `is_assigned()` fail-closed default

Switch the canonical dispatch guard from fail-open to fail-closed on internal errors. When the guard cannot determine whether dispatch is safe (jq error, gh API failure, helper-script failure), the function MUST refuse dispatch and emit a `GUARD_UNCERTAIN` signal, mirroring the existing `PARENT_TASK_BLOCKED` and cost-budget signal patterns. This prevents the same shape of bug as GH#18537 from recurring with any *other* internal failure mode.

### Deliverable B — parent-task PR keyword guard

Prevent the `Resolves #NNN` auto-close trap that bit PR #18581 by adding three layered defenses:

1. **Documentation** — new paragraph in `templates/brief-template.md` and `AGENTS.md` "Traceability" covering parent-task PR keyword conventions.
2. **Client-side check** — new helper `parent-task-keyword-guard.sh` invoked by `full-loop-helper.sh commit-and-pr` that scans the PR body for closing keywords and refuses to create the PR if any reference a `parent-task`-labeled issue (unless `--allow-parent-close` is passed for the legitimate final-phase case).
3. **CI check** — `.github/workflows/parent-task-keyword-check.yml` runs the same logic on every `pull_request` event as belt-and-braces for PRs created outside the helper (web UI, external contributors).

## Why

See `todo/plans/parent-task-incident-hardening.md` §2 and §3 for the full root-cause analysis.

Short version:

- **Deliverable A** — three workers were dispatched to a `parent-task`-labeled issue because the guard's jq filter crashed on null labels and the function silently returned the "allow dispatch" code path. The specific bug was fixed in GH#18537. The architectural default (fail-open on internal errors) was not. Any future jq filter, API schema change, or helper script failure will recreate the same outcome until the default is flipped to fail-closed.
- **Deliverable B** — PR #18581 used `Resolves #18458` and auto-closed the parent issue, requiring manual reopen. Nothing in the framework hints to PR authors (worker or interactive) that parent-task issues need different keyword treatment than leaf issues. Existing `prompts/build.txt` "Traceability" rule covers commit-vs-planning but not parent-vs-leaf.

Both fixes prevent recurrence of the t2010 incident shape across all future parent tasks. The decomposition pattern from t1962 is spreading (t1986, t2010, more in flight) and the surface area for these two traps grows with each new parent.

## Tier

`tier:standard` — sonnet. Mechanical implementation following established patterns.

### Tier checklist (verify before assigning)

- [x] **>2 files?** Yes (4 new files + 3 edited existing) — disqualifies `tier:simple`.
- [ ] Skeleton code blocks? No — every change has a verbatim source pattern in the existing codebase.
- [ ] Error/fallback logic to design? No — the fail-closed pattern is fully specified in Plan §2.4 and §3.3.2.
- [x] Estimate >1h? Yes (~5-6h) — disqualifies `tier:simple`.
- [ ] >4 acceptance criteria? See below — 7 criteria, but each is a single mechanical check.
- [ ] Judgment keywords? No — every step has a specific code or doc location.

`tier:standard` is correct. Do NOT escalate to `tier:reasoning` — there is no novel design here, only adaptation of patterns that already ship in the framework.

## How (Approach)

### Files to modify

#### Deliverable A — fail-closed guard

- **EDIT:** `.agents/scripts/dispatch-dedup-helper.sh` — modify `is_assigned()` (line 1035) and the helpers it calls. Add a new local rc capture pattern that distinguishes "operation succeeded with negative answer" from "operation failed". On failure, emit `GUARD_UNCERTAIN (reason=...)` and `return 0` (block). Update the function docstring above line 1035 to document the new fail-closed contract.
- **NEW:** `.agents/scripts/tests/test-dispatch-dedup-fail-closed.sh` — model verbatim on existing `test-parent-task-guard.sh`. Four test cases (Plan §2.4):
  - missing labels key → `GUARD_UNCERTAIN`, exit 0
  - null labels key → `GUARD_UNCERTAIN`, exit 0
  - well-formed parent-task labels → `PARENT_TASK_BLOCKED`, exit 0
  - clean dispatchable issue → exit 1

#### Deliverable B — parent-task PR keyword guard

- **NEW:** `.agents/scripts/parent-task-keyword-guard.sh` — single-purpose check script. Two subcommands:
  - `check-body --body-file PATH --repo OWNER/REPO [--strict] [--allow-parent-close]` — scans body for `(Closes|Resolves|Fixes)\s+#(\d+)`, looks up each issue's labels via `gh issue view`, returns 0 (clean), 1 (warning, parent-task referenced), or 2 (strict mode block).
  - `check-pr <PR_NUMBER> --repo OWNER/REPO [--strict]` — same but reads the PR body via `gh pr view`.
- **EDIT:** `.agents/scripts/full-loop-helper.sh` — wire `parent-task-keyword-guard.sh check-body --strict` into the `commit-and-pr` subcommand BEFORE `gh pr create` runs. If the guard returns 2, abort with a clear message: "PR body uses Resolves/Closes/Fixes on a parent-task issue (#NNN). Use For/Ref instead, or pass --allow-parent-close if this PR closes the final phase."
- **NEW:** `.github/workflows/parent-task-keyword-check.yml` — runs on `pull_request` (opened, edited, synchronize, ready_for_review). Calls `parent-task-keyword-guard.sh check-pr ${{ github.event.pull_request.number }} --strict` and posts a check status. Fails the check on violation; passes otherwise.
- **NEW:** `.agents/scripts/tests/test-parent-task-keyword-guard.sh` — five cases (Plan §3.3.2 closing list).
- **EDIT:** `templates/brief-template.md` — add the §3.3.1 paragraph in the "PR conventions" subsection.
- **EDIT:** `.agents/AGENTS.md` "Traceability" subsection — add the same paragraph (or a one-line cross-reference to the brief template).

### Reference patterns

- **For Deliverable A:**
  - `dispatch-dedup-helper.sh:1058-1075` — the existing `PARENT_TASK_BLOCKED` short-circuit. Follow the same emit-and-return pattern for `GUARD_UNCERTAIN`.
  - `dispatch-dedup-helper.sh:1077-1093` — the existing `_check_cost_budget` signal flow. Same pattern: explicit local rc capture, emit signal, return 0 on block.
  - `tests/test-parent-task-guard.sh` (in particular the Cases F and G added by GH#18537) — the model for the new fail-closed tests. Same fixture structure, same mock pattern.
- **For Deliverable B:**
  - `gh-signature-helper.sh` — small single-purpose helper script with subcommands. Model the structure of `parent-task-keyword-guard.sh` on this.
  - `.github/workflows/framework-validation.yml` — model for the new GitHub Actions workflow. Use the same setup steps (checkout, gh auth, run script).
  - `verify-issue-close-helper.sh` — analogous helper that checks issue/PR relationships. Model the gh API calls and label-parsing on this.
  - `prompts/build.txt` "Traceability" section — existing convention text. The new parent-task paragraph slots in directly after.

### Implementation steps

1. **Read the plan in full.** `todo/plans/parent-task-incident-hardening.md` is short (~250 lines) and contains every design decision. Don't re-derive.
2. **Deliverable A first.** Start with `tests/test-dispatch-dedup-fail-closed.sh` — write the test cases against the *current* (fail-open) behavior, prove they fail. Then modify `is_assigned()` to fail closed. Re-run the test, prove they pass.
3. **Update the function docstring** above `is_assigned()` to document the contract: blocks on parent-task, blocks on cost budget exceeded, blocks on assignee conflict, **blocks on internal uncertainty (GUARD_UNCERTAIN)**, allows otherwise.
4. **Audit the other guard functions** listed in Plan §2.3 (`_check_db_entry`, `is_duplicate`, `_is_stale_assignment`, `_check_cost_budget`, `_is_dispatch_comment_active`). For each, document the current default (read-only). If any are obviously fail-open and the fix is mechanical, include in this PR. Otherwise file follow-up tasks via `findings-to-tasks-helper.sh`.
5. **Deliverable B second.** Start with the documentation edit (`templates/brief-template.md` + `AGENTS.md`) — cheapest and immediately useful even before the code lands.
6. **Then write `parent-task-keyword-guard.sh`** with the `check-body` subcommand. Test it locally against PR #18581's body file (downloaded via `gh pr view 18581 --json body --jq .body`) — must return exit 2 with a clear error. Test against any normal merged PR — must return exit 0.
7. **Wire into `full-loop-helper.sh commit-and-pr`** as a pre-flight check before `gh pr create`. Add `--allow-parent-close` flag passthrough for the final-phase exemption.
8. **Add the GitHub Actions workflow.** Use `framework-validation.yml` as the template.
9. **Test end-to-end** by running `commit-and-pr` against a synthetic PR body that includes `Resolves #18458` (the parent-task issue used as the canonical fixture). Must abort with the documented error.
10. **shellcheck everything.**

### Verification

```bash
# Deliverable A
bash .agents/scripts/tests/test-dispatch-dedup-fail-closed.sh         # all 4 cases pass
shellcheck .agents/scripts/dispatch-dedup-helper.sh                    # clean
~/.aidevops/agents/scripts/dispatch-dedup-helper.sh is-assigned 18458 marcusquinn/aidevops
# Expected: PARENT_TASK_BLOCKED (label=parent-task), exit 0 (still blocked, behavior preserved)

# Deliverable B
bash .agents/scripts/tests/test-parent-task-keyword-guard.sh           # all 5 cases pass
shellcheck .agents/scripts/parent-task-keyword-guard.sh                # clean
echo "Resolves #18458" > /tmp/test-body.md
bash .agents/scripts/parent-task-keyword-guard.sh check-body --body-file /tmp/test-body.md --repo marcusquinn/aidevops --strict
# Expected: exit 2, message "Resolves #18458 references parent-task issue. Use For/Ref instead."
echo "For #18458" > /tmp/test-body.md
bash .agents/scripts/parent-task-keyword-guard.sh check-body --body-file /tmp/test-body.md --repo marcusquinn/aidevops --strict
# Expected: exit 0
```

## Acceptance Criteria

- [ ] `is_assigned()` blocks dispatch on internal uncertainty (jq error, gh API failure, helper failure), emitting `GUARD_UNCERTAIN (reason=...)` to stdout. Documented in the function docstring.
- [ ] `tests/test-dispatch-dedup-fail-closed.sh` exists with 4 cases (Plan §2.4) and all pass.
- [ ] Other guard functions in `dispatch-dedup-helper.sh` audited; either fixed in this PR or filed as follow-up tasks via `findings-to-tasks-helper.sh`.
- [ ] `parent-task-keyword-guard.sh` exists with `check-body` and `check-pr` subcommands; rejects `Resolves`/`Closes`/`Fixes` references to parent-task issues in `--strict` mode unless `--allow-parent-close`.
- [ ] `tests/test-parent-task-keyword-guard.sh` exists with 5 cases (Plan §3.3.2) and all pass.
- [ ] `full-loop-helper.sh commit-and-pr` invokes the guard in `--strict` mode before `gh pr create`. Failure aborts the PR creation with a clear message.
- [ ] `.github/workflows/parent-task-keyword-check.yml` runs on `pull_request` events and calls the guard with `--strict`.
- [ ] `templates/brief-template.md` + `.agents/AGENTS.md` "Traceability" updated with the parent-task PR keyword paragraph.
- [ ] ShellCheck clean on all modified shell files.
- [ ] PR body uses `For #2046` (NOT `Resolves`) — eat the dogfood.

## Relevant Files

- `todo/plans/parent-task-incident-hardening.md` — the plan (READ FIRST)
- `.agents/scripts/dispatch-dedup-helper.sh` — Deliverable A target
- `.agents/scripts/full-loop-helper.sh` — Deliverable B integration point
- `.agents/scripts/gh-signature-helper.sh` — model for the new guard helper structure
- `.agents/scripts/verify-issue-close-helper.sh` — model for the gh API + label parsing
- `.agents/scripts/tests/test-parent-task-guard.sh` — model for the new test files
- `.github/workflows/framework-validation.yml` — model for the new workflow
- `templates/brief-template.md` — gets the new convention text
- `.agents/AGENTS.md` "Traceability" section — gets the cross-reference

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing immediately. The hardening prevents a recurring bug class but doesn't gate any other work.
- **Related:** GH#18537 (the immediate jq null-fallback fix this builds on), GH#18419 (t1986, the original parent-task guard), GH#18458 (the t2010 incident issue)

## Estimate

~5-6h total. Splittable:

- Deliverable A: ~2-3h (test + fail-closed switch + audit + docstring update)
- Deliverable B: ~3-4h (helper script + 2 test files + workflow + 2 doc edits + integration)

If the worker prefers two PRs, decompose: file Deliverable A as t2046 (this brief, scope-reduced) and Deliverable B as a sibling. Both point back to this plan.

## Out of scope

- Auditing guards in helpers OTHER than `dispatch-dedup-helper.sh` (Plan §6) — file as separate tasks if the audit surfaces further issues.
- The §3.3.3 auto-reopen sweeper — defer until §3.3.1 + §3.3.2 are observed insufficient.
- Modifying `prompts/build.txt` "Traceability" beyond adding a one-line cross-reference to the new parent-task rule (the rule belongs in `AGENTS.md` and `templates/brief-template.md`).
