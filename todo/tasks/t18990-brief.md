<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `collaborator permission memo per-process merge routine quota` → 0 hits
- [x] Discovery pass: GH#38242 / PR #38247 (merged 2026-11-14 09:47Z, released in v3.39.192 at 11:13Z) added the per-process memo in `_gh_collaborator_permission_lookup`. No issue covers verifying that it takes effect.
- [x] File refs verified at `main` (`shared-gh-collaborator-permission.sh:306-357`)
- [x] Tier: `tier:standard`. Diagnosis first, then a narrow fix inside one trust-boundary helper.

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (productivity mission session)
- **Conversation context:** Pulse cycle at 13:10Z ended `blocker=rest-core-quota dispatched=0`. Attributing that hour found `pulse-merge-routine.sh` still spending 131 `collaborators/:u/permission` reads (stage `collaborator-permission-rest`, which only `shared-gh-collaborator-permission.sh:265` sets), after the GH#38242 memo was deployed.

## Reproducer

```bash
awk -F'\t' '$1>=1794650000 && $5=="rest-core" && $9=="attempt" && $2=="pulse-merge-routine.sh" && $25 ~ /permission$/ {b=int(($1-1794650000)/1800); n[b]++} END {for (x in n) print x, n[x]}' ~/.aidevops/logs/gh-api-calls.log | sort -n
```

**Actual (30-minute buckets from 09:53Z; v3.39.192 deployed around bucket 3):** 65, 77, 26 before; 72, 56, 75 after. There was no visible drop. The same buckets for `commits/:id` fell only from about 49 to about 28, and `/user` stayed at 8-23 per bucket.

Process tree observed during one run: `pulse-merge-routine.sh run` (pid A) → child subshell (pid B, alive for the whole run) → further nested subshells per PR. Memo writes made inside a `$(...)` substitution or a pipeline/loop subshell are discarded when that subshell exits.

## What

1. **Verify the premise first.** Add one summary log line per routine run, `collab_memo hits=N misses=M`, to `pulse-merge-routine.sh`'s runner log. Measure one run. If misses are mostly distinct `(repo, login)` pairs, the memo is working and the volume is real. In that case, close with the measurement and stop.
2. **If the memo is being lost in subshells,** back it with a per-run scratch file. Create it under the routine's existing temp area at run start, export its path, append successful lookups, and delete it in the routine's EXIT trap. Subshells then share hits within one run. The next run still observes revocation, which keeps the GH#38242 decision intact.

## Why

REST core quota is the current ceiling on unattended throughput: at 0 remaining the pulse dispatches no workers at all. A memo that does not survive the routine's own process structure gives no saving and hides the real cost.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The fix touches a `#aidevops:trust-boundary` helper. It must keep "only successful lookups, never across runs" semantics and needs mirrored hit/miss tests.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/shared-gh-collaborator-permission.sh:306-357`: count hits and misses. When `AIDEVOPS_GH_COLLAB_MEMO_FILE` is set and is a regular file owned by the current user, read and append memo entries there as well as the in-process variable. Keep failures, deferrals and fallback/retry routes unmemoized.
- `EDIT: .agents/scripts/pulse-merge-routine.sh` (run path around `_pmr_acquire_lock`, `:421-445`): create the memo file with `mktemp` after the lock is acquired. Export it, remove it in the existing EXIT trap, and log the hit/miss summary at run end.
- `EDIT: .agents/scripts/tests/test-shared-gh-collaborator-permission-cache.sh`: add (a) a lookup inside `$(...)` followed by a parent lookup for the same key makes one API call when the memo file is set; (b) a failed lookup is not written to the file; (c) without the env var, behaviour is unchanged.

### Files Scope

- `.agents/scripts/shared-gh-collaborator-permission.sh`
- `.agents/scripts/pulse-merge-routine.sh`
- `.agents/scripts/tests/test-shared-gh-collaborator-permission-cache.sh`

### Complete Write Surface

- **Callers/readers:** every `_gh_collaborator_permission_lookup` / `_gh_actor_has_repo_write_authority` caller. Outside the merge routine the env var is unset, so behaviour is unchanged.
- **Writers/mutation paths:** one per-run temp file, mode 600, deleted on exit.
- **Schemas/config:** new internal env `AIDEVOPS_GH_COLLAB_MEMO_FILE`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts`.
- **Migrations/backfills:** N/A.
- **Cleanup/rollback paths:** EXIT trap; revert the PR.
- **Existing verification/tests:** the GH#38242 tests added in PR #38247.

### Hazards and Compatibility

- **Trust boundary:** revocation is observed by the next run, the same as today. A run lasts minutes. Do not add any cross-run TTL cache (GH#38242 decision).
- **File safety:** refuse a memo path that is a symlink, is not owned by the current user, or is outside the temp root.
- **Bash 3.2:** no associative arrays.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-shared-gh-collaborator-permission-cache.sh
bash .agents/scripts/tests/test-pulse-merge-routine-standalone.sh
shellcheck .agents/scripts/shared-gh-collaborator-permission.sh .agents/scripts/pulse-merge-routine.sh
```

- **Surface mapping:** permission tests cover the helper; the standalone suite covers routine lifecycle and traps.
- **Broad verification trigger:** Not required.

## Acceptance Criteria

- [ ] Each merge-routine run logs `collab_memo hits=N misses=M`.
- [ ] A lookup made inside a command substitution is reused by a later lookup for the same key in the same run (one API call).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-routine-standalone.sh"
  ```

- [ ] Failed or deferred lookups are never written to the memo file; the file is removed at run exit.
- [ ] After deploy, `collaborator-permission-rest` attempts from `pulse-merge-routine.sh` per 30 minutes fall measurably below the 56-77 baseline, or the issue closes with hit/miss evidence that the remaining volume is distinct pairs.

## Context & Decisions

- Related: GH#38242 (memo origin), GH#38281 (routine responder identity reads), GH#38273 (App read routing), GH#37888 (unattributed same-login drain).
