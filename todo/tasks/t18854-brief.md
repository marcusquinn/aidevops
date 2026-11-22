<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Local SEO: geogrid metric definitions and cost-efficient grid collection (SEO Utils, DataForSEO, SerpApi)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `local SEO skills import subagent google business profile` → 0 hits — preference stored this session: SEO Utils over Local Falcon; DataForSEO/direct APIs for source data
- [x] Discovery pass: 1 commit (a528f2ffce, unrelated) / 0 merged PRs / 0 open PRs touch target files
- [x] File refs verified: 6 refs checked, all present at HEAD 83ee6cd5f0
- [x] Tier: `tier:standard` — docs with API-fact verification; no code or trust boundary
- [x] Seeded draft PR decision recorded: skipped — provider endpoint details must be verified live by the worker

## Origin

- **Created:** 2026-11-02
- **Session:** opencode:ses_e631bdc7cffe2C1iEoG8vJ7bBC
- **Created by:** ai-interactive (Build+), approved by maintainer
- **Parent task:** local SEO capability roadmap (see `Parent:` line on the issue)
- **Blocked by:** none
- **Conversation context:** A reviewed third-party local SEO skill pack defined geogrid metrics incorrectly (ATRP as "average of top 3 positions", SoLV as "any appearance") and routed grid scans to paid vendors. The maintainer uses SEO Utils instead of Local Falcon and prefers DataForSEO or direct APIs for cost-efficient tracking.

## What

Documentation that lets agents collect, compute and interpret map-pack geogrid data without a dedicated paid grid vendor:

1. `.agents/seo/seo-utils.md` gains a **Geogrid metrics** section: our own explicit definitions, required scan metadata, and interpretation guardrails. Prefer SEO Utils' stored GMB grid values (`google_business_*` tables) when present; record which definition a number uses.
2. `.agents/seo/dataforseo.md` gains a **Local pack / Maps grid collection** recipe: one Maps SERP task per grid point using a coordinate location parameter, cost estimate before running, and standard-queue vs live trade-off.
3. `.agents/seo/serpapi.md` gains a one-paragraph `google_maps` coordinate recipe as the alternative.

Definitions to document (cutoff `C` = deepest rank checked, e.g. 20; `N` = all grid points; "found" = business present within `C`):

- **ARP (average rank position)** = sum of found ranks / number of found points.
- **ATRP (average total rank position)** = (sum of found ranks + (C+1) × not-found points) / N.
- **SoLV (share of local voice)** = 100 × points ranked 1-3 / N.
- **Found rate** = 100 × found points / N (separate metric; never call it SoLV).

Note that ARP/ATRP/SoLV names come from Local Falcon; state that parity with any vendor's numbers must be checked against that vendor's current docs before comparing reports.

## Why

SEO Utils already stores grids (`.agents/seo/seo-utils.md:27,60`) and spends DataForSEO credits for runs (`:84`), but nothing defines the metrics or a vendor-neutral collection recipe. Without this, agents copy vendor definitions or paid-tool routing from third-party skill packs.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No — endpoint parameters need live verification.
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** Exact provider parameter syntax remains to confirm.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** Docs with resolved definitions but provider API facts that must be verified from primary docs → tier:standard.

## PR Conventions

Leaf task: PR body uses `Resolves #<this issue>` and `For #<parent issue>`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Provider parameter syntax and pricing must come from current docs, not this brief.
- **Status:** `not-created`
- **Freshness evidence:** file verification at HEAD 83ee6cd5f0
- **Verification run:** `UNVERIFIED — not run`
- **Stale-assumption warning:** DataForSEO/SerpApi parameter names may have changed; trust the live docs.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/seo/seo-utils.md:20-90` — where GMB grid data lives, spend rules (`:84`), destructive deletes (`:82`).
- **Read first:** `.agents/seo/dataforseo.md` (whole file is short) — existing section style and credential handling.
- **Load only if:** Context7 or the provider's official docs for DataForSEO SERP Google Maps / Local Finder and SerpApi Google Maps — to confirm the coordinate parameter format and pricing unit.
- **Why:** correct parameter syntax and cost estimation.
- **Stop when:** coordinate format, task endpoint, queue options and price unit are confirmed.

### Files to Modify

- `EDIT: .agents/seo/seo-utils.md` — add `## Geogrid metrics` after the "Local data before lookups" section (line 51); include definitions above, required metadata (keyword, business identifier, centre lat/lng, grid size, spacing/radius, platform, device, language, cutoff C, timestamp, provider), and guardrails below
- `EDIT: .agents/seo/dataforseo.md` — add `## Local pack / Maps grid collection` recipe
- `EDIT: .agents/seo/serpapi.md:19` — add a short `google_maps` coordinate grid note near the engines line

Guardrails to include verbatim in spirit:

- Compare scans only when grid geometry, keyword, device, language and cutoff match.
- Grid points are sample locations, not customers or audience share.
- A single scan is a snapshot; treat 1-2 position moves as noise unless repeated.
- Movement does not prove cause; attribute only with dated change logs.
- Estimate cost as points × keywords × price-per-task and ask before spending (matches `seo-utils.md:84`).
- Never route grid tracking to a paid vendor by default; SEO Utils first if installed, else DataForSEO standard queue, else SerpApi.

### Complete Write Surface

- **Callers/readers:** `seo.md:71` lists `seo-utils` and `dataforseo` as data providers; the local SEO leaf (sibling child) will link here.
- **Writers/mutation paths:** documentation only; no script writes these files. Searched `rg -l "seo-utils.md" .agents/scripts` for generators.
- **Existing verification/tests:** `linters-local.sh --changed` (markdownlint); no tests cover these docs.
- **Schemas/config:** N/A because this is documentation-only; no MCP config change in `configs/`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/` to `~/.aidevops/agents/`; `subagent-index.toon` unchanged because no new file.
- **Migrations/backfills:** N/A because this is documentation-only with no existing data.
- **Cleanup/rollback paths:** revert the PR; N/A because documentation-only work leaves no state outside git.

### Implementation Steps

1. Confirm DataForSEO Maps/Local Finder coordinate parameter format, endpoints and price unit from official docs (Context7 or the docs site); same for SerpApi `google_maps` (`ll` parameter). Cite only URLs actually opened.
2. Add the three sections. Include one worked example: a 7×7 grid (49 points), 3 keywords = 147 tasks; show the cost formula with a placeholder price, not a hardcoded figure.
3. Add a one-line pointer from the `seo-utils.md` Geogrid section to the DataForSEO recipe for users without SEO Utils.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — docs; sibling local-SEO leaf creates a different file. Rebase if `seo-utils.md` changed meanwhile.
- **Migration/rollback:** revert-only.
- **Mixed-version/backward compatibility:** existing SEO Utils and DataForSEO guidance unchanged; sections are additive.
- **Idempotency/retry:** N/A — docs.
- **Partial failure/recovery:** if a provider parameter cannot be verified, document it as "verify before use" rather than guessing.

### Verification Before Dispatch

```bash
rg -n "## Geogrid metrics|ATRP|SoLV" .agents/seo/seo-utils.md
rg -n "Maps grid" .agents/seo/dataforseo.md
rg -n "google_maps" .agents/seo/serpapi.md
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** first three commands prove each file gained its section; linter proves markdown quality.
- **Broad verification trigger:** Not required — no shared tooling change.

### Scope Boundaries

**Hard boundaries:** documentation only; no new helper scripts, no vendor adapters (no Local Falcon, LocalSEOData or LSA Spy integration), no live paid API calls during implementation.

**AI brief owner:** maintainer interactive session (marcusquinn).

**Recovery:** preserve the current PR and use `reference/worker-discipline.md` runtime request when local recovery is unsafe.

### Files Scope

- `.agents/seo/seo-utils.md`
- `.agents/seo/dataforseo.md`
- `.agents/seo/serpapi.md`

## Acceptance Criteria

- [ ] `seo-utils.md` defines ARP, ATRP (with not-found = C+1) and SoLV (top-3 share) with formulas and required scan metadata.

  ```yaml
  verify:
    method: codebase
    pattern: "SoLV"
    path: ".agents/seo/seo-utils.md"
  ```

- [ ] `dataforseo.md` contains a Maps grid collection recipe with a cost formula.

  ```yaml
  verify:
    method: codebase
    pattern: "Maps grid"
    path: ".agents/seo/dataforseo.md"
  ```

- [ ] Negative: no doc routes grid tracking to Local Falcon, LocalSEOData or another paid grid vendor by default, and SoLV is never described as a percentage of customers.

  ```yaml
  verify:
    method: subagent
    prompt: "Do .agents/seo/seo-utils.md, dataforseo.md or serpapi.md route geogrid tracking to a paid grid vendor by default, or describe SoLV/grid coverage as a share of customers or audience? PASS only if neither."
    files: ".agents/seo/seo-utils.md,.agents/seo/dataforseo.md,.agents/seo/serpapi.md"
  ```

- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Maintainer: "we tend to use seoutils.app as an alternative to localfalcon, and direct apis or our dataforseo or other similar api tools for more cost-efficient source data to track and compare".
- Third-party definitions rejected: ATRP as top-3 average; SoLV as any appearance; grid % translated into customers.
- Ruled out: a metric-computation script (add later only if repeated manual computation is evidenced).

## Relevant Files

- `.agents/seo/seo-utils.md:27` — GMB grids in the SEO Utils database
- `.agents/seo/seo-utils.md:60` — `google_business_*` tables for grids/reviews
- `.agents/seo/seo-utils.md:84` — spend rules for `run_gmb_rank_tracker`
- `.agents/seo/dataforseo.md:37` — existing `BUSINESS_DATA` module row
- `.agents/seo/serpapi.md:19` — engines list including `google_maps`

## Dependencies

- **Blocked by:** none
- **Blocks:** local SEO routine SOPs child task
- **External:** public provider docs only; no credentials needed

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | three docs + provider docs |
| Implementation | 1h | three sections |
| Verification | 10m | rg + linter |
| **Total** | **~1h40m** | |
