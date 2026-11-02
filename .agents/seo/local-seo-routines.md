---
description: Draft-only, routine-ready local SEO monitoring and reporting SOPs
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Local SEO Routines

These SOPs are reusable instructions, not installed routines. Add a selected SOP
to a project's top-level `TODO.md` `## Routines` through `/routine`, using an
`agent:SEO` entry or an appropriate deterministic `run:` entry. Keep the SOP,
the routine's `repeat:` schedule, and targets independent. Supply targets only
through the routine entry or a private targets file; do not place them here.

All outputs use `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/`.
They are observations or draft handoffs, never authority to publish, edit a
listing, send a reply, buy credits, or start a paid lookup. Mark incomplete
outputs `PARTIAL` with the missing inputs, coverage, and safe next action.

### Weekly geogrid snapshot

- **Suggested schedule:** `repeat:weekly(mon@07:00)` (the project chooses the actual schedule in `TODO.md`)
- **Targets:** supplied by the routine entry or a private targets file — never embedded here
- **Evidence source:** matching stored SEO Utils GMB-grid data first; otherwise the approved DataForSEO Maps grid recipe. Record all metadata required by `seo/seo-utils.md`.
- **Output:** `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/geogrid/<date>.md` with matching-geometry comparisons only, ARP, ATRP, SoLV, found rate, cutoff, and limitations.
- **Approval:** read-only; any external lookup needs its exact bounded cost and approval before collection.
- **Failure handling:** return `PARTIAL` with unavailable dimensions or data-source access; do not retry paid lookups automatically.
- **Do not:** compare changed query, business ID, grid geometry, platform, device, language, cutoff, or metric definition as a trend; describe sampled grid points as customers or audience share.

### Review velocity and unanswered-review queue

- **Suggested schedule:** `repeat:weekly(mon@08:00)` (the project chooses the actual schedule in `TODO.md`)
- **Targets:** supplied by the routine entry or a private targets file — never embedded here
- **Evidence source:** authorized, read-only GBP review collection through `content/social-google-business-profile.md`; review text and replies are protected customer content.
- **Output:** `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/reviews/<date>.md` with a rolling velocity baseline, bounded aggregate counts, and approval-ready reply drafts without customer identifiers.
- **Approval:** read-only; reply drafts are held for the separately approved platform route in `workflows/marketing-actions.md`.
- **Failure handling:** return `PARTIAL` with the missing collection window or access state; do not retry any paid or quota-limited collection automatically.
- **Do not:** publish replies, send review requests, expose protected customer content, review-gate, solicit only positive reviews, or claim replies improve rankings.

### GBP profile change watch

- **Suggested schedule:** `repeat:daily(@07:00)` (the project chooses the actual schedule in `TODO.md`)
- **Targets:** supplied by the routine entry or a private targets file — never embedded here
- **Evidence source:** authorized, read-only GBP profile and attributes snapshots through `content/social-google-business-profile.md`, compared with a stored baseline.
- **Output:** `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/profile-changes/<date>.md` containing field-level diffs, retrieval metadata, and a review queue.
- **Approval:** read-only; proposed corrections are drafts held for `workflows/marketing-actions.md` or a separately authorized platform route.
- **Failure handling:** return `PARTIAL` when no comparable baseline or field coverage exists; preserve the prior baseline and do not retry quota-limited collection automatically.
- **Do not:** overwrite a baseline automatically after a suspicious change, treat absence from a change log as proof of unauthorised activity, or edit the profile.

### Quarterly citation audit

- **Suggested schedule:** `repeat:monthly(1@09:00)` with a project-side quarterly enablement rule
- **Targets:** supplied by the routine entry or a private targets file — never embedded here
- **Evidence source:** read-only inventory of approved listing URLs and the owner-approved location register, following `seo/local-seo.md`.
- **Output:** `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/citations/<date>.md` with observed URLs, substantive versus cosmetic differences, and net changes since the preceding audit.
- **Approval:** read-only; correction proposals are held for explicit owner approval and their authorized platform route.
- **Failure handling:** return `PARTIAL` with inaccessible, unverified, or missing inventory sources; do not use paid vendors or retry paid checks automatically.
- **Do not:** submit directories, edit listings, expose private addresses, force byte-identical formatting, or promise a ranking outcome from citation cleanup.

### Monthly local report

- **Suggested schedule:** `repeat:monthly(1@10:00)` (the project chooses the actual schedule in `TODO.md`)
- **Targets:** supplied by the routine entry or a private targets file — never embedded here
- **Evidence source:** completed prior local outputs only; render the report using `/report-render` without initiating new paid calls.
- **Output:** `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/reports/<date>.md` or the selected report artifact, with partial-data accounting, source dates, and evidence labels.
- **Approval:** read-only draft report; recommendations and external actions remain approval-ready handoffs under `workflows/marketing-actions.md`.
- **Failure handling:** return `PARTIAL` with every missing prior output, non-comparable metric, or coverage gap; do not backfill through new paid calls automatically.
- **Do not:** make causal claims without dated change logs, merge Maps, website, conversion, and revenue metrics into one claimed outcome, or publish the report without approval.

### Multi-location rollup

- **Suggested schedule:** `repeat:monthly(2@09:00)` (the project chooses the actual schedule in `TODO.md`)
- **Targets:** supplied by the routine entry or a private targets file — never embedded here
- **Evidence source:** completed per-location local outputs and their retained source metadata; do not initiate location-level collection for the rollup.
- **Output:** `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/rollups/<date>.md` with location-labelled aggregates, comparison constraints, and an explicit missing-location list.
- **Approval:** read-only draft report; any recommended listing or outreach action is an approval-ready handoff only.
- **Failure handling:** return `PARTIAL` with missing locations and non-comparable inputs listed; do not automatically retry paid collection or infer absent locations as zero.
- **Do not:** mix incompatible grid geometry or date ranges, conceal missing locations, edit any account, or claim rollup metrics prove causation.
