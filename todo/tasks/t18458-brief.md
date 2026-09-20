<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18458: Integrate decision agents, commands and disabled routine templates

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: current primary-agent routing and build-agent guidance reviewed; new leaf code belongs to predecessor tasks.
- [x] File refs verified: seo.md, marketing-sales.md, content.md, domain-index, subagent generator and routines guidance exist.
- [x] Tier: standard; wire known delivered leaves without modifying dispatch implementation or model defaults.
- [x] Seeded draft PR skipped: final integration must use actual predecessor exports.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18457. All other children are transitive prerequisites; recheck merged contracts before editing.

## What

Make the delivered workflows discoverable from existing SEO/Marketing-Sales/Content agents, expose small domain commands, provide disabled budgeted routine templates, and prove one offline end-to-end path from imported evidence to report/action proposal.

## Why

Prevent a pile of unconnected helper files and avoid loading every domain prompt on every row. Scheduling and live activation remain explicit operator choices.

## Tier

Selected tier: `tier:standard`; integration/documentation uses known patterns, not a prescriptive simple-tier transform. Do not modify dispatch-path code; if genuinely required, return a scoped follow-up rather than hiding a risk override.

## How

### Files to Modify

- `EDIT: .agents/seo.md` — pointers and ownership for matching/disposition/visibility.
- `EDIT: .agents/marketing-sales.md` — Google/creative/community and shared reporting pointers.
- `EDIT: .agents/content.md` — evidence-backed content handoff, no duplicate strategy.
- `EDIT: .agents/reference/domain-index.md` — narrow intent routes.
- `EDIT: .agents/workflows/marketing-decisions.md` — final workflow, capability matrix and operating costs.
- `NEW: .agents/scripts/commands/marketing-decisions.md` — combined entry point.
- `NEW: .agents/templates/marketing-decision-routines.md` — disabled opt-in examples.
- `NEW: .agents/scripts/tests/test-marketing-decision-integration.py` — focused offline chain test.

Reference `.agents/tools/build-agent/build-agent.md`, `.agents/reference/routines.md`, `.agents/scripts/subagent-index-helper.sh` and `.agents/scripts/lib/subagent_validation.py`. Reuse their current documented invocation rather than inventing flags.

### Files Scope

- `.agents/seo.md`
- `.agents/marketing-sales.md`
- `.agents/content.md`
- `.agents/reference/domain-index.md`
- `.agents/workflows/marketing-decisions.md`
- `.agents/scripts/commands/marketing-decisions.md`
- `.agents/templates/marketing-decision-routines.md`
- `.agents/subagent-index.toon`
- `.agents/scripts/tests/test-marketing-decision-integration.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/integration-input.json`

### Complete Write Surface

- **Callers/readers:** three existing domain coordinators and `.agents/scripts/commands/marketing-decisions.md` route to delivered leaves.
- **Writers/mutation paths:** source pointers/templates plus generated `.agents/subagent-index.toon`; no runtime schedules or account state.
- **Tests/fixtures:** `.agents/scripts/tests/test-marketing-decision-integration.py` and integration-input.json, reusing predecessor fixtures.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json`; no model-routing/provider-default or always-loaded AGENTS.md changes.
- **Generated/deployed mirrors:** regenerate `.agents/subagent-index.toon` from this worktree with AIDEVOPS_AGENTS_DIR; use existing validators, never edit deployed copies.
- **Migrations/backfills:** N/A because existing routes remain and new entries are additive, with no automatic routine activation.
- **Cleanup/rollback paths:** revert added pointers/commands/templates and regenerate `.agents/subagent-index.toon`; existing tools remain available.

### Implementation Steps

1. Register the actual delivered leaves and shared workflow under existing primary agents. Keep knowledge progressive/on-demand; distinguish agent guidance, executable helper, configured provider and verified live readiness.
2. Document command examples for imports, triage, matching, links/disposition, creative/community, visibility, reporting, optional connectors/Jev and guarded actions. Verify every command against current CLI help; do not promise an unimplemented mode.
3. Supply disabled routine examples with account/site scope, owner, maximum requests/tokens/cost/time, freshness/change detection, action mode and stop conditions. Prefer code collection then one bounded agent review per batch; never one worker per row. Do not edit TODO routines or install launchd/cron jobs.
4. Explain default use of the existing approved model route, optional Jev privacy/readiness checks, per-job calibration, cache invalidation, business-value cadence and unknown ROI. First-party conversion gaps normally precede broad citation polling; operator context can change priority.
5. Run an offline imported-account/page/answer fixture through delivered workflows into a report and dry-run action plan. Assert all 33 article jobs plus paid-to-organic bridge have an owner/path or explicit unsupported collection coverage. Record remaining live activation prerequisites without asking workers for client secrets.

### Hazards and Compatibility

- **Concurrency/atomicity:** this final task exclusively owns shared routing files after predecessors merge; regenerate source index once from the same snapshot.
- **Migration/rollback:** additive routes/templates only; revert pointers and regenerate without removing legacy entry points.
- **Mixed-version/backward compatibility:** verify actual exports/help; stale or unavailable routes must fail visibly instead of silently switching provider.
- **Idempotency/retry:** generator and offline example should replay without duplicate agents, routine installation or account actions.
- **Partial failure/recovery:** missing predecessor behavior remains an open defect with exact evidence; no fabricated end-to-end success or automatic live setup.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test-marketing-decision-integration.py
AIDEVOPS_AGENTS_DIR="$PWD/.agents" .agents/scripts/subagent-index-helper.sh generate
python3 .agents/scripts/lib/subagent_validation.py --help
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** integration test executes real offline CLI paths, schema joins and no-side-effect guarantees; run applicable existing subagent validation after checking its help; generator proves index source; lint checks changed docs/code. No full repository gate by default.
- **Recoverability:** checkpoint functional evidence before further gates; preserve failures and resume from the exact merged dependency snapshot. Do not release/deploy, install schedules or claim live ROI to finish.

## Acceptance Criteria

- [ ] Existing coordinators/command discover every delivered workflow through concise pointers and the generated index.
- [ ] Offline end-to-end chain produces validated report/action proposals and preserves unsupported/missing provider coverage and unknown economics.
- [ ] Routine examples remain disabled and no live provider activation, scheduler installation, remote publication or account mutation occurs.
