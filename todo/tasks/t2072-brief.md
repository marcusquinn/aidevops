<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2072: Decompose higgsfield video/image plugin cluster (higgsfield-video.mjs, higgsfield-image.mjs, higgsfield-api.mjs, higgsfield-common.mjs)

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** The higgsfield plugin cluster accounts for ~12 smells across four files. It's the largest remaining subsystem smell source after the IMAP adapters, opencode plugins, and oauth-pool. The top complexity functions here are `downloadVideoFromApiData` (26), `generateLipsync` (21), `matchJobSetsToSubmittedJobs` (25), `downloadMatchedVideos` (23), `waitForImageGeneration` (29), `apiRequest` (22), `diffRoutesAgainstCache` (18).

## What

Decompose `.agents/scripts/higgsfield/*.mjs` (4 files: `higgsfield-video.mjs`, `higgsfield-image.mjs`, `higgsfield-api.mjs`, `higgsfield-common.mjs`) so that no function exceeds cyclomatic 15 and no file carries a qlty smell.

## Why

- Top file-complexity counts in the repo:
  - `higgsfield-video.mjs` — 322 total (5 smells)
  - `higgsfield-common.mjs` — 289 total (3 smells)
  - `higgsfield-image.mjs` — 113 total (2 smells)
  - `higgsfield-api.mjs` — 113 total (2 smells)
- ~12 smells removed = ~11% progress toward A.
- This cluster is also a self-contained subsystem — changes here don't ripple into the core pulse code — which makes it a low-risk target for an Opus refactor.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Multi-file cluster, async video/image generation workflows, job-matching logic that's easy to break subtly. Opus-tier.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# Smell breakdown per file
for f in higgsfield-video higgsfield-image higgsfield-api higgsfield-common; do
  echo "=== $f ==="
  ~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
    | jq -r --arg f ".agents/scripts/higgsfield/$f.mjs" \
      '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == $f) | "\(.ruleId)\t\(.message.text)\t\(.locations[0].physicalLocation.region.startLine)"'
done

# Callers of higgsfield
rg -l "higgsfield/" .agents/ --type sh --type js --type py
```

### Files to Modify

- `EDIT: .agents/scripts/higgsfield/higgsfield-video.mjs`
- `EDIT: .agents/scripts/higgsfield/higgsfield-image.mjs`
- `EDIT: .agents/scripts/higgsfield/higgsfield-api.mjs`
- `EDIT: .agents/scripts/higgsfield/higgsfield-common.mjs`
- `NEW: helper sibling files as needed (video-download.mjs, image-polling.mjs, api-retry.mjs, etc.)`
- `EDIT: .agents/scripts/higgsfield/higgsfield-commands.mjs` (if it imports the internals)

### Implementation Steps

1. **Read all 4 files end to end.** Budget 2h. These files describe a video/image generation pipeline with polling, retry, and multi-job matching — understanding the data flow is essential before any extraction.

2. **Target complexity hotspots** in order of impact:
   - `waitForImageGeneration` (29) — a polling loop with timeout and status transitions. Extract each status handler.
   - `downloadVideoFromApiData` (26) — HTTP + filesystem + format branching. Extract per-format handlers.
   - `matchJobSetsToSubmittedJobs` (25) — set-theoretic matching. Extract the match predicate into a pure function, the iteration into a helper.
   - `downloadMatchedVideos` (23) — parallel download orchestration. Extract the per-video download into a helper.
   - `apiRequest` (22) — generic HTTP wrapper with retry. Extract retry policy into `_retry.mjs`.
   - `generateLipsync` (21) — pipeline coordination. Extract each stage.
   - `diffRoutesAgainstCache` (18) — cache diff logic. Straightforward extraction.

3. **Extract shared helpers to `higgsfield-common.mjs`** — polling loop abstraction, retry wrapper, download abstraction. Common should become a utilities module, not a catch-all.

4. **Preserve public API.** `higgsfield-commands.mjs` is the CLI entrypoint; it must continue to work unchanged.

5. **Characterisation tests** — at minimum, mock the higgsfield API (or snapshot real responses) and verify that `waitForImageGeneration`, `downloadVideoFromApiData`, and `matchJobSetsToSubmittedJobs` produce the same outputs pre and post-refactor.

### Verification

```bash
# Zero smells across cluster
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("higgsfield/"))] | length'
# Expected: 0

# Cluster still imports
cd .agents/scripts/higgsfield && node -e "import('./higgsfield-commands.mjs').then(() => console.log('ok'))"
```

## Acceptance Criteria

- [ ] Zero qlty smells on any file matching `higgsfield/`
- [ ] No function in the cluster exceeds cyclomatic 15
- [ ] `higgsfield-commands.mjs` public CLI unchanged
- [ ] Characterisation tests added and passing
- [ ] Repo-wide total smell count drops by at least 10

## Context & Decisions

- **Don't merge the 4 files.** They represent a natural subsystem boundary (video/image/api/common) and merging would trade one smell set for another.
- **Don't change the higgsfield API wire protocol.** Whatever HTTP calls the current code makes, the refactored code must make identical calls.

## Relevant Files

- `.agents/scripts/higgsfield/higgsfield-commands.mjs` — public CLI entrypoint (do not change behaviour)
- `.agents/scripts/higgsfield/README.md` (if exists)

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** higgsfield API credentials only needed if running live integration tests; mock/snapshot responses preferred

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 2h | Four files end-to-end + data-flow mapping |
| Characterisation tests | 1.5h | Mock API + snapshot test |
| Implementation | 4h | Cluster-wide refactor |
| Testing | 1h | Rerun + smoke |
| **Total** | **~8.5h** | |
