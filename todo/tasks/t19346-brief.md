# Pulse stats quarantine: duplicate scan has no early break and backlog is never pruned

Target repository: marcusquinn/aidevops

## Problem

`_pulse_stats_recover_locked` quarantines a corrupt `pulse-stats.json` before
reinitialising it. GH#37776 (commit `5231638d02`, 2026-11-11) correctly capped new
quarantine copies at 5, but two gaps remain on installs that accumulated a
pre-cap backlog:

1. **No early break in the duplicate scan.** `.agents/scripts/pulse-stats-helper.sh:121-128`
   globs every `pulse-stats.json.corrupt.*` file into an array and runs `cmp -s`
   against each one on every recovery attempt, even after `count` has passed the
   cap of 5. The cap is only consulted afterwards at line 129. With a large
   backlog this spawns one `cmp` subprocess per quarantine file per recovery.
2. **No pruning path.** `.agents/scripts/storage-cleanup-helper.sh` has no
   handling for these files: `rg -n 'corrupt|quarantine|pulse-stats'` against it
   returns no matches. Nothing in the storage-hygiene routine reclaims them, so
   the backlog and its per-recovery scan cost persist indefinitely.

## Observed evidence

On one Linux install (aidevops v3.39.277):

- `fd -H -t f -g 'pulse-stats.json.corrupt.*' ~/.aidevops/logs | wc -l` -> `16408`
- `~/.aidevops/logs` shrank from 966M to 901M after deleting them, i.e. ~65 MB
  held by quarantine copies alone.
- File mtimes spanned 2026-10-08 to 2026-10-27; sizes ranged from 16 B to 787 KB.
  No new quarantine file has appeared since 2026-10-27, so the underlying
  corruption is not currently reproducing and is NOT part of this task.
- Two samples were preserved for reference before deletion (16 B and 787 KB).

The 16408-file scan is therefore a real cost on any install that accumulated a
backlog before the cap landed: every corruption recovery would fork 16408 `cmp`
processes while holding the stats lock.

### Files Scope

- `.agents/scripts/pulse-stats-helper.sh`
- `.agents/scripts/storage-cleanup-helper.sh`

## Required changes

`.agents/scripts/pulse-stats-helper.sh`: add an early `break` in the quarantine
enumeration loop at lines 121-128 once the cap and duplicate checks can no
longer change the outcome. Keep the existing duplicate detection semantics for
backlogs under the cap: the loop must still be able to observe a duplicate, so
break only when `count` has reached the cap AND a duplicate has already been
found, or restructure so the cap short-circuits without changing behaviour for
small backlogs. Do not raise or remove the cap.

`.agents/scripts/storage-cleanup-helper.sh`: prune `pulse-stats.json.corrupt.*`
beyond the retained cap (keep the newest few as evidence), consistent with how
this helper already treats other reclaimable log artifacts.

## Reference pattern

Follow the existing guarded-glob and `nullglob` restore style already used in
`_pulse_stats_recover_locked` (`.agents/scripts/pulse-stats-helper.sh:119-122`),
and the existing size/age-based reclamation entries in
`.agents/scripts/storage-cleanup-helper.sh` for the pruning addition.

## Verification

- `shellcheck .agents/scripts/pulse-stats-helper.sh .agents/scripts/storage-cleanup-helper.sh`
  must report zero violations.
- `.agents/scripts/linters-local.sh` for the changed files.
- Create a scratch directory with, say, 50 `pulse-stats.json.corrupt.*` files
  plus a deliberately invalid `pulse-stats.json`, trigger one recovery, and
  confirm the recovery still reinitialises the stats file, still refuses to add
  a sixth quarantine copy, and no longer scans every backlog file.
- Confirm the storage-cleanup addition reports the reclaimed count and retains
  the newest evidence copies.

## Out of scope

The root cause of the original `pulse-stats.json` corruption (last observed
2026-10-27) is not part of this task; no active reproduction is available.
