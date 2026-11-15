<!-- aidevops:brief-schema=v2 -->

# t19007: fix(terminal-blocker): publish the external trigger and revisit external_trigger_pending holds

## Pre-flight (auto-populated by briefing workflow)

- [x] Discovery: `external_trigger_pending` re-arms only on a brief/dependency change or an authorized retry directive (`.agents/scripts/terminal-blocker-circuit.sh` `_TBC_REVISION_REARM_REASONS`, line 36). Nothing revisits it on a schedule and nothing checks whether the trigger happened.
- [x] Reference patterns: GH#36760 (`aed371e4ed`, "publish sanitized requested input") for `input_required`; GH#38155 (`c2683ce9a5`, AI brief-owner pass) for an AI decision pass over parked drafts.
- [x] Prerequisite: t19008 (GH#38351) fixes approval-snapshot reader drift and adds a writer-generated parity test. Land it first so the reader already admits one sanitized optional line.

## Origin

- Created: 2026-11-14, interactive productivity-mission session (OpenCode), author ai-interactive.
- Standing direction from the maintainer: "blocked is a label, not an instruction; it still needs a why, and revisiting to see if AI can unblock without needing scarce user time."

## What

1. **Publish the why.** When a worker or triage classifies `external_trigger_pending`, the public release comment gains one sanitized line, `Trigger awaited: <event, owner or date>`.
2. **Revisit the hold.** Pulse runs a bounded AI revisit for `external_trigger_pending` holds older than a revisit interval (default 24h, doubling to at most 7d). It returns exactly one of `trigger_met` (post the existing authorized retry directive), `still_pending` (record the next revisit time) or `not_external` (reclassify through the existing triage path).
3. **Make the labels agree.** An issue under an active `external_trigger_pending` hold never shows `status:available`.

## Why

Evidence from one private managed product repo on 2026-11-14:

- 45 open issues carry an `external_trigger_pending` release comment: 25 `status:blocked`, 10 `status:available`, 8 `status:in-review`, 2 unlabelled. Last updated 0-27 days ago (17 within a day, 9 over a week).
- Every public comment says only "Wait for the specified external trigger ... Raw evidence remains in protected worker telemetry." The trigger exists only on the releasing runner's machine, so no other runner, AI pass or maintainer can tell what to wait for.
- Worked example: an issue labelled `status:available`, `auto-dispatch`, `priority:high` and unassigned, untouched for 3 days, whose worker released with `reason=external_trigger_pending owner=dependency-owner` and left a green draft checkpoint PR. Each pulse cycle spent 133-194s of a dispatch slot re-deriving `worker_draft_checkpoint_blocked` (see t19006). Nothing checks whether the trigger has happened.

## Tier

**Selected tier:** `tier:thinking`

It changes a public, approval-relevant comment format and adds a bounded AI decision with re-arm authority.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/terminal-blocker-circuit.sh:310-330` — set `AIDEVOPS_TERMINAL_BLOCKER_TRIGGER` next to `AIDEVOPS_TERMINAL_BLOCKER_QUESTION` from a worker `TERMINAL_BLOCKER_TRIGGER=` line.
- `EDIT: .agents/scripts/terminal-blocker-circuit.sh:356-400` — `_terminal_blocker_triage_unknown`: when the decision is `external_trigger_pending`, export its `trigger_evidence`.
- `EDIT: .agents/scripts/terminal-blocker-circuit.sh:1031-1034,1068-1070` — print `Trigger awaited: %s` after the evidence line, mirroring `Input requested:`.
- `NEW: .agents/scripts/terminal-blocker-trigger-revisit.sh` — the bounded revisit pass, modelled on `.agents/scripts/pr-checkpoint-unknown-digest.sh` `_pcc_unknown_pending_work`.
- `EDIT: .agents/scripts/approval-snapshot-v2.sh:138` — admit the optional `Trigger awaited:` line with the same strict single-line pattern used for `Input requested:`.
- `EDIT: .agents/scripts/pulse-dispatch-engine-housekeeping.sh` — call the revisit pass, bounded per cycle.
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:367` — `_dispatch_draft_hint_boundary`: wake at the recorded revisit time.

### Complete Write Surface

- **Callers/readers:** `approval-snapshot-v2.sh` `canonical_terminal_blocker_release` (line 138) parses the release body. `terminal-blocker-recovery-helper.sh` (lines 394, 679, 881), `dependency-event-reconciler.sh:118`, `pulse-dep-graph.sh:431` and `pr-checkpoint-target-lib.sh:482` match release comments by prefix and are unaffected by an extra trailing line. `pulse-diagnose-helper.sh` displays it.
- **Writers/mutation paths:** `terminal_blocker_observation_fragment` (line 705) and `_terminal_blocker_recovery` (line 999) write the public text. The revisit pass writes one retry directive (existing `terminal-blocker-circuit:retry` marker) or one reclassification observation per due hold, plus a local revisit record.
- **Existing verification/tests:** `.agents/scripts/tests/test-terminal-blocker-circuit.sh` (question publication around lines 560-600 is the pattern), `.agents/scripts/tests/test-approval-helper-content-binding.sh` (canonical release cases around lines 662-700).
- **Schemas/config:** the release comment format (public, approval-relevant). New knobs: `AIDEVOPS_TRIGGER_REVISIT_INTERVAL_S` (default 86400) and `AIDEVOPS_TRIGGER_REVISIT_MAX_PER_CYCLE` (default 5), read in `terminal-blocker-trigger-revisit.sh`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`; no generated output.
- **Migrations/backfills:** legacy holds have no trigger line. The revisit pass treats a missing line as `not_external` input and sends it to the existing unknown-triage path in `pr-checkpoint-unknown-digest.sh`. No comment is edited retroactively.
- **Cleanup/rollback paths:** revert the PR. Revisit records under `~/.aidevops/logs/` are advisory and expire; deleting them only causes one early revisit.

### Implementation Steps

1. Add `_terminal_blocker_public_trigger`, reusing `_terminal_blocker_public_question` (line 960) so the trigger gets the same length, control-character, markup and credential rejection. Prefer extracting a shared `_terminal_blocker_public_line` over duplicating the sanitizer.
2. Plumb `AIDEVOPS_TERMINAL_BLOCKER_TRIGGER` from `terminal_blocker_capture_output` (worker line `TERMINAL_BLOCKER_TRIGGER=`) and from the triage decision. Clear it on every failed capture, exactly as the question is cleared.
3. Emit `Trigger awaited:` only for `external_trigger_pending`. With no sanitized trigger, keep today's action text and add nothing.
4. Extend `canonical_terminal_blocker_release` in `approval-snapshot-v2.sh` to admit the optional `Trigger awaited:` line. Extend the writer/reader parity test added by t19008 to cover it.
5. Write `terminal-blocker-trigger-revisit.sh`: list open `status:blocked` issues whose latest trusted observation is `external_trigger_pending` and older than the interval. Make one `ai-research-helper.sh --stdin` call per issue with an allowlisted JSON result (`{"decision":"trigger_met|still_pending|not_external","evidence":"..."}`) and apply the outcome. Only `trigger_met` with quoted evidence may post the retry directive.
6. Wire the pass into housekeeping and expose the next revisit time to `_dispatch_draft_hint_boundary` so the negative cache wakes when it is due.
7. Fix the label mismatch: when a fresh `external_trigger_pending` observation projects `status:blocked`, keep that label until re-arm. Find the path that leaves `status:available` with `pulse-diagnose-helper.sh` on a real affected issue before editing.

### Hazards and Compatibility

- **Concurrency/atomicity:** two runners may revisit the same issue. Use the existing claim lock or a per-issue revisit marker in the posted directive and skip when a newer retry or observation exists. A duplicate `trigger_met` retry is harmless because retry is scheduling consent only.
- **Migration/rollback:** legacy comments keep working; the trigger line is optional for readers.
- **Mixed-version/backward compatibility:** older runners' approval readers do not know the new line. Land the reader change in the release before or with the writer, and keep the writer from emitting the line until the reader version is deployed (gate on the framework version or ship both in one PR).
- **Idempotency/retry:** a revisit outcome is recorded with the observation fingerprint; the same fingerprint is not revisited before its next time.
- **Partial failure/recovery:** if the AI call fails or returns invalid JSON, record `still_pending` with a short backoff and post nothing.

### Complexity Impact

`terminal-blocker-circuit.sh` is 1,448 lines, near the 1,500-line shell gate. Put the revisit pass in the new file and keep the writer edits under about 30 lines; extract the shared sanitizer instead of copying it.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-terminal-blocker-circuit.sh
bash .agents/scripts/tests/test-approval-helper-content-binding.sh
shellcheck .agents/scripts/terminal-blocker-circuit.sh .agents/scripts/terminal-blocker-trigger-revisit.sh .agents/scripts/approval-snapshot-v2.sh .agents/scripts/pulse-dispatch-engine-housekeeping.sh
```

- **Surface mapping:** `test-terminal-blocker-circuit.sh` proves the writer emits only a sanitized trigger, rejects unsafe text and clears stale state (acceptance 1 and 4). `test-approval-helper-content-binding.sh` proves the reader still treats the comment as canonical and rejects extra prose (acceptance 1 and 4; mixed-version hazard). Production check after deploy: one revisit run against the affected repo's `external_trigger_pending` issues shows outcome records and no `status:available` holds (acceptance 2 and 3). `shellcheck` covers every touched script.
- **Broad verification trigger:** Not required. Changes are confined to terminal-blocker and approval helpers with focused tests.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: the two test scripts above
- [ ] WIP commit created before broad gates: `wip: t19007 trigger publication and revisit`
- [ ] Evidence-triggered broad verification then run: not required — confined helpers

### Scope Boundaries

**Hard boundaries:** do not publish raw worker telemetry. Do not auto-clear `permission_required` or `source_access_blocked`; their human-owned flows stay. Do not loosen the approval reader beyond one strict optional line.

**AI brief owner:** the interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/terminal-blocker-circuit.sh`
- `.agents/scripts/terminal-blocker-trigger-revisit.sh`
- `.agents/scripts/approval-snapshot-v2.sh`
- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/pulse-dispatch-engine-housekeeping.sh`
- `.agents/scripts/headless-runtime-contract.sh` (integration scope recovery, GH#38353: workers must be told to emit `TERMINAL_BLOCKER_TRIGGER=`)
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`
- `.agents/scripts/tests/test-approval-helper-content-binding.sh`
- `.agents/reference/worker-diagnostics.md`
- `TODO.md`

## Acceptance Criteria

- [ ] Positive: a new `external_trigger_pending` release posts `Trigger awaited: <sanitized text>`, and `approval-snapshot-v2.sh` still classifies the comment as canonical (approval stays `VERIFIED`).
- [ ] Positive: a hold older than its revisit time gets exactly one outcome record (`trigger_met`, `still_pending` with the next time, or `not_external`), and `trigger_met` re-arms dispatch through the existing retry directive.
- [ ] Positive: no issue under an active `external_trigger_pending` hold carries `status:available`.
- [ ] Negative: URLs, multi-line text, markup, over-length text and credential-shaped strings never appear in the trigger line; the comment then carries no trigger line. Extra prose after the trigger line still makes the comment content-bound (approval goes `STALE_APPROVAL`).
- [ ] Negative: no hold is revisited more often than its interval, and `permission_required` / `source_access_blocked` holds are never revisited by this pass.

## Context & Decisions

- The maintainer's aim is that a person rarely needs to read an issue. A hold must say what it waits for, and AI must check whether that has happened.
- Retry directives are scheduling consent only; downstream guards still verify. That is why an AI `trigger_met` decision with quoted evidence may post one.
