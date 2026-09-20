<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18469: Scoped public-engagement authority on the existing social outbox

## Pre-flight

- [x] Memory recall: public-engagement/Reddit/approval query returned no relevant lessons.
- [x] Discovery pass: source 8a0372261; existing Reddit publishing and immutable approval queue inspected; prework discovery and open engagement/outbound/standing-authority searches found no duplicate or conflicting PR.
- [x] File refs verified: outbound intent, claim, provider-start, query, schema/migration and Reddit adapter paths exist; prospecting service paths are delivered by t18466.
- [x] Tier: thinking; delegated publishing authority and migration of security-sensitive shared queue paths require coherent design.
- [x] Seeded draft PR skipped: this is a background implementation brief, not authority to activate or test a real account.

## Origin

2026-09-20 interactive follow-up: the maintainer asks to brief a subagent for automated public engagement too. Parent: t18459 / #32076. blocked-by:t18466 / #32085. This explicitly adds an optional engagement lane; the nine core prospecting tasks retain their no-posting boundaries. Auto-dispatch authorizes implementation, not live account activation or sending.

## What

Extend the existing owner-only social outbox with narrowly scoped, owner-authenticated standing grants for unattended Reddit text posts/replies. Preserve per-draft exact approval as the default. Deliver the policy/authority CLI and service contract consumed by t18470, without creating another publisher or allowing an agent to approve its own authority.

## Why

Reddit post/reply transport, immutable operation hashes, approvals, fenced attempts and ambiguous-result reconciliation already exist. The missing capability is explicit bounded delegation for future drafts, not another PRAW wrapper or a loop calling operation-approve on every generated reply.

## Tier

**Selected tier:** `tier:thinking` — authority separation, atomic budgets and legacy reader compatibility are consequential security decisions.

## How

### Files to Modify

- `NEW: .agents/scripts/public-engagement-policy-helper.py` — inspect/preview and owner-controlled grant lifecycle.
- `NEW: .agents/scripts/_public_engagement_policy.py` — scope, expiry, suppression, reservation and decision contract.
- `NEW: .agents/scripts/_knowledge_social_outbound_delegation.py` — policy-derived authorization integrated with the existing outbox.
- `NEW: .agents/configs/public-engagement-policy.schema.json` — versioned disabled-by-default policy.
- `NEW: .agents/reference/public-engagement-policy.md` — authority, privacy, recovery and activation runbook.
- `NEW: .agents/scripts/tests/test-public-engagement-policy.py` — focused authority/race/regression tests and synthetic fixture.
- `EDIT: .agents/scripts/_knowledge_social_outbound.py` — explicitly distinguish exact owner approval from delegated authorization.
- `EDIT: .agents/scripts/_knowledge_social_outbound_claim.py` — atomic scoped claim and cap reservation.
- `EDIT: .agents/scripts/_knowledge_social_outbound_runtime.py` — recheck authorization immediately before provider start.
- `EDIT: .agents/scripts/_knowledge_social_outbound_queries.py` — bounded eligible operations without broadening legacy eligibility.
- `EDIT: .agents/scripts/_knowledge_social_store_schema.py` — private grant/authorization/reservation state.
- `EDIT: .agents/scripts/_knowledge_social_store_migration.py` — fail-closed additive migration and rollback evidence.
- `EDIT: .agents/scripts/knowledge_social_operations.py` — typed integration and sanitized receipt metadata.
- `EDIT: .agents/scripts/prospecting_api.py` — predecessor-owned explicit owner grant controls and separately scoped executor routes.
- `EDIT: .agents/scripts/prospecting_auth.py` — predecessor-owned owner versus engagement-executor permissions.
- `EDIT: .agents/configs/prospecting-openapi.json` — document explicit new permission boundary; read tokens remain read-only.
- `EDIT: .agents/content/social-reddit.md` — document the opt-in delegation exception, never direct SDK writes.
- `EDIT: .agents/aidevops/knowledge-plane/05-social-operations.md` — preserve collection isolation and exact-approval defaults.

Reference `_claimable_operation` and `mark_provider_started` in the named queue files. `.agents/scripts/_knowledge_social_reddit_outbound_provider.py` already supplies bounded identity-checked post/reply transport. Reuse it unchanged unless a separately evidenced defect needs its own task. Do not repurpose GitHub approval signatures as social publishing grants.

### Files Scope

- `.agents/scripts/public-engagement-policy-helper.py`
- `.agents/scripts/_public_engagement_policy.py`
- `.agents/scripts/_knowledge_social_outbound_delegation.py`
- `.agents/configs/public-engagement-policy.schema.json`
- `.agents/reference/public-engagement-policy.md`
- `.agents/scripts/tests/test-public-engagement-policy.py`
- `.agents/scripts/tests/fixtures/public-engagement/policy.json`
- `.agents/scripts/_knowledge_social_outbound.py`
- `.agents/scripts/_knowledge_social_outbound_claim.py`
- `.agents/scripts/_knowledge_social_outbound_runtime.py`
- `.agents/scripts/_knowledge_social_outbound_queries.py`
- `.agents/scripts/_knowledge_social_store_schema.py`
- `.agents/scripts/_knowledge_social_store_migration.py`
- `.agents/scripts/knowledge_social_operations.py`
- `.agents/scripts/prospecting_api.py`
- `.agents/scripts/prospecting_auth.py`
- `.agents/configs/prospecting-openapi.json`
- `.agents/content/social-reddit.md`
- `.agents/aidevops/knowledge-plane/05-social-operations.md`

### Complete Write Surface

- **Callers/readers:** t18470 and `.agents/scripts/knowledge_social_operations.py` consume policy decisions and content-free authorization/attempt receipts.
- **Writers/mutation paths:** `_knowledge_social_outbound_delegation.py` alone integrates scoped authorization/reservations; actual sends remain in the existing mapped provider queue.
- **Tests/fixtures:** `.agents/scripts/tests/test-public-engagement-policy.py`, synthetic policy.json and existing social operations/provider/sharing suites.
- **Schemas/config:** `.agents/configs/public-engagement-policy.schema.json`, prospecting-openapi.json and private social schema; no secret values or live policies in Git.
- **Generated/deployed mirrors:** source deploys via `setup.sh`; no deployed changes, new MCP write tools, global permissions or enabled routines.
- **Migrations/backfills:** `_knowledge_social_store_migration.py` keeps old exact approvals exact; no legacy row is promoted into standing authority.
- **Cleanup/rollback paths:** `public-engagement-policy-helper.py` revokes grants/pauses unstarted work while preserving immutable receipts; backup-aware migration recovery never resets unknown sends.

### Implementation Steps

1. Define modes disabled, exact-draft approval and explicitly owner-enabled policy automation. Trace the delivered owner-authenticated service boundary before implementation. Only an owner control path may create, select, broaden, renew or revoke a grant. A caller-supplied owner flag, model decision, filesystem UID or routine config alone is not consent. Executor credentials cannot administer grants or access owner credentials/signing material; failure to prove the boundary leaves automation disabled.
2. Bind each grant to project/corpus, stable account/connection, Reddit provider, explicit community allowlist, text post/reply actions, validity window, evidence/disclosure policy, hard per-account/community/time-window caps and per-thread cooldown/turn limits. Defaults permit zero sends until explicitly configured. Aggregate overlapping grants/projects so they cannot multiply account limits. No wildcard audiences, votes/likes, DMs, follows, moderation, account rotation, cross-posting, media or identity changes in this lane.
3. Each proposed immutable operation records authorization kind, exact grant ID/revision/hash, content/target/account/schedule digests, policy evaluation and source/rules freshness. Never silently switch grants or label policy-derived output as human-reviewed. Preserve the legacy approval path; do not fabricate owner approval rows by invoking operation-approve from the agent. Model relevance judgments cannot override hard scope, permission, disclosure or budget checks.
4. Reserve capacity transactionally with claim and revalidate the same grant, suppression, kill switch, owner revocation/expiry, account identity, provider cooldown and fresh community/thread eligibility immediately before the durable provider-start boundary. Concurrent workers must not exceed caps. Changed body/target/profile, stale or unknown rules, deleted/locked/removed threads and unavailable platform permission block sending. Existing read collectors, project read tokens and MCP tools must remain unable to publish even while a grant is active.
5. Preserve unknown-after-provider-start semantics. Retain reservations for ambiguous outcomes until verified not sent; no blind retry, new operation ID workaround or claimed exactly-once provider delivery. Revocation/kill switch stops unstarted work; clearly report that an already-started remote request may complete and cannot be unsent. Reconciliation requires provider evidence, not model assertions.
6. Keep grant/suppression/authorization state private and out of shared corpus exports and ordinary logs. Document manual-review fallback and owner activation/revocation without acquiring secrets or enabling anything. Verify installed PRAW/API/terms through the existing route before any later live activation; live posting is not required for worker acceptance.

### Hazards and Compatibility

- **Concurrency/atomicity:** cap reservation and authorization validation share the existing fenced transaction; test concurrent grants/projects and revocation between enqueue, claim and provider start.
- **Migration/rollback:** back up and migrate only private queue state; rollback disables new delegated operations rather than interpreting them as old approvals.
- **Mixed-version/backward compatibility:** old runners cannot execute delegated intents; existing exact approvals and non-Reddit provider behavior remain unchanged.
- **Idempotency/retry:** stable intent/attempt/reservation identities survive replay; unknown sends retain budget and require reconciliation.
- **Partial failure/recovery:** checkpoint verified changes, preserve unmet criteria on a fuse and continue with offline fixtures; never recover by relaxing authority or running a live send.

### Verification Before Dispatch

```bash
python3 .agents/scripts/public-engagement-policy-helper.py preview --input .agents/scripts/tests/fixtures/public-engagement/policy.json --dry-run
python3 .agents/scripts/tests/test-public-engagement-policy.py
bash .agents/tests/test-knowledge-social-operations.sh
bash .agents/tests/test-knowledge-social-reddit.sh
bash .agents/tests/test-knowledge-social-sharing.sh
python3 .agents/scripts/tests/test-social-linkedin-youtube-outbound.py
python3 .agents/scripts/tests/test-social-meta-tiktok-outbound.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** preview/tests prove the policy and owner/executor API boundary with synthetic identities and fake transports. Existing suites are required because shared claim/schema/provider-start code affects other providers and private exports. Reuse existing test infrastructure; do not activate accounts, install providers, post live, or run a full-repository gate as substitute evidence.

## Acceptance Criteria

- [ ] A synthetic owner grants bounded Reddit post/reply authority; the executor can publish a conforming immutable operation through the existing mocked provider boundary with visibly policy-derived authorization.
- [ ] Concurrent workers, overlapping grants/projects, expiry/revocation and kill-switch races cannot exceed caps or execute an unstarted unauthorized operation; unknown sends retain reservations and never auto-resend.
- [ ] Reject forged/self-issued grants, stale eligibility, changed content/account/target, missing disclosure, prohibited actions and attempts by read-only collectors/MCP/tokens to publish or administer grants.
- [ ] Legacy exact-approval behavior and other providers pass existing regressions; private grant state is not exported. No real posting, credentials or activation is required to complete this implementation.
