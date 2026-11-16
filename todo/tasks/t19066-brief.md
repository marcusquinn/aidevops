<!-- aidevops:brief-schema=v2 -->

# fix(runtime): service PATH must keep aidevops gh/git shims ahead of npm global bin

## Pre-flight

- [x] Memory recall: `service PATH gh shim bypass launchd npm global bin` → 0 hits
- [x] Discovery pass: last change to `runtime-env.sh` is GH#38526 / PR #38549 (the regression source); 0 open PRs touch it

## What

Service PATH (launchd `EnvironmentVariables.PATH`, systemd `Environment=`, cron) must keep the aidevops shim directories (`~/.aidevops/agents/scripts`, `~/.aidevops/bin`) ahead of the npm global bin. Since GH#38526 / PR #38549 the npm global bin leads the service PATH. On Homebrew-node hosts `npm prefix -g` is `/opt/homebrew`, so `/opt/homebrew/bin/gh` and `/opt/homebrew/bin/git` shadow the aidevops `gh` shim and the canonical-git guard for every launchd daemon and its children.

## Why

Evidence (2026-11-16, after the plist regeneration at 05:50):

- `plutil -extract EnvironmentVariables.PATH raw ~/Library/LaunchAgents/sh.aidevops.pulse-watchdog.plist` starts `/opt/homebrew/bin:~/.bun/bin:~/.local/bin:~/.aidevops/agents/scripts:~/.aidevops/bin`.
- Pulse re-execs into a runtime bundle (`pulse-runtime-pin.sh:290`), so the `export PATH="${SCRIPT_DIR}:${PATH}"` re-prioritisation at `pulse-wrapper.sh:308` prepends a bundle dir, which every later `runtime-env.sh` source (`runtime-env.sh:293` → `aidevops_compose_path`, line 46) strips. The inherited service order then wins: a live pulse child (`_dlw_observer`) has `PATH=/opt/homebrew/bin:...` with no shim dir ahead of it.
- A 3-minute process probe of native `gh` processes: 149 of 266 had bare argv0 `gh` (PATH lookup straight to native) rather than the canonical Cellar path the shim always uses. Parents: `pulse-wrapper.sh`, `stats-wrapper.sh`, bundled `terminal-blocker-recovery-helper.sh`, `review-bot-gate-helper.sh`, `timeout 15 gh ...`.
- Impact: those calls skip `gh-api-calls.log` instrumentation, REST/GraphQL budget routing, the transport governor and write guards, and daemon `git` calls skip the canonical-git guard. Unaccounted REST-core usage blocks dispatch through `rest-core-quota` (GH#38332 / GH#37888).

## How

### Files Scope

- `.agents/scripts/runtime-env.sh`
- `.agents/scripts/tests/test-launchd-sanitized-path.sh`

### Change

- `.agents/scripts/runtime-env.sh` `aidevops_service_path` (about line 91): build `stable_path` as `~/.aidevops/agents/scripts:~/.aidevops/bin:<npm global bin>:~/.bun/bin:~/.local/bin`. This keeps GH#38526's requirement (npm global bin ahead of `~/.bun/bin`) and restores the invariant stated at `runtime-env.sh:268-269` ("framework shims intentionally lead PATH"). Update the function comment.
- `.agents/scripts/tests/test-launchd-sanitized-path.sh` `test_sanitized_path_filters_unsafe_entries`: update the order assertion and add a case with `_AIDEVOPS_NPM_GLOBAL_BIN` set to a dir containing a `gh`, asserting the shim dirs precede it.

Plists regenerate on the next `aidevops update` / `setup.sh` (launchd install-if-changed), so the fix applies after release + update.

## Acceptance

- `aidevops_service_path` output starts with `~/.aidevops/agents/scripts:~/.aidevops/bin:` and lists the npm global bin before `~/.bun/bin`.
- With that PATH, `command -v gh` resolves to the aidevops shim even when the npm global bin contains `gh`.

## Verification

- `bash .agents/scripts/tests/test-launchd-sanitized-path.sh`
- `bash .agents/scripts/tests/test-runtime-env.sh`
- `bash .agents/scripts/tests/test-canonical-git-command-guard.sh`
- `shellcheck .agents/scripts/runtime-env.sh .agents/scripts/tests/test-launchd-sanitized-path.sh`
- Post-deploy: `plutil -extract EnvironmentVariables.PATH raw ~/Library/LaunchAgents/sh.aidevops.pulse-watchdog.plist` leads with the shim dirs, and a fresh process probe shows native `gh` children only under the shim (canonical Cellar argv0).
