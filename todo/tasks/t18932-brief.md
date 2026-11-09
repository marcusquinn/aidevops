<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t18932: stale macOS source renders 0h instead of unavailable for unobserved periods

Ref: GH#37467. Same class as GH#36709 / GH#36737 (Linux before-first-sample).

## What

On macOS, a profile README period with no screen-time observations is published as `0h` when the live source is `stale`. It should show `unavailable`. An unobserved period is unknown, not zero.

## Why (evidence)

- The maintainer profile README render at 2026-11-08T02:13Z showed `Screen time (macOS) | 0h | 69.4h | 294.7h | ~3768h*`, with the note `Screen time from macos-knowledge-db:/display/isBacklit; collection status: ok, stale`. The previous render showed 17.6h for the prior day and 93.4h for the week. The wrong 0h stayed published for about 18.6h, until the next render at 2026-11-08T20:50Z. At the time the user was active (5.7–6.7h interactive attention per day).
- Repro on `main` (`dccc247faf`): a collection with `status: stale`, `latest_epoch` 36h before the start of yesterday, intervals only earlier in the week, and an empty history passed to `profile_payload()`. Result: `day: 0.0 stale source-observations coverage_days 0.0`.
- Cause: in `.agents/scripts/screen_time_history.py`, `bounded_period_payload()` computes hours whenever status is not `unavailable`. `coverage()` returns `(0.0, 0.0)` when nothing was observed in the window and `latest_epoch < start`. `apply_short_history()` cannot backfill, because the snapshot deliberately omits unobserved stale dates (test: `snapshot omits unobserved stale dates and records explicit zero-event dates`). The result is a measured-looking 0h.

### Files Scope

- `.agents/scripts/screen_time_history.py`
- `.agents/scripts/tests/test-screen-time-helper.sh`

## How

1. In `bounded_period_payload()`, when the status is not `unavailable`, `observed_since` is `None`, and `coverage()` returns 0 observed days, set `status, reason = "unavailable", "no-observations-in-period"` and `hours = None`. A fresh source always has `latest_epoch >= start`, so coverage is at least 1 day. Explicit zero-event days from a fresh source therefore still show `0h`.
2. Keep Linux sampler behaviour unchanged. It uses `observed_since_epoch`, and `before-first-sample` already covers its unobserved periods.
3. Add one assertion beside the existing stale or sparse cases: a stale source with no in-window observations gives an `unavailable` day, and a fresh zero-event day still gives `0h`.

## Acceptance

- A stale macOS source with no observations in a period renders `unavailable (no-observations-in-period)`, not `0h`.
- The existing case `empty sources, explicit zero, and relative sparse-source selection are distinct` still passes.

## Verification

```bash
bash .agents/scripts/tests/test-screen-time-helper.sh
.agents/scripts/screen-time-helper.sh profile-stats | jq '.periods.day'
```
