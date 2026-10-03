<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18502: OpenCode V2 promotion gates — weekly V2 canary, plugin/tool probe, documented gate checks, requalified pin

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `opencode 2 v2 compatibility sidebar lsp todo` → 0 hits — no relevant lessons
- [x] Discovery pass: no open PR touches `opencode-pin-canary.sh` or `opencode-pin-canary.yml`; related open V2 issues are #32619, #32645 and #32647
- [x] File refs verified: 4 refs checked, all present at `5a2a4dc46`
- [x] Tier: `tier:standard` — the canary pattern exists and the boundaries are known; the probe marker choice is local
- [x] Seeded draft PR decision recorded: skipped — marker and tool-capture details need live verification

## Origin

- **Created:** 2026-09-28
- **Session:** opencode:ses_f1ae20a63ffeFJycVVOT3WXoWq
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** A parity review found that the V2 "promotion gates" are written as prose but not tested. The weekly canary tests only V1, and the probe cannot detect missing plugins or removed tools, such as the `todowrite` removal in V2.

## What

1. The weekly `OpenCode Pin Canary` workflow runs for both the `v1` and `v2` profiles. Each profile gets its own review issue title, so one result never deduplicates the other.
2. The isolated probe fails unless the aidevops plugin actually loaded. It also records the tool names offered to the mock provider and fails if any expected aidevops tool is missing. Changes in native tools (for example `todowrite` disappearing) are reported against the pinned baseline, so capability loss becomes visible.
3. `.agents/tools/opencode/opencode.md` "Runtime profiles" maps each of the six promotion gates (plugin, security hooks, lifecycle cleanup, OAuth/MCP, headless, V1 rollback) to an automated check or an explicit manual verification command.
4. The V2 profile is requalified against the current `@opencode/cli` release, or the reason it stays at 2.0.3 is recorded. The profile's `testedVersion`, `headlessPin`, `lastCanaryDate`, `lastCanaryResult` and `reviewDeadline` are updated together.

## Why

Evidence gathered 2026-09-28:

- `.github/workflows/opencode-pin-canary.yml` never sets `AIDEVOPS_OPENCODE_PROFILE`. `opencode-pin-canary.sh:13` therefore resolves the default profile (`v1`, `.agents/configs/opencode-runtime-profiles.json:3`), and V2 is never canaried on schedule. Its `lastCanaryResult` of `pass:2.0.3` dates from 2026-09-15, and its `reviewDeadline` of 2026-09-22 has passed.
- `run_isolated_probe` (`opencode-pin-canary.sh:230-312`) passes when the mock provider answers "Four" and receives a request (`:298`). It never checks that the plugin loaded or that tools were registered.
- The mock provider logs only request paths (`opencode-pin-canary.sh:179-180`), so tool changes are invisible.
- The six gates in `opencode.md:85-87` have no corresponding checks.
- npm latest is `@opencode/cli` 2.0.18, while the pin is 2.0.3. The upstream migration guide (`migrate-v1.mdx`, `v2` branch) now says `instructions` needs no migration and that the V2 curl installer replaces V1. Both points may make parts of `opencode.md:74-80` outdated.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Skeletons only.
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** The plugin-loaded marker and expected tool list are chosen by the worker.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** It extends an existing canary with known files. The remaining choices (marker, tool list) are local and verifiable.

## PR Conventions

Leaf issue: the PR uses a closing keyword for this issue.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/opencode-pin-canary.yml:16-84` — add `strategy.matrix.profile: [v1, v2]`, export `AIDEVOPS_OPENCODE_PROFILE`, give each profile its own artifact name, and include the profile in both review issue titles.
- `EDIT: .agents/scripts/opencode-pin-canary.sh:142-227` — make the mock provider also append the request's `tools[].name` or `tools[].function.name` (one JSON line per request) to a sibling file.
- `EDIT: .agents/scripts/opencode-pin-canary.sh:230-312` — after the probe, fail when the plugin-loaded marker is absent or when any expected aidevops tool (at least `aidevops_pre_edit_check`, `aidevops_memory`) is missing. Print the native tool diff between baseline and candidate.
- `EDIT: .agents/scripts/tests/test-opencode-pin-policy.sh` — assert that the workflow runs both profiles and that the probe enforces plugin/tool checks.
- `EDIT: .agents/tools/opencode/opencode.md:85-87` — gate-to-check table; refresh the `instructions` and side-by-side statements after verifying them against the requalified version.
- `EDIT: .agents/configs/opencode-runtime-profiles.json:26-47` — requalified V2 fields, only after a passing canary run.

### Complete Write Surface

- **Callers/readers:** the `opencode-pin-canary.yml` schedule and `workflow_dispatch`; `opencode-pin-canary.sh status|canary`; `aidevops-update-check.sh` and `headless-runtime-lib.sh`, which read the profile JSON.
- **Writers/mutation paths:** the workflow's `record-review` job creates issues; the profile JSON is edited by hand in this PR.
- **Existing verification/tests:** `.agents/scripts/tests/test-opencode-pin-policy.sh`, `.agents/scripts/tests/test-opencode-runtime-profile.sh`, `.agents/scripts/tests/test-opencode-v2-setup.sh`.
- **Schemas/config:** `.agents/configs/opencode-runtime-profiles.json` (schema `aidevops-opencode-runtime-profiles/v1`, unchanged shape).
- **Generated/deployed mirrors:** `setup.sh` deploys scripts and configs to `~/.aidevops/agents/`, and the V2 runtime reinstalls at the new pin on `aidevops update`.
- **Migrations/backfills:** N/A because the profile field values are updated in place with no migration.
- **Cleanup/rollback paths:** revert the PR, which restores the V2 pin at 2.0.3 and the single-profile canary; the `cleanup_canary` trap in `opencode-pin-canary.sh:33` still removes temp roots.

### Implementation Steps

1. Choose a deterministic plugin-loaded marker for each profile. For example, use a line the plugin already logs under `AIDEVOPS_PLUGIN_DEBUG=1` (`index.mjs:240-245`, `v2.mjs:219-225,272`), or add one explicit startup debug line. Verify locally with the isolated probe command before relying on it.
2. Extend the mock provider to record tool names, then add the plugin/tool assertions and the baseline-vs-candidate native tool diff to the probe output.
3. Add the workflow matrix and profile-specific titles and artifacts.
4. Run `gh workflow run opencode-pin-canary.yml -f candidate=latest` for both profiles, or the matrix. Update the V2 profile fields only on `RESULT=pass`, and record the tool diff (expect `todowrite` absent in V2).
5. Write the gate-to-check table in `opencode.md` and correct any outdated upstream statements.

### Hazards and Compatibility

- **Concurrency/atomicity:** Matrix jobs use separate runners and temp roots; the review-issue dedupe must include the profile so parallel jobs do not collide.
- **Migration/rollback:** Pin advances only after a passing canary; a revert restores 2.0.3.
- **Mixed-version/backward compatibility:** V1 probe behaviour stays equivalent apart from the stricter plugin/tool assertions. If V1 lacks a marker today, add one without changing plugin behaviour.
- **Idempotency/retry:** Workflow reruns reuse the existing open-issue dedupe, now keyed per profile.
- **Partial failure/recovery:** An inconclusive result for one profile must not block the other profile's review issue.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-opencode-pin-policy.sh
bash .agents/scripts/tests/test-opencode-runtime-profile.sh
AIDEVOPS_OPENCODE_PROFILE=v2 .agents/scripts/opencode-pin-canary.sh status
gh workflow run opencode-pin-canary.yml -f candidate=latest
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The policy test proves the workflow and probe contract; the profile test proves the JSON stays valid; the workflow run proves live V1 and V2 results; lint covers shell and YAML.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** Do not change the profile `default` from `v1`; promotion is a separate decision once the gates pass.

**AI brief owner:** marcusquinn interactive session.

**Recovery:** Preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.github/workflows/opencode-pin-canary.yml`
- `.agents/scripts/opencode-pin-canary.sh`
- `.agents/scripts/tests/test-opencode-pin-policy.sh`
- `.agents/tools/opencode/opencode.md`
- `.agents/configs/opencode-runtime-profiles.json`

## Acceptance Criteria

- [ ] The scheduled canary runs both `v1` and `v2` profiles, with profile-specific review issue titles.

  ```yaml
  verify:
    method: codebase
    pattern: "AIDEVOPS_OPENCODE_PROFILE"
    path: ".github/workflows/opencode-pin-canary.yml"
  ```

- [ ] The probe fails when the plugin marker or an expected aidevops tool is absent, and prints the native tool diff.
- [ ] `opencode.md` maps all six promotion gates to a check or a manual command.
- [ ] The V2 profile records a fresh canary result for the current release, or documents why the pin stays at 2.0.3.
- [ ] Regression guarantee: the profile `default` remains `v1`, and `test-opencode-pin-policy.sh` passes.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-opencode-pin-policy.sh"
  ```

## Context & Decisions

- Follow upstream direction: missing `todowrite`/LSP are expected V2 changes (see #32645 decision and #32694), so the tool diff is informational. Only aidevops-owned tools are hard failures.
- Non-goal: promoting V2 to default.

## Relevant Files

- `.agents/scripts/opencode-pin-canary.sh:13-26,142-227,230-312,344-425`
- `.github/workflows/opencode-pin-canary.yml`
- `.agents/configs/opencode-runtime-profiles.json`
- `.agents/tools/opencode/opencode.md:35-108`

## Dependencies

- **Blocked by:** none
- **Blocks:** any future V2 default promotion
- **External:** GitHub Actions ubuntu runners (Linux-only canary)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | canary script and plugin debug markers |
| Implementation | 2h | matrix, mock tool capture, assertions, docs |
| Verification | 1h | policy tests and live workflow runs |
| **Total** | **3.5h** | |
