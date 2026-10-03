<!-- aidevops:brief-schema=v2 -->

# t18497: Finish shallow counter fetches and discovery timeout guidance

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Backfill the stranded publication for #32692. PR #32963 already shallowed both discovery fetches; this brief covers only remaining work.

## What

Audit the other fetches in `.agents/scripts/claim-task-id-counter.sh` and use `--depth=1` only where the tip's file is the sole input. Include `CAS_HTTPS_TIMEOUT_S` in the `COUNTER_BRANCH_DISCOVERY_ERROR` diagnostic. Do not reimplement #32963.

## Why

#32692 observed `fetch_rc=124` under the default 30-second timeout; longer timeout succeeded. Full-history fetches where history is not used waste the timeout budget. The initial two discovery fetches were fixed by #32963, but other fetches and the discovery diagnostic remain.

## Tier

**Selected tier:** `tier:standard`

The remaining fetches require classifying CAS push/rebase history use before changing transport behavior.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/claim-task-id-counter.sh` — inspect fetches near lines 839, 894, 1103-1112, 1192-1211 and 1281-1315; shallow only tip-only reads. Include timeout hint near line 510.
- `EDIT: .agents/scripts/tests/test-claim-task-id-no-orphan.sh` — cover safe shallow-fetch selection and the discovery diagnostic when practical using existing fixtures.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/claim-task-id.sh` invokes the counter helpers and consumes their result/diagnostics; do not change the claim CLI contract.
- **Writers/mutation paths:** `.agents/scripts/claim-task-id-counter.sh` fetches into isolated refs and CAS pushes the remote counter branch. Keep history-dependent CAS/rebase inputs intact.
- **Existing verification/tests:** `test-claim-task-id-no-orphan.sh`, other `test-claim-task-id-*.sh` scripts and a linked-worktree dry run.
- **Schemas/config:** `CAS_HTTPS_TIMEOUT_S` already exists (default 30); no new setting.
- **Generated/deployed mirrors:** `setup.sh` copies the source script for deployment; edit the repository copy only.
- **Migrations/backfills:** N/A because fetched refs are transient and no stored format changes.
- **Cleanup/rollback paths:** `git revert` restores previous fetch flags and diagnostic; no persisted data migration.

### Implementation Steps

1. Confirm #32963's shallow discovery fetches remain; inspect each remaining fetch's downstream `show`, CAS push and rebase usage.
2. Add `--depth=1` only where neither ancestry nor CAS/rebase history is required.
3. Add `CAS_HTTPS_TIMEOUT_S=${CAS_HTTPS_TIMEOUT_S:-30}` to the discovery error; run targeted tests and a default-timeout dry run.

### Hazards and Compatibility

- **Concurrency/atomicity:** CAS retry still checks remote changes; never shallow a ref required for ancestry comparisons or pushes.
- **Migration/rollback:** no persistent migration; revert is sufficient.
- **Mixed-version/backward compatibility:** preserve the claim command's output and counter monotonicity.
- **Idempotency/retry:** repeated fetches must still resolve the same remote tip.
- **Partial failure/recovery:** timeout errors continue to fail closed with actionable budget hint.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/claim-task-id-counter.sh
bash .agents/scripts/tests/test-claim-task-id-no-orphan.sh
for t in .agents/scripts/tests/test-claim-task-id-*.sh; do bash "$t"; done
.agents/scripts/claim-task-id.sh --dry-run --title x
```

- **Surface mapping:** shellcheck and claim tests cover fetch flags, retry and diagnostic behavior; the dry run checks the real default timeout from a linked worktree.
- **Broad verification trigger:** none; no shared configuration or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:** do not rewrite #32963's fix or shallow history-dependent CAS/rebase fetches. Do not allocate a replacement task ID.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve any PR and use the structured runtime/Pulse intake if the scope must expand.

### Files Scope

- `.agents/scripts/claim-task-id-counter.sh`
- `.agents/scripts/tests/test-claim-task-id-no-orphan.sh`

## Acceptance Criteria

- [ ] The remaining tip-only fetches are shallow and the discovery failure names `CAS_HTTPS_TIMEOUT_S`.

  ```yaml
  verify:
    method: codebase
    pattern: "CAS_HTTPS_TIMEOUT_S"
    path: ".agents/scripts/claim-task-id-counter.sh"
  ```

- [ ] Negative/regression: CAS contention, monotonicity and implicit migration continue to pass without shallowing history-dependent fetches.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-no-orphan.sh"
  ```

- [ ] Changed-file lint and the default-timeout linked-worktree dry run pass.

## Context & Decisions

- #32963 already fixed the two discovery fetches; keep this follow-up narrow rather than claiming they still need repair.

## Relevant Files

- `.agents/scripts/claim-task-id-counter.sh` — remaining fetch sites and discovery diagnostic.
- `.agents/scripts/tests/test-claim-task-id-no-orphan.sh` — existing isolated claim checks.
