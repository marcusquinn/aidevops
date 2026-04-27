<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2969: _campaigns/ P6 — performance integration + learnings promotion

## Origin

- **Created:** 2026-04-27
- **Session:** Headless worker (auto-dispatch)
- **Parent task:** #20929 (t2870 `_campaigns/` plane)
- **Phase:** P6 (final phase)

## What

Post-launch lifecycle integration for the `_campaigns/` plane:

1. **`campaign launch <id>`** — extends P2's launch command with P6 deliverables: moves `_campaigns/active/<id>/` → `launched/<id>/` and creates `results.md` + `learnings.md` templates for post-launch tracking.

2. **`campaign promote <id> --results`** — pushes metrics summary from `_campaigns/launched/<id>/results.md` to `_performance/marketing/<id>.md`.

3. **`campaign promote <id> --learnings`** — promotes post-mortem insights from `_campaigns/launched/<id>/learnings.md` to `_knowledge/insights/marketing/<YYYY-MM>/<id>-learnings.md`.

4. **`campaign feedback [<id>]`** — surfaces `_feedback/` insights as campaign research inputs; if `<id>` given, writes aggregated insights to `_campaigns/active/<id>/research/feedback-insights.md`.

## Why

Closes the campaign lifecycle loop. Without P6, post-launch metrics and retrospective learnings have no structured promotion path — they stay in `_campaigns/launched/` where they're invisible to the `_performance/` and `_knowledge/` planes.

Cross-plane promotion lets:
- `_performance/marketing/` accumulate campaign ROI data over time
- `_knowledge/insights/marketing/` grow as an institutional memory of campaign learnings

## How

### Files Created / Modified

- **NEW:** `.agents/scripts/campaign-helper.sh` — implements `launch`, `promote`, `feedback` subcommands; follows `case-helper.sh` / `knowledge-helper.sh` pattern
- **NEW:** `.agents/templates/campaign-results.md` — template for `results.md` created at launch
- **NEW:** `.agents/templates/campaign-learnings.md` — template for `learnings.md` created at launch
- **EDIT:** `aidevops.sh` — adds `campaign | campaigns` dispatch case + help text

### Reference Pattern

Modelled on `case-helper.sh` (archive move, actor resolution, git-aware mv) and `knowledge-helper.sh` (file provisioning, template substitution).

### Complexity Impact

All functions are new (no existing function modified). Largest function: `cmd_feedback` (~50 lines). Well under the 80-line advisory and 100-line gate.

### Verification

```bash
shellcheck .agents/scripts/campaign-helper.sh
# Expect: zero violations

# Smoke test help output
.agents/scripts/campaign-helper.sh help

# Verify aidevops.sh dispatch wired
grep -n "campaign" aidevops.sh
```

## Acceptance Criteria

- [x] `campaign-helper.sh` passes `shellcheck` with zero violations
- [x] `campaign launch <id>` creates `results.md` + `learnings.md` in `launched/<id>/`
- [x] `campaign promote <id> --results` writes to `_performance/marketing/<id>.md`
- [x] `campaign promote <id> --learnings` writes to `_knowledge/insights/marketing/<YYYY-MM>/<id>-learnings.md`
- [x] `campaign feedback [<id>]` surfaces `_feedback/` insights (graceful no-op if plane absent)
- [x] `aidevops campaign` dispatches to `campaign-helper.sh`
- [x] `aidevops help` includes `campaign` in command list and detailed section

## Dependencies

- **Blocked by (architecture):** t2962 (#21250 P1), t2963 (#21251 P2) — need `_campaigns/` plane + CLI to exist at runtime. Script includes graceful error messages if prerequisites are absent.
- **Part of:** #20929 (t2870 parent-task)

## Notes

P1-P5 are still OPEN at time of dispatch. This PR ships the P6 code defensively — `campaign launch` checks for `_campaigns/active/<id>/` and returns a clear error if the plane is absent. The code is production-ready once P1-P2 land.
