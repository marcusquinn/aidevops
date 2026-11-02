<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Local SEO: add evidence-labelled local SEO agent (seo/local-seo.md)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `local SEO skills import subagent google business profile` → 0 hits — no prior lessons; user preferences stored this session (SEO Utils over Local Falcon, DataForSEO/direct APIs, GBP appeals URL)
- [x] Discovery pass: 1 commit (a528f2ffce, unrelated worker-permissions) / 0 merged PRs / 0 open PRs touch target files; no open or closed "local seo" issues
- [x] File refs verified: 9 refs checked, all present at HEAD 83ee6cd5f0
- [x] Tier: `tier:standard` — documentation with editorial judgment; no trust boundary or migration
- [x] Seeded draft PR decision recorded: skipped — content needs worker judgment and primary-source checks

## Origin

- **Created:** 2026-11-02
- **Session:** opencode:ses_e631bdc7cffe2C1iEoG8vJ7bBC
- **Created by:** ai-interactive (Build+), approved by maintainer ("1 a. brief todos/issues for auto-dispatch")
- **Parent task:** local SEO capability roadmap (see `Parent:` line on the issue)
- **Blocked by:** none
- **Conversation context:** We reviewed the third-party MIT repo `garrettjsmith/localseoskills` (untrusted; vendor-promotional routing) for reusable local SEO value. Verdict: adopt workflows, reject its ranking doctrine. aidevops has no local SEO agent today.

## What

A new progressive-disclosure leaf `.agents/seo/local-seo.md` that an agent loads for Google Business Profile (GBP), map pack, citation, service-area, multi-location, Apple Business Connect, Bing Places and suspension/reinstatement work. It must:

1. Label every ranking statement as **Google-documented**, **practitioner-observed (named source)** or **unsupported**, and include a "Claims we do not make" table (inline list below).
2. Provide procedural checklists (identity/category/hours accuracy; storefront vs service-area vs hybrid; duplicate listings; citation audit; Apple/Bing listing maintenance; location and service-area pages; review requests/replies within policy; suspension evidence pack and appeal).
3. Route data collection to existing aidevops tools, never to a single paid vendor by default: SEO Utils (`seo/seo-utils.md`) for GMB grids/rank tracking, DataForSEO (`seo/dataforseo.md`) or SerpApi `google_maps` (`seo/serpapi.md`) for raw cost-efficient SERP/Maps data, and the read-only GBP collector (`content/social-google-business-profile.md`) for the owner's own profile, reviews and performance.
4. Be registered in `seo.md` and `reference/domain-index.md` so "local SEO / GBP / map pack" requests route here.

## Why

Local SEO requests currently fall through to generic SEO guidance. NAP appears only in `seo/eeat-score.md:57`, `seo/seo-audit-skill.md:123` and `seo/seo-audit-skill/aeo-geo-patterns/04-page-type-tactic-matrix.md:48`. Third-party local SEO skill packs are full of unsupported ranking claims and vendor routing, so agents need a vetted in-house reference instead.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No — prose must be authored.
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** Editorial wording and section depth remain.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** Documentation authoring inside decided boundaries with editorial judgment and primary-source checks → tier:standard.

## PR Conventions

Leaf task: PR body uses `Resolves #<this issue>` and `For #<parent issue>`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Content requires worker authoring and live primary-source verification.
- **Status:** `not-created`
- **Freshness evidence:** discovery and file verification at HEAD 83ee6cd5f0
- **Verification run:** `UNVERIFIED — not run`
- **Stale-assumption warning:** If another local SEO leaf lands first, merge into it instead of duplicating.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/seo.md:56-85` — Quick Reference format and subagent list to extend.
- **Read first:** `.agents/content/social-google-business-profile.md:1-34` — what the GBP collector can and cannot read (Q&A has no read route, line 28).
- **Load only if:** `.agents/seo/llm-visibility-instructional-report.md` — reuse its evidence-badge / "Myths and caveats" stance (line 31).
- **Load only if:** `.agents/seo/programmatic-seo.md:60-120` — location/service-area page guardrails to link rather than duplicate.
- **Why:** keep the new leaf consistent with existing evidence discipline and avoid duplicating programmatic-SEO and GBP-collector content.
- **Stop when:** section list, routing targets and claim labels are clear.

### Worker Quick-Start

```text
Section skeleton for .agents/seo/local-seo.md (frontmatter: description, mode: subagent):
1. Quick Reference (AI-CONTEXT block): scope, tool routing, evidence labels
2. Ranking model (Google-documented: relevance, distance, prominence; cite Google's
   "Tips to improve your local ranking" help page after opening it live)
3. Profile accuracy checklist (real-world name, most specific primary category,
   accurate hours incl. special hours, storefront/SAB/hybrid address rules)
4. Duplicates and multi-location (one listing per real location, per-location URL,
   location register, access audit)
5. Citations (inventory with URLs; substantive vs cosmetic NAP differences)
6. Apple Business Connect and Bing Places maintenance (claim/verify, category
   mapping, drift checks; Bing can import from GBP; verify each step live)
7. Location and service-area pages (link seo/programmatic-seo.md; doorway guardrails)
8. Reviews (no gating, no incentives; privacy-safe reply drafts routed through
   workflows/marketing-actions.md; never auto-post)
9. Suspension and reinstatement (below)
10. Claims we do not make (table below)
11. Data routing (SEO Utils / DataForSEO / SerpApi / GBP collector; no vendor default)
```

Suspension/reinstatement content to include:

- Evidence pack before appealing: guideline review of name/address/category/website, proof of business (registration, utility bill or lease matching the address, signage/storefront photos, licence), list of recent profile edits.
- Appeal route: `https://support.google.com/business/contact/local_appeals` — maintainer-supplied, used successfully for appeals and hard to find. Record it as maintainer-verified and tell agents to open it live before citing it in client deliverables.
- Submit one appeal at a time and track its reference; do not create a replacement listing while an appeal is pending.

"Claims we do not make" (each row: claim → label → instruction):

- Social signals are a confirmed local ranking factor → unsupported → do not claim.
- Domain Authority/Domain Rating are Google signals → unsupported (third-party metrics) → use only as vendor comparison context.
- Review replies are a confirmed ranking factor → unsupported as stated (Google advises replying; ranking effect not documented) → recommend replies for customers, not rankings.
- Dwell time / pogo-sticking on a listing drives ranking → unsupported → do not claim.
- Keyword-stuffed business names → violates Google guidelines → never recommend.
- Hiding an SAB address costs rankings (single unattributed correlation study) → unsupported causation → follow Google's address rules.
- Seeding GBP Q&A → feature/API status uncertain (no read route at `content/social-google-business-profile.md:28`) → verify current availability before advising.
- Excluding unhappy customers from review requests → review gating, violates policy → never recommend.
- Fixed word-count thresholds (300/500 words) → editorial heuristic, not a Google rule → do not present as a ranking requirement.
- Open-at-search-time boost / extended hours → practitioner-observed (name the source if cited) → never recommend inaccurate hours.
- Geogrid share-of-voice equals "% of customers who can see you" → unsupported → report grid points, not audience.

### Files to Modify

- `NEW: .agents/seo/local-seo.md` — the leaf above; model frontmatter and AI-CONTEXT block on `.agents/seo/ecommerce-seo.md`
- `EDIT: .agents/seo.md:5-50` — add `local-seo` to `subagents:`
- `EDIT: .agents/seo.md:68-81` — add a **Local** bullet to the Quick Reference subagent list
- `EDIT: .agents/reference/domain-index.md:40` — add keywords `local SEO, Google Business Profile, GBP, map pack, citations, Apple Business Connect, Bing Places` and path `seo/local-seo.md` to the SEO row
- `EDIT: .agents/subagent-index.toon` — regenerate with `subagent-index-helper.sh generate`; do not hand-edit

### Complete Write Surface

- **Callers/readers:** `seo.md` (subagent routing), `reference/domain-index.md` (domain trigger), OpenCode plugin reads `subagent-index.toon`. `rg -n "ecommerce-seo" .agents --glob '!*.toon'` shows the same registration surface for the last SEO leaf (commit a0e82c6890).
- **Writers/mutation paths:** documentation only; `subagent-index-helper.sh generate` writes the index.
- **Existing verification/tests:** `subagent-index-helper.sh check`, `verify-agent-discoverability.sh`, markdownlint via `linters-local.sh --changed`.
- **Schemas/config:** N/A because this is documentation-only; frontmatter follows existing `.agents/seo/ecommerce-seo.md`.
- **Generated/deployed mirrors:** `subagent-index.toon` (regenerated); `setup.sh` deploys `.agents/` to `~/.aidevops/agents/` on next update — no manual copy.
- **Migrations/backfills:** N/A because this is new-file-only documentation with no existing data.
- **Cleanup/rollback paths:** revert the PR; N/A because documentation-only work leaves no state outside git.

### Implementation Steps

1. Open Google's current GBP guidelines, local ranking help page and LSA-independent policies live; record the URLs actually opened in the leaf's source list (do not invent URLs).
2. Write `.agents/seo/local-seo.md` using the skeleton, suspension content and claims table above. Keep it under ~250 lines; link out instead of duplicating `programmatic-seo.md`, `schema-validator.md`, `link-building.md`.
3. Register in `seo.md` and `reference/domain-index.md`; run `subagent-index-helper.sh generate`.
4. Do not fetch or copy from `garrettjsmith/localseoskills`; this brief already contains the vetted extracts.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — docs; sibling child tasks edit different files (`seo-utils.md`, `dataforseo.md`, `marketing-sales/*`). If `seo.md` conflicts, rebase and keep both entries.
- **Migration/rollback:** revert-only; no persisted state.
- **Mixed-version/backward compatibility:** existing SEO routing unchanged; new leaf is additive.
- **Idempotency/retry:** re-running `subagent-index-helper.sh generate` is idempotent.
- **Partial failure/recovery:** if index regeneration fails, commit the doc and report the failing command in the PR.

### Verification Before Dispatch

```bash
subagent-index-helper.sh check
rg -n "local-seo" .agents/seo.md .agents/reference/domain-index.md .agents/subagent-index.toon
rg -n "local_appeals" .agents/seo/local-seo.md
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** `check` proves index registration; first `rg` proves routing edits; second proves the appeals route is captured; linter proves markdown quality.
- **Broad verification trigger:** Not required — no shared config or tooling change.

### Scope Boundaries

**Hard boundaries:** documentation only; no new scripts, MCP servers, vendor integrations or API writes. Do not recommend any guideline-violating tactic.

**AI brief owner:** maintainer interactive session (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/seo/local-seo.md`
- `.agents/seo.md`
- `.agents/reference/domain-index.md`
- `.agents/subagent-index.toon`

## Acceptance Criteria

- [ ] `.agents/seo/local-seo.md` exists, is registered in `seo.md` and `reference/domain-index.md`, and appears in `subagent-index.toon`.

  ```yaml
  verify:
    method: bash
    run: "rg -q 'local-seo' .agents/seo.md && rg -q 'seo/local-seo.md' .agents/reference/domain-index.md && rg -q 'local-seo' .agents/subagent-index.toon"
  ```

- [ ] The leaf contains the GBP appeals route and a "Claims we do not make" section.

  ```yaml
  verify:
    method: codebase
    pattern: "support.google.com/business/contact/local_appeals"
    path: ".agents/seo/local-seo.md"
  ```

- [ ] Negative: the leaf never recommends review gating, keyword-stuffed names, or a paid vendor as the default data source (no Local Falcon/LocalSEOData default routing).

  ```yaml
  verify:
    method: subagent
    prompt: "Does .agents/seo/local-seo.md recommend review gating, keyword-stuffing business names, fake hours, or route data collection to a single paid vendor by default? Answer PASS only if none."
    files: ".agents/seo/local-seo.md"
  ```

- [ ] Every ranking claim carries an evidence label (Google-documented / practitioner-observed with source / unsupported).
- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Maintainer preference: SEO Utils (seoutils.app) instead of Local Falcon; DataForSEO or direct APIs for cost-efficient tracking and comparison.
- Third-party "skills" packs that default-route to a vendor are treated as affiliate/promotional plays; extract workflows only.
- Ruled out: importing the external repo via `/add-skill`; a scheduler or brief-state system separate from aidevops routines/memory.

## Relevant Files

- `.agents/seo.md:68-81` — Quick Reference subagent bullets
- `.agents/seo/seo-utils.md:27,60` — GMB grids live in SEO Utils local tables
- `.agents/content/social-google-business-profile.md:20-28` — collector coverage, Q&A unavailable
- `.agents/seo/eeat-score.md:57` — existing NAP consistency check
- `.agents/seo/programmatic-seo.md:66,116` — 300-word quality gate (editorial heuristic; do not restate as a Google rule)

## Dependencies

- **Blocked by:** none
- **Blocks:** local SEO routine SOPs child task (filed after this one)
- **External:** none (live reads of public Google/Apple/Microsoft help pages only)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | listed files + live official help pages |
| Implementation | 1.5h | new leaf + registration |
| Verification | 15m | index check, rg, linter |
| **Total** | **~2h15m** | |
