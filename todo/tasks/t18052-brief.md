<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18052: Reach efficiency, headed/headless/offload routing, routines, and auditability

## Pre-flight

- [x] Memory recall: `aidevops reach efficiency headed headless offload routine audit` → 0 hits — no relevant prior lesson found.
- [x] Discovery pass: no t18052 brief/open related PR found; `/auto-browse` and reach targets are present or declared blockers.
- [x] File refs verified: `.agents/workflows/auto-browse.md`, reach docs/helper targets, and performance/feedback targets are present or declared blockers.
- [x] Tier: `tier:standard` — routing policy, routine integration, and audit fields.
- [x] Seeded draft PR decision recorded: skipped — depends on t18047 and t18051.

## Origin

- **Created:** 2026-07-01
- **Session:** OpenCode interactive reach/capture planning
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** t18047, t18051
- **Conversation context:** The final slice makes reach/capture efficient and operational with explicit budgets, headed/headless decisions, offload choices, routines, and audit links.

## What

Extend reach routing with token/discovery budgets, headed/headless selection, local-vs-offloaded execution recommendations, routine/watch integration, and audit fields connecting captures, performance records, feedback themes, TODO tasks, GitHub issues, and PRs.

## Why

Reach should not become another expensive exploratory loop. Budgets and audit refs let workers stop early, reuse prior decisions, offload long work, and prove what was captured/logged/mined/filed/fixed.

## Tier

**Selected tier:** `tier:standard` — policy/docs/helper work with deterministic tests.

## PR Conventions

Leaf task. Worker PR should resolve this task's own issue only.

## How

### Progressive Context Plan

- **Read first:** `.agents/workflows/auto-browse.md:121-164` — learning-loop metrics and graduation.
- **Read first:** `.agents/aidevops/reach-capture.md` and `reach-helper.sh` after t18047-t18051.
- **Load only if:** adding a routine entry — inspect existing TODO routine formatting before editing scheduler surfaces.
- **Stop when:** route output includes budgets/mode/offload/audit fields and tests prove deterministic policy selection.

### Files to Modify

- `EDIT: .agents/scripts/reach-helper.sh` — add efficiency policy, mode/offload selection, audit refs, and `watch` hook.
- `EDIT: .agents/aidevops/reach-capture.md` — document budgets, headed/headless/offload, routines, and audit chain.
- `EDIT: .agents/workflows/auto-browse.md` — reference reach doctor/route as reusable preflight for repeatable capture workflows.
- `NEW: .agents/scripts/reach-routine.sh` — safe periodic reach feedback/watch entry point when needed.
- `NEW: .agents/scripts/tests/test-reach-efficiency.sh` — deterministic policy tests.

### Implementation Steps

1. Add route budget fields: max iterations, max tool calls, max token estimate, stop-after-repeated-success, and stop-on-permanent-failure.
2. Add efficiency policy: prefer text/DOM over screenshots, prefer API/fetch before browser, reuse profile lease, reuse prior route decision with TTL.
3. Add headed/headless rules: public static/crawler capture is headless; login/MFA/manual consent/CAPTCHA/payment/posting/destructive actions are headed/manual-gated; long stable recurring captures go to headless worker/routine.
4. Add offload fields: `offload`, `offload_reason`, `routine_candidate`, and safe compute notes. Keep short public fetch local; offload long crawls/repeat captures when safe; do not offload sensitive profile/cookie work unless private workspace/credential refs are available.
5. Add audit fields: `todo_id`, `issue_ref`, `pr_ref`, `capture_ref`, `performance_ref`, `feedback_ref`, and `route_decision_id`.
6. Add `reach watch --once --dry-run` and `reach-routine.sh` in report-only mode by default.
7. Update `/auto-browse` docs to run `aidevops reach doctor` and `aidevops reach route` before high-agency browser discovery for repeatable capture/data-mining workflows.

### Verification

```bash
shellcheck .agents/scripts/reach-helper.sh .agents/scripts/reach-routine.sh .agents/scripts/tests/test-reach-efficiency.sh
.agents/scripts/tests/test-reach-efficiency.sh
./aidevops.sh reach route --objective "repeat public changelog capture" --scope public --format json
./aidevops.sh reach watch --once --dry-run --format json
```

### Files Scope

- `.agents/scripts/reach-helper.sh`
- `.agents/scripts/reach-routine.sh`
- `.agents/scripts/tests/test-reach-efficiency.sh`
- `.agents/aidevops/reach-capture.md`
- `.agents/workflows/auto-browse.md`
- `TODO.md`

## Acceptance Criteria

- [ ] Route output includes discovery/token budgets and stop conditions.
- [ ] Route output chooses headed/headless mode with rationale.
- [ ] Route output recommends local/worker/container/remote offload with safety constraints.
- [ ] Watch/routine path runs dry-run/report-only by default.
- [ ] Audit fields link TODO, GitHub issue/PR, capture artifact, performance record, feedback theme, and route decision ID.
- [ ] Tests cover public fetch, logged-in/profile, long crawl, manual gate, routine candidate, and sensitive no-offload cases.

## Dependencies

- **Blocked by:** t18047, t18051.
