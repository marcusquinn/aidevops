## What

Run the macOS input-activity sampler LaunchAgent (`sh.aidevops.screen-activity-sampler`, added in t18934 / GH#37496) at standard scheduling priority instead of `ProcessType=Background`, so that per-minute `HIDIdleTime` reads succeed while the Mac is busy. Keep `Nice=10`. Drop `LowPriorityBackgroundIO`.

## Why

- The sampler only measures when it gets CPU time. On the maintainer Mac (v3.39.161, 2026-11-10, load average 45–50 from concurrent headless sessions), consecutive launchd samples at 15:46:39Z and 15:57:11Z recorded `evidence: ["hid-idle-unavailable"]` in `~/.aidevops/.agent-workspace/observability/screen-activity-state.json`. One `screen-time-helper.sh sample` run was still alive after 64 s, which exceeds its 60 s `StartInterval`. `screen-time-helper.sh input-stats` reported `collection_status: partial`.
- `ioreg -c IOHIDSystem -r -k HIDIdleTime -d 1` itself returns in 0.01 s under the same load.
- The deployed probe `hid_idle_seconds()` + `console_root()` (`.agents/scripts/screen_time_macos_input.py`) measured 0.02–0.03 s per read under `nice -n 10`. Under `nice -n 10 taskpolicy -b` (the Darwin background policy that `ProcessType=Background` applies) the same probe printed nothing within 240 s.
- A failed read records no input. Busy periods are when the maintainer is most active with many AI sessions, so the README "Input activity (Mac)" row under-reports exactly when it matters. The Linux sampler has no equivalent throttling.
- The job is tiny (one `ioreg` read plus one console-state read per minute), so standard priority costs nothing measurable.

## How

1. `.agents/scripts/setup/modules/schedulers.sh` `_setup_screen_activity_sampler_darwin`: in the plist heredoc, change `ProcessType` from `Background` to `Standard` and remove the `LowPriorityBackgroundIO` key. Keep `Nice` 10, `StartInterval` 60, `RunAtLoad`, the log paths and the PATH/HOME environment. Update the function comment to say why the sampler must not use the background policy.
2. Leave `sh.aidevops.screen-time-snapshot` (every 6 h, not time-critical) and the memory-pressure monitor unchanged. They are outside this measurement defect.
3. `_launchd_install_if_changed` already reloads the agent when the plist content changes, so `setup.sh --non-interactive` / `aidevops update` applies the fix on existing installs.

## Acceptance

- `shellcheck .agents/scripts/setup/modules/schedulers.sh` is clean.
- After deploy on a Mac: `~/Library/LaunchAgents/sh.aidevops.screen-activity-sampler.plist` has `ProcessType` `Standard`, no `LowPriorityBackgroundIO`, and `Nice` 10. `launchctl list sh.aidevops.screen-activity-sampler` shows `LastExitStatus` 0.
- Under load, `screen-activity-state.json` keeps `evidence: ["hid-idle"]` across consecutive samples, and `screen-time-helper.sh input-stats` reports `collection_status: ok`.

### Files Scope

- .agents/scripts/setup/modules/schedulers.sh
