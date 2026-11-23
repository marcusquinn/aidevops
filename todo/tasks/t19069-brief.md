<!-- aidevops:brief-schema=v2 -->

# fix(setup): a service PATH generator change regenerates installed scheduler plists

## Pre-flight

- [x] Memory recall: `launchd plist PATH regenerate setup.sh non-interactive drift` → 0 hits
- [x] Discovery pass: last plist drift change is t19030 (`9a0c1dffea`); 0 open PRs or claimed issues touch the target files

## What

A change to the launchd service PATH generator (`aidevops_service_path` in `.agents/scripts/runtime-env.sh`) or the plist environment-override library (`.agents/scripts/plist-env-overrides-lib.sh`) regenerates the installed scheduler plists on the next update, the same way a scheduler template change already does.

## Why

t19066 (PR #38644, released in v3.39.213) moved the aidevops `gh`/`git` shim directories ahead of the npm global bin in `aidevops_service_path`. The deployed runtime contains the fix, but at 2026-11-16 11:42Z, an hour after the release deployed, every installed plist still had the old PATH. `com.aidevops.aidevops-supervisor-pulse.plist` and `sh.aidevops.pulse-watchdog.plist` both began `/opt/homebrew/bin:...`, and their mtimes (05:43 and 05:50) were earlier than the release. The plist content is generated from `runtime-env.sh`, but neither regeneration path watches that file:

- `scheduler_template_hash` (`.agents/scripts/setup/modules/schedulers-template-hash.sh:52`) hashes only `setup/modules/schedulers*.sh` and `setup/_scheduler_runtime.sh`, so `check_launchd_plist_drift` (`.agents/scripts/auto-update-freshness-lib.sh:214`) sees no drift.
- `_setup_ai_session_plan_file` (`setup.sh:1319`) maps only those scheduler files to `_SETUP_AI_SESSION_NEEDS_SCHEDULERS`, so the incremental update stage never reruns the scheduler pass for a `runtime-env.sh` change.

As a result, a PATH fix takes effect only when an unrelated scheduler template happens to change. Until then, the native `/opt/homebrew/bin/gh` shadows the shim for every launchd daemon. Before t19066, a 3-minute probe saw 149 of 266 `gh` processes bypass the shim, losing call accounting, budget routing and write guards.

**Scope update (rebase, 2026-11-16):** GH#37888 (`6b46b0490c`) landed on `main` first and added `runtime-env.sh` to both the hash and the incremental planner. This task now adds the remaining generator library, `plist-env-overrides-lib.sh`, which `schedulers-pulse.sh` sources to render the plist env-override XML.

## How

1. `.agents/scripts/setup/modules/schedulers-template-hash.sh`, function `scheduler_template_hash`: in the existing loop, also hash `<scripts dir>/runtime-env.sh` and `<scripts dir>/plist-env-overrides-lib.sh`, where `<scripts dir>` is the parent of the setup dir (`${setup_dir%/*}`). Keep the `[[ -f "$file" ]] || continue` guard so fixtures without these files keep their current hash. Both sides of the drift contract call this function (`schedulers.sh:81` records the hash; `check_launchd_plist_drift` compares against it), so they stay in agreement. Update the header comment that lists the hashed files.
2. `setup.sh`, function `_setup_ai_session_plan_file`: add `.agents/scripts/runtime-env.sh | .agents/scripts/plist-env-overrides-lib.sh` to the existing `schedulers*.sh | _scheduler_runtime.sh` case so the incremental stage sets `_SETUP_AI_SESSION_NEEDS_SCHEDULERS=1`. That stage then reruns `_setup_noninteractive_schedulers` and records the new hash.

## Acceptance

- Changing only `runtime-env.sh` changes the value `scheduler_template_hash` returns for a real checkout.
- `bash .agents/scripts/tests/test-worker-reliability-self-heal.sh` still passes (its fixture has neither file, so its hash is unchanged).
- The incremental planner selects the scheduler refresh for `.agents/scripts/runtime-env.sh`.
- After deployment, the installed pulse plist PATH begins `~/.aidevops/agents/scripts:~/.aidevops/bin` without a manual `setup.sh --non-interactive`.

## Files Scope

- `.agents/scripts/setup/modules/schedulers-template-hash.sh`
- `setup.sh`

## Verification

`shellcheck .agents/scripts/setup/modules/schedulers-template-hash.sh setup.sh`; `bash .agents/scripts/tests/test-worker-reliability-self-heal.sh`; source the hash library and compare `scheduler_template_hash .agents/scripts/setup/modules` before and after a one-byte change to a scratch copy of `runtime-env.sh` in a temporary tree.
