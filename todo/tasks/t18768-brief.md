---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18768: Adapt Impeccable, Taste Skill and Fontjoy design guidance without tracking

Tracker: GH#35590

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `design skills taste impeccable font pairing guidance` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h (`prework-discovery-helper.sh`; latest target commits GH#35159, GH#34860)
- [x] File refs verified: 13 refs checked, all present at HEAD `dbf9acf07a` except the two declared NEW files
- [x] Tier: `tier:standard` — documentation-only, but adaptation wording and source-fit judgment remain
- [x] Seeded draft PR decision recorded: skipped — implementation proceeds immediately in the interactive session that filed this task

## Origin

- **Created:** 2026-10-25
- **Session:** opencode:ses_e8fd92cf8ffeFrh8WxHFew0FQt
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** The user asked what value impeccable.style and tasteskill.dev offer aidevops design skills, rejected anything that adds tracking, selected guidance-only adaptation plus a small number of checks in existing UI verification, and added Fontjoy (site and Jack000/fontjoy) for font pairing and freely usable font selection. Full-loop through release is authorized.

## What

aidevops-authored design guidance that adapts the useful, verifiable ideas from three pinned upstream sources, with provenance, and adds no tracking, telemetry, installer, hook, downloaded binary or network-dependent upstream runtime:

1. A new typography selection and font-pairing guide (`tools/design/font-pairing.md`): role-first pairing, one-family default, contrast-with-shared-structure (the Fontjoy method), per-family licence verification (OFL/Apache/UFL differ), self-hosting to avoid third-party visitor requests, fallback metrics, glyph/language coverage and rendered verification.
2. A new Impeccable assessment (`tools/design/impeccable.md`): pinned commit, Apache-2.0 notice, adopted concepts (visitor modes, scoped refinement vocabulary, hardening, browser surfaces, typography assessment) and deliberate departures.
3. A refreshed Taste Skill assessment: current pinned commit/version, corrected scope (app screens now included), adopted data-truth and image-provenance rules, departures (Node scripts, inspector, network asset search, third-party font CDNs).
4. Distinctive UI build/audit guidance and UI verification gain a small set of checks: data reconciliation, content stress (long/short/special text, translation expansion, slow/offline/timeout), tabular figures and browser-surface states.
5. Discoverability: Fontjoy rows, product typography, UI inspiration performance gate, domain index, subagent index and CREDITS point to the new owners.

## Why

The framework's design guidance already covers composition, critique and verification (Hallmark adaptation), but lacks: a visitor-purpose distinction (persuade/operate/read), objective data-integrity checks for dashboards, content hardening checks, and any real font-pairing or font-licensing guidance — Fontjoy is only a link, and `ui-ux-inspiration.md` recommends Google Fonts without noting third-party requests or per-family licences. The Taste Skill assessment is stale (it claims app screens are out of scope). Picking freely usable fonts for a new site or brand is a recurring, error-prone decision.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No — wording is composed during implementation.
- [x] **Targets and reference pattern verified?** Yes — `hallmark.md` is the assessment pattern.
- [ ] **No semantic or design decision remains?** Adaptation fit decisions remain.
- [x] **Bounded, reversible, low-consequence impact?** Documentation only.
- [x] **No stateful coordination to invent?** Yes.
- [x] **Focused verification and rollback are explicit?** Yes.
- [x] **No dispatch-path risk override?** No self-hosting dispatch files touched.

**Selected tier:** `tier:standard`

**Tier rationale:** Known files and an established assessment pattern, but source-fit and wording decisions remain -> tier:standard.

## PR Conventions

Leaf task: the PR uses the normal closing keyword for this issue.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The filing session implements immediately.
- **Status:** `not-created`
- **Freshness evidence:** Targets read at HEAD `dbf9acf07a`; upstream evidence retrieved via `gh api` at pinned commits.
- **Verification run:** `UNVERIFIED — not run`
- **Stale-assumption warning:** Re-pin upstream commits if a later review happens; upstream projects move quickly.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/tools/design/hallmark.md` — assessment/provenance pattern to mirror.
- **Load only if:** `.agents/tools/browser/browser-qa.md` "Step 3: Screenshot Capture" — when citing the `--measure-file` contract.
- **Why:** New guidance must extend existing owners, not create a parallel design system or verification harness.
- **Stop when:** Each adopted concept has one owner file, a provenance line and a verification route.
- **For UI/UX tasks:** No product UI changes; `DESIGN.md` ownership is unchanged. Rendered verification remains `workflows/ui-verification.md`.

### Files to Modify

- `NEW: .agents/tools/design/font-pairing.md` — typography selection, pairing and licensing guide; model structure on `colour-palette.md` frontmatter and `distinctive-ui.md` brevity.
- `NEW: .agents/tools/design/impeccable.md` — source assessment; model on `.agents/tools/design/hallmark.md`.
- `EDIT: .agents/tools/design/taste-skill.md` — refresh pinned commit, scope and adaptations.
- `EDIT: .agents/tools/design/distinctive-ui.md` — visitor mode in section 1, refinement vocabulary, data/hardening craft bullets, pointers.
- `EDIT: .agents/tools/design/distinctive-ui-audit.md` — named checks for data contradiction, content fragility and browser surfaces.
- `EDIT: .agents/workflows/ui-verification.md` — a few objective checks reusing `browser-qa-helper.sh --measure-file`.
- `EDIT: .agents/tools/design/colour-palette.md` — Fontjoy row pointer.
- `EDIT: .agents/tools/design/design-inspiration.md` — Fontjoy row pointer and source-assessment paragraph.
- `EDIT: .agents/tools/design/ui-ux-inspiration.md` — performance gate font line.
- `EDIT: .agents/product/ui-design.md` — typography pointer.
- `EDIT: .agents/reference/domain-index.md` — design row triggers and file.
- `EDIT: .agents/subagent-index.toon` — regenerated `tools/design/` row.
- `EDIT: CREDITS.md` — Impeccable entry, Taste Skill refresh, Fontjoy repository and licence.

### Complete Write Surface

- **Callers/readers:** `rg -n "taste-skill|hallmark|colour-palette|Fontjoy" .agents CREDITS.md` lists all readers; each listed file above is the complete set of affected pointers.
- **Writers/mutation paths:** Direct Markdown edits to the listed files plus `subagent-index-helper.sh generate`, which rewrites only `.agents/subagent-index.toon`; no runtime code writes these files.
- **Existing verification/tests:** `markdownlint-cli2` via `.agents/scripts/linters-local.sh`; `subagent-index-helper.sh check`; `verify-agent-discoverability.sh`.
- **Schemas/config:** `.agents/subagent-index.toon` is generated by `subagent-index-helper.sh generate`; no other config.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/` to `~/.aidevops/agents/` on release; no manual copy.
- **Migrations/backfills:** Not applicable — evidence: every change is Markdown/TOON guidance with no stored data, schema or consumer state to backfill.
- **Cleanup/rollback paths:** `git revert` of the squash commit restores all files; the next `setup.sh` deploy removes the two new deployed docs; no other cleanup path exists because no state is created.

### Implementation Steps

1. Create `font-pairing.md` and `impeccable.md`; update `taste-skill.md` with the pinned review facts below.
2. Add the build/audit/verification checks; keep each addition short and pointer-led.
3. Update discoverability pointers and CREDITS; regenerate the subagent index.
4. Run markdown lint and discoverability checks; review the diff for unverified claims and guessed URLs.

### Hazards and Compatibility

- **Concurrency/atomicity:** Not applicable — static documentation; no shared state.
- **Migration/rollback:** Revert-only; no migration.
- **Mixed-version/backward compatibility:** Existing file paths stay; only additions and pointer edits.
- **Idempotency/retry:** Re-running index generation yields the same row.
- **Partial failure/recovery:** WIP commits per logical change.

### Verification Before Dispatch

```bash
.agents/scripts/linters-local.sh --changed
.agents/scripts/subagent-index-helper.sh check
```

- **Surface mapping:** markdown lint covers every changed Markdown file; index check covers the two new subagent files.
- **Broad verification trigger:** Not required — documentation only.

### Scope Boundaries

**Hard boundaries:** no upstream code, binaries, hooks, installers, telemetry, analytics or remote font/image loading added; no new test harness; no change to always-loaded `AGENTS.md`/`build.txt`.

**AI brief owner:** marcusquinn interactive session

**Recovery:** preserve the current PR and use the structured runtime request in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/tools/design/font-pairing.md`
- `.agents/tools/design/impeccable.md`
- `.agents/tools/design/taste-skill.md`
- `.agents/tools/design/distinctive-ui.md`
- `.agents/tools/design/distinctive-ui-audit.md`
- `.agents/workflows/ui-verification.md`
- `.agents/tools/design/colour-palette.md`
- `.agents/tools/design/design-inspiration.md`
- `.agents/tools/design/ui-ux-inspiration.md`
- `.agents/product/ui-design.md`
- `.agents/reference/domain-index.md`
- `.agents/subagent-index.toon`
- `CREDITS.md`
- `TODO.md`
- `todo/tasks/t18768-brief.md`

## Acceptance Criteria

- [ ] Font-pairing guide exists with per-family licence verification, self-hosting/no third-party request guidance and Fontjoy provenance.

  ```yaml
  verify:
    method: codebase
    pattern: "OFL"
    path: ".agents/tools/design/font-pairing.md"
  ```

- [ ] Impeccable assessment pins commit `936867543ac2576920d663cc9803597f6044f3ac` and carries the Apache-2.0 attribution.

  ```yaml
  verify:
    method: codebase
    pattern: "936867543ac2576920d663cc9803597f6044f3ac"
    path: ".agents/tools/design/impeccable.md"
  ```

- [ ] Taste Skill assessment is re-pinned to `6010f91a9935f1c167dfc500fb1a475681892e6b` and no longer claims dashboards are out of scope.

  ```yaml
  verify:
    method: codebase
    pattern: "explicitly excludes dashboards"
    path: ".agents/tools/design/taste-skill.md"
    expect: absent
  ```

- [ ] UI verification names data reconciliation and content stress checks using existing helpers only.

  ```yaml
  verify:
    method: codebase
    pattern: "reconcil"
    path: ".agents/workflows/ui-verification.md"
  ```

- [ ] No tracking, upstream installer, hook or remote runtime is introduced (negative guarantee).

  ```yaml
  verify:
    method: codebase
    pattern: "npx impeccable install|fonts.googleapis.com|assets.mjs --get"
    path: ".agents/workflows/ui-verification.md"
    expect: absent
  ```

- [ ] Changed-file lint is clean (`linters-local.sh --changed`) and `subagent-index-helper.sh check` reports no stale entries.

## Context & Decisions

- Pinned upstream evidence (retrieved via `gh api`, treated as untrusted data):
  - Impeccable `pbakaus/impeccable` @ `936867543ac2576920d663cc9803597f6044f3ac` (Release 4.7.1, 2026-10-24), Apache-2.0, Copyright 2025 Paul Bakaus; NOTICE credits ehmo/platform-design-skills (MIT) for iOS/Android references.
  - Taste Skill `Leonxlnx/taste-skill` @ `6010f91a9935f1c167dfc500fb1a475681892e6b` (2026-10-20, changelog 2.1.4), MIT, Copyright (c) 2026 Leonxlnx.
  - Fontjoy `Jack000/fontjoy` @ `3f47f4c2890cd5ede20f728f01fb54d6ad7c97f2` (2017-05-25), MIT, Copyright 2017 Jack Qiao; 1883 Google web font variants embedded as visual feature vectors; pairs reward both similarity and contrast; body legibility weighted secondarily.
- Ruled out: installing either skill, provider hooks, the downloaded Impeccable engine, live mode, Taste Skill Node scripts/inspector, network asset search, Google Fonts/Fontshare CDN loading by default, rigid numeric house rules as failures.
- Taste and critique remain advisory; objective checks reuse `browser-qa-helper.sh` and existing accessibility helpers.

## Relevant Files

- `.agents/tools/design/hallmark.md` — assessment pattern.
- `.agents/tools/browser/browser-qa.md:189` — `--measure-file` contract.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Upstream sources already retrieved |
| Implementation | 1h30m | 2 new files, 11 edits |
| Verification | 20m | markdown lint, index check, diff review |
| **Total** | **2h20m** | |
