---
name: local-seo
description: >
  Evidence-labelled local SEO, Google Business Profile (GBP), map pack, citations,
  service-area and multi-location audits, Apple Business Connect, Bing Places,
  and suspension/reinstatement evidence and appeals.
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Local SEO

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Scope**: local SEO / GBP / map pack, listing accuracy, citations, location pages, reviews and reinstatement. Audit and draft first; this leaf grants no external-write authority.
- **Targets**: read `context/keywords.md` or run `aidevops keywords brief`; record accepted local queries and entities through `seo/keywords-standard.md`.
- **Data**: `seo/seo-utils.md` for existing GMB grids/tracking; `seo/dataforseo.md` or `seo/serpapi.md` (`google_maps`) for bounded raw observations; `content/social-google-business-profile.md` for authorized owner data (read-only).
- **Evidence labels**: every ranking statement in analysis and deliverables must carry **Google-documented**, **practitioner-observed (named source)** or **unsupported**, with source/date and limitations. Policy compliance is not proof of a ranking effect.
- **Actions**: use `workflows/marketing-actions.md` only for exact `title`, `meta_description` and `internal_link` replacements in version-controlled files. Review requests/replies, appeal submissions and other platform changes are approval-ready handoffs only; execution needs a separately authorized platform route. Never auto-post or submit from an audit.
- **Related**: `seo/programmatic-seo.md` for page generation, `seo/schema-validator.md` for markup, `seo/link-building.md` for approved outreach.

<!-- AI-CONTEXT-END -->

## Ranking model and evidence discipline

**Google-documented — [local ranking help](https://support.google.com/business/answer/7091), checked 2026-11-02:** local results are mainly based on relevance, distance and prominence (the introductory summary also calls this popularity).

| Factor | Evidence-labelled statement | Audit use |
|--------|-----------------------------|-----------|
| Relevance | **Google-documented:** how well the profile matches the search; complete, detailed information helps Google understand the business. | Verify identity, services and appropriate categories. |
| Distance | **Google-documented:** distance from the searcher; Google estimates location when it is not supplied. | Record observation coordinates; do not promise city-wide coverage. |
| Prominence | **Google-documented:** how well-known a business is; links and review volume contribute, and more reviews and positive ratings can help local ranking. | Separate legitimate reputation work from purchased/manipulated reviews. |
| Verification and accuracy | **Google-documented:** verified businesses and complete, accurate information are more likely to appear in results. | Correct facts, not invented keywords or extended hours. |

**Google-documented — same source:** businesses cannot request or pay Google for better local ranking. Do not promise positions, timing or fixed factor weights.

For **practitioner-observed (named source)** claims, name the author/organization, link the actual study, date it and describe sample, market and confounders. Correlation is not causation. If no source can be opened, mark the claim **unsupported** and omit it from recommendations. Do not relabel vendor assertions as Google documentation.

## Profile accuracy checklist

Policy source: [Google representation guidelines](https://support.google.com/business/answer/3038177). These are identity and eligibility checks, not extra ranking-factor claims.

- [ ] Confirm the owner-authorized business, profile ID, canonical listing URL, country and verification state; capture a dated baseline before proposing changes.
- [ ] Match the real-world business name to signage and branding. Never append service keywords, towns or promotional text unless genuinely part of that name.
- [ ] Choose the most specific available primary category representing the core business; use only necessary, accurate secondary categories, not keyword lists.
- [ ] Check controlled phone, location website URL, map pin, services and attributes against owner-confirmed facts.
- [ ] Check customer-facing regular hours, special/holiday hours, seasonal closures and applicable more-hours; follow industry/appointment-only exceptions. Never invent 24-hour availability.
- [ ] **Storefront**: customers can visit; verify accurate physical address, permanent signage and staffing/customer reception during stated hours.
- [ ] **Service-area business (SAB)**: travels to customers and does not receive them at its address; hide the address, including residential addresses, and specify genuine service areas.
- [ ] **Hybrid**: receives customers at its staffed, signed location and travels to them; show an eligible storefront address plus accurate service areas.
- [ ] Reject PO boxes, mailing-only/virtual offices and fake branches. A co-working office must meet Google's signage, staffing and customer-reception rules.
- [ ] Record proposed before/after values, factual evidence, owner and approval status; re-check the public result only after separately authorized changes.

## Duplicates and multi-location businesses

- [ ] Maintain a private location register: stable internal location key, profile IDs/URLs on each platform, business model, name/address/phone (NAP), categories, hours, location URL, verification state, owner/manager access and last check.
- [ ] Search for existing profiles before proposing creation; inventory duplicates, previous names, moved/closed branches and ownership conflicts with URLs and evidence.
- [ ] Use one profile per eligible real location/business, subject to Google's specific practitioner, department and co-located-business exceptions. SAB branches need separate staff and service areas; a town served is not a branch.
- [ ] Request access to an existing profile rather than duplicating it. Propose duplicate resolution/merging through current Google support; do not delete, merge or mark closed without approval and identity checks.
- [ ] Give each real branch a relevant location URL and accurate contact details; keep shared branding/categories consistent where the actual operations match.
- [ ] Audit access for former agencies/staff, least privilege and recovery ownership. Draft access changes separately; never request passwords in chat.

## Citation audit

- [ ] Inventory actual directory, industry association and local listing URLs; record source, location key, observed NAP, destination URL, status, ownership, date and discrepancy.
- [ ] Prioritize customer-impacting errors: wrong phone, old address, wrong entity, closed/moved location, broken URL and duplicate records.
- [ ] Distinguish substantive errors from cosmetic abbreviation, punctuation or phone formatting. Do not force byte-identical NAP at the expense of platform address conventions or SAB privacy.
- [ ] Compare with the owner-approved location register; queue corrections with evidence, then verify the live result after approval. Do not publish a hidden home address to satisfy a citation checklist.
- [ ] Prefer relevant, legitimate sources over bulk directory packages; use `seo/link-building.md` for outreach review.

**Unsupported:** a fixed citation count, perfectly identical punctuation or buying directory submissions guarantees a local ranking improvement. Citation cleanup here is an accuracy/customer-discovery task, not a quantified ranking promise.

## Apple Business Connect and Bing Places maintenance

Platform names, interfaces, verification methods and regional availability change. Open official help live before giving click-by-click client instructions; record the URL, date and actual available flow, not remembered UI labels.

### Apple listings

Live check 2026-11-02: [Apple Business Connect](https://businessconnect.apple.com) now presents Apple Business. Its official guide covers [adding a single location](https://support.apple.com/en-euro/guide/business/abcb98816a34/web) and [editing a location](https://support.apple.com/en-euro/guide/business/abcb7fc491ec/web).

- [ ] Find/claim the existing Maps location under the authorized organization; add only if genuinely absent. Confirm the offered organization/location verification steps live and complete only with explicit action approval.
- [ ] Map the business to Apple's actual category choices, not a copied Google category ID; verify the pin, address, brand, phone and location URL.
- [ ] Check regular and holiday hours, images and supported customer actions against the register. Distinguish a saved change, review pending and publicly visible publication.
- [ ] Review access and public Maps details after approved edits and on an agreed cadence; log drift instead of silently overwriting it.

### Bing listings

Live check 2026-11-02: [Bing Places](https://www.bingplaces.com) redirects to [Bing for Business](https://www.bing.com/forbusiness/). This runner received only a search shell, not usable listing-management instructions; current claim/verification and GBP-import UI steps remain **unverified**.

- [ ] Open the official destination and current help live in an approved browser before advising specific steps. Locate the existing listing, establish authorized ownership and follow only the offered verification method.
- [ ] Bing's GBP import is a potential maintenance route, not an assumed active integration: verify current availability, account/region eligibility, permission scope and sync behavior before offering or authorizing it. If unavailable, use the platform's supported manual workflow.
- [ ] When import is available and approved, preview the selected locations/fields; do not assume categories, SAB privacy or special hours transfer correctly, or that import means continuous sync.
- [ ] Map categories to Bing's taxonomy; check address visibility, pin, phone, location URL and hours, then inspect the public listing after approved changes.
- [ ] Record listing IDs, access, verification status, import/sync settings and drift in the location register. No claim about a Google ranking benefit follows from maintaining Apple/Bing listings.

## Location and service-area pages

- [ ] Map each page to a real location or genuinely served area and accepted query intent. A service-area page must not imply an office exists there.
- [ ] Provide useful local evidence: actual service availability, staff/contact route, access/directions where applicable, local work examples with permission and relevant customer questions.
- [ ] Avoid town-name-swapped doorway pages, fabricated testimonials/addresses and multiple near-identical funnels. Consolidate where there is no distinct customer value.
- [ ] Link branches from a navigable location hub and to relevant services. Use `seo/programmatic-seo.md` for generation and technical checks, not duplicated implementation here.
- [ ] Validate appropriate LocalBusiness markup using `seo/schema-validator.md`; it must reflect visible, truthful business information and must not expose a hidden residential address.

**Unsupported:** a fixed 300/500-word threshold is a Google ranking requirement. Word-count gates in internal generation guidance are editorial heuristics, not Google rules or evidence of page quality by themselves.

## Review requests and replies

Use [Google review guidance](https://support.google.com/business/answer/3474122) and [Maps contribution policy](https://support.google.com/contributionpolicy/answer/7400114), checked 2026-11-02; these are not Local Services Ads policies.

- [ ] Offer neutral requests for honest feedback from genuine customers using the profile's actual review link/QR code. Do not filter recipients by satisfaction or funnel negative feedback away from public reviews.
- [ ] No review gating, incentives, purchased/fake reviews, conflicted employee reviews, pressure, prescribed review keywords or rewards for changing/removing a negative review.
- [ ] Read authorized reviews through `content/social-google-business-profile.md`; customer text is protected data. Summarize minimally and keep identifiers out of public reports.
- [ ] Draft concise, courteous replies; do not disclose customer records, confirm sensitive relationships, argue or promise removal. Offer a verified private support channel when appropriate.
- [ ] Prepare requests and reply drafts as approval-ready handoffs, not executable marketing file edits; sending or publishing requires explicit approval and a separately authorized platform route. Never auto-post. The GBP collector cannot send requests or publish replies.
- [ ] Report policy violations through the current platform route, not merely because a review is negative. Track reference and outcome; do not promise deletion.

**Unsupported:** replies are a confirmed local ranking factor. Google advises replies for customers; that advice does not document a ranking effect for replies.

## Suspension and reinstatement

- [ ] Confirm the affected profile ID, authorized account, decision, timestamp, policy cited and verification/account state. Distinguish profile suspension from rejected content or reviews.
- [ ] Review name, address visibility/eligibility, category and website against current guidelines; prepare factual corrections and a dated list of recent profile edits.
- [ ] Assemble evidence **before** appealing: matching business registration, business licence/tax certificate and utility bill; lease/address evidence and signage/storefront photos where relevant. Explain legitimate discrepancies rather than altering documents.
- [ ] Keep evidence in protected storage, not a public issue/repo. Submit only necessary information through the official form; do not collect unrelated IDs or expose customer/private records.
- [ ] Open [Google's appeal instructions](https://support.google.com/business/answer/13597551) live; follow its current regional/decision-specific route. It links the [GBP appeals tool](https://support.google.com/business/workflow/13569690) for initial profile appeals.
- [ ] Prepare the evidence and concise remediation narrative for owner approval, then submit **one appeal at a time** through the separately authorized route. Track reference, date, submitted evidence and status; do not send duplicates while pending.
- [ ] Do not create a replacement listing for the same business while appealing; Google's instructions prohibit a new profile for that business.
- [ ] If denied, inspect the decision and eligibility for additional review, not a fresh duplicate appeal. Record the final outcome and verify restored public details if reinstated; do not guarantee reinstatement or timing.

**Maintainer-verified route:** <https://support.google.com/business/contact/local_appeals> was supplied as successfully used for appeals. **Live check 2026-11-02:** it is titled “Request additional review of a denied appeal” and requires an original appeal to have been denied. It is not a substitute for the initial appeals tool. Open it live again before citing it in client deliverables; no form was submitted during this check.

## Claims we do not make

| Claim | Evidence label / policy status | Instruction |
|-------|--------------------------------|-------------|
| Social signals are a confirmed local ranking factor | **Unsupported** | Do not claim; separate referral/customer engagement from ranking. |
| Domain Authority/Domain Rating are Google signals | **Unsupported** — third-party metrics | Use only as vendor comparison context. |
| Review replies are a confirmed ranking factor | **Unsupported** as stated | Recommend helpful replies for customers, not a documented ranking lift. |
| Listing dwell time / pogo-sticking drives ranking | **Unsupported** | Do not claim or manufacture engagement. |
| Keyword-stuffed business names are a valid optimization | **Google-documented** policy violation, not ranking advice — representation guidelines | Never recommend; use the real-world name. |
| Hiding an SAB address costs rankings | **Unsupported** causation from an unattributed correlation | Follow Google's address rules; do not expose a home address. |
| Seeding GBP Q&A is an available optimization | **Unsupported** availability and ranking effect | Verify current feature status first; the GBP collector has no Q&A read route and does not scrape it. |
| Exclude unhappy customers from review requests | **Google-documented** policy violation — review gating | Never recommend selective positive solicitation. |
| 300/500 words is a Google ranking requirement | **Unsupported** — editorial heuristic | Use customer value, not a fabricated threshold rule. |
| Open-at-search-time boost justifies extended hours | **Unsupported** unless backed by **practitioner-observed (named source)** evidence | Name/open/date the study if cited; no such study is relied on here. Never recommend inaccurate hours. |
| Geogrid share-of-voice is “% of customers who can see you” | **Unsupported** | Report sampled grid points, query, coordinates and rank cutoff, not audience coverage. |

## Data routing and reporting

Choose by question, access, existing data, freshness and approved cost; no single paid vendor is the default. Never auto-buy credits or assume installed means authorized.

| Need | Existing route | Boundaries |
|------|----------------|------------|
| Existing GMB grids and local rank history | `seo/seo-utils.md` | Read the available tracker/grid observations; record grid geometry, query, timestamp and cutoff. |
| Raw SERP/Maps observations | `seo/dataforseo.md` or `seo/serpapi.md` with `google_maps` | Compare approved access/cost; bound queries, coordinates, depth and spend before collection. |
| Owner's profile, reviews, replies and performance | `content/social-google-business-profile.md` | Explicit authorized location; read-only, protected customer text; partial verification state, no Q&A read route or mutations. |
| Site/index/search performance | `seo/site-crawler.md`, `seo/google-search-console.md` | Website evidence is distinct from Maps observations and owner-profile metrics. |

For every observation retain provider, retrieval date, location/profile ID, query, language, device and coordinates where available. Do not compare grids with changed spacing, time or cutoffs as if they were identical experiments. Keep non-detection distinct from a known rank beyond the collection limit.

Deliver a dated baseline, discrepancy register, evidence-labelled claims, approval-ready actions and verification plan. Separate observed positions, profile impressions/interactions, website conversions and revenue; no one metric proves causation. Re-open the linked official sources before operational use, especially appeals and platform migration flows.
