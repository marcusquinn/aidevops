## Origin

Interactive session (productivity mission, 2026-11-15). Live Pulse telemetry shows that candidate supply depends on whether one large repository's census scan finishes. When the largest backlog repository (820 open issues, about 90 dispatchable `auto-dispatch` issues) finishes its scan, a cycle has 120–133 candidates. When that scan times out, the cycle has 1–4 candidates, even with 10–19 free worker slots.

Evidence from `~/.aidevops/logs/pulse.log` (repo names generalized):

```text
Candidate repository enumeration unavailable: repo=<large-repo> rc=124 budget=60s (GH#38226)   # x5 at the full cap
Candidate repository enumeration unavailable: repo=<large-repo> rc=124 budget=9s|23s|29s|38s   # clamped to census remainder
Dispatch_max: available=19, candidates=1      # typical cycle when the large repo timed out
Candidate repository enumeration slow: repo=<large-repo> elapsed=34s budget=42s next=51s
Dispatch_max: available=19, candidates=133    # the cycle where it completed
```

Over the log window, the large repository's enumeration was unavailable 31 times and completed 8 times. The 2.5-day launch average was about 3.7 workers/hour against roughly 19 free slots.

Two mechanisms, both in `build_ranked_dispatch_candidates_json` / `_dispatch_census_enumerate_repo` (`.agents/scripts/pulse-dispatch-engine.sh`):

1. **Doomed clamped scans.** `_dispatch_census_enumerate_repo` clamps a repository's learned budget (GH#38274) to the remaining census time. A repository already proven to need about 60s is started with 9–38s, times out, and contributes nothing. The census cursor has already advanced past it, so it waits another full rotation.
2. **A timeout discards everything.** Any rc=124 yields `[]`, even though a successful candidate list for the same repository from minutes earlier is valid input. Every candidate still passes the live dispatch gates (state check, `gh_issue_view`, the 7 dedup layers), and the code already treats cached candidates as "revalidated later, but cannot prove absence" (`list_dispatchable_issue_candidates_json`).

## What

1. **Defer instead of starting a doomed scan.** When a repository's learned budget is above the base budget and greater than the census time remaining, stop the census before polling it. Do not touch its poll timestamp or the rotation cursor, so the next census starts with that repository and its full budget. Never defer the first repository polled in a census, so every census makes progress even when the learned budget exceeds the whole census budget.
2. **Last-good fallback on timeout.** After each completed scan, store that repository's candidate list with its timestamp. When a scan times out (rc=124), reuse the stored list if it is at most `PULSE_CENSUS_LAST_GOOD_MAX_AGE_S` seconds old (default 3600; 0 disables). Keep rc=124, so `scan_failed` and product incompleteness are still reported. Log every reuse with count and age.

## Tier

`tier:standard`. One shell library plus an existing hermetic test.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-engine.sh`
  - Extract the schedule, interval and new defer checks from the `build_ranked_dispatch_candidates_json` loop into `_dispatch_census_admit_repo` (rc 0 scan, 1 skip, 2 skip and mark product incomplete, 3 stop the census). The function is at the 100-line complexity gate (99 lines), so it must not grow.
  - Add `_dispatch_census_last_good_file`, `_dispatch_census_store_last_good` and `_dispatch_census_last_good_candidates`, and call them from `_dispatch_census_enumerate_repo`. Write atomically (mktemp+mv) and pass JSON on stdin, never argv.
- `EDIT: .agents/scripts/tests/test-pulse-dispatch-first-wave.sh`: next to the GH#38274 block, cover defer/resume ordering, the first-repository progress guard, last-good reuse on timeout, and expiry.

### Files Scope

- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/tests/test-pulse-dispatch-first-wave.sh`

## Acceptance Criteria

- [ ] A known-slow repository reached with less census time than its learned budget is not scanned that census. The next census scans it first with its full budget.
- [ ] A known-slow repository that is the first repository of a census is still scanned (clamped), so the census always makes progress.
- [ ] A timed-out scan returns that repository's last completed candidate list when it is fresh, logs `Candidate census reused last-good candidates`, and still returns 124. An expired or missing list yields `[]`.
- [ ] After deploy, `pulse.log` shows `Dispatch_max: ... candidates=` values that no longer collapse to 1–4 whenever the large repository times out.
- [ ] The existing first-wave/census test passes and ShellCheck is clean:

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dispatch-first-wave.sh && shellcheck .agents/scripts/pulse-dispatch-engine.sh"
  ```

## Context & Decisions

- Not raising `PULSE_REPO_ENUMERATION_BUDGET_MAX_S` or the 180s census budget. The large repository has also timed out at the 60s cap, and a bigger budget only moves the starvation to other repositories.
- Reuse is limited to rc=124. Other failures (auth, source unavailable or rate limit) keep returning `[]`, so a GitHub outage does not drive dispatch from stale data.
- Why the large repository's scan costs 25–60s+ (full 1000-issue snapshot plus normalization) is a separate optimization and out of scope here.
