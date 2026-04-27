---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2962: _campaigns/ directory contract + sub-folder structure

## Pre-flight

- [x] Memory recall: "campaigns directory contract provisioning" → no hits (new primitive)
- [x] Discovery: no in-flight PRs on campaigns P1; `t2969` (P6) merged as the only prior campaign work
- [x] File refs verified: `knowledge-plane.md`, `cases-plane.md`, `knowledge-helper.sh`, `campaign-helper.sh` (P6)
- [x] Tier: `tier:standard` — directory contract + gitignore + config template + provisioning script + CLI wiring

## Origin

- **Created:** 2026-04-27
- **Session:** Claude Code headless worker (auto-dispatched)
- **Parent task:** t2870 / GH#20929
- **Phase:** Phase 1 — _campaigns/ directory contract + sub-folder structure

## What

Establishes the `_campaigns/` directory contract as a peer-level user-data plane.
Creates `lib/brand/`, `lib/swipe/`, `intel/`, `active/`, `launched/`, `_config/` sub-folder structure.
Defines the CAMPAIGNS.md contract file, gitignore rules, config template, per-repo provisioning script,
and `aidevops campaign init/provision/status/ls` commands for directory introspection.

**Concrete deliverables:**

1. `.agents/templates/campaigns-gitignore.txt` — gitignore template (`active/`, `intel/`, `index/` ignored)
2. `.agents/templates/campaigns-config.json` — plane config template (sensitivity tiers, blob threshold, cross-plane paths)
3. `.agents/aidevops/campaigns-plane.md` — directory contract documentation (peer to `cases-plane.md`)
4. `.agents/scripts/campaigns-provision-helper.sh` — provisioning helper with `init`, `provision`, `status`, `ls` commands
5. `aidevops.sh` — dispatch P1 commands (`init/provision/status/ls/list`) to new helper; P6 commands stay in `campaign-helper.sh`

## Why

Phase 1 is the foundation that all subsequent campaign phases build on:
- Phase 2 (t2963) needs the directory structure to scaffold `active/<id>/`
- Phase 3 needs the sensitivity configuration to route `intel/` to local LLM
- Phase 6 (t2969, already shipped) needs `active/` and `launched/` directories to exist

Without the contract, users and agents can't provision the plane, and P6 silently fails on missing paths.

## How (Approach)

Follows the same pattern as `knowledge-helper.sh` (init/provision) and `cases-plane.md` (directory contract docs).

### Files Scope

- NEW: `.agents/templates/campaigns-gitignore.txt`
- NEW: `.agents/templates/campaigns-config.json`
- NEW: `.agents/aidevops/campaigns-plane.md`
- NEW: `.agents/scripts/campaigns-provision-helper.sh`
- EDIT: `aidevops.sh` (campaign dispatch + help text)

## Acceptance Criteria

- [x] `aidevops campaign init` provisions `_campaigns/` with `lib/brand/`, `lib/swipe/`, `intel/`, `active/`, `launched/`, `_config/`
- [x] `_campaigns/.gitignore` written: `active/`, `intel/`, `index/` are ignored
- [x] `_campaigns/_config/campaigns.json` written with sensitivity tiers + cross-plane paths
- [x] `_campaigns/CAMPAIGNS.md` written (user-facing contract overview)
- [x] `_campaigns/intel/README.md` written (sensitivity warning + policy)
- [x] Repo root `.gitignore` patched with `# campaigns-plane-rules` block
- [x] `aidevops campaign provision` is idempotent (safe to re-run on provisioned plane)
- [x] `aidevops campaign status` shows provisioning state + active/launched/asset counts
- [x] `aidevops campaign ls` lists active + launched campaigns
- [x] `aidevops campaign ls --active` shows only active campaigns
- [x] ShellCheck zero violations on `campaigns-provision-helper.sh`
- [x] `campaigns-plane.md` documents the full directory contract, sensitivity tiers, CLI reference, cross-plane connections

## Dependencies

- **Blocked by:** none at provisioning level — P6 (`campaign-helper.sh`) already ships but gracefully errors on missing `_campaigns/` plane
- **Blocks:** t2963 (P2 campaign CLI), Phase 3 sensitivity integration, Phase 4 asset binary integration
- **Soft dependency:** t2846 (sensitivity detector) for automatic classification; not required for provisioning

## Reference

- Pattern: `knowledge-helper.sh` (init/provision commands)
- Pattern: `cases-plane.md` (directory contract documentation style)
- Peer P6 helper: `.agents/scripts/campaign-helper.sh` (launch/promote/feedback)
