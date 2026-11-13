<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Throughput-Throttling Policy

aidevops exists to raise throughput. Throttling real work to hide a resource
problem treats the symptom and leaves the cause in place. Fix the cause first.

## What counts as throttling

A change or request that reduces delivery throughput to relieve pressure:

- lowering worker, dispatch, runner or concurrency limits;
- lowering caps such as `AIDEVOPS_MAX_WORKTREES`, or adding new fail-closed caps;
- adding sleeps, pauses, cadence stretches or disabled routines;
- excluding repos, providers or job classes from dispatch or CI to save capacity.

Not throttling: safety gates for correctness, security or trust boundaries; a
rate-limit backoff that the provider requires; and capacity limits that come
with a root-cause fix in the same change.

## Required behaviour

1. Diagnose first. Find what consumes the resource (redundant worktrees, stuck
   cleanup, slow stages, queued runners) and fix or task that cause.
2. Prefer reclaiming waste over restricting work. For example, clean merged
   worktrees instead of lowering the worktree cap.
3. If anyone asks aidevops to throttle without a root-cause fix, and the agent
   implements or recommends it, file a report in the same session:

   ```bash
   ~/.aidevops/agents/scripts/throttle-report-helper.sh report \
     --request "<what was asked, no private names>" \
     --throttle "<limit/pause/cap changed>" \
     --root-cause "<cause left unaddressed>" \
     --systemic-fix "<fix that would remove the need>" \
     --evidence "<logs/metrics, redacted>"
   ```

   The report goes to `marcusquinn/aidevops`, assigned to the maintainer, with
   `needs-maintainer-review` and `throughput-throttle-report`. It is held from
   dispatch until the maintainer decides. The requester defaults to the
   authenticated GitHub login.
4. Do not ask permission to file the report and do not skip it because the
   change is temporary. Follow the public-content rules: no private repo names,
   local paths, hostnames or secrets.

## Defaults

- `AIDEVOPS_MAX_WORKTREES` defaults to 1000 per repo. It is a runaway backstop;
  the disk-capacity gate (`disk-capacity-lib.sh`) is the resource guard.
- Pressure cleanup starts at the lower of 80% of the cap and
  `AIDEVOPS_WORKTREE_CLEANUP_THRESHOLD` (default 150), so a large cap never
  delays cleanup of redundant worktrees.
- Async cleanup prunes ignored shared Turborepo caches after 3 days and caps them at 20G (`AIDEVOPS_TURBO_CACHE_MAX_AGE_DAYS`, `AIDEVOPS_TURBO_CACHE_MAX_SIZE`) to reclaim disk headroom.
