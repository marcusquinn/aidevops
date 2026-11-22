<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t18863: Linux README shows 0h before first sample; sampler not installed on updates

Ref: GH#36709. Follow-up to GH#36628 / PR #36635.

## What

Two Linux profile READMEs still showed no meaningful screen time after the input-activity collector shipped in v3.39.119:

- Profile A, sampler running: shows `0h | 0h | 0h | ~0h*` with `collection status: ok`. Completed days from before the sampler's first sample count as observed zero.
- Profile B, on 3.39.119: shows `unavailable` with source `linux-input-activity`, meaning the sampler has never recorded a sample. The per-minute sampler scheduler was not installed.

## Why (evidence)

- Profile A's README history: the collector source changed at about 06:47Z, but status stayed `unavailable` until about 15:49Z. Auto-update tracks `origin/main`. Its incremental `--stage ai-session` path maps `.agents/scripts/setup/modules/schedulers*.sh` changes to `setup_supervisor_pulse` only (`setup.sh` `_setup_ai_session_plan_file`), so the sampler added to `setup_screen_time_snapshot` was not installed. The sampler appeared only after an unrelated `.agents/scripts/setup/*` change (14:39Z) forced a full setup.
- Profile B was still `unavailable` after that full setup. The non-interactive full setup installs screen-time schedulers only when the 6-hourly snapshot scheduler is already detected (`_should_setup_noninteractive_scheduler "Screen time" ...`). On Linux, that strands any install without the snapshot timer.
- `.agents/scripts/screen_time_history.py` `coverage()` counts `latest_epoch` as coverage for any window that starts before it, and `bounded_period_payload()` returns `0.0` hours whenever the collection is not `unavailable`. Windows that end before the first sample therefore render as `0h` with 100% coverage, and the year extrapolation becomes `~0h`.

## Files Scope

- `.agents/scripts/screen_time_history.py`
- `.agents/scripts/screen_time_linux_activity.py`
- `.agents/scripts/profile-readme-render-lib.sh`
- `.agents/scripts/setup/_runtime_helpers.sh`
- `setup.sh`
- `.agents/scripts/tests/test-screen-time-helper.sh`

## How

1. The activity collection exposes `observed_since_epoch`, the first retained coverage start. `bounded_period_payload` reports `hours: null`, `status: unavailable`, `reason: before-first-sample` for windows that end before it, and clips coverage days to the time since it. Collections without the key, which includes macOS, are unchanged.
2. The README footnote appends the period reason when a period is unavailable. When Linux sampling began inside the 28-day window, it also names the start date.
3. `_should_setup_noninteractive_screen_time`: the snapshot is installed, OR (Linux AND the profile README scheduler is installed). This follows the `_should_setup_noninteractive_complexity_scan` escape-hatch pattern.
4. The incremental ai-session plan refreshes installed non-pulse schedulers when `schedulers.sh`, `schedulers-linux.sh`, `schedulers-platform.sh` or `_scheduler_runtime.sh` change. `schedulers-pulse.sh` keeps the pulse-only refresh.

## Acceptance

- Before the first sample, all four Linux periods render `unavailable` with reason `before-first-sample`. After one completed sampled day, real hours appear and the year estimate extrapolates from the real coverage.
- macOS screen-time tests are unchanged and pass.
- A Linux install with the profile README scheduler but no snapshot timer gets the sampler on the next non-interactive setup.

## Verification

```bash
bash .agents/scripts/tests/test-screen-time-helper.sh
bash .agents/scripts/tests/test-profile-readme-boundary.sh
shellcheck setup.sh .agents/scripts/setup/_runtime_helpers.sh .agents/scripts/profile-readme-render-lib.sh
```
