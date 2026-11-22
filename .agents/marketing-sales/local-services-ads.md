<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

## Local Services Ads and local paid search (proposal-only)

Prepare evidence-backed proposals only. Agents must not change budgets or bids, submit disputes or lead feedback, edit accounts or Business Profiles, link accounts, upload verification documents, or activate campaigns. No Google Ads/LSA API integration or vendor adapter is provided. An authorized human owns all account actions; approval does not turn this guide into an execution workflow. Search-term hygiene remains in `marketing-sales/google-ads-triage.md`.

### Choose the appropriate product

| Product | What it is | When to propose it |
|---------|------------|--------------------|
| Local Services Ads (LSA) | Pay-per-lead advertising for eligible service categories and markets; customers contact the selected provider by supported lead channels. A lead is not a guaranteed booked job. | The business qualifies and has capacity to answer and fulfil service enquiries. |
| Search campaigns with location assets | Search ads enriched with location information, such as address, phone and directions; not LSA pay-per-lead billing. | Search intent and landing-page targeting matter, alongside relevant local business information. |
| Maps/local search ads | Local ad placements, including Maps pins and search results, available through eligible Search and Performance Max campaigns with location assets. Not a separate LSA product or a promise of Maps placement. | Calls, directions and visits are useful outcomes for the business; verify campaign and location eligibility. |

Google's [Local Ads overview](https://support.google.com/google-ads/answer/3246303) and [location assets documentation](https://support.google.com/google-ads/answer/2404182) describe these placements and prerequisites. Local Ads billing depends on configuration: Search and Performance Max may charge CPC for eligible clicks; Performance Max for store goals charges CPM for branded logo pin impressions on Maps. Do not label all Maps ads pay-per-lead or all Maps formats CPC.

### LSA readiness checklist

Record each item as confirmed, missing, or unknown, with source and check date. These are review prompts, not instructions to change settings.

- [ ] **Eligibility:** country, region and service category are currently supported. Open [Getting started with LSA](https://support.google.com/localservices/answer/6224841?hl=en&ref_topic=10491040), select the actual country and verify eligibility live; the opened page defaulted to the United States. Do not generalize its category list globally.
- [ ] **Verification:** record business registration, licence, insurance, background checks and any additional checks Google requires for this category/location. Use [screening and verification](https://support.google.com/localservices/answer/6226575?hl=en&ref_topic=10491040) and the human-supplied dashboard requirements. Verify per market: not every check applies everywhere, and requirements may change or be repeated. Record status and expiry dates, not sensitive identity documents or background-check results.
- [ ] **Linked GBP:** confirm the matching Google Business Profile, ownership/management authorization and connection status from first-party evidence. Do not create a duplicate profile or request access on the business's behalf.
- [ ] **Service area and job types:** compare recorded coverage with work the business can actually fulfil, including exclusions and capacity. Flag mismatches as proposals only.
- [ ] **Budget and bidding:** record current budget, currency, billing period and bidding mode from an owner-provided snapshot; identify missing evidence and propose bounded options, never a default spend increase or an account change.
- [ ] **Hours and lead-answer coverage:** compare business hours and ad schedule with staffed call/message coverage, weekends and holidays. Name the human response owner, escalation route and capacity limits; do not imply 24-hour availability without evidence.
- [ ] **Measurement:** obtain authorized, redacted LSA lead/billing exports, call/message logs and booking/CRM outcomes for the same reporting cohort. Identify missing tracking before recommending spend.

### Ranking: Google's documented factors only

Source: [About ad rankings](https://support.google.com/localservices/answer/7527305?hl=en&ref_topic=10491040), opened 2026-11-02. Reopen it before client recommendations; preserve the check date and actual market. Google describes an auction taking bid and overall profile quality into account. Its listed factors are:

- **Bid:** the maximum amount the advertiser is willing to pay per lead, though actual payment may be lower. Google recommends Maximize Leads on this page; that is not authorization for an agent to select or change a bidding mode.
- **Likelihood of producing a lead**, including:
  - Responsiveness to customer inquiries and requests; missed calls may negatively affect responsiveness.
  - Customer search context (service/job, time, location and other characteristics) and business relevance (services and business bio).
  - Message and/or booking leads providing more ways to contact the business, potentially increasing lead likelihood, especially at nights/weekends.
  - Profile quality: rating, review count, average response time, high-quality images, completed verification checks, and other business information that may influence user preferences.

Google additionally says ranking optimizes for ecosystem health and diversity, provides opportunity for all providers, and is subject to experiments. For multiple business locations serving the same area, it shows only the highest-ranking ad for a query. These are Google's descriptions, not numerical weights or a factor hierarchy. Do not import organic local-ranking factors into LSA ranking claims.

### Measurement from first-party evidence

Fix the reporting window, timezone, currency, account/product and lead cohort before calculation. Join stable lead IDs to CRM/call records; deduplicate repeated contacts for the same lead and preserve charged, uncharged, credited, answered and booked statuses separately. Show raw numerators and denominators alongside rates. Never treat a click, directions request or ringing phone as a booked job.

| Measure | Definition and evidence |
|---------|-------------------------|
| Lead count | Distinct leads received in the cohort from the first-party lead export, split by channel and charge status; not clicks or impressions. |
| Answer rate | Answered incoming lead calls / all incoming lead calls × 100, using call logs for the cohort; voicemail-only and missed calls are not answered. Report message response rate separately, with a stated response window. |
| Booked-job rate | Distinct cohort leads with at least one confirmed job booking / distinct cohort leads × 100, using CRM/booking evidence. Report completed jobs and cancellations separately. |
| Cost per lead | Attributable ad spend / distinct cohort leads. State whether spend is gross charges or net of posted credits; show charged-lead count separately and label any charged-lead-only calculation explicitly. |
| Cost per booked job | The same attributable ad spend / confirmed booked jobs linked to cohort leads. Count unique job IDs and disclose if a lead produces multiple jobs. |
| Disputed-lead rate | Distinct charged cohort leads with a documented human-submitted dispute / distinct charged cohort leads × 100. This is historical/account evidence only, not an instruction to dispute; label unavailable where that process does not exist. |

Use “not available” for missing evidence or a zero denominator, never an invented zero cost or conversion rate. Distinguish observed no bookings from missing booking data. Show the outcome cutoff and booking lag; recent cohorts may be incomplete. Keep LSA, Search and Maps reporting separate where attributable, and label unknown placement rather than allocating spend speculatively. These are operating measures, not ROI: revenue and profit cannot be inferred from lead counts.

### Lead quality and credit policy

Google's current [automated lead credits guidance](https://support.google.com/localservices/answer/15100654), opened 2026-11-02 through its “How to dispute charges” link, describes automatic assessment and reassessment, not a universal manual dispute route. It states credits are unavailable for health care verticals, tax specialists and EMEA advertisers, and no longer supports credits for “job type not serviced” or “geo not serviced” leads. Verify per market before making any eligibility claim.

Separate not-charged, charged, in-review and credited leads in reports. Automated credits and human lead feedback are not disputes; do not relabel them to populate disputed-lead rate. Record observed credits and pending statuses from exports, not expected refunds. Agents may prepare a redacted lead-quality evidence summary for the account owner; they must not submit a dispute, feedback survey or account change.

### Claims we do not make

- Unsourced LSA ranking hierarchies, numerical factor weights or third-party factors absent from the cited Google ranking page.
- Guaranteed placements, guaranteed lead volumes, guaranteed bookings or automatic credit entitlement.
- Inferences about competitor budgets, bids or responsiveness from ad positions.
- Claims that paid local ads improve organic Maps rankings or that LSA and Google Ads location assets share one auction or billing model.

### Proposal deliverable

Provide the product fit, readiness gaps, dated primary sources, reporting cohort and raw metrics, evidence limitations, proposed options and named human owner. Keep recommendations separate from observed facts. All cited Google pages above were opened on 2026-11-02; this is a dated policy snapshot, not perpetual validation. Recheck the live market-specific rules before reusing it.
