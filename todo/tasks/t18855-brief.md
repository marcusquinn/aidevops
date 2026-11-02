<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Local SEO: Local Services Ads and local paid search guidance (proposal-only)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `local SEO skills import subagent google business profile` → 0 hits — no prior LSA lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h; `rg -i "local services|LSA" .agents/marketing-sales.md .agents/seo.md` → no coverage
- [x] File refs verified: 3 refs checked, all present at HEAD 83ee6cd5f0
- [x] Tier: `tier:standard` — new doc with policy verification; proposal-only boundary already decided by `google-ads-triage.md`
- [x] Seeded draft PR decision recorded: skipped — content depends on live Google Ads help pages

## Origin

- **Created:** 2026-11-02
- **Session:** opencode:ses_e631bdc7cffe2C1iEoG8vJ7bBC
- **Created by:** ai-interactive (Build+), approved by maintainer
- **Parent task:** local SEO capability roadmap (see `Parent:` line on the issue)
- **Blocked by:** none
- **Conversation context:** Review of a third-party local SEO skill pack found useful LSA/local-ads checklists mixed with unsourced ranking-factor hierarchies and vendor tools (LSA Spy). aidevops has Google Ads search-term triage but no Local Services Ads guidance.

## What

`NEW .agents/marketing-sales/local-services-ads.md`, a proposal-only guide that:

1. Distinguishes Local Services Ads (pay-per-lead), Search campaigns with location assets, and Maps/local search ads, and when each fits.
2. Gives an LSA readiness checklist: eligible category and country, business/licence/insurance verification and background checks as Google requires for that category (verify live per market), linked GBP, service area and job types, budget and bidding mode, business hours and lead-answer coverage.
3. Defines measurement from first-party evidence: lead count, answer rate, booked-job rate, cost per lead, cost per booked job, disputed-lead rate. Use plain names; no invented "ROI" formulas.
4. Documents ad ranking factors only as listed on Google's current LSA help page, with the URL actually opened; no third-party factor hierarchies.
5. Keeps execution proposal-only, consistent with `.agents/marketing-sales/google-ads-triage.md:8`: no budget/bid changes, dispute submissions, or account edits by agents.

Also add a Quick Reference pointer in `.agents/marketing-sales.md` and a one-line cross-link in `google-ads-triage.md`.

## Why

Local service businesses often spend more on LSA than SEO, and the triage helper (`google-ads-triage.md:6`) covers only Search search-term hygiene. Third-party guidance mixes vendor promotion with unverified ranking claims, so agents need a vetted, proposal-only reference.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No — prose authoring.
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** Policy details need live verification.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** New documentation inside the existing proposal-only boundary, needing primary-source policy checks → tier:standard.

## PR Conventions

Leaf task: PR body uses `Resolves #<this issue>` and `For #<parent issue>`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Content depends on current Google Ads help pages.
- **Status:** `not-created`
- **Freshness evidence:** file verification at HEAD 83ee6cd5f0
- **Verification run:** `UNVERIFIED — not run`
- **Stale-assumption warning:** LSA eligibility and verification types vary by country and change often.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/marketing-sales/google-ads-triage.md` (10 lines) — proposal-only wording to mirror.
- **Read first:** `.agents/marketing-sales.md:38-58` — Quick Reference style for the pointer.
- **Load only if:** `.agents/workflows/marketing-actions.md` — if describing how approved changes are handed to a human.
- **Why:** match boundary and registration conventions.
- **Stop when:** pointer location and proposal-only wording are clear.

### Files to Modify

- `NEW: .agents/marketing-sales/local-services-ads.md` — model header on `.agents/marketing-sales/google-ads-triage.md` (SPDX + H2 title) or add frontmatter like other `marketing-sales/` leaves
- `EDIT: .agents/marketing-sales.md:49` — add a **Local Services Ads** bullet after the Affiliate programmes bullet
- `EDIT: .agents/marketing-sales/google-ads-triage.md:10` — append one line: LSA and local campaign guidance lives in `marketing-sales/local-services-ads.md`

### Complete Write Surface

- **Callers/readers:** `marketing-sales.md` Quick Reference; the sibling local SEO leaf may link here. `rg -n "google-ads-triage" .agents` shows no other registration surface.
- **Writers/mutation paths:** documentation only; `.agents/scripts/google_ads_triage.py` is not changed.
- **Existing verification/tests:** `linters-local.sh --changed`; `subagent-index-helper.sh check` for the new leaf.
- **Schemas/config:** N/A because this is documentation-only; no Ads API config exists in `configs/` for LSA.
- **Generated/deployed mirrors:** `subagent-index.toon` regenerated with `subagent-index-helper.sh generate`; `setup.sh` deploys `.agents/`.
- **Migrations/backfills:** N/A because this is new-file-only documentation.
- **Cleanup/rollback paths:** revert the PR; N/A because documentation-only work leaves no state outside git.

### Implementation Steps

1. Open Google's current LSA help pages (eligibility, verification, ranking, lead disputes) and Google Ads location-asset docs; cite only URLs opened.
2. Write the leaf with the five parts in **What**. Include a "Claims we do not make" list: unsourced LSA ranking hierarchies, guaranteed placements, inferring competitor budgets or responsiveness from ad positions.
3. Add the two pointers; run `subagent-index-helper.sh generate`.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — docs; no sibling task edits these files.
- **Migration/rollback:** revert-only.
- **Mixed-version/backward compatibility:** `google_ads_triage.py` behaviour unchanged; additive docs.
- **Idempotency/retry:** index regeneration is idempotent.
- **Partial failure/recovery:** where a policy detail cannot be verified for a market, write "verify per market" rather than a guess.

### Verification Before Dispatch

```bash
rg -n "local-services-ads" .agents/marketing-sales.md .agents/marketing-sales/google-ads-triage.md
subagent-index-helper.sh check
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** `rg` proves both pointers; `check` proves index registration; linter proves markdown quality.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** proposal-only; no Google Ads/LSA API integration, no account writes, no LSA Spy or other vendor adapter.

**AI brief owner:** maintainer interactive session (marcusquinn).

**Recovery:** preserve the current PR and use `reference/worker-discipline.md` runtime request when local recovery is unsafe.

### Files Scope

- `.agents/marketing-sales/local-services-ads.md`
- `.agents/marketing-sales.md`
- `.agents/marketing-sales/google-ads-triage.md`
- `.agents/subagent-index.toon`

## Acceptance Criteria

- [ ] The new leaf exists and is linked from `marketing-sales.md` and `google-ads-triage.md`.

  ```yaml
  verify:
    method: bash
    run: "test -f .agents/marketing-sales/local-services-ads.md && rg -q 'local-services-ads' .agents/marketing-sales.md && rg -q 'local-services-ads' .agents/marketing-sales/google-ads-triage.md"
  ```

- [ ] The leaf defines answer rate, cost per lead and cost per booked job from first-party evidence.

  ```yaml
  verify:
    method: codebase
    pattern: "cost per booked job"
    path: ".agents/marketing-sales/local-services-ads.md"
  ```

- [ ] Negative: the leaf never instructs agents to change budgets/bids, submit disputes or edit accounts, and lists no ranking factor absent from Google's cited help page.

  ```yaml
  verify:
    method: subagent
    prompt: "Does .agents/marketing-sales/local-services-ads.md instruct agents to perform account changes (budgets, bids, disputes) or state LSA ranking factors without citing Google's help page? PASS only if neither."
    files: ".agents/marketing-sales/local-services-ads.md"
  ```

- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Proposal-only matches `google-ads-triage.md:8`.
- Vendor tools (LSA Spy etc.) are out of scope; mention only as optional user-owned sources if at all.

## Relevant Files

- `.agents/marketing-sales/google-ads-triage.md:6-8` — proposal-only pattern
- `.agents/marketing-sales.md:49` — insertion point for the pointer
- `.agents/workflows/marketing-actions.md` — approved-action handoff

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** public Google Ads help pages only

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | help pages + two local files |
| Implementation | 1h | new leaf + pointers |
| Verification | 10m | rg, index check, linter |
| **Total** | **~1h40m** | |
