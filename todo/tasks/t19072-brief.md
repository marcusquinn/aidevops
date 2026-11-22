<!-- aidevops:brief-schema=v2 -->
# t19072: fix(logs): honour AIDEVOPS_WORKER_BLOCKER_LOG_FILE in worker-activity-helper.sh

## Pre-flight

- [x] Memory recall: `github issue create wrapper origin label task id aidevops` → `0` hits — no relevant lessons
- [x] Discovery pass: `2` commits / `0` merged PRs / `0` open PRs touch target files in last 48h — most recent is `7d220fc73` (GH#38621), which added the rotation cap this task aligns with
- [x] File refs verified: `5` refs checked, all present at HEAD (`worker-activity-helper.sh:53,421,1104,1109`; `worker-blocker-log.mjs:69-73`; `pulse-logging.sh:749`; both test files)
- [x] Tier: `simple` — disqualifier check clean (verbatim single-line replacement, precedence decided, no trust boundary or migration)
- [x] Seeded draft PR decision recorded: skipped — a one-line change needs no seed, and the exact edit is already inline below

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive
- **Conversation context:** While verifying the GH#38621 jsonl-rotation fix, the interactive session found that the rotation path and the canonical writer resolve the blocker-log path from `AIDEVOPS_WORKER_BLOCKER_LOG_FILE`, while `worker-activity-helper.sh` resolves it from its own `WAH_BLOCKER_LOG_FILE`. With both unset they collapse to the same default, so there is no live impact today; the divergence is latent.

## What

`worker-activity-helper.sh` must honour the canonical `AIDEVOPS_WORKER_BLOCKER_LOG_FILE`
environment variable when resolving the worker-progress blocker log path, keeping
`WAH_BLOCKER_LOG_FILE` working as a legacy alias that takes precedence when both are set.

After the change, setting only `AIDEVOPS_WORKER_BLOCKER_LOG_FILE` makes every
component agree on one path: the Node writer/reader (`worker-blocker-log.mjs`),
the pulse rotation cap (`pulse-logging.sh`), and `worker-activity-helper.sh`.

## Why

Two independent resolution chains exist for the same file:

- `worker-blocker-log.mjs:69-73` — `options.logPath` → `AIDEVOPS_WORKER_BLOCKER_LOG_FILE` → default.
- `pulse-logging.sh:749` — `AIDEVOPS_WORKER_BLOCKER_LOG_FILE` → default (this is the rotation size cap added by GH#38621).
- `worker-activity-helper.sh:53` — `WAH_BLOCKER_LOG_FILE` → default.

`AIDEVOPS_WORKER_BLOCKER_LOG_FILE` is the canonical name: it is used by
`worker-blocker-log.mjs`, `pulse-logging.sh`, `pulse-wrapper-dispatch-gates.sh`,
`pulse-current-state.py`, `approval-helper-permissions.sh` and
`storage-inventory-helper.sh`. `WAH_BLOCKER_LOG_FILE` appears only in
`worker-activity-helper.sh` and two of its tests.

Consequence today: an operator who sets `AIDEVOPS_WORKER_BLOCKER_LOG_FILE` to relocate
the log moves the Node writer and the rotation cap, but `worker-activity-helper.sh`
keeps reading and appending at the default path — which then has no rotation owner
pointing at it and grows unbounded. This is the same unbounded-growth class that
GH#38621 just fixed, reachable through configuration instead of through a missing call.

## Tier

### Tier checklist

- [x] **Exact execution contract supplied?** Complete `oldString`/`newString` below.
- [x] **Targets and reference pattern verified?** Single line, verified at HEAD.
- [x] **No semantic or design decision remains?** Precedence order is decided below.
- [x] **Bounded, reversible, low-consequence impact?** One variable default; revert is the inverse edit.
- [x] **No stateful coordination to invent?** Single-line change, no shared state.
- [x] **Focused verification and rollback are explicit?** Commands supplied below.
- [x] **No dispatch-path risk override?** `worker-activity-helper.sh` is not in `.agents/configs/self-hosting-files.conf`; verify before dispatch and use `tier:thinking` if that is stale.

**Selected tier:** `tier:simple`

**Tier rationale:** Verbatim single-line replacement with decided precedence, focused verification and inverse rollback -> tier:simple.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/worker-activity-helper.sh:53` — chain the canonical env var into the default while preserving the legacy alias.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/worker-activity-helper.sh:421` (`local blocker_log="$WAH_BLOCKER_LOG_FILE"`), `:1104` (existence probe), `:1109` (`--log-file "$WAH_BLOCKER_LOG_FILE"` passed to `worker-blocker-log.mjs` as the highest-precedence `options.logPath`). All three read the variable set at line 53, so they inherit the fix with no further edits.
- **Writers/mutation paths:** the variable is assigned only at line 53; no other assignment exists in the file.
- **Existing verification/tests:** `.agents/scripts/tests/test-worker-activity-helper.sh` and `.agents/scripts/tests/test-worker-permission-helper.sh` set `WAH_BLOCKER_LOG_FILE`. The chosen precedence keeps the legacy name winning, so neither needs editing. **Pre-existing baseline (measured on the filing host at HEAD `0bf45cf74`, before any change): `test-worker-activity-helper.sh` reports 170 run / 2 failed — `1j: live count excludes unrelated processes` and `1l: live-workers counts only effective-UID workers`.** Both concern live-process counting and effective-UID filtering, are unrelated to blocker-log path resolution, and reproduce on a host where a second OS user runs their own aidevops install. Do not attempt to fix them in this task; compare against this 2-failure baseline rather than requiring a fully green suite.
- **Schemas/config:** N/A — no schema or config file encodes this variable name; verified by the usage search above.
- **Generated/deployed mirrors:** `~/.aidevops/agents/scripts/worker-activity-helper.sh` is the deployed mirror, refreshed by `setup.sh --non-interactive`; no commit needed.
- **Migrations/backfills:** N/A — environment-variable resolution only, no stored state.
- **Cleanup/rollback paths:** rollback is the inverse single-line edit; no artifacts are created.

### Implementation Steps

1. Apply the exact replacement in `.agents/scripts/worker-activity-helper.sh`.

oldString:

```bash
WAH_BLOCKER_LOG_FILE="${WAH_BLOCKER_LOG_FILE:-${HOME}/.aidevops/logs/worker-progress-blockers.jsonl}"
```

newString:

```bash
# Canonical name is AIDEVOPS_WORKER_BLOCKER_LOG_FILE (worker-blocker-log.mjs,
# pulse-logging.sh rotation cap). WAH_BLOCKER_LOG_FILE stays as a legacy alias
# and wins when both are set, so existing overrides keep working.
WAH_BLOCKER_LOG_FILE="${WAH_BLOCKER_LOG_FILE:-${AIDEVOPS_WORKER_BLOCKER_LOG_FILE:-${HOME}/.aidevops/logs/worker-progress-blockers.jsonl}}"
```

2. Run the verification commands below. Do not change the two tests that set the legacy variable; they must pass as-is.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — variable resolution at source time, no locking or shared write.
- **Migration/rollback:** no migration; rollback is the inverse edit.
- **Mixed-version/backward compatibility:** preserved deliberately. `WAH_BLOCKER_LOG_FILE` keeps first precedence, so any existing override and both existing tests behave exactly as before. Only the previously-ignored canonical variable gains effect.
- **Idempotency/retry:** the edit is idempotent; re-running the replacement is a no-op.
- **Partial failure/recovery:** single-line edit, no partial state possible.

### Complexity Impact

Not applicable: the change edits a top-level variable assignment, not a function body.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/worker-activity-helper.sh
bash .agents/scripts/tests/test-worker-activity-helper.sh
bash .agents/scripts/tests/test-worker-permission-helper.sh
AIDEVOPS_WORKER_BLOCKER_LOG_FILE=/tmp/canon.jsonl bash -c 'source .agents/scripts/worker-activity-helper.sh 2>/dev/null; printf "%s\n" "$WAH_BLOCKER_LOG_FILE"'
WAH_BLOCKER_LOG_FILE=/tmp/legacy.jsonl AIDEVOPS_WORKER_BLOCKER_LOG_FILE=/tmp/canon.jsonl bash -c 'source .agents/scripts/worker-activity-helper.sh 2>/dev/null; printf "%s\n" "$WAH_BLOCKER_LOG_FILE"'
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** `shellcheck` proves the edited line is syntactically valid; the two test scripts prove the legacy alias still wins (backward-compatibility hazard) — compare against the documented 2-failure baseline, not a green suite; the first `bash -c` proves the canonical variable now takes effect (the positive criterion); the second proves precedence when both are set; `linters-local.sh --changed` covers the changed-file gate. If sourcing the helper executes a command dispatcher, substitute an equivalent probe that prints the resolved value without side effects.
- **Broad verification trigger:** Not required — single-line change in one script, no shared contract, root tooling, or release infrastructure involved.

### Scope Boundaries

**Hard boundaries:** Do not rename or remove `WAH_BLOCKER_LOG_FILE`, and do not add the legacy name to `pulse-logging.sh` or any other component. Making rotation honour the legacy name would spread a deprecated alias into more files; the decided direction is that `AIDEVOPS_WORKER_BLOCKER_LOG_FILE` is the single supported control and the legacy name remains a local alias only. Setting only the legacy name therefore keeps today's behaviour, which is an accepted non-goal, not a bug to fix here.

**AI brief owner:** interactive session that filed this task.

### Files Scope

- `.agents/scripts/worker-activity-helper.sh`

## Acceptance Criteria

- [ ] `worker-activity-helper.sh` resolves the blocker-log path from `AIDEVOPS_WORKER_BLOCKER_LOG_FILE` when the legacy variable is unset

  ```yaml
  verify:
    method: codebase
    pattern: "AIDEVOPS_WORKER_BLOCKER_LOG_FILE"
    path: ".agents/scripts/worker-activity-helper.sh"
  ```

- [ ] The legacy alias still wins when both variables are set, so existing overrides are unaffected

  ```yaml
  verify:
    method: codebase
    pattern: "WAH_BLOCKER_LOG_FILE:-\\$\\{AIDEVOPS_WORKER_BLOCKER_LOG_FILE"
    path: ".agents/scripts/worker-activity-helper.sh"
  ```

- [ ] The legacy variable is not removed and the deprecated name is not spread to other components

  ```yaml
  verify:
    method: codebase
    pattern: "WAH_BLOCKER_LOG_FILE"
    path: ".agents/scripts/worker-activity-helper.sh"
  ```

- [ ] Changed-file lint is clean (`shellcheck` plus `linters-local.sh --changed`)

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/worker-activity-helper.sh"
  ```

## Context & Decisions

- Precedence chosen as legacy-then-canonical so the two existing tests and any operator override keep working without edits; the alternative (canonical wins) would silently change behaviour for anyone already setting the legacy name.
- Spreading the legacy name into `pulse-logging.sh` was considered and ruled out: it would make a deprecated alias load-bearing in more components.
- Discovered while verifying GH#38621, which added the rotation cap for this same file. Severity is latent, not live: with both variables unset the paths already agree.

## Relevant Files

- `.agents/scripts/worker-activity-helper.sh:53` — the line to change; `:421`, `:1104`, `:1109` consume it.
- `.agents/scripts/worker-blocker-log.mjs:69-73` — canonical resolution chain to match.
- `.agents/scripts/pulse-logging.sh:749` — rotation cap keyed on the canonical name (GH#38621).
- `.agents/scripts/tests/test-worker-activity-helper.sh` — sets the legacy name; must keep passing.
- `.agents/scripts/tests/test-worker-permission-helper.sh` — sets the legacy name; must keep passing.

## Dependencies

- **Blocked by:** nothing.
- **Blocks:** nothing; removes a latent unbounded-growth path reachable by configuration.
- **External:** none.
