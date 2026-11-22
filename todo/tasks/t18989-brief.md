<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `gh api user identity cache trust boundary collaborator permission cache quota` → 0 hits
- [x] Discovery pass: GH#38242 / PR #38247 (merged) cached `/user`, commit-by-SHA and per-process permission reads for `pulse-merge-routine.sh` only. GH#38273 covers moving reads to a GitHub App. GH#37888 covers unattributed same-login drain. None covers the routine comment responder.
- [x] File refs verified at `main` (`routine-comment-responder.sh:33-36,132-151`, `pulse-ancillary-dispatch.sh:946-984`, `pulse-ancillary-dispatch-core.sh:203-210`)
- [x] Tier: `tier:simple`. Two files, a single-value env pass-through plus a negative-result stamp, with an existing test file to extend.

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (productivity mission session)
- **Conversation context:** At 13:10Z the pulse cycle ended `outcome=blocked blocker=rest-core-quota dispatched=0 workers=0/20`. REST core had 0/5000 remaining. Attributing the exhausted hour showed the routine comment responder spending one identity read per pulse-enabled repo per cycle.

## Reproducer

```bash
awk -F'\t' '$5=="rest-core" && $9=="attempt" && $2=="routine-comment-responder.sh" {n[$25]++} END {for (x in n) print n[x], x}' ~/.aidevops/logs/gh-api-calls.log
```

**Actual (2026-11-14 09:53Z-13:11Z, 70 pulse-enabled repos):** 280 `GET user` calls, about 84 per hour, plus about 94 per hour logical `rest-core-selected` reads from the per-repo `gh issue list --label routine-tracking`. Together they use about 3.5% of the 5,000/h PAT budget every hour. Most repos have no open `routine-tracking` issues.

## What

1. `dispatch_routine_comment_responses` resolves the runner login once per cycle and passes it to every `scan`/`dispatch` child as `ROUTINE_COMMENT_SELF_LOGIN`.
2. `routine-comment-responder.sh scan` skips a repo for 1 hour (configurable, `ROUTINE_COMMENT_EMPTY_TTL_SECONDS`, default 3600) after a scan found no open `routine-tracking` issues.

## Why

Pulse cycles are stopping at REST core exhaustion with all 20 worker slots idle. Every repeated read that cannot change within a cycle delays worker dispatch for every repo.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** Env pass-through with a validated fallback, plus a stamp-file skip. No trust-boundary change: the login is the same credential's own identity, resolved by the same process tree in the same cycle.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/routine-comment-responder.sh:33-36`: `_get_self_login` returns `ROUTINE_COMMENT_SELF_LOGIN` when it matches `^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$`, otherwise it keeps the current `gh api user` call.
- `EDIT: .agents/scripts/routine-comment-responder.sh:143-151`: before `gh issue list`, skip the repo when `${STATE_DIR}/${slug//\//_}_empty.stamp` is younger than the TTL (use `_file_mtime_epoch` from `portable-stat.sh`, or `find -mmin`). Touch the stamp when the list is empty. Remove it when the list is non-empty. A failed list call writes no stamp.
- `EDIT: .agents/scripts/pulse-ancillary-dispatch.sh:946-977`: resolve the login once before the repo loop. Reuse `_DISPATCH_SELF_LOGIN` (exported at `pulse-dispatch-engine.sh:895`) when set, else `_foss_current_gh_login` (`pulse-ancillary-dispatch-core.sh:203`). Pass `ROUTINE_COMMENT_SELF_LOGIN="$login"` on the `bash "$responder" scan ...` and `dispatch ...` invocations.
- `EDIT: .agents/scripts/tests/test-routine-comment-responder-ops-filter.sh`: add cases using its existing gh stub: (a) with `ROUTINE_COMMENT_SELF_LOGIN` set, `scan` makes no `api user` call; (b) a second scan within the TTL after an empty list makes no `issue list` call.

### Files Scope

- `.agents/scripts/routine-comment-responder.sh`
- `.agents/scripts/pulse-ancillary-dispatch.sh`
- `.agents/scripts/tests/test-routine-comment-responder-ops-filter.sh`

### Complete Write Surface

- **Callers/readers:** `pulse-dispatch-preflight-lib.sh:715` calls `dispatch_routine_comment_responses || true`; unchanged.
- **Writers/mutation paths:** new `*_empty.stamp` files in the existing `ROUTINE_COMMENT_STATE_DIR`.
- **Schemas/config:** new optional env `ROUTINE_COMMENT_SELF_LOGIN`, `ROUTINE_COMMENT_EMPTY_TTL_SECONDS`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts`.
- **Migrations/backfills:** N/A.
- **Cleanup/rollback paths:** revert; stale stamps only delay one scan by at most the TTL.
- **Existing verification/tests:** `test-routine-comment-responder-ops-filter.sh`, `test-routine-comment-responder-trust.sh`, `test-pulse-dispatch-engine-stage-wiring.sh`.

### Hazards and Compatibility

- **Trust boundary:** unchanged. The responder still compares comment authors against the runner's own login; an invalid env value falls back to the live read.
- **Latency:** a newly created `routine-tracking` issue in a previously empty repo is scanned at most one TTL later. Comments on routine issues are not latency-critical.
- **Bash 3.2:** no associative arrays.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-routine-comment-responder-ops-filter.sh
bash .agents/scripts/tests/test-routine-comment-responder-trust.sh
bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
shellcheck .agents/scripts/routine-comment-responder.sh .agents/scripts/pulse-ancillary-dispatch.sh
```

- **Surface mapping:** responder tests cover scan/dispatch; stage-wiring covers the pulse call site.
- **Broad verification trigger:** Not required.

## Acceptance Criteria

- [ ] With `ROUTINE_COMMENT_SELF_LOGIN` set to a valid login, `scan` performs no `gh api user` call.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-routine-comment-responder-ops-filter.sh"
  ```

- [ ] A repo whose last scan found no open `routine-tracking` issues is not listed again within the TTL; a failed list never writes the stamp.
- [ ] After deploy, `routine-comment-responder.sh` `GET user` attempts in `~/.aidevops/logs/gh-api-calls.log` drop from about 84/h to at most about 1 per pulse cycle.

## Context & Decisions

- Related: GH#38242 (merge-routine read caching), GH#38273 (App read routing), GH#37888 (unattributed drain).
- Cross-process caching of collaborator permissions stays out of scope (GH#38242 decision: it would delay revocation).
