<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1453: Auto-sync deployed agents after merge/release

## Origin

- **Created:** 2026-03-12
- **Session:** OpenCode interactive request
- **Created by:** OpenCode gpt-5.3-codex
- **Parent task:** none
- **Conversation context:** After GEO/SRO SEO agent rollout and release, runtime deployment in `~/.aidevops/agents/` did not include newly merged files until a manual `rsync` was run. User requested a durable framework fix.

## What

Implement an automatic post-merge/release sync mechanism so the runtime agents directory (`~/.aidevops/agents/`) always reflects repo `.agents/` changes immediately after normal merge/release flows.

## Why

- Runtime drift causes user-visible feature gaps even when code is merged and released.
- Manual sync steps are easy to forget and are not reliable for autonomous/headless workflows.
- This is framework-level operational debt that can recur with every new agent or command.

## How (Approach)

1. Add deterministic drift detection between repo `.agents/` and `~/.aidevops/agents/` to make failures observable.
2. Wire automatic runtime sync into release/post-merge lifecycle at the canonical integration point.
3. Preserve protected runtime directories and plugin namespaces exactly as existing deployment logic does.
4. Add verification and operator-facing fallback guidance when automation cannot run.

## Acceptance Criteria

- [ ] Post-merge/release lifecycle syncs `~/.aidevops/agents/` without manual intervention.
- [ ] Drift check command reports accurate PASS/DRIFT status with actionable details.
- [ ] New files under `.agents/seo/` and `.agents/scripts/commands/` are present in runtime after release.
- [ ] Preserved runtime directories (`custom/`, `draft/`, `loop-state/`, plugin namespaces) remain untouched.
- [ ] Documentation references new behavior and fallback remediation command.

## Context & Decisions

- Reuse existing deployment behavior from `setup-modules/agent-deploy.sh` rather than introducing a second deployment implementation.
- Prefer deterministic file checks over inferred state flags.
- Keep fallback manual sync command documented for recovery, but not as the normal path.

## Relevant Files

- `setup-modules/agent-deploy.sh` — current deployment logic and exclusions
- `setup.sh` — merge/release/setup integration points
- `.agents/scripts/deploy-agents-on-merge.sh` — candidate hook for post-merge sync wiring
- `TODO.md` — task tracking entry
- `todo/PLANS.md` — detailed phased execution plan

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** GitHub issue [GH#4205](https://github.com/marcusquinn/aidevops/issues/4205)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | identify exact merge/release hook points |
| Implementation | 1h 45m | sync wiring + drift check + docs updates |
| Testing | 45m | release-path verification and regression checks |
| **Total** | **~3h** | |
