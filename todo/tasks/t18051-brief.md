<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18051: Reach performance logging, feedback miner, and issue generator

## Pre-flight

- [x] Memory recall: `aidevops reach performance feedback miner issue generator` → 0 hits — no relevant prior lesson found.
- [x] Discovery pass: no t18051 brief/open related PR found; `_performance` and `_feedback` docs are present.
- [x] File refs verified: `.agents/aidevops/performance.md`, `.agents/aidevops/feedback.md`, and reach/capture target files are present or declared blockers.
- [x] Tier: `tier:standard` — append-only metrics, mining thresholds, routine, and safe issue generation.
- [x] Seeded draft PR decision recorded: skipped — depends on t18050 capture metadata.

## Origin

- **Created:** 2026-07-01
- **Session:** OpenCode interactive reach/capture planning
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** t18050
- **Conversation context:** Reach/capture should improve itself by logging attempt cost/outcomes, mining repeated failures, and turning high-confidence gaps into worker-ready issues.

## What

Add append-only performance logging for reach attempts, a feedback miner that clusters repeated failures or inefficiencies, and a dry-run issue generator that produces privacy-safe worker-ready task briefs when thresholds are met.

## Why

Without metrics and feedback, repeated discovery, brittle selectors, slow backends, and noisy retries remain invisible. Structured logs turn those costs into measurable follow-up work.

## Tier

**Selected tier:** `tier:standard` — spans helper, performance/feedback docs, routine, and tests.

## PR Conventions

Leaf task. Worker PR should resolve this task's own issue only.

## How

### Progressive Context Plan

- **Read first:** `.agents/aidevops/performance.md:14-83` — result record semantics.
- **Read first:** `.agents/aidevops/feedback.md:141-202` — mining loop and review gates.
- **Read first:** `.agents/templates/brief-template.md:273-380` — worker-ready issue body expectations.
- **Read first:** `reach-helper.sh` after t18050.
- **Stop when:** attempts append normalized JSONL, miner clusters local fixtures, and issue generation defaults to dry-run.

### Files to Modify

- `EDIT: .agents/scripts/reach-helper.sh` — append performance records and add `feedback mine|issue` commands.
- `EDIT: .agents/aidevops/performance.md` — document reach metric fields/storage.
- `EDIT: .agents/aidevops/feedback.md` — document reach feedback thresholds and promotion to tasks.
- `NEW: .agents/scripts/reach-feedback-routine.sh` — periodic report-only miner.
- `NEW: .agents/scripts/tests/test-reach-feedback.sh` — log/mining/dry-run tests.

### Implementation Steps

1. Append reach performance JSONL to repo `_performance/reach-capture.jsonl` when available, otherwise to `~/.aidevops/.agent-workspace/performance/reach-capture.jsonl`.
2. Record fields: timestamp, safe session ref, target key/hash, operation, backend, agency level, headed/headless, profile class, proxy class, offload, latency, discovery steps, token estimate, bytes in/out, status, failure class, temporary flag, and next-best action.
3. Add `reach feedback mine --window 7d --format json` grouping records by failure class/backend/agency/target key and reporting repeated temporary failures, permanent blockers, slow choices, high discovery counts, high token estimates, and repeated manual-review outcomes.
4. Add `reach feedback issue --dry-run` that prints a worker-ready brief skeleton by default. Real issue creation must require an explicit wrapper-safe flag and enough evidence.
5. Add `reach-feedback-routine.sh` in report-only mode. Suggested filing threshold: 3 similar failures across 2 sessions, or one permanent blocker affecting a documented routine.

### Verification

```bash
shellcheck .agents/scripts/reach-helper.sh .agents/scripts/reach-feedback-routine.sh .agents/scripts/tests/test-reach-feedback.sh
.agents/scripts/tests/test-reach-feedback.sh
./aidevops.sh reach feedback mine --window 7d --format json
./aidevops.sh reach feedback issue --dry-run --format markdown
```

### Files Scope

- `.agents/scripts/reach-helper.sh`
- `.agents/scripts/reach-feedback-routine.sh`
- `.agents/scripts/tests/test-reach-feedback.sh`
- `.agents/aidevops/performance.md`
- `.agents/aidevops/feedback.md`

## Acceptance Criteria

- [ ] Reach route/capture/failure attempts append normalized JSONL performance records.
- [ ] Logs include backend, mode, profile/proxy class, offload, latency, tokens, status, failure class, temporary/permanent flag, and next action.
- [ ] Feedback miner emits privacy-safe repeated-failure/inefficiency themes.
- [ ] Issue generator defaults to dry-run and emits worker-ready brief content.
- [ ] Tests cover log append, thresholds, dry-run output, and sanitization.

## Dependencies

- **Blocked by:** t18050.
- **Blocks:** t18052 routine/audit integration.
