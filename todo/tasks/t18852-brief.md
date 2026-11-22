<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Local SEO capability for aidevops (parent roadmap)

## Origin

- **Created:** 2026-11-02
- **Session:** opencode:ses_e631bdc7cffe2C1iEoG8vJ7bBC
- **Created by:** ai-interactive (Build+), approved by maintainer ("1 a. brief todos/issues for auto-dispatch")
- **Conversation context:** Reviewed the third-party MIT repo `garrettjsmith/localseoskills` (37 skills, 15 scheduled tasks). It contains useful local SEO workflows but also unsupported ranking claims, guideline-violating advice (review gating) and vendor-first routing to an author-promoted data product. aidevops has no local SEO agent.

## What

Roadmap parent for a vetted, vendor-neutral local SEO capability. This issue is `parent-task`: it is never dispatched itself; child PRs reference it with `For #<this issue>`.

Children (independent unless noted):

1. `seo/local-seo.md` — evidence-labelled local SEO leaf: GBP accuracy, storefront/SAB/hybrid, duplicates, multi-location, citations, Apple Business Connect, Bing Places, location pages, review policy, suspension evidence pack and appeal route (`https://support.google.com/business/contact/local_appeals`, maintainer-verified), "Claims we do not make".
2. Geogrid metric definitions (ARP, ATRP, SoLV with explicit formulas) in `seo/seo-utils.md`, plus cost-efficient grid collection recipes in `seo/dataforseo.md` and `seo/serpapi.md`.
3. `marketing-sales/local-services-ads.md` — proposal-only LSA and local paid search guidance.
4. `seo/local-seo-routines.md` — routine-ready monitoring/reporting SOPs. Blocked by children 1 and 2.

## Why

Local SEO requests currently fall through to generic SEO guidance, and third-party skill packs would import myths and vendor bias. Maintainer preferences: SEO Utils (seoutils.app) instead of Local Falcon; DataForSEO or direct APIs for cost-efficient tracking and comparison.

## Decisions

- Extract workflows, not ranking doctrine. Every ranking claim is labelled Google-documented, practitioner-observed (named source) or unsupported.
- No paid vendor is a default data source. No new vendor adapters (Local Falcon, LocalSEOData, LSA Spy, Whitespark, BrightLocal) in this roadmap.
- Execution stays read-only or draft-only through `workflows/marketing-actions.md`; no listing edits, posting or ad account writes.
- aidevops routines and memory replace the external pack's scheduler, approval tiers and per-location brief files.
- Workers must not fetch or copy from the external repo; child briefs contain the vetted extracts.

## Phases

- Phase 1 - seo/local-seo.md leaf (child 1)
- Phase 2 - geogrid metrics and grid collection recipes (child 2)
- Phase 3 - Local Services Ads guidance (child 3)
- Phase 4 - local SEO routine SOPs (child 4, blocked by children 1 and 2)

### Files Scope

- `.agents/seo/local-seo.md`
- `.agents/seo/local-seo-routines.md`
- `.agents/seo.md`
- `.agents/reference/domain-index.md`
- `.agents/seo/seo-utils.md`
- `.agents/seo/dataforseo.md`
- `.agents/seo/serpapi.md`
- `.agents/marketing-sales/local-services-ads.md`
- `.agents/marketing-sales.md`
- `.agents/marketing-sales/google-ads-triage.md`
- `.agents/subagent-index.toon`

## Acceptance Criteria

- [ ] All four children merged.
- [ ] `seo.md` routes local SEO requests to `seo/local-seo.md`.
- [ ] No merged child recommends review gating, keyword-stuffed names, fake hours or a paid vendor as the default data source.

## Related

- Separate framework issue filed in the same session: `/add-skill` content review for vendor/affiliate bias and unsupported claims.
