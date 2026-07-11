<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18098: Prevent worktree infrastructure markers from breaking worker ownership transfer

## Pre-flight

- [x] Memory recall: `worktree ownership metadata marker` → no relevant memories returned; direct incident evidence retained in the originating session.
- [x] Discovery pass: no matching open issue/PR; recent worktree/runtime changes reviewed.
- [x] File refs verified: `worktree-exclusions-helper.sh`, `worktree-helper-add.sh`, `headless-runtime-worker.sh`, and focused worktree tests exist at HEAD.
- [x] Tier: `tier:thinking` — cross-lifecycle safety semantics and recovery behavior span more than two files.
- [x] Seeded draft PR decision recorded: skipped — the correct marker-storage contract requires implementation judgment.

## Origin

- **Created:** 2026-07-11
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** Two manual worker launches failed because macOS exclusion setup created an unignored `.metadata_never_index`, making a dispatcher-precreated worktree dirty before ownership transfer. Exit recovery then committed the marker and opened duplicate PRs containing only that file.

## What

Make OS indexing/backup exclusions compatible with the clean-worktree ownership contract so infrastructure metadata can never block worker startup, become a WIP commit, or generate a recovery PR.

## Why

One local-only marker caused two failed launches, two duplicate PRs, wasted CI, and a false impression that the implementation issue lacked a worker. This class of metadata must be invisible to task Git state by construction.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The worker must choose between out-of-tree metadata, repository-local excludes, or a narrowly proven cleanliness exemption without weakening dirty-work preservation.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Multiple safe designs exist; tests must prove no real task edit is ignored.
- **Status:** not-created
- **Freshness evidence:** Incident reproduced against current deployed/runtime paths and target files verified at HEAD.
- **Verification run:** UNVERIFIED — issue composition only.
- **Stale-assumption warning:** Re-check whether newer worktree code already relocated or ignores the marker.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/worktree-exclusions-helper.sh` — prevent exclusion artifacts from appearing as task changes.
- `EDIT: .agents/scripts/worktree-helper-add.sh` — preserve exclusion behavior without dirtying a fresh worktree.
- `EDIT: .agents/scripts/headless-runtime-worker.sh` — retain fail-closed ownership transfer for genuine changes and avoid recovery PRs for verified infrastructure-only state.
- `NEW/EDIT: .agents/scripts/tests/test-worktree-exclusion-owner-transfer.sh` — reproduce macOS marker creation through launch readiness and abnormal-exit recovery.

### Implementation Steps

1. Reproduce the clean-worktree → exclusion application → ownership transfer sequence with a fixture.
2. Select one canonical contract that keeps exclusion metadata outside tracked task state or makes it ignored before creation.
3. Keep `git status` cleanliness strict for every non-infrastructure path; do not broadly ignore dotfiles or untracked files.
4. Ensure abnormal exit cannot commit/push an exclusion marker or create a PR when no task work exists.
5. Cover reused worktrees and non-macOS no-op behavior.
6. Create a WIP commit after focused tests pass, then run broad shell/framework gates.

### Verification

```bash
bash .agents/scripts/tests/test-worktree-exclusion-owner-transfer.sh
bash .agents/scripts/tests/test-worktree-registry-session-claim.sh
bash .agents/scripts/tests/test-dispatch-single-issue-helper.sh
shellcheck .agents/scripts/worktree-exclusions-helper.sh .agents/scripts/worktree-helper-add.sh .agents/scripts/headless-runtime-worker.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] A fresh macOS worker worktree remains clean through exclusion setup and ownership transfer.
- [ ] Genuine dirty task state still blocks unsafe ownership takeover.
- [ ] Infrastructure-only markers never produce commits, pushes, or recovery PRs.
- [ ] Reused worktrees and Linux behavior retain current safety semantics.
- [ ] Focused tests and repository lint pass.

## Recovery Checkpoint

If broad gates or runtime limits interrupt work, push a focused-test-passing WIP commit and record the selected marker contract, remaining platforms, and next verification command.
