<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t18865: Linux first partial sampled day shown as full coverage; year from under one day

Ref: GH#36737. Follow-up to GH#36709 / PR #36713 (released in v3.39.121).

## What

Both Linux profile READMEs now have running input samplers, but the first partial sampled day is presented as if it were full coverage:

- Profile A: `2.4h | 2.4h | 2.4h | ~876h*`, source `screen-time-history:daily-observations`. The 2.4h comes from about 9 sampled hours on the first day. The year estimate is that partial day times 365.
- Profile B: `0h | 0h | 0h | ~0h*`, source `screen-time-history:daily-observations`. The first day had under an hour of sampling, just before midnight. One render earlier, the live collector showed `Input sampling began 2026-11-04`. That note disappeared once the snapshot wrote history.

## Why (evidence)

- Repro on `main` (d0ea9b1fbd): sampler from yesterday 15:00, typing 2.4h, `now` = today 01:00:
  - before the snapshot: source `linux-input-activity`, month `coverage_days` 0.4, year 876h (`observed-calendar-coverage-extrapolation`, because `max(1.0, coverage_days)` still extrapolates from less than one day)
  - after the snapshot: source `screen-time-history:daily-observations`, `coverage_days` 1, year 876h (`calendar-span-extrapolation`)
- `.agents/scripts/screen_time_history.py` `apply_short_history()` replaces a live period whenever the history coverage percentage is higher. The snapshot records the partial first day as one whole observed day, so history always wins in the first weeks. The history period has no `observed_since_epoch`, so the README sampling-start note is lost.
- On Linux the history rows are derived from the same sampler log, which keeps 400 days. They never add data the live collection lacks while the live collection is available.

## Files Scope

- `.agents/scripts/screen_time_history.py`
- `.agents/scripts/profile-readme-render-lib.sh`
- `.agents/scripts/tests/test-screen-time-helper.sh`

## How

1. `apply_short_history`: keep a live period that has `observed_since_epoch` and is not `unavailable`. History still backfills unavailable periods. macOS periods have no `observed_since_epoch` and are unchanged.
2. `estimated_year` for sampler collections: use the live 365-day window directly. At 330 or more sampled days, report it as is. From 7 to 329 days, extrapolate `hours / coverage_days * 365`. Under 7 days, report `unavailable` with reason `fewer-than-7-sampled-days` instead of a 365x estimate.
3. README note: `Input sampling began YYYY-MM-DD (N of 28 days sampled); earlier days are not counted.`

## Acceptance

- After a snapshot, the Linux periods keep source `linux-input-activity:*`, fractional coverage and the sampling-start note.
- With fewer than 7 sampled days, the year is unavailable (`fewer-than-7-sampled-days`). With 7 or more, it extrapolates from the sampled coverage.
- macOS screen-time tests pass unchanged.

## Verification

```bash
bash .agents/scripts/tests/test-screen-time-helper.sh
bash .agents/scripts/tests/test-profile-readme-boundary.sh
shellcheck .agents/scripts/profile-readme-render-lib.sh
```
