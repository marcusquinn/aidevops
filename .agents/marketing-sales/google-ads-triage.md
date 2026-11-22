<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

## Google Ads hygiene and search-term triage

Use `.agents/scripts/google_ads_triage.py analyze --input SNAPSHOT --decisions DECISIONS --dry-run` to create offline, evidence-backed proposals. It never authenticates to Google Ads or changes an account.

The report covers search intent, negative conflicts, keyword/ad-group fit, RSA relevance, landing-page matching, routing, brand classification, and policy/disapproval routing. It preserves campaign/ad-group scope in each evidence record. Treat every output as a proposal: do not add negatives, adjust budgets or bids, submit appeals, dismiss recommendations, or change conversion settings.

To apply an approved subset, write it as Google Ads action input and use the approval-bound adapter in `workflows/marketing-actions.md` ("Google Ads Account Actions"). That covers negative keywords, keyword pause/enable, Maximize Clicks with a CPC ceiling, and budget amounts. The flow is a validate-only plan, then `sudo aidevops approve marketing-plan`, then apply, with rollback available. Everything else stays manual.

Negative conflict detection uses only explicit exact, phrase, and broad matching rules. Semantic resemblance and close variants do not block a query. Terms with conversions, profitability, missing outcomes, or ambiguous brand classification remain review outcomes. Supply account-specific brand aliases and business definitions in the snapshot rather than inferring them.

LSA and local campaign guidance lives in `marketing-sales/local-services-ads.md` (proposal-only).
