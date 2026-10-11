<!-- aidevops:brief-schema=v2 -->

# t18664: stop Pulse-run auto-updates rolling back every verified release

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `auto-update deployment incomplete runtime bundle rollback agents_stale` → 0 hits — no relevant lessons
- [x] Discovery pass: no open PRs touch `.agents/scripts/auto-update-helper.sh`; no open or closed issue reports the rollback. The bundle check was added in 48a522d013 (2026-07-11); last helper change 41d9b663f2 (t18626)
- [x] File refs verified at origin/main f8bb961c48: `_auto_update_runtime_bundle_root`, `_auto_update_runtime_bundle_valid`, `_cmd_check_perform_update` (`.agents/scripts/auto-update-helper.sh`); `pin_aidevops_active_runtime_bundle_root` (`.agents/scripts/setup/modules/agent-runtime.sh`); Pulse pin export (`.agents/scripts/pulse-wrapper.sh`)
- [x] Tier: `tier:standard` — one-function fix in update verification; setup, activation and rollback mechanics unchanged
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Found while verifying that a released Pulse fix was running: v3.39.8, v3.39.9 and v3.39.10 each deployed, passed setup, then were rolled back by the automatic updater one second after `SETUP_COMPLETE`.

## What

Post-update verification checks the bundle behind the global activation link (`~/.aidevops/agents`), whichever process runs the update. `_auto_update_runtime_bundle_root` stops resolving the caller's inherited `AIDEVOPS_AGENTS_DIR` pin, so a Pulse-run update (routine r902) verifies the bundle it just activated instead of the Pulse's own older bundle.

## Why

- `pulse-wrapper.sh` exports `AIDEVOPS_AGENTS_DIR` pinned to its own physical bundle (`pwd -P`). Routine r902 runs `aidevops auto-update check` as a Pulse child, so the pin is inherited; `aidevops.sh` keeps an inherited value.
- `_cmd_check_perform_update` runs setup (which re-binds to the activation link via `pin_aidevops_active_runtime_bundle_root`, and activates the new bundle correctly), then verifies with `_auto_update_runtime_bundle_root`, which resolves the stale pin. The old bundle's `VERSION` never matches the new version, so every Pulse-run update logs `Update pulled vX but agents at vX — deployment incomplete` and rolls back to the bundle it just replaced. The launchd-scheduled path has a clean environment and succeeds, which is why some updates stick.
- Runner evidence (`~/.aidevops/logs/auto-update.log`): 84 same-version `deployment incomplete` rollbacks since 2026-07-23 against 30 `Update complete` lines since July; today v3.39.8, v3.39.9 and v3.39.10 all rolled back. Recovery only comes 3–7 minutes later from `_cmd_check_stale_agent_redeploy` (`Deployed agents stale ... re-deploying`).
- Cost per release on every runner: two extra full setup runs, two extra Pulse restarts that discard the in-flight dispatch cycle, and minutes of running the previous release. A manual `aidevops update` started in that window reports "already up to date" because it compares the version before the rollback lands.
- Local reproduction with the real functions in a sandbox HOME (activation link → new bundle): clean env → verification valid; Pulse-style pin → resolves the old bundle → `INVALID(rollback)`; CLI symlink pin → valid.

## How

### Files to Modify

- `EDIT: .agents/scripts/auto-update-helper.sh` — `_auto_update_runtime_bundle_root` resolves `${HOME}/.aidevops/agents` (the activation link) with `pwd -P`, ignoring an inherited `AIDEVOPS_AGENTS_DIR`; comment cites the Pulse pin and the matching rule in `pin_aidevops_active_runtime_bundle_root`.

### Complete Write Surface

- **Callers/readers:** `_auto_update_runtime_bundle_root` is called twice, both in `_cmd_check_perform_update`: `prior_bundle_root` (rollback target, now the bundle active before the update instead of the caller's pin) and `active_bundle_root` (verification). Sibling reads in the same flow already use `$HOME/.aidevops/...` (`deployed_version`, `_auto_update_rollback_runtime_bundle` previous link and bundles root).
- **Writers/mutation paths:** no new writes. Setup, activation, Pulse reconciliation and `runtime-bundle-rollback-helper.sh` are unchanged; a genuinely invalid or missing bundle still rolls back.
- **Existing verification/tests:** no test calls these functions (`rg '_auto_update_runtime_bundle' .agents/scripts/tests` is empty); `test-linux-lifecycle-smoke.sh` sets `AIDEVOPS_AGENTS_DIR` equal to `$HOME/.aidevops/agents`, so it is unaffected.
- **Schemas/config:** N/A because no schema or config changes.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` into the runtime bundle.
- **Migrations/backfills:** N/A because the change only affects future update runs.
- **Cleanup/rollback paths:** revert the PR to restore pin-based resolution.

### Hazards and Compatibility

- **Mixed-version:** the fix runs from the updater's own (old) bundle, so the first update to the release containing it may still roll back on a Pulse-run updater and self-heal through the stale-agent redeploy; updates after that verify correctly.
- **Custom agents directories:** the auto-updater already assumes the default layout (`INSTALL_DIR`, `deployed_version`, rollback links), so ignoring a custom `AIDEVOPS_AGENTS_DIR` here removes an inconsistency rather than a feature.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/auto-update-helper.sh
bash .agents/scripts/tests/test-auto-update-health-check.sh
bash .agents/scripts/tests/test-cmd-update-sha-drift.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the sandbox reproduction (real functions, Pulse-style pin) must report `valid` for all three environments after the change; the existing auto-update suites cover the helper's other subcommands; ShellCheck and the changed-file linters cover the edit.
- **Runtime:** after this release is deployed, the next Pulse-run update logs `Update complete: vX -> vY (agents deployed)` with no `deployment incomplete` or `Rolled back runtime activation` line.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/auto-update-helper.sh`
- `TODO.md`
- `todo/tasks/t18664-brief.md`

## Acceptance Criteria

- [ ] With `AIDEVOPS_AGENTS_DIR` pinned to an older bundle and the activation link on the new bundle, post-update verification checks the new bundle and passes.
- [ ] A missing, unvalidated or version-mismatched active bundle still fails verification and rolls back.
- [ ] ShellCheck, the existing auto-update suites and `linters-local.sh --changed` pass.

## Context & Decisions

- Fix the verifier instead of unsetting the pin in the r902 wrapper: any caller with an inherited pin (Pulse routines, workers, interactive sessions) hits the same false negative, and setup already applies the activation-link rule for global reconciliation.
- Not in scope: rollback-helper behaviour, the stale-agent redeploy debounce, or setup's own pin handling.
