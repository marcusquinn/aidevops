<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Target B bounded lint evidence

## Scope

Target B was inspected and profiled through the serialized F1 safety wrapper.
This report contains aggregate measurements only; repository identity, local
paths, source content, raw command output, and raw process diagnostics remain
private.

## Initial route

- Input: one fixed three-file change set from the target's default-branch
  history.
- Normalized affected graph: 37 tasks across 30 packages.
- Changed-file coverage digest:
  `0a6613c417c72bd815cca7a3270b46504269c6dd72fcc1f9c13a258b7b55c926`.
- Affected task-graph digest:
  `e40298a17334932e230017788ecb399a700046386729593806c18b1cd2d46e19`.
- Existing required CI lint already used explicit concurrency 1 with
  fail-closed timeout handling.

The cold concurrency-1 affected route exited 137 after 45 seconds with
5,593,600 KiB aggregate peak RSS and a peak of 11 processes. It started with
86% free memory, zero swap, and normal thermal state. This route was stopped
and was not retried.

An earlier two-second sample executed zero target packages because the sandbox
did not inherit an outer base-ref override. It was excluded before the
decision.

## Recovery route

The objective resumed through package-level checkpoints rather than repeating
the terminated command. All 37 lint-capable package shards passed serially in
492 aggregate seconds. The largest completed shard peaked at 8,398,512 KiB
across at most 11 processes. Thermal state remained normal and swap did not
grow.

One documentation shard first reached its 120-second bound. A longer diagnostic
run identified a missing generated documentation prerequisite and a stale local
lint cache. Generating the prerequisite and invalidating only that cache allowed
the same shard to pass in 192 seconds. Generated outputs remained ignored and
no source change was required for this recovery.

The complete dry task graph contained 102 tasks. Its normalized digest was
identical before and after the retained default change:
`541589c15e5253a1af87bac6a490399ab5a258b178274bbb933842cf1b64503d`.
A retained warm full run then passed all 38 lint tasks from cache in 4 seconds
with 12,384 KiB aggregate peak RSS.

## Decision

Accept a **safety guardrail**, not a measured performance optimisation: local
`lint` and `lint:affected` now default from four concurrent Turbo tasks to one.
Environment overrides remain available for independently resourced execution,
and required CI retains its existing explicit profile.

No performance improvement is claimed against the incomplete terminated
baseline. The evidence supports a lower-risk local default because the complete
serial route preserved the full task digest and passed target-local CI. Cache
contention and duplicate traversal were not measured above the mission
threshold, so conditional F5 is closed as falsified with no additional code.

## Rollback

Restore the two local default concurrency literals from `1` to `4`. No affected
filtering, task graph, cache structure, timeout behavior, or required CI profile
changed. The target-local change merged only after terminal lint, format,
typecheck, unit, end-to-end, security, and review checks passed.

## Verification

- Complete serial coverage: 37 of 37 lint-capable package shards passed.
- Before/after full task-graph digests are identical.
- Profiling concurrency never exceeded 1.
- The post-stop route was changed rather than repeating the terminated command.
- Public privacy review contains only the Target B alias and aggregate values.
