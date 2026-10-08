---
description: Link-building strategies - competitor backlink gap with topical-reason outreach and human approval
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Link Building

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Earn editorial backlinks with evidence-based, human-approved outreach
- **Data**: Ahrefs (`seo/ahrefs.md`), DataForSEO Backlinks (`seo/dataforseo.md`), Semrush backlinks API (`seo/semrush.md`)
- **Sending**: `/email-outreach` (`services/email/email-outreach.md`) under `services/outreach/cold-outreach.md` guardrails
- **Monitoring**: `seo/backlink-checker.md` (new/lost links, reclamation)
- **Core strategy**: Competitor backlink gap → topical reason per prospect → manual approval → agent-sent outreach

**Hard rules**: no send before human approval; no pitch without a real, page-specific reason; no paid or exchanged links presented as editorial.

<!-- AI-CONTEXT-END -->

## Strategy: Competitor Backlink Gap with Topical-Reason Outreach

A site that already links to a competitor has shown interest in the topic. The
agent's job is to find a real reason for that site to link to us as well. The
human's job is to approve the pitch. The agent then sends it.

### 1. Export competitors' best backlinks

- Pick 3-5 competitors that rank for our target queries (`context/keywords.md`,
  `seo/keyword-research.md` competitor mode). Use the competitors that actually
  rank in search, not only direct business rivals.
- Export referring domains and backlinks for each competitor. Ahrefs:
  `site-explorer/refdomains` and `site-explorer/all-backlinks` (`seo/ahrefs.md`).
  DataForSEO: `/v3/backlinks/referring_domains/live`. Semrush: `backlinks` and
  `backlinks_refdomains` (`seo/semrush.md`).
- Keep links that are **best**: live, dofollow, editorial in-content placements
  on pages that are relevant and get real traffic, from domains with reasonable
  authority. Drop sitewide/footer links, directories, link farms, PBN patterns,
  scraped mirrors, comment/forum spam and unrelated topics.
- Drop domains that already link to us (the gap step). Prioritise domains that
  link to two or more competitors (link intersect).
- Store exports and the working prospect list under
  `~/.aidevops/.agent-workspace/work/seo-data/{domain}/link-building/`, recording
  the source and capture date.

### 2. Find a topical reason for each prospect

For each prospect, read the actual linking page before drafting anything:

- **Why it links to the competitor**: the claim, resource, statistic, tool or
  definition the link supports.
- **Our matching asset**: a specific URL on our site that is more current, more
  complete, more original (data, tool, template, case study) or covers a gap the
  page leaves open.
- **Angle**: one of: replacement (outdated or broken competitor resource),
  addition (complements existing references), correction (data has changed),
  expert source (quote or original data for the page's topic).
- **Placement**: the sentence or section where our link would help the reader.

If there is no real reason, reject the prospect. If several strong prospects
need an asset we don't have, log it as a content gap (`content.md`) instead of
pitching a weak page. Do not invent claims, statistics or relationships.

### 3. Manual approval

Present prospects in batches for human review. Nothing is sent before approval.

```text
Prospect domain / linking page URL:
Competitor linked + anchor/context:
Link quality evidence (DR, traffic, dofollow, placement, capture date):
Our target URL:
Angle + topical reason (1-2 sentences, page-specific):
Contact (name, role, public source):
Draft email (subject + body):
Risks / flags:
Decision: approve | edit | reject (+ reason)
```

Use rejected prospects and edits to improve the next batch's selection and
copy.

### 4. Agent-sent outreach

- Send only approved, unedited-since-approval drafts through `/email-outreach`
  (Smartlead, Instantly, ManyReach). Apply `services/outreach/cold-outreach.md`:
  warmed dedicated sending domains, volume caps, CAN-SPAM/GDPR controls, and
  suppression lists.
- Write one short, personal email per prospect. Name the page, explain the
  reason and offer the link. Use at most one or two polite follow-ups. Do not
  use mass templates.
- Stop the sequence on any reply. Route positive replies, questions and
  negotiation to the human owner. Any request for payment or a link swap goes
  back to the human; never agree to it automatically.
- Record outcomes per prospect: sent, replied, linked, declined, no response.

### Measure and maintain

- Verify won links are live and check their attributes (`rel`, placement) with
  `seo/backlink-checker.md`. Re-check periodically for lost links.
- Track the win rate by angle and prospect type, plus the referral traffic and
  ranking movement for target pages. Treat ranking changes as correlation.
- Re-run the competitor gap periodically. New competitor links are fresh
  prospects.

## Guardrails

- Google treats paid links, excessive link exchanges and manipulative outreach
  as link spam: https://developers.google.com/search/docs/essentials/spam-policies#link-spam
  If a placement is paid or sponsored, it must be qualified (`rel="sponsored"`)
  and reported separately, not as an editorial win.
- Use only contact details that are publicly listed for business purposes, and
  honour opt-outs across all campaigns.
- Keep competitor data within the provider's terms of use. Never reuse
  prospects' content or claim endorsements that don't exist.

## Related

- `seo/backlink-checker.md` - backlink monitoring and lost-link reclamation
- `seo/youtube-description-link-acquisition.md` - disclosed YouTube description placements (experiment)
- `seo/ahrefs.md`, `seo/dataforseo.md`, `seo/semrush.md` - backlink data sources
- `services/outreach/cold-outreach.md` - deliverability and compliance
- `services/email/email-outreach.md` - campaign launch and management
- `marketing-sales.md` - relationship and commercial ownership
