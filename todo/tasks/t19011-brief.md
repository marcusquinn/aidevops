<!-- aidevops:brief-schema=v2 -->

# t19011: perf(worker): wait once, bounded, for the PR's required checks and merge in-session instead of handing every pending PR to pulse

## Pre-flight

- [x] Memory recall: `worker POST_PR_HANDOFF wait for CI merge latency headless contract` → 0 hits
- [x] Discovery pass: `prework-discovery-helper.sh` found no open PR on `headless-runtime-contract.sh`; related merged work is GH#27658 (stop unbounded post-PR polling), GH#34931 (worker may merge its own PR), GH#36176 (re-verify POST_PR_HANDOFF)
- [x] File refs verified: `headless-runtime-contract.sh` lines 106-131, 241-249, 268-283 and `.agents/AGENTS.md:58` read at `origin/main` `6093070107`
- [x] Tier: `tier:standard` — prompt-contract change in one generator plus one always-loaded line; no runtime code change
- [x] Seeded draft PR decision recorded: skipped — implemented interactively

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (productivity-mission session)
- **Issue:** GH#38388
- **Conversation context:** The user asked whether interactive full-loop sessions solve issues faster than Pulse workers, and whether worker complexity could be simplified to match. Session mining showed the main gap is after the worker opens its PR.

## What

After `commit-and-pr`, a headless worker waits for its own PR's required checks through the existing bounded helper (`full-loop-helper.sh wait-checks <PR> --timeout 200`, at most 8 chunks, about 27 minutes), then merges through `full-loop-helper.sh merge`, the same path interactive full-loop uses. A check that fails because of this PR is fixed in the same session with full context. Only work that is still pending after the bound, or that needs a human, review approval or native auto-merge, is handed to Pulse with `POST_PR_HANDOFF`.

## Why

Evidence from 2026-11-12T23:30Z to 2026-11-14T23:30Z (local read-only GitHub probes in the session workspace, not committed):

- Managed product repo A (private, placeholder name): interactive PRs 34 (31 merged, 0 rework); worker PRs 10 (7 merged, 4 needed conflict rework). Interactive issue solve p50 49 min; worker p50 287-577 min. Merge hop after the last check: interactive p50 2 min; worker p50 12, p75 55, p90 70 min.
- In repo A, one worker PR opened 3 min after dispatch, then sat unmerged 2.5 h until an interactive merge conflicted it; the repair PR took 6.5 h more. Another issue lost 9.5 h the same way.
- `marcusquinn/aidevops`: PR open-to-merge p50 interactive 23 min, worker 45 min.
- Local Pulse used at most 4 of 20 worker slots on 2026-11-14 (`pulse-cycle-index.jsonl`), so holding a slot for a bounded CI wait costs nothing measurable. Each avoided redispatch saves the ~5 min dispatch ceremony (`dedup.ceremony_total` avg 315 s) and a fresh context load.

Interactive sessions win because the same session owns the PR through merge. Workers exit at the PR (contract item 8, "Do not sleep, wait, or poll"), so every pending PR costs at least one Pulse merge pass, and slow ones collect conflicts from concurrent interactive merges.

GH#27658 removed unbounded model polling for human reviews (16 `sleep 120` loops until a 3600 s sandbox kill). This change keeps that protection: the wait is bounded, uses one helper with heartbeat output, covers required checks only, and never waits for human review or approval.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Worker contract text, one guidance line and one watchdog marker; behaviour is verified by the existing contract tests and live worker outcomes.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/headless-runtime-contract.sh:127` — Mandatory behavior 8: bounded required-check wait, one in-session repair round, then merge or `POST_PR_HANDOFF`.
- `EDIT: .agents/scripts/headless-runtime-contract.sh:245-248` — watchdog section: allow only the bounded `wait-checks` chunks; keep the 240 s limit.
- `EDIT: .agents/scripts/headless-runtime-contract.sh:278-279` — pre-exit self-check wording for the new handoff condition.
- `EDIT: .agents/AGENTS.md:58` — same rule in always-loaded guidance, no size increase.
- `EDIT: .agents/scripts/pulse-dispatch-worker-prompt.sh:562,565` — first-pass completion contract items 2 and 5 said "one merge attempt"/"attempt merge once"; align them with behavior 8.
- `EDIT: .agents/scripts/tests/test-headless-contract-clarity.sh:238-252` — assert the bounded wait, the review/approval polling ban and the no-`sleep` rule instead of the old "immediate state check" text.
- `EDIT: .agents/scripts/tests/test-zero-output-url-fallback.sh:165` — the embedded-prompt assertion quoted the old item 5 text.
- `EDIT: .agents/scripts/headless-runtime-lib.sh:969` — `_activity_output_has_ci_wait` did not recognise `wait-checks`, so a quiet bounded wait could be killed as a stall; add the marker (hard-kill backstop unchanged).
- `EDIT: .agents/scripts/tests/test-headless-runtime-provider-tests.sh:80-92` — classifier case for the `wait-checks` marker.
- `EDIT: .agents/scripts/gh-checks-wait-helper.sh:786-794` — cap the last poll sleep at the remaining `--timeout` budget so the option is a real wall-clock bound.

### Complete Write Surface

- **Callers/readers:** `_worker_headless_contract_text` is appended to every headless worker prompt by `headless-runtime-helper.sh`.
- **Writers/mutation paths:** workers already call `full-loop-helper.sh merge` once; the change only delays that call until checks are terminal.
- **Existing verification/tests:** `test-headless-contract-clarity.sh`, `test-headless-runtime-contract-tests.sh` (via `test-headless-runtime-helper.sh`).
- **Schemas/config:** N/A because no config key is added.
- **Generated/deployed mirrors:** deployed by `setup.sh` on release.
- **Migrations/backfills:** N/A because nothing persistent changes.
- **Cleanup/rollback paths:** revert the commit; workers return to one merge attempt and immediate handoff.

### Implementation Steps

1. Rewrite item 8 with the bounded wait: run `full-loop-helper.sh wait-checks "$PR_NUMBER" --repo "$WORKER_REPO_SLUG" --timeout 200` up to 8 times, with one status line before each; exit 0 → merge; exit 1 → fix a failure caused by this PR, push, wait again once; exit 9 → `gh pr ready`, wait again; exit 2/8 after the bound → `POST_PR_HANDOFF`.
2. Keep the GH#27658 guard explicit: never wait for human review, approval or native auto-merge; never use `sleep` loops.
3. Align the watchdog and pre-exit text and the AGENTS.md line.
4. Run the contract tests and ShellCheck.

### Hazards and Compatibility

- **Concurrency/atomicity:** Pulse may merge the same green PR while the worker waits; `full-loop-helper.sh merge` and runtime classification already accept an already-merged PR (GH#34931).
- **Migration/rollback:** prompt text plus one watchdog marker; revert restores the old contract.
- **Watchdog:** each `wait-checks --timeout 200` call stays under the 240 s quiet rule because the helper now caps its last sleep at the remaining budget (before the cap, a live `--timeout 220` call on PR #38390 ran 248 s); the helper's 120 s heartbeat and the new marker defer stall kills; the hard-kill backstop and 3 h sandbox limit still apply.
- **Mixed-version/backward compatibility:** older runners keep the old contract until they update; both behaviours are safe together.
- **Idempotency/retry:** a resumed session re-runs the bounded wait from the current PR state.
- **Partial failure/recovery:** API errors (exit 2) end the wait and hand off as today.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-headless-contract-clarity.sh
bash .agents/scripts/tests/test-headless-runtime-helper.sh
shellcheck .agents/scripts/headless-runtime-contract.sh
```

- **Surface mapping:** contract tests render the real prompt text; live check after release is worker PR open-to-merge time and the `post_pr_handoff` share in `worker-activity-helper.sh summary`.

### Files Scope

- `.agents/scripts/headless-runtime-contract.sh`
- `.agents/scripts/pulse-dispatch-worker-prompt.sh`
- `.agents/scripts/headless-runtime-lib.sh`
- `.agents/scripts/gh-checks-wait-helper.sh`
- `.agents/scripts/tests/test-headless-contract-clarity.sh`
- `.agents/scripts/tests/test-zero-output-url-fallback.sh`
- `.agents/scripts/tests/test-headless-runtime-provider-tests.sh`
- `.agents/AGENTS.md`
- `todo/tasks/t19011-brief.md`
- `TODO.md`

## Acceptance Criteria

- [ ] The worker contract tells workers to wait for required checks with bounded `wait-checks` chunks and merge in-session, and still forbids waiting for human review or approval.

  ```yaml
  verify:
    method: codebase
    pattern: "wait-checks \"\\$PR_NUMBER\" --repo \"\\$WORKER_REPO_SLUG\" --timeout 200"
    path: ".agents/scripts/headless-runtime-contract.sh"
  ```

- [ ] Contract tests pass.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-headless-contract-clarity.sh"
  ```

- [ ] After release, worker PR open-to-merge p50 in `marcusquinn/aidevops` and repo A falls below the 2026-11-14 baseline (45 min open-to-merge and 12 min merge hop respectively), measured over 24 h.

## Context & Decisions

- Chose a prompt-level bounded wait over a runtime-owned post-PR waiter for the first step: it reuses the existing helper and watchdog CI-wait handling and can be measured within a day. If token cost or watchdog kills rise, move the wait into the runtime and resume the same session on failure.
- 8 chunks × 200 s covers the observed CI p50 (21-28 min); 200 s leaves room for API fetch latency and stays below the 240 s quiet-output rule and the 3 h sandbox limit.

## Relevant Files

- `.agents/scripts/headless-runtime-contract.sh:106-131` — execution contract
- `.agents/scripts/headless-runtime-contract.sh:241-283` — watchdog and pre-exit text
- `.agents/scripts/headless-runtime-lib.sh:966-1008` — watchdog CI-wait deferral
- `.agents/scripts/gh-checks-wait-helper.sh:40-52` — `--timeout` and exit codes
