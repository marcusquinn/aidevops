<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18136: Prevent LaunchAgents from pinning stale runtime-bundle PATH entries

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `t18125 launchd runtime bundle path sanitization` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 3 recent target-file commits / 0 related merged PRs / 0 related open PRs; issue-title and body searches found no exact duplicate
- [x] File refs verified: 8 source/test refs checked, all present at `3428e0535`
- [x] Tier: `tier:standard` — four coordinated shell/test surfaces and setup/deployment recovery disqualify `tier:simple`, while the implementation pattern is established
- [x] Seeded draft PR decision recorded: skipped — implement the reproduced fix directly with focused regression tests

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive t18125 deployment verification
- **Created by:** AI DevOps (ai-interactive) under maintainer-authorised full-loop execution
- **Parent task:** None; leaf reliability defect discovered while completing t18125
- **Blocked by:** None
- **Conversation context:** Deploying the merged exact-telemetry patch activated framework `3.32.123`, but setup generated the Pulse LaunchAgent with an inherited `3.32.112` runtime-bundle scripts directory at the front of `PATH`. The directory still existed, so the current sanitiser retained it and the daemon continued resolving stale helpers until the plist was corrected and reloaded manually.

## What

Make launchd PATH generation reject immutable aidevops runtime-bundle entries even when those directories still exist, while adding the stable user-level aidevops tool roots before system defaults. Mirror the contract in the scheduler module's standalone fallback, cover both the shared helper and generated Pulse plist, then regenerate the live scheduler through setup.

## Why

`aidevops_launchd_sanitized_path` currently filters only missing directories. A long-lived interactive session intentionally retains a valid immutable bundle, so any setup run from that session serialises the old physical path into new LaunchAgent plists. Restarting Pulse then selects stale scripts despite successful atomic activation, undermining deployment convergence and invalidating telemetry canaries that assume the merged recorder is live.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The desired stable-path contract is clear, but production and standalone fallback implementations plus two shell harnesses must remain aligned across mixed-version and deployment states.

## PR Conventions

Leaf task: title the implementation PR `t18136: ...` and use the standard closing keyword for this issue.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The issue is being implemented immediately in its dedicated linked worktree; a separate unverified seed would add no value.
- **Status:** `not-created`
- **Freshness evidence:** Source, fallback, Pulse plist generator, focused tests, current `PATH`, deployed plist, and current `origin/main` were checked in this session.
- **Verification run:** Live reproduction and manual stable-path recovery verified; source regression tests are unrun at brief creation.
- **Stale-assumption warning:** Re-check the shared sanitiser and scheduler fallback if either changes before implementation.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/shared-constants.sh:339-378` — reject managed runtime-bundle entries and prepend existing stable user-level aidevops roots.
- `EDIT: .agents/scripts/setup/modules/schedulers.sh:34-58` — keep the direct-test/standalone fallback behavior identical.
- `EDIT: .agents/scripts/tests/test-launchd-sanitized-path.sh:73-99` — prove an existing stale bundle is excluded and stable roots are retained.
- `EDIT: .agents/scripts/tests/test-pulse-defense-restart.sh:63-114,116-170` — prove the generated Pulse plist cannot serialise an inherited runtime-bundle path.

### Complete Write Surface

- **Callers/readers:** `aidevops_launchd_sanitized_path` is consumed by auto-update, repository sync/health, routine, memory-pressure, watchdog, DB-maintenance, and setup scheduler plist generators; all should receive the same exclusion contract.
- **Writers/mutation paths:** `.agents/scripts/setup/modules/schedulers-pulse.sh:_generate_pulse_plist_content` and sibling generators serialise the helper result into LaunchAgent `EnvironmentVariables.PATH`; setup's `_launchd_install_if_changed` atomically replaces changed plists.
- **Tests/fixtures:** `.agents/scripts/tests/test-launchd-sanitized-path.sh` owns shared helper behavior; `.agents/scripts/tests/test-pulse-defense-restart.sh` owns Pulse/watchdog plist generation.
- **Schemas/config:** No persistent schema changes. PATH ordering gains stable `$HOME/.local/bin`, `$HOME/.aidevops/agents/scripts`, and `$HOME/.aidevops/bin` when those directories exist.
- **Generated/deployed mirrors:** Repository scripts deploy through `setup.sh`; the live `~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist` must be regenerated and reloaded after merge.
- **Migrations/backfills:** `setup.sh` regenerates existing plists when content changes; no historical data migration is required.
- **Cleanup/rollback paths:** `git revert` plus `setup.sh` restores prior generation. Do not delete runtime bundles: active interactive sessions may legitimately lease them.

### Implementation Steps

1. Extend shared path hygiene so managed immutable bundle entries are rejected before existence/dedup checks, while existing stable user roots are considered before system defaults:

```bash
case "$dir" in
*/.aidevops/runtime-bundles/*) return 0 ;;
esac

local default_path="${HOME:-}/.local/bin:${HOME:-}/.aidevops/agents/scripts:${HOME:-}/.aidevops/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
```

2. Apply the same ordering and runtime-bundle exclusion to the fallback function in `schedulers.sh`; direct tests source this module without the shared helper.
3. Expand `test_sanitized_path_filters_missing_entries` with a physically existing `.../.aidevops/runtime-bundles/old/agents/scripts` entry plus stable roots. Assert stable roots are present once and the old bundle is absent.
4. Add a Pulse plist fixture whose subshell `HOME` contains stable directories and whose inherited `PATH` begins with an existing old runtime bundle. Assert the rendered XML contains the stable scripts path and excludes `/runtime-bundles/`.
5. Run setup after merge and verify both plist text and `launchctl print gui/<uid>/com.aidevops.aidevops-supervisor-pulse` show stable roots with no runtime-bundle component.

### Hazards and Compatibility

- **Concurrency/atomicity:** Do not prune or mutate runtime bundles; only omit their paths from newly generated plist content. Existing atomic plist replacement remains unchanged.
- **Migration/rollback:** Setup detects changed content and reloads launchd. If reload fails, `_launchd_install_if_changed` must preserve its existing recovery behavior.
- **Mixed-version/backward compatibility:** Interactive processes remain pinned to their startup bundle as designed. Newly launched daemons use the stable symlink so atomic activation updates future child resolution.
- **Idempotency/retry:** Repeated sanitisation/setup runs produce the same ordered deduplicated PATH. All unrelated existing inherited directories remain preserved.
- **Partial failure/recovery:** If user-level stable roots do not exist, the helper still emits existing system/tool roots. A setup failure must not delete runtime bundles or the prior valid plist.

### Complexity Impact

- **Target functions:** `_aidevops_append_launchd_path_dir`, `aidevops_launchd_sanitized_path`, and the scheduler fallback.
- **Current line count:** Each target function is below 30 lines.
- **Estimated growth:** Under 30 production lines plus focused fixtures.
- **Projected post-change:** Functions remain below complexity thresholds with one high-precision path guard.
- **Action required:** Keep the shared and fallback contracts textually aligned; do not add Pulse-only path rewriting.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-launchd-sanitized-path.sh
bash .agents/scripts/tests/test-pulse-defense-restart.sh
shellcheck .agents/scripts/shared-constants.sh .agents/scripts/setup/modules/schedulers.sh .agents/scripts/tests/test-launchd-sanitized-path.sh .agents/scripts/tests/test-pulse-defense-restart.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The first suite proves global sanitisation and auto-update plist behavior; the second proves actual Pulse/watchdog generation; ShellCheck protects Bash 3.2/explicit-return rules; changed lint covers repository gates.
- **Broad verification trigger:** Run setup and inspect live launchd state because the defect occurred only after deployment from a pinned session.

### Recoverability Checkpoint

- [ ] Focused tests pass before broad setup/deployment checks.
- [ ] Create WIP commit `wip: stabilize launchd runtime paths` after focused tests.
- [ ] Run changed lint, PR CI, merge, setup, and live LaunchAgent verification from the exact merged SHA.

### Files Scope

- `.agents/scripts/shared-constants.sh`
- `.agents/scripts/setup/modules/schedulers.sh`
- `.agents/scripts/tests/test-launchd-sanitized-path.sh`
- `.agents/scripts/tests/test-pulse-defense-restart.sh`

## Acceptance Criteria

- [ ] An existing inherited `~/.aidevops/runtime-bundles/*/agents/scripts` directory is absent from sanitised PATH output and generated Pulse plist XML.
- [ ] Existing stable user roots are ordered before system defaults, deduplicated, and missing roots remain omitted.
- [ ] Non-aidevops existing inherited directories remain preserved and missing directories remain filtered.
- [ ] Focused tests, ShellCheck, changed-file lint, and required PR checks pass.
- [ ] Post-merge setup reloads Pulse with stable `~/.aidevops/agents/scripts` and no runtime-bundle entry in live launchd state.

## Context & Decisions

- Filter managed immutable bundle paths globally rather than special-casing Pulse; every long-lived LaunchAgent has the same stale-pin risk.
- Preserve runtime bundles themselves because live interactive sessions lease and require them.
- Replace stale physical paths with stable user-level roots, not merely deletion, so daemon child commands remain resolvable.

## Relevant Files

- `.agents/scripts/shared-constants.sh:339-378` — canonical launchd PATH hygiene.
- `.agents/scripts/setup/modules/schedulers.sh:34-58` — fallback used by direct scheduler tests.
- `.agents/scripts/setup/modules/schedulers-pulse.sh:734-748,887-897` — Pulse and watchdog PATH serialisation.
- `.agents/scripts/tests/test-launchd-sanitized-path.sh:73-130` — shared helper and auto-update coverage.
- `.agents/scripts/tests/test-pulse-defense-restart.sh:63-114` — Pulse/watchdog renderer fixtures.

## Dependencies

- **Blocked by:** None.
- **Blocks:** Starting the trustworthy t18125 telemetry observation window.
- **External:** macOS launchd is required only for post-merge deployment verification; focused fixtures are hermetic.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 30m | Shared/fallback path contract |
| Focused tests | 30m | Helper and Pulse plist fixtures |
| Review/deploy | 30m | CI, merge, setup, live launchd check |
| **Total** | **1.5h** | |
