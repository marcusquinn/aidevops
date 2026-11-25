## What

Share one host-wide process-table read between concurrent `sandbox-exec-helper.sh`
wait loops on platforms without `/proc` (macOS), instead of every worker's poll
loop forking a full `ps -axo pid=,ppid=,pgid=,stat=,lstart=` every 0.5 s.

## Why (evidence, 2026-11-25, 16-core macOS runner)

- Host CPU was saturated: load average 208-272, `top` 0.0% idle, ~49% sys.
- Reaped-child-aware rusage (`proc_pid_rusage` self+child) for the live
  `sandbox-exec-helper.sh run` wrappers: 16 wrappers at 0.08-0.09 average cores
  each over 76-3,963 s lifetimes, almost all of it reaped `ps`/`awk`/`sleep`
  children (e.g. 328.3 s total = 18.2 s self + 310.1 s child over 3,963 s).
  That is ~1.3 cores (~8% of the host) spent watching workers.
- One replayed poll iteration (`ps -o stat= -p` + full-table `ps` + the snapshot
  awk) costs ~71 ms CPU; the full-table `ps` alone costs 43-48 ms CPU (35-38 ms
  sys) for ~1,490 processes regardless of columns (`pid=,ppid=` costs the same),
  so the cost is the per-process table walk, not the `lstart` format (t19345
  already fixed the zone-file reload).
- Cost scales with workers x host process count, i.e. superlinearly with
  concurrency: every extra worker adds a poller and more rows for all pollers.
- Launch ceremonies on the same host averaged 266.7 s (n=116); CPU contention
  inflates every shell/API stage, so freed CPU goes straight to workers and
  admission.

## How

File: `.agents/scripts/sandbox-exec-helper.sh`, `_sandbox_snapshot_descendants_ps`
(the macOS fallback; the Linux `/proc` subtree walk is unchanged).

1. Add a host-wide cached table: a user-owned file
   (`${AIDEVOPS_SANDBOX_PS_TABLE_DIR:-$SANDBOX_DIR}/ps-table`) whose first line
   records the refresh time from `$EPOCHREALTIME`, followed by the existing
   `TZ=UTC0 LC_ALL=C ps -axo pid=,ppid=,pgid=,stat=,lstart=` rows. Reuse it
   while younger than a TTL (default 500 ms, matching the poll interval).
   Otherwise claim an exclusive staging file (`ps-table.next`, created with
   noclobber; it doubles as the refresh lock and is reclaimed after 2 s if its
   writer died), append the read and `mv -f` it into place. Loops that find a
   refresh in progress reuse a table up to four TTLs old instead of duplicating
   the read; a first benchmark without that lock refreshed on ~50% of polls.
   The awk skips non-numeric first columns, so the header needs no parsing.
   Implemented: the awk indexes rows by parent and splits/joins columns only
   for descendants (identical output; ~16 ms -> ~10 ms per 1,600-row read).
2. Trust the cache only if the directory and file are owned by the current user
   (`-O`) and the file is not a symlink; otherwise fall back to the direct read.
3. Keep the cleanup-time final snapshot (GH#38861) on a fresh, uncached read so
   the last view before signalling is never stale. Keep cleanup identity
   revalidation (`_sandbox_snapshot_identity_matches`) unchanged: it re-reads
   each PID, so a stale table row can never authorise a kill.
4. Bash without `EPOCHREALTIME` (3.2) keeps today's direct per-poll read.
5. Optional kill switch: `AIDEVOPS_SANDBOX_PS_TABLE_TTL_MS=0` disables sharing.

Reference pattern: the existing single-read awk snapshot in the same function
(GH#38858 / t19079) and the TZ=UTC0 change (t19345).

### Files Scope

- `.agents/scripts/sandbox-exec-helper.sh`

## Acceptance

- Same descendant rows are recorded as before (cached and direct reads feed the
  identical awk program).
- Cleanup's final snapshot bypasses the cache.
- With N concurrent wrappers, full-table `ps` invocations drop from ~2N/s to
  ~2-3/s host-wide; measured wrapper average CPU drops from ~0.08 cores.
- `shellcheck` clean; existing sandbox tests pass, especially
  `tests/test-sandbox-nested-process-group-cleanup.sh` and
  `tests/test-sandbox-timeout-budget.sh`.

## Verification

```bash
shellcheck .agents/scripts/sandbox-exec-helper.sh
bash .agents/scripts/tests/test-sandbox-nested-process-group-cleanup.sh
bash .agents/scripts/tests/test-sandbox-timeout-budget.sh
```

After deploy, re-measure live wrappers' lifetime self+child CPU.
