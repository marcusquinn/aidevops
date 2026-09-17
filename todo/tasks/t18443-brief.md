---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18443: Add recommended apps and prioritize Recommended tab

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `aidevops.app recommended apps issue auto-dispatch tabs Recommend AIDevOps` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch the target files in the last 48h; no matching open issue found
- [x] File refs verified: 4 refs checked, all present at HEAD `a3100e9bb35259de27c31e951cec822553d4805a`
- [x] Tier: `tier:standard` — targets and behavior are fixed, but test adaptation requires normal local implementation judgment
- [x] Seeded draft PR decision recorded: skipped — issue-only is clearer than a draft for two small data/order edits

## Origin

- **Created:** 2026-09-17
- **Session:** `opencode:ses_f4e7a3abdffe9cYER3N6MQkcZy`
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** The user asked to add Davit, CaskHub, Vorssaint, OrbStack, Buzz, Ulysses, iA Presenter, and ONLYOFFICE Desktop to aidevops.app recommendations, and to show the Recommended collection tab before AIDevOps.

## What

Extend the aidevops.app Recommended collection with seven new app cards and update the existing ONLYOFFICE card to use the supplied Desktop Editors download page. Reorder the Apps collection tabs so `Recommended` is rendered before `AIDevOps`, without changing the currently selected default collection.

## Why

The recommendations should reflect the user's tried-and-tested app set and put discovery of those recommendations first in the tab row. ONLYOFFICE already exists, so updating its canonical website target avoids a duplicate card while honoring the requested desktop-app link.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** App records and tab replacement are exact, but the test edits are specified as assertions rather than complete old/new source blocks.
- [x] **Targets and reference pattern verified?** The data array, tab array, and existing component-test pattern are identified at current HEAD.
- [x] **No semantic or design decision remains?** Names, descriptions, URLs, OS/platform tags, order, default-selection behavior, and duplicate handling are decided.
- [x] **Bounded, reversible, low-consequence impact?** Static recommendation metadata and tab display order only; rollback is a direct revert.
- [x] **No stateful coordination to invent?** No persistence, API, migration, or shared-state change.
- [x] **Focused verification and rollback are explicit?** Component tests, changed-file lint, and source assertions are named.
- [x] **No dispatch-path risk override?** No worker dispatch/spawn files are in scope.

**Selected tier:** `tier:standard`

**Tier rationale:** The outcome, data, targets, and regression boundaries are resolved, while extending the existing component tests still requires ordinary local adaptation; this is bounded `tier:standard` work.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The exact contract fits in the brief; a draft PR would add coordination overhead without reducing implementation uncertainty.
- **Status:** `not-created`
- **Freshness evidence:** Memory, collision, file, line, and source-site checks were completed against current HEAD on 2026-09-17.
- **Verification run:** Brief verification only; implementation checks are intentionally left for the worker.
- **Stale-assumption warning:** Re-check the two target arrays if either source file changed after `a3100e9bb35259de27c31e951cec822553d4805a`.

## How (Approach)

### Files to Modify

- `EDIT: packages/gui-web/src/RecommendedAppsSurface.tsx:50-101` — add seven unique app records and update the existing ONLYOFFICE website URL.
- `EDIT: packages/gui-web/src/InventorySurfaces.tsx:144-147` — render Recommended before AIDevOps while preserving `useState<AppCollectionId>("aidevops")` at line 12.
- `EDIT: packages/gui-web/tests/component.test.ts:283-292,479-517` — cover the requested app records, deduplication, supplied ONLYOFFICE URL, tab order, and unchanged default selection.
- `DESIGN.md:157-169` — checked design source; no token or design-system update is needed because this task changes data and control order, not styling or interaction design.

### Complete Write Surface

- **Callers/readers:** `AppsSurface` in `packages/gui-web/src/InventorySurfaces.tsx:11-84` imports, filters, and renders `recommendedApps`; `RecommendedAppsSurface` maps each record to a card at `packages/gui-web/src/RecommendedAppsSurface.tsx:107-138`.
- **Writers/mutation paths:** Static source arrays only: `recommendedApps` and `appCollectionTabs`. Runtime filter state remains local React state and is not persisted.
- **Tests/fixtures:** `packages/gui-web/tests/component.test.ts:283-292` demonstrates direct metadata assertions; `packages/gui-web/tests/component.test.ts:479-517` renders `AppsSurface` and inspects source/order.
- **Schemas/config:** No external schema or config; records satisfy the local `RecommendedApp` interface at `RecommendedAppsSurface.tsx:19-31`.
- **Generated/deployed mirrors:** N/A because the searched write surface shows Vite consumes `packages/gui-web/src/RecommendedAppsSurface.tsx` and `packages/gui-web/src/InventorySurfaces.tsx` directly, with no generated recommendation mirror.
- **Migrations/backfills:** N/A because the records and tab order are static source constants with no persisted data.
- **Cleanup/rollback paths:** N/A because Git revert of the three scoped files fully restores the prior static records and order; no persisted state needs cleanup.

### Implementation Steps

1. In `recommendedApps`, retain alphabetical sorting and add these exact records (the final runtime order remains controlled by the existing `.sort(...)`):

```ts
{ name: "Buzz", description: "Collaboration workspace for people, AI agents, and projects.", websiteUrl: "https://buzz.xyz/", os: [], platforms: ["webapp", "saas"] },
{ name: "CaskHub", description: "Native macOS app store for browsing and managing Homebrew casks.", websiteUrl: "https://caskhub.app/", repoUrl: "https://github.com/alielsokary/CaskHub", os: ["macos"], platforms: [] },
{ name: "Davit", description: "Native macOS interface for Apple's container platform.", websiteUrl: "https://davit.app/", repoUrl: "https://github.com/wouterdebie/davit", os: ["macos"], platforms: [] },
{ name: "iA Presenter", description: "Writing-first presentation app with automatic layouts and speaker notes.", websiteUrl: "https://ia.net/presenter", os: ["macos"], platforms: [] },
{ name: "OrbStack", description: "Fast, lightweight Docker, Kubernetes, and Linux environment for macOS.", websiteUrl: "https://orbstack.dev/", os: ["macos"], platforms: ["cli"] },
{ name: "Ulysses", description: "Focused writing and project-management app for Mac, iPad, and iPhone.", websiteUrl: "https://ulysses.app/", iosUrl: "https://apps.apple.com/app/ulysses/id1225570693?platform=iphone", os: ["macos", "ios"], platforms: [] },
{ name: "Vorssaint", description: "Free, open source modular menu-bar utilities for macOS.", websiteUrl: "https://vorssaint.com/", repoUrl: "https://github.com/vorssaint/vorssaint-utils", os: ["macos"], platforms: [] },
```

2. Do not add another ONLYOFFICE record. Change only its existing `websiteUrl` from `https://www.onlyoffice.com/` to `https://www.onlyoffice.com/download-desktop`; retain its current description, repository, mobile links, OS tags, and platform tags.
3. Replace the exact tab array with the following order, but do not change the `appCollection` initial state:

```ts
const appCollectionTabs: TabOption<AppCollectionId>[] = [
  { id: "recommended", label: "Recommended" },
  { id: "aidevops", label: "AIDevOps" },
];
```

4. Extend the existing component tests rather than creating test infrastructure. Assert all eight requested names/URLs are represented, `ONLYOFFICE` appears once in `recommendedApps`, `Recommended` precedes `AIDevOps` in `appCollectionTabs`, and initial rendering still shows the AIDevOps collection.
5. Run the focused component test and changed-file lint. Because no CSS/layout changes are made, visual screenshot review and `DESIGN.md` edits are not required; confirm keyboard/ARIA tab semantics remain unchanged by retaining the existing `TabNav` implementation.

### Hazards and Compatibility

- **Concurrency/atomicity:** No concurrent writes or transactions; both arrays are module constants. If target lines moved, re-read and apply by identifiers rather than stale line numbers.
- **Migration/rollback:** No migration. A normal Git revert restores prior cards and order.
- **Mixed-version/backward compatibility:** No serialized/API contract changes. Existing filters accept every supplied OS/platform value.
- **Idempotency/retry:** Records must remain unique by `name`; rerunning the work must not append duplicates, especially ONLYOFFICE.
- **Partial failure/recovery:** If tests fail after only one source edit, keep the issue open, inspect the static metadata/order assertions, complete or revert the partial edit, and rerun focused checks.

### Verification Before Dispatch

```bash
bun test packages/gui-web/tests/component.test.ts
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The Bun component test proves card metadata, uniqueness, tab order, and unchanged default rendering. Changed-file lint covers the three TypeScript/TSX files and formatting/type-sensitive regressions.
- **Broad verification trigger:** Not required; this changes package-local static UI data and order, with no root tooling, dependency, schema, API, or release-infrastructure impact.

### Files Scope

- `packages/gui-web/src/RecommendedAppsSurface.tsx`
- `packages/gui-web/src/InventorySurfaces.tsx`
- `packages/gui-web/tests/component.test.ts`

## Acceptance Criteria

- [ ] Recommended Apps exposes Davit, CaskHub, Vorssaint, OrbStack, Buzz, Ulysses, and iA Presenter with the exact supplied website URLs and brief descriptions/metadata from this contract.
- [ ] The existing ONLYOFFICE card uses `https://www.onlyoffice.com/download-desktop` and there is exactly one `ONLYOFFICE` record.
- [ ] The Apps collection tab row renders `Recommended` before `AIDevOps` while the initial selected collection remains `AIDevOps`.
- [ ] Existing recommendation filtering, external-link behavior, tab roles, labels, and keyboard semantics are unchanged.
- [ ] `bun test packages/gui-web/tests/component.test.ts` passes.
- [ ] `.agents/scripts/linters-local.sh --changed` passes.
- [ ] `DESIGN.md` is cited as checked; no update is required because no visual style, layout rule, or interaction pattern changes.

## Context & Decisions

- The eight supplied pages were fetched on 2026-09-17 and passed prompt-injection scanning; facts in this brief were extracted from those pages only.
- ONLYOFFICE is already present at `RecommendedAppsSurface.tsx:74`, so updating that record is correct and duplication is explicitly prohibited.
- The user asked to swap visible tab order, not alter which collection opens first; preserve the existing `aidevops` initial state.
- Existing naming uses `Recommended`, so retain that label rather than introducing a near-duplicate `Recommend` label.
- Source-site evidence: Davit, CaskHub, Vorssaint, OrbStack, Ulysses, and iA Presenter are macOS apps; Buzz describes an early collaboration workspace; ONLYOFFICE supplies desktop apps for Windows, Linux, and macOS while the existing card also covers its mobile and online products.

## Relevant Files

- `packages/gui-web/src/RecommendedAppsSurface.tsx:19-31` — recommendation record shape.
- `packages/gui-web/src/RecommendedAppsSurface.tsx:50-101` — alphabetically sorted recommendation data, including existing ONLYOFFICE.
- `packages/gui-web/src/InventorySurfaces.tsx:11-15` — Apps collection state; default must remain AIDevOps.
- `packages/gui-web/src/InventorySurfaces.tsx:144-147` — collection tab order.
- `packages/gui-web/tests/component.test.ts:283-292` — focused recommendation metadata test pattern.
- `packages/gui-web/tests/component.test.ts:479-517` — Apps rendering and source-order test pattern.
- `DESIGN.md:157-169` — checked design principles; no design-system edit required.

## Dependencies

- **Blocked by:** none
- **Blocks:** refreshed aidevops.app recommendations and requested navigation priority
- **External:** Public source pages only; no credentials, purchases, or external service mutations required

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Re-read the three scoped files and exact contract |
| Implementation | 25m | Add/update records, reorder tabs, extend existing assertions |
| Verification | 20m | Focused Bun test and changed-file lint |
| **Total** | **~1h** | |
