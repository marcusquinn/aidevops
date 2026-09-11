---
description: Verify and select press-release publication and syndication channels
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Press-Release Distribution

Use when the user asks where to publish, submit, or syndicate a press release.

## Positioning

Treat syndication as a supplementary public-record and entity-discovery channel,
not earned media. Never promise journalist pickup, Google News inclusion, search
or AI citations, backlinks, rankings, traffic, or publicity. Do not distribute a
release solely to manufacture ranking signals; Google's spam policies identify
optimized links in widely distributed press releases as link spam.

Run `newsworthiness-check.md` first. Prefer the canonical release on the user's
site, direct journalist outreach where justified, and audience-relevant channels.
Syndication should support those activities rather than replace them.

## Verification workflow

Pricing, editorial rules, ownership, reach, and availability change. Before every
recommendation or submission:

1. Find the service's official pricing or submission page through search; do not
   infer a URL or rely on third-party listicles.
2. Confirm the page is live, the free tier is explicit, and the terms apply to the
   user's organization, geography, language, and announcement type.
3. Separate verified platform features from vendor claims about reach, indexing,
   Google News, SEO, or AI visibility.
4. Review contact-data exposure, link policy, moderation, permanence, correction,
   removal, and paid-upgrade requirements.
5. Recommend only channels with a specific audience, archive, or distribution
   rationale. Low-quality open-publishing networks can weaken trust even when free.
6. Keep submission human-approved. Record the service, checked date, selected
   tier, canonical release URL, published URL, cost, status, and observed outcome.

## Verified starting points

This is a dated research snapshot, not a permanent allowlist. Re-verify before use.

| Service | Evidence checked 2026-09-11 | Working guidance |
|---|---|---|
| [PRLog](https://www.prlog.org/) | Free hosting plus search-engine and feed distribution; broader news-site and journalist distribution is paid | Viable free archive/feed candidate; do not imply broad media distribution |
| [openPR](https://www.openpr.com/news/submit.html) | One free release per 30 days; editorial, length, link, business-email, and postal-contact requirements | Viable when its disclosure and content rules fit |
| [PR.com](https://www.pr.com/press-release-pricing) | Free reduced distribution; links and wider packages cost extra | Compare the link cost and reduced reach with publishing only on the canonical site |
| [PRFree](https://prfree.org/pricing.php) | Free low-priority tier; search and AI discoverability are subject to its quality check | Use cautiously; treat discoverability statements as vendor claims |
| [BriefingWire](https://www.briefingwire.com/submitPR.aspx) | Free member submission; paid plans also offered | Verify current moderation and audience value before choosing |

## Candidate and exclusion notes

- **SubmitPR.org** operated and claimed free instant publication on 2026-09-11,
  but its reach, provenance, Google News, and SEO claims lacked independent support.
  Treat it as low-confidence and verify trust and audience fit before recommending.
- **PRUrgent** operated on 2026-09-11 but had moved to paid-only express plans;
  do not call it free.
- **Online PR News**, **Press Release Point**, and **PRSync** did not provide enough
  retrievable official pricing/submission evidence during the 2026-09-11 review.
  Do not recommend them as free without fresh verification.

## Output

Return a short decision table with `service`, `official evidence`, `checked date`,
`free-tier limits`, `trust/audience rationale`, and `recommend/hold`. Distinguish
published, indexed, syndicated, referred traffic, journalist interest, and earned
coverage as separate outcomes.

## Primary policy source

- [Google Search spam policies: link spam](https://developers.google.com/search/docs/essentials/spam-policies#link-spam), checked 2026-09-11.
