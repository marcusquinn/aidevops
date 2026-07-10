<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Target B bounded lint evidence

## Scope

Target B was inspected and profiled through the serialized F1 safety wrapper.
This report contains aggregate measurements only; repository identity, local
paths, source content, raw command output, and raw process diagnostics remain
private.

## Fixed graph

- Input: one fixed three-file change set from the target's current default
  branch history.
- Normalized graph: 37 tasks across 30 packages.
- Changed-file coverage digest:
  `0a6613c417c72bd815cca7a3270b46504269c6dd72fcc1f9c13a258b7b55c926`.
- Task-graph digest:
  `e40298a17334932e230017788ecb399a700046386729593806c18b1cd2d46e19`.
- Existing required CI lint already uses explicit concurrency 1 with
  fail-closed timeout handling.

## Profile result

The valid cold concurrency-1 affected profile selected one lint package plus
its prerequisite graph. It exited 137 after 45 seconds with aggregate peak RSS
of 5,593,600 KiB and a peak of 11 processes. The run started with 86% free
memory, zero swap, and normal thermal state.

An earlier two-second sample executed zero target packages because the sandbox
did not inherit an outer base-ref override. It was identified before the
decision and excluded as invalid evidence.

## Decision

Classify the local-default hypothesis as **inconclusive and rejected**. Exit
137 is an explicit mission stop condition, so concurrency 2 and warm retries
were not run. No lint concurrency, affected filtering, cache, task graph, CI,
or timeout configuration changed.

The conditional cache/traversal optimisation is skipped because no safe profile
proved contention or duplicate traversal. There is no target rollback action:
the runtime configuration is unchanged.

## Verification

- The target-local brief and worktree were created before profiling.
- Profiling started at concurrency 1 and never exceeded 1.
- The post-stop system check remained at 86% free memory, zero swap, and normal
  thermal state.
- Public privacy review found only Target B aliases and aggregate values.
