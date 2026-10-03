<!-- aidevops:brief-schema=v2 -->

# t18504: Preserve concurrent TODO changes during planning publication

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Backfill the stranded brief for #32714 after #32705 silently removed lines merged by #32690.

## What

Merge the publisher's file snapshot with concurrent parent changes instead of replacing the entire TODO blob. Fail closed on genuine conflicts.

## Why

The snapshot writer hashes a whole local TODO.md; `_planning_publish_build_index` inserts that blob into an index based on the fresh parent. #32705 consequently removed t18496/t18497 even though its base already contained them.

## Tier

**Selected tier:** `tier:standard`

The change alters snapshot/index plumbing and receipt consistency under concurrency.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/planning-publisher.sh` — record origin blob alongside snapshot; 3-way merge when new parent differs, verify receipt against actual merged blob.
- `EDIT: .agents/scripts/tests/test-planning-publisher.sh` — cover unrelated parent additions and true same-line conflict using current fixture machinery.

### Complete Write Surface

- **Callers/readers:** planning publish invokes `_planning_publish_snapshot`, `_planning_publish_build_index` and `_planning_publish_verify_index`; receipt readers rely on the final digest.
- **Writers/mutation paths:** `.agents/scripts/planning-publisher.sh` writes Git blobs/index and planning PR commits; never overwrite parent data on conflict.
- **Existing verification/tests:** `test-planning-publisher.sh` covers receipt, digest and retry behavior.
- **Schemas/config:** `.agents/scripts/planning-publisher.sh` snapshot metadata needs its origin blob; preserve compatibility or fail closed for older incomplete snapshots.
- **Generated/deployed mirrors:** `setup.sh` deploys this source; no generated source edits.
- **Migrations/backfills:** `.agents/scripts/planning-publisher.sh` must handle existing snapshots safely on retry; no repository schema migration.
- **Cleanup/rollback paths:** `git revert` restores prior behavior; reattempt conflicted planning publications from a fresh snapshot, not a forced overwrite.

### Implementation Steps

1. Store each path's origin blob at snapshot creation along with its new blob.
2. In `_planning_publish_build_index`, compare origin to parent; use `git merge-file -p --diff3` for divergence, and abort on conflict before publishing.
3. Bind receipt and read-only verification to the resulting merged blob, then replay #32705's base and run tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** build a candidate index; publish only after all merges succeed.
- **Migration/rollback:** reject incomplete legacy metadata rather than silently dropping parent lines.
- **Mixed-version/backward compatibility:** preserve stable receipt interpretation or explicitly version the snapshot format.
- **Idempotency/retry:** repeated publication of the same resolved snapshot produces the same digest.
- **Partial failure/recovery:** conflict reports retry guidance without pushing a destructive commit.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/planning-publisher.sh
bash .agents/scripts/tests/test-planning-publisher.sh
```

- **Surface mapping:** publisher tests exercise index merge, same-line conflict, receipt and idempotent retry. Replay the #32705 snapshot on parent `923ec107d` to verify t18496/t18497 survive.
- **Broad verification trigger:** none; no root build or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:** never silently drop a concurrent TODO line or publish a conflicted snapshot. Do not change unrelated publication/dispatch gates.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve any PR and use the structured runtime/Pulse intake if scope expansion is required.

### Files Scope

- `.agents/scripts/planning-publisher.sh`
- `.agents/scripts/tests/test-planning-publisher.sh`

## Acceptance Criteria

- [ ] Parent additions remain alongside the publisher's own additions.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-planning-publisher.sh"
  ```

- [ ] Negative/regression: same-line conflicts abort without writing, and existing receipt/digest/retry checks pass.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-planning-publisher.sh"
  ```

- [ ] `shellcheck .agents/scripts/planning-publisher.sh` passes.

## Context & Decisions

- A 3-way blob merge is preferable to whole-file replacement because TODO.md is shared across planning sessions.

## Relevant Files

- `.agents/scripts/planning-publisher.sh` — snapshot, index and verification helpers.
- `.agents/scripts/tests/test-planning-publisher.sh` — publication regression checks.
