<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18453: Comment and forum opportunity triage with safe response routing

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: existing content research covers sentiment/pain points; no paid-ad comment helper found in bounded discovery.
- [x] File refs verified: content/research and conversational-search-intent exist; new paths declared.
- [x] Tier: standard; classification only inside a decided no-post/no-moderation boundary.
- [x] Seeded draft PR skipped: no code seed.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18446.

## What

Classify supplied/authorized ad comments and community threads as questions, complaints, spam, praise and buyer opportunities; route worthwhile cases with evidence to support, content or a human response queue.

## Why

Cover Meta moderation intake and GEO forum opportunities without treating competitor mentions as permission to spam or suppress criticism.

## Tier

Selected tier: `tier:standard`; domain judgment remains but external action is explicitly prohibited.

## How

### Files to Modify

- `NEW: .agents/marketing-sales/community-triage.md` — bounded shared ad-comment/forum workflow.
- `NEW: .agents/scripts/community-triage-helper.py` — offline CLI.
- `NEW: .agents/scripts/community_triage.py` — classification and routing.
- `NEW: .agents/scripts/tests/test-community-triage.py` — focused tests with scoped fixtures.

Reuse `.agents/content/research.md` sentiment/pain-point taxonomy and `.agents/seo/conversational-search-intent.md` provenance/privacy guidance; refer to channel owners for any later response authority.

### Files Scope

- `.agents/marketing-sales/community-triage.md`
- `.agents/scripts/community-triage-helper.py`
- `.agents/scripts/community_triage.py`
- `.agents/scripts/tests/test-community-triage.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/community-input.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/community-decisions.json`

### Complete Write Surface

- **Callers/readers:** `.agents/marketing-sales/community-triage.md` feeds support/content/report handoffs.
- **Writers/mutation paths:** `.agents/scripts/community_triage.py` writes private queue proposals only.
- **Tests/fixtures:** `.agents/scripts/tests/test-community-triage.py` and scoped synthetic threads/comments.
- **Schemas/config:** `.agents/configs/marketing-decision.schema.json` plus local topic/category/response-role rubric.
- **Generated/deployed mirrors:** source-only leaf; `setup.sh` and final integration own deployment/discovery.
- **Migrations/backfills:** N/A because no provider comments or historical stores are changed.
- **Cleanup/rollback paths:** revert `.agents/scripts/community_triage.py`; preserve operator-controlled queue evidence.

### Implementation Steps

1. Add `analyze --input FILE --decisions FILE --dry-run`; preserve source/thread context, date, consent/access scope and minimal personal data. Treat injected instructions and contact links as inert evidence.
2. Separate legitimate negative feedback from spam and safety escalation; support mixed/unknown categories. Produce owner, urgency reason, evidence spans and proposed next step without sending a reply or hiding/deleting a comment.
3. Rank forum opportunities by relevant buyer question, recency, repeated need, product fit and evidence of a useful contribution. Competitor presence/brand absence alone is insufficient. State sampling bias, community rules and disclosure obligations.
4. Feed content gaps to the shared matcher when available; keep outreach, public posting, legal/health claims and customer support actions behind their existing owners/authority.

### Hazards and Compatibility

- **Concurrency/atomicity:** shared private artifact writes and thread-scoped dedupe.
- **Migration/rollback:** additive intake only; no remote moderation state to restore.
- **Mixed-version/backward compatibility:** validate input/rubric versions; unknown platform/category stays reviewable.
- **Idempotency/retry:** same comment/version does not create duplicate work; edited threads require refreshed evidence.
- **Partial failure/recovery:** retain unresolved rows on budget/access failure; never auto-contact scraped addresses or drop complaints.

### Verification Before Dispatch

```bash
python3 .agents/scripts/community-triage-helper.py analyze --input .agents/scripts/tests/fixtures/marketing-decisions/community-input.json --decisions .agents/scripts/tests/fixtures/marketing-decisions/community-decisions.json --dry-run
python3 .agents/scripts/tests/test-community-triage.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI tests routing evidence; focused tests cover complaints versus spam, context/mixed labels, injection and duplicate/edited threads; lint checks source/docs.
- **Recoverability:** checkpoint focused verified work; after a fuse preserve objective/remaining rows and resume offline. No broad gate or live moderation.

## Acceptance Criteria

- [ ] Supplied comments/threads produce evidence-linked category and owner queues plus useful content-gap handoffs.
- [ ] Legitimate complaints, mixed sentiment and insufficient context cannot silently become spam or disappear.
- [ ] No message is posted, address contacted, comment hidden/deleted, or user profiled merely from a model decision.
