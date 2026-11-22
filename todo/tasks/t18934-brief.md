## What

Add a macOS "Input activity" row to the profile README "Work with AI" table, measured exactly like the Linux sampler: time counts from each keyboard/mouse input until 300s of idle (`linux-input-activity:idle-cutoff-300s` rule). Label the Linux row "Input activity (Linux)" (it already measures input, not screen-on time) and note whether the latest Linux sample saw desktop idle evidence or terminals only. Result: the maintainer's Mac README and contributors' Linux READMEs carry a like-for-like row for productivity comparison.

## Why

- macOS "Screen time (Mac)" is display-on time (knowledgeC backlit spans ∪ pmset display assertions, fixed in t18933 / GH#37492). Linux "Screen time (Linux)" is sampled human input with a 5-minute idle cut-off (`.agents/scripts/screen_time_linux_activity.py`, `DEFAULT_IDLE_SECONDS=300`). The two rows measure different things, so cross-platform comparison is misleading.
- macOS exposes system-wide input idle time permission-free: `ioreg -c IOHIDSystem -r -k HIDIdleTime -d 1` prints `"HIDIdleTime" = <ns>`. Verified on the maintainer Mac 2026-11-09: two reads 6s apart rose by 6.03e9, so the unit is nanoseconds. `caffeinate -u` does not reset it, so declared user-activity assertions are not counted as input.
- Linux evidence kinds are already recorded per sample (`state["evidence"]`, e.g. `gnome-idle-monitor`, `tty-atime`, `graphical-idle-unavailable`) but never shown, so a reader cannot tell whether a desktop was observed.

## How

1. `.agents/scripts/screen_time_linux_activity.py`: make the collector name a parameter (default `linux-input-activity`) for `record_sample`, `record_line`, `prune_records`, `persist`, `source_name`, `unavailable`, `activity_collection`; keep file names and Linux behaviour unchanged.
2. New `.agents/scripts/screen_time_macos_input.py`: read `HIDIdleTime` from `ioreg` and console lock/owner state from the `ioreg -n Root` plist (`IOConsoleLocked`, `IOConsoleUsers`). Evidence kinds: `hid-idle` (counted), `hid-idle-unavailable`, `console-state-unknown` (still counted), `locked` and `not-console-user` (no input). Collector `macos-input-activity`. Fixture env `AIDEVOPS_HID_IDLE_FIXTURE` is a JSON file `{idle_seconds, locked, on_console}`.
3. `.agents/scripts/screen_time_sources.py` (per-platform source selection, added in t18933): `input_collection`, `record_input_sample`, `with_evidence`, so the engine stays within its Qlty file-complexity budget.
4. `.agents/scripts/screen-time-interval-engine.py`: `sample` on Darwin records a macOS input sample (previously `no-sampler-needed:Darwin`); new `input-profile` command prints `profile_payload(<input collection>, None, now)` plus the latest `evidence` list; `profile` also carries `evidence`.
5. `.agents/scripts/screen-time-helper.sh`: `input-stats` command → engine `input-profile`; usage text.
6. `.agents/scripts/setup/modules/schedulers.sh` `setup_screen_time_snapshot`: macOS LaunchAgent `sh.aidevops.screen-activity-sampler` running `screen-time-helper.sh sample` with `StartInterval` 60, mirroring the snapshot plist (RunAtLoad, Background, Nice 10, log `screen-activity-sampler.log`).
7. `.agents/scripts/routines/core-routines.sh` (`describe_r909`): name the macOS sampler in the screen-time routine description.
8. `.agents/scripts/profile-readme-data-lib.sh` (`_get_input_activity`) + `.agents/scripts/profile-readme-render-lib.sh` (`_generate_input_activity_vars`, `_input_evidence_note`, `_generate_work_with_ai_table`): on Darwin add an "Input activity (Mac)" row after "Screen time (Mac)" with the same formatting and sampling-began note; on Linux relabel the row "Input activity (Linux)" and append the latest-sample evidence (desktop vs terminal input).
9. Tests: `.agents/scripts/tests/test-screen-time-helper.sh` (fixture-driven macOS samples → input-stats hours, source, lock and console rules); `.agents/scripts/tests/test-profile-readme-boundary.sh` (module copy list, row label, Mac input row and Linux evidence note).

## Acceptance

- `bash .agents/scripts/tests/test-screen-time-helper.sh` and `bash .agents/scripts/tests/test-profile-readme-boundary.sh` pass; ShellCheck clean on changed shell files.
- On a Mac after `setup.sh --non-interactive`: `launchctl list | rg screen-activity-sampler` shows the job; `~/.aidevops/.agent-workspace/observability/screen-activity-state.json` updates each minute; `screen-time-helper.sh input-stats` reports `macos-input-activity:idle-cutoff-300s` with `observed_since_epoch` set.
- Generated README shows "Screen time (Mac)" and "Input activity (Mac)" rows on macOS, "Input activity (Linux)" with an evidence note on Linux.

### Files Scope

- `.agents/scripts/screen_time_linux_activity.py`
- `.agents/scripts/screen_time_macos_input.py`
- `.agents/scripts/screen_time_sources.py`
- `.agents/scripts/screen-time-interval-engine.py`
- `.agents/scripts/screen-time-helper.sh`
- `.agents/scripts/setup/modules/schedulers.sh`
- `.agents/scripts/routines/core-routines.sh`
- `.agents/scripts/profile-readme-data-lib.sh`
- `.agents/scripts/profile-readme-render-lib.sh`
- `.agents/scripts/tests/test-screen-time-helper.sh`
- `.agents/scripts/tests/test-profile-readme-boundary.sh`
