# t19349: throughput report counts still-running and unlogged workers

Ref: GH#40220. Parent context: GH#40108 (Phase 0 helper t19323 / PR #40113).

## What

`pulse-throughput-report-helper.sh report` under-reported worker-slot
occupancy. GH#40108 judges its phases on that number, so the error could steer
the dispatch-lock decision.

## Why (measured 2026-11-24 on one macOS runner, 20 slots)

The report built occupancy only from spawn→exit pairs, using pulse.log
`[lifecycle] worker_exited` lines as the only exit source. That under-counted
for three reasons:

1. **Running workers.** Spawns with no exit yet were dropped. For the
   17:45–20:30 window the paired-only mean read 6.15 at 20:40, then 7.21 at
   20:56, as more workers exited and paired.
2. **Missing exit lines.** Only the parent observer writes `worker_exited` to
   pulse.log (289/289 lines are `observer=parent`). In about 18:00–20:30 it
   logged about 47 exits, while `headless-runtime-metrics.jsonl` holds 73
   worker completion records (70 distinct workers).
3. **Host reboot at 17:28:07Z.** Workers killed by the reboot left no exit
   record anywhere.

Treating every unpaired spawn as open until six hours over-corrected: the mean
for 17:45–20:30 became 31.5 on a 20-slot runner, because of the
reboot-killed spawns from 17:05–17:27.

## How

- `pulse_throughput_logs.py`: `runtime_exits` reads worker records
  (`role=worker`, `ts`, `issue_number`) from `headless-runtime-metrics.jsonl`.
- `pulse_throughput_events.py`: worker-exit look-back now covers the six-hour
  spawn look-back, so a worker that finished before the window still uses up
  its spawn. A new census series records each `Dispatch_capacity` round's
  `active_workers`, which is Pulse's own `ps` count, and `simultaneous_target_final`.
- `pulse_throughput_workers.py` (new; pairing moved here from the report to
  stay under the Qlty complexity ratchet): `slot_occupancy` counts paired plus
  open intervals. Each open interval ends at the earliest of: the next
  same-issue spawn, the longest paired runtime, the latest host boot (read from
  a clock that keeps counting during sleep), or now.
- `pulse_throughput_report.py`: `slot_occupancy_paired_only` keeps its keys.
  Adds `slot_occupancy` and `slot_occupancy_census`.
- `pulse_throughput_metrics.py`: `census_metrics` carries each census forward
  for at most 600 s and reports coverage plus the mean and minimum of the
  final target.
- The read-only contract still holds: no subprocesses, network access or writes.

### Files Scope

- `.agents/scripts/pulse_throughput_report.py`
- `.agents/scripts/pulse_throughput_events.py`
- `.agents/scripts/pulse_throughput_logs.py`
- `.agents/scripts/pulse_throughput_metrics.py`
- `.agents/scripts/pulse_throughput_workers.py` (new)

## Acceptance

- In the 17:45–20:30 window, `slot_occupancy.mean` agrees with
  `slot_occupancy_census.mean` to within about 2.
- JSON output still parses. Existing keys are unchanged; new keys are added
  only.
- `python3 -m py_compile` passes on all changed files.

## Verification

```bash
.agents/scripts/pulse-throughput-report-helper.sh report --since 2026-11-24T17:45:00Z --until 2026-11-24T20:30:00Z --json \
  | jq -c '{all: .slot_occupancy, paired: .slot_occupancy_paired_only.mean, census: .slot_occupancy_census}'
```
