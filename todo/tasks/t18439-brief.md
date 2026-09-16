---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18439: Aggregate PR #31958 and PR #31960 release provenance

## Pre-flight

- [x] Memory recall: `aidevops release workflow version bump GH31945 PR31958` → 0 hits — no relevant lessons
- [x] Discovery pass: reviewed aggregation PR #29545 and current release controls; no duplicate open task found
- [x] File refs verified: 2 refs checked, both present at `e66fb1aeb41c5b765e7597dac4fb45563224bfaf`
- [x] Tier: `tier:standard` — exact metadata contract is known, but release-lane coordination is stateful
- [x] Seeded draft PR decision recorded: create a draft after the initial trailer-free documentation commit

## Origin

- **Created:** 2026-09-16
- **Session:** OpenCode interactive release recovery
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** t18438 / GH#31959
- **Conversation context:** The authorized PR #31958 minor release failed before tagging. PR #31960 repaired the preflight but advanced `main`, requiring reviewed exact-tip aggregation.

## What

Create a metadata-only draft PR at exact `main` tip `e66fb1aeb41c5b765e7597dac4fb45563224bfaf`. Its initial documentation commit must contain no recognized aggregation trailer. After GitHub allocates the PR number, add one final commit with a contiguous trailer block covering both otherwise-unreleased sources.

## Why

The fenced tagless recovery correctly rejects an arbitrary descendant of PR #31958. A reviewed aggregate is the only supported path that can expand authorization without manually editing the lane or inventing provenance.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The files and immutable source manifest are exact, but publication provenance and exact-tip fencing make the work stateful and consequential.

## Seeded Draft PR

- **Decision:** Create after the initial documentation commit
- **Rationale:** The PR number is required for the immutable aggregator trailer.
- **Status:** `not-created`
- **Freshness evidence:** `origin/main` and canonical `main` both resolved to `e66fb1aeb41c5b765e7597dac4fb45563224bfaf` before worktree creation.
- **Verification run:** Pending initial commit and draft creation.
- **Stale-assumption warning:** Any intervening `main` merge requires `aidevops release refresh-aggregate` rather than rewriting this branch.

### Files to Modify

- `EDIT: TODO.md` — track the interactive aggregation task and its GitHub reference.
- `EDIT: .agents/reference/release-publication-controls/controls-and-history.md` — record the exact-tip reviewed aggregation.
- `NEW: todo/tasks/t18439-brief.md` — preserve the immutable recovery contract and verification evidence.

### Complete Write Surface

- **Callers/readers:** release provenance resolver reads the squash commit trailers; operators read the release controls history.
- **Writers/mutation paths:** this interactive session writes the two planning/docs files; the canonical merge helper creates the squash commit.
- **Existing verification/tests:** changed-file lint, required CI, review-bot gate, `git interpret-trailers --parse`, and the release provenance resolver.
- **Schemas/config:** N/A — no schema or configuration changes; evidence is commit metadata.
- **Generated/deployed mirrors:** N/A — no generated or deployed file changes.
- **Migrations/backfills:** N/A — one exact-tip metadata checkpoint only.
- **Cleanup/rollback paths:** close the draft before merge; after an intervening merge use `aidevops release refresh-aggregate` rather than rewriting history.

## Reference pattern

Model on aggregation PR #29545 and `.agents/reference/release-publication-controls/controls-and-history.md` under “Intervening-main recovery.” The initial commit carries documentation only. The final branch commit carries exactly:

```text
Aidevops-Release-Aggregator-PR: <allocated-pr-number>
Aidevops-Release-Aggregates: 31958@3be82399f6fb3e7a06899acefb43ac1bd0cd4a29
Aidevops-Release-Aggregates: 31960@e66fb1aeb41c5b765e7597dac4fb45563224bfaf
```

## Acceptance Criteria

- [ ] Draft PR is based on exact `main` tip `e66fb1aeb41c5b765e7597dac4fb45563224bfaf`.
- [ ] No recognized aggregation trailer appears before the final branch commit.
- [ ] Final commit has one aggregator identity and one entry for each authorized source.
- [ ] Required CI and review gate pass before squash merge.
- [ ] Squash message parses to the same complete manifest at exact `origin/main` tip.
- [ ] `aidevops release minor 31958 incremental` resumes the existing lane; no manual tag or second independent bump occurs.

## Verification

```bash
bash .agents/scripts/linters-local.sh --changed
git interpret-trailers --parse
aidevops release minor 31958 incremental
```

## Rollback

Before merge, close the draft and delete its branch. If `main` advances, use the canonical refresh-aggregate command; never amend, force-push, or reuse the stale aggregator identity.
