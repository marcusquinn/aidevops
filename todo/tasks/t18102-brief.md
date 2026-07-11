<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18102: Deploy CLI, agents, and plugins as one atomic version bundle

## Pre-flight

- [x] Memory recall: `atomic deploy CLI agents version mismatch` → no relevant memories returned.
- [x] Discovery pass: recent agent deploy and auto-update commits reviewed; no matching open issue/PR.
- [x] File refs verified: auto-update and setup deploy modules exist at HEAD.
- [x] Tier: `tier:thinking` — atomic rollout and rollback span installer/runtime boundaries.
- [x] Seeded draft PR decision recorded: skipped — bundle layout and compatibility window require design judgment.

## Origin

- **Created:** 2026-07-11
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** During a batch dispatch the deployed agents changed versions while the CLI remained older. The running command recalculated an invalid nested scripts path and dropped the remaining dispatches.

## What

Deploy the CLI, agents, plugins, generated runtime config, and version metadata as one validated bundle switched atomically, with rollback to the prior complete bundle on failure.

## Why

Hot updates currently expose mixed-version states to long-running pulse and interactive processes. A partial update can break command paths in the middle of a batch and leave work silently unstarted.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires transactional filesystem design, process compatibility, rollback, and cross-platform tests.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The safest versioned-directory/symlink or manifest approach must be selected after tracing current installers.
- **Status:** not-created
- **Freshness evidence:** Current update and deploy module paths verified at HEAD.
- **Verification run:** UNVERIFIED — issue composition only.
- **Stale-assumption warning:** Re-check any task-coordinator or setup changes merged after filing.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/auto-update-helper.sh` — stage, validate, atomically activate, and roll back complete bundles.
- `EDIT: .agents/scripts/setup/modules/agent-deploy.sh` — deploy into a versioned staging target rather than mutating live files piecemeal.
- `EDIT: .agents/scripts/setup/modules/plugins.sh` — bind plugin generation/activation to the same bundle manifest.
- `EDIT: .agents/scripts/setup/modules/agent-runtime.sh` — resolve one immutable bundle root per process/session.
- `NEW/EDIT: .agents/scripts/tests/test-atomic-runtime-bundle-deploy.sh` — interrupted deploy, mixed-version prevention, active process, and rollback fixtures.

### Implementation Steps

1. Trace every file/runtime path changed by update and setup.
2. Define a bundle manifest containing framework, CLI compatibility, agents, plugin/config generation, and integrity evidence.
3. Stage and validate the complete bundle before one atomic activation operation.
4. Pin each running pulse/worker/interactive command to its resolved bundle root for its lifetime.
5. Retain a bounded previous bundle and roll back automatically on validation or activation failure.
6. Test interruption after every stage and ensure no command observes a partially activated tree.
7. Create a WIP commit after focused transactional tests pass.

### Verification

```bash
bash .agents/scripts/tests/test-atomic-runtime-bundle-deploy.sh
bash .agents/scripts/tests/test-agent-deploy-staging.sh
bash .agents/scripts/tests/test-agent-auto-sync.sh
bash .agents/scripts/tests/test-setup-scoped-dispatch.sh
shellcheck .agents/scripts/auto-update-helper.sh .agents/scripts/setup/modules/agent-deploy.sh .agents/scripts/setup/modules/plugins.sh .agents/scripts/setup/modules/agent-runtime.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] No process can resolve CLI, agents, or plugins from different activated bundle versions.
- [ ] Interrupted staging leaves the active bundle unchanged.
- [ ] Failed activation automatically returns to the last validated bundle.
- [ ] Long-running workers continue using their original immutable bundle root.
- [ ] macOS and Linux activation paths are covered.
- [ ] Focused tests and lint pass.

## Recovery Checkpoint

Before broad setup tests, push the manifest/activation fixtures and document the rollback command and active-bundle resolution contract.
