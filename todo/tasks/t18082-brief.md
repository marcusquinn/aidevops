---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t18082: Fix sandbox cleanup for descendants that create new process groups

## Pre-flight

- [x] Memory recall: no reusable nested sandbox cleanup lesson found.
- [x] Discovery: issue #5530 fixed descendants in the original process group;
  this task covers descendants that create a different session or process group.
- [x] File refs verified against the current default branch.
- [x] Tier: `tier:standard` — process identity and cross-platform cleanup require
  focused fixtures and judgment.

## Origin

- **Created:** 2026-07-10
- **Created by:** AI DevOps (interactive)
- **Issue:** #26951
- **Related mission:** m-20260710-11431d
- **Evidence:**
  `todo/missions/m-20260710-11431d/research/resource-baseline.md:25-26`

## What

Extend generic sandbox cleanup so a nested descendant cannot escape by creating
a new session or process group.

## Why

The sandbox currently terminates the original child process group or direct
child. A committed timeout fixture showed that a nested background group could
survive this boundary. The lint profiler's private process snapshot supplied
defence-in-depth, but every sandbox caller should receive the same guarantee.

## Files to Modify

- `.agents/scripts/sandbox-exec-helper.sh:422-463` — retain and terminate a
  verified descendant snapshot after the original PGID-first cleanup.
- `.agents/scripts/lint-resource-benchmark.sh:281-320` — reference the existing
  snapshot-based PID and process-group termination pattern; avoid duplication
  where a shared helper is appropriate.
- `NEW: .agents/scripts/tests/test-sandbox-nested-process-group-cleanup.sh` —
  timeout, normal-exit, PID-recycling, and unrelated-process fixtures.

## Reference Pattern

Model survivor cleanup on
`.agents/scripts/lint-resource-benchmark.sh:281-320`: retain PID, PGID, and
identity evidence before the parent exits; revalidate identity before signals;
terminate process groups and individual survivors after a grace period. Preserve
the sandbox's existing PGID-first graceful shutdown and secondary watchdog.

## Reproducer

1. Run the sandbox with a short timeout around a fixture that starts a nested
   `setsid` background process, records its PID, and waits.
2. Require sandbox status 124.
3. After a bounded grace period, assert that the recorded nested PID and process
   group no longer exist.
4. Repeat the normal-exit path and verify no unrelated process is signalled.

## Acceptance Criteria

- [ ] A nested descendant that creates a new process group is terminated after
  sandbox timeout.
- [ ] Normal exit leaves no tested descendant alive.
- [ ] PID/start-token verification prevents signalling a recycled or unrelated
  PID.
- [ ] Existing sandbox, sensitive-output, Bash 3.2, ShellCheck, and portability
  checks pass.

## Verification

```bash
bash .agents/scripts/tests/test-sandbox-nested-process-group-cleanup.sh
bash .agents/scripts/tests/test-sandbox-sensitive-output-guard.sh
.agents/scripts/linters-local.sh --changed
```

## Workarounds Applied

- The F1 profiler retained a recent process-tree snapshot and killed surviving
  PIDs or groups after generic cleanup returned.
- Target-specific validators used bounded process-tree termination until the
  generic contract can be hardened.

## Privacy

Publish aggregate process behavior only. Do not include private repository
names, paths, commands, source, or raw process diagnostics.
