---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18440: Correct retained release aggregation provenance

## Pre-flight

- [x] Memory recall: `release aggregation expected_sources retained lane exact manifest recovery` → 0 hits — no relevant lessons
- [x] Discovery pass: recent target-file commits and merged PRs #31957, #31958, and #31963 reviewed; no open duplicate PR found
- [x] File refs verified: `TODO.md`, this brief path, and the release controls history are present at `f34287f5401cb8068458f65736df5ee431a34476`
- [x] Tier: `tier:standard` — exact metadata is known, but immutable PR allocation and release-lane coordination are stateful
- [x] Seeded draft PR decision recorded: draft PR #31965 created from trailer-free commit `38e7b2e6cebfa340a88452c1e02242b765fe8c86`

## Origin

- **Created:** 2026-09-16
- **Session:** OpenCode interactive release recovery
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** None
- **Conversation context:** The authorized minor release for source PR #31958 remained tagless. Release provenance rejected merged aggregation PR #31963 because its manifest differed from the retained lane's immutable expected source set.

## What

Create a metadata-only draft PR from exact `main` tip `f34287f5401cb8068458f65736df5ee431a34476`. Push one trailer-free correction commit, allocate the PR number, then append one immutable final commit whose terminal trailer block identifies that PR and exactly the lane's two persisted sources.

## Why

The release lane authorizes exactly PR #31957 and PR #31958. Git ancestry proves that later repairs are present but cannot add release authority. Omitting #31957 or adding #31960 must remain a pre-publication failure, so a fresh reviewed exact-tip aggregate is required.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The exact source set and files are resolved, while PR-number allocation, exact-tip freshness, and immutable trailer sequencing require coordinated operations.

## Seeded Draft PR

- **Decision:** Created draft PR #31965 after the initial trailer-free commit
- **Rationale:** The allocated PR number is required by the final immutable aggregator identity.
- **Status:** `draft`
- **Freshness evidence:** Local HEAD and `origin/main` both resolved to `f34287f5401cb8068458f65736df5ee431a34476` before editing.
- **Verification run:** Initial commit `38e7b2e6cebfa340a88452c1e02242b765fe8c86` pushed with no recognized trailers; PR base/head identities verified through GitHub.
- **Stale-assumption warning:** If `main` advances before merge, keep this PR immutable and use the canonical aggregate refresh path.

## How (Approach)

### Files to Modify

- `EDIT: TODO.md` — track t18440 and its issue/PR references.
- `EDIT: .agents/reference/release-publication-controls/controls-and-history.md` — record the rejected manifest and corrected exact-tip aggregate.
- `NEW: todo/tasks/t18440-brief.md` — preserve the exact lane evidence and recovery contract.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/release-provenance-helper.sh` reads only the final squash commit trailers; operators read the control history and task brief.
- **Writers/mutation paths:** `.agents/scripts/full-loop-helper-merge.sh` writes the squash message from a validated body file; this session writes only the three scoped docs.
- **Tests/fixtures:** `.agents/scripts/linters-local.sh` plus brief readiness, required CI, review gate, and `git interpret-trailers --parse` verify this metadata-only checkpoint; no product fixtures exist.
- **Schemas/config:** N/A because this documentation-only correction does not change schema or configuration; the lane's persisted authorization remains immutable.
- **Generated/deployed mirrors:** N/A because no generated or deployed file is in scope; publication and deployment are explicitly outside this PR.
- **Migrations/backfills:** N/A because this documentation-only change adds one checkpoint without migration, backfill, or rewriting PR #31963.
- **Cleanup/rollback paths:** `.agents/reference/release-aggregation-recovery.md` defines stale aggregate refresh; otherwise close the draft before merge.

### Implementation Steps

1. Commit this correction without recognized release-aggregation trailers and create the draft PR.
2. Replace the pending issue/PR metadata with allocated identities without changing the exact branch base.
3. Add one final commit ending with exactly one aggregator identity plus these sources, in numeric order:

```text
Aidevops-Release-Aggregator-PR: <allocated-pr-number>
Aidevops-Release-Aggregates: 31957@94baff6cfa3c10cc84e67fd150bbe3c36e0c0a3d
Aidevops-Release-Aggregates: 31958@3be82399f6fb3e7a06899acefb43ac1bd0cd4a29
```

4. Push the immutable final head, run checks, and merge only with an identical terminal manifest in the squash body.

### Hazards and Compatibility

- **Concurrency/atomicity:** the exact `origin/main` base and immutable final PR head form the fence; any concurrent `main` merge makes this PR stale.
- **Migration/rollback:** there is no migration; before merge close the draft, and after staleness use aggregate refresh rather than history rewriting.
- **Mixed-version/backward compatibility:** the existing lane and PR #31963 remain readable; this PR only supplies the exact manifest required by the current resolver.
- **Idempotency/retry:** retries must observe or refresh this immutable PR; never amend, force-push, duplicate a source, or edit the lane.
- **Partial failure/recovery:** a stop before merge has no release side effects; a stop after merge resumes only through `aidevops release minor 31958 incremental` after revalidation.
- Do not include PR #31960, PR #31963, or the corrective aggregate itself in the source manifest.

### Verification Before Dispatch

```bash
bash .agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18440-brief.md
bash .agents/scripts/linters-local.sh --changed
git diff --check
git interpret-trailers --parse
```

- **Surface mapping:** brief readiness proves the canonical file/write/hazard contract; changed-file lint and `git diff --check` cover all three scoped docs; trailer parsing proves the final commit and squash manifests; required CI/review prove the exact remote head.
- **Broad verification trigger:** not required because the change is metadata-only and does not alter shared tooling, schemas, dependencies, or runtime behavior.

### Files Scope

- `TODO.md`
- `.agents/reference/release-publication-controls/controls-and-history.md`
- `todo/tasks/t18440-brief.md`

## Acceptance Criteria

- [ ] Draft PR is based on exact `main` tip `f34287f5401cb8068458f65736df5ee431a34476`.
- [ ] Initial correction commit contains no recognized aggregation trailers in its commit message.
- [ ] Final head has one immutable aggregator identity and exactly the two retained lane source entries.
- [ ] Required CI and review gate pass at the immutable final head.
- [ ] Squash message parses to the identical complete manifest at exact `origin/main` tip.
- [ ] The existing lane accepts `aidevops release minor 31958 incremental` without a manual lane edit, manual tag, override, or independent bump.

## Verification

Run the commands under **Verification Before Dispatch**, then use the guarded PR checks and merge helper with an exact body file.

## Rollback

Before merge, close the draft and delete its branch. After any intervening `main` merge, preserve this immutable PR and use `aidevops release refresh-aggregate`; never rewrite reviewed history.
