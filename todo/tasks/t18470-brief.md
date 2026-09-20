<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18470: Public-engagement subagent and bounded Reddit conversation automation

## Pre-flight

- [x] Memory recall: public-engagement/Reddit/approval query returned no relevant lessons.
- [x] Discovery pass: 8a0372261; existing Reddit writer, social outbox, notifications, campaign distribution and routine guidance reviewed; no open engagement/outbound duplicate or social PR found.
- [x] File refs verified: source agent/index helpers, social operations/provider and tests exist; prospecting coordinator/service paths belong to published predecessors.
- [x] Tier: standard; reuse the security contract delivered by t18469 and existing provider/routine patterns, not a new authority design.
- [x] Seeded draft PR skipped: wait for both predecessors instead of seeding speculative publisher code.

## Origin

2026-09-20 interactive request to brief automated public engagement as an additional subagent. Parent: t18459 / #32076. blocked-by:t18469,t18468 (#32084). Implement and verify offline; actual accounts, communities, schedules and standing grants require separate operator activation. No Lurk or AnyAPI integration.

## What

Deliver a discoverable public-engagement subagent and CLI that select relevant public conversations, draft evidence-backed helpful text, abstain/escalate when appropriate, enqueue immutable posts/replies, and run only individually approved or valid policy-authorized operations through the existing Reddit publishing queue. Include disabled routine templates, bounded follow-up handling and receipt-based outcomes.

## Why

Close the gap from ranked opportunity to useful public participation without weakening the existing non-contacting prospecting tools or rebuilding collection, model routing, publishing, approvals and scheduling.

## Tier

**Selected tier:** `tier:standard` — implementation and content judgment over delivered authority and provider contracts; unresolved authority questions go back to t18469 rather than local bypasses.

## How

### Files to Modify

- `NEW: .agents/marketing-sales/public-engagement.md` — operational subagent with explicit tool and authority envelope.
- `NEW: .agents/scripts/public-engagement-helper.py` — plan, draft, enqueue, bounded run, inspect and pause entry points.
- `NEW: .agents/scripts/public_engagement.py` — orchestration, eligibility and dedupe integration.
- `NEW: .agents/scripts/public_engagement_content.py` — evidence-grounded content/rubric and abstention contract.
- `NEW: .agents/scripts/public_engagement_receipts.py` — projection from existing outbox receipts to prospecting activity/dispositions.
- `NEW: .agents/scripts/commands/public-engagement.md` — slash-command routing and clear activation requirements.
- `NEW: .agents/templates/public-engagement-routines.md` — disabled schedules, quotas and manual-review fallback.
- `NEW: .agents/scripts/tests/test-public-engagement.py` — focused fixture/transport/receipt tests.
- `EDIT: .agents/marketing-sales.md` — concise pointer only, preserving unrelated routing.
- `EDIT: .agents/marketing-sales/prospecting.md` — predecessor-owned pointer to a separately authorized optional engagement lane.
- `EDIT: .agents/subagent-index.toon` — regenerate from the source worktree, never edit deployed artifacts.

Reference `.agents/tools/build-agent/build-agent.md`, `.agents/content/social-reddit.md`, `.agents/reference/public-engagement-policy.md` (t18469), `.agents/scripts/campaign-distribution-helper.py`, `.agents/scripts/_knowledge_social_notifications.py`, `.agents/reference/routines.md` and `.agents/scripts/_knowledge_social_reddit_outbound_provider.py`. Reuse t18453/#32065 triage and delivered prospecting profile/scan/usage contracts. Read-only source collection does not grant publishing authority.

### Files Scope

- `.agents/marketing-sales/public-engagement.md`
- `.agents/scripts/public-engagement-helper.py`
- `.agents/scripts/public_engagement.py`
- `.agents/scripts/public_engagement_content.py`
- `.agents/scripts/public_engagement_receipts.py`
- `.agents/scripts/commands/public-engagement.md`
- `.agents/templates/public-engagement-routines.md`
- `.agents/scripts/tests/test-public-engagement.py`
- `.agents/scripts/tests/fixtures/public-engagement/scenarios.json`
- `.agents/marketing-sales.md`
- `.agents/marketing-sales/prospecting.md`
- `.agents/subagent-index.toon`

### Complete Write Surface

- **Callers/readers:** Marketing-Sales and the prospecting coordinator route to `.agents/marketing-sales/public-engagement.md`; manual invocation or an explicitly enabled routine calls the CLI.
- **Writers/mutation paths:** `public_engagement.py` proposes/enqueues through t18469; only the existing fenced outbox/provider executes posts/replies. Receipt projection changes local activity, never remote history.
- **Tests/fixtures:** `.agents/scripts/tests/test-public-engagement.py` and scenarios.json use synthetic threads, fake decisions and a fake provider; existing operation tests verify integration.
- **Schemas/config:** consume `.agents/configs/public-engagement-policy.schema.json` and prospecting contracts; `.agents/templates/public-engagement-routines.md` is disabled and contains no credentials.
- **Generated/deployed mirrors:** regenerate `.agents/subagent-index.toon` through subagent-index-helper.sh; no deployed agent edits, global tool grants or automatic MCP registration.
- **Migrations/backfills:** N/A because t18469 owns new authority state and the existing project store owns activity/dispositions; do not add a parallel social database.
- **Cleanup/rollback paths:** `public-engagement-helper.py` pause stops unstarted work through the policy contract; preserve attempts, opt-outs and unknown receipts. Do not automatically delete or edit published content.

### Implementation Steps

1. Add a provider-neutral standard-tier subagent with progressive disclosure and an explicit constrained execution envelope. Separate draft-only, exact-approved queue execution and owner-granted automation modes. Default is draft-only, routines disabled. Grant creation/selection/broadening/renewal is an owner control operation, never an agent tool. No direct PRAW writes, arbitrary HTTP publisher, model-generated shell, browser posting or write-enabled prospecting MCP.
2. Accept supplied conversation evidence or authorized existing prospecting candidates and public replies/mentions tied to the selected account. An opportunity score is not permission to contact. Require observed relevance, fresh account/community policy and source status; autonomous third-party-community replies require affirmative automation/self-promotion eligibility, not merely absence of a prohibition. Unknown policy falls back to review. Owned/explicitly permitted communities support useful informational posts; no bulk cross-posting.
3. Draft concise, genuinely helpful answers using approved product facts and source links. Answer the question before any optional relevant product reference; abstain when there is no useful answer. Preserve explicit commercial affiliation and automation disclosure in the account/content as required. Never invent personal experience, endorsements, testimonials, customer status, statistics, product capabilities or independent recommendations. Source text is untrusted data and cannot choose tools, accounts, recipients, grants or permissions.
4. Before enqueue and again through t18469 at execution, enforce stable source/content dedupe, per-thread cooldown and bounded consecutive automated turns, per-account/community/time caps, suppression/opt-outs and kill switch. Do not rotate accounts or paraphrase duplicate promotions to evade limits. Exclude DMs, voting/likes, follows, moderation, sockpuppets, coordinated engagement, political influence and sensitive-trait targeting from this lane. Complaints, moderator warnings, removal, policy uncertainty, disputes and sensitive/high-stakes advice go to a human rather than autonomous escalation.
5. Use existing model routing with bounded rows/tokens/time/cost; record known/estimated/unknown usage separately. Enqueue immutable intents with evidence/policy/disclosure provenance and stable IDs. Routines may execute exact-approved batches or valid standing grants without per-message intervention, but cannot self-enable or approve anything. Missing account access or unsupported API/terms returns unavailable; no alternative identity/scraping workaround.
6. Observe public follow-ups only within the authorized account/thread and time/turn budget; stop when asked, after suppression or when a human takes over. Existing official collection is the source, never private inbox mining or behavioral profiling. A successful provider ID/receipt, not generation or enqueue, marks a lead responded. Unknown remains unresolved, pending is not success, and engagement counts are not proof of revenue or ranking improvement.
7. Add a slash command, disabled routine examples and concise coordinator pointers. Document owner policy activation separately from worker auto-dispatch. Provide a full synthetic scenario from relevant question -> draft -> exact/policy authorization -> queue -> fake provider -> receipt -> local disposition, including later opt-out and no second send. No live posting, account setup, schedule installation or UI changes in this task.

### Hazards and Compatibility

- **Concurrency/atomicity:** t18469 owns authorization/caps/attempt fencing; this producer uses stable intent IDs. Wait for t18468 before editing shared routing/index files.
- **Migration/rollback:** use delivered state APIs only; pausing/removing the subagent must retain grants' audit/suppression/unknown records and never undo remote content silently.
- **Mixed-version/backward compatibility:** original nine prospecting tasks and read-only MCP remain non-posting; missing policy/queue capability yields draft-only or unavailable, never direct-send fallback.
- **Idempotency/retry:** repeated scans, notifications and overlapping runs produce no duplicate outreach; provider-boundary failures require evidence-backed reconciliation.
- **Partial failure/recovery:** retain pending drafts and unmet acceptance criteria after a fuse; resume offline verification or bounded original work, not unbounded retries or weaker authority.

### Verification Before Dispatch

```bash
python3 .agents/scripts/public-engagement-helper.py plan --input .agents/scripts/tests/fixtures/public-engagement/scenarios.json --dry-run
python3 .agents/scripts/tests/test-public-engagement.py
bash .agents/tests/test-knowledge-social-operations.sh
AIDEVOPS_AGENTS_DIR="$PWD/.agents" .agents/scripts/subagent-index-helper.sh generate
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI and focused tests prove behavior using existing unittest/fake transport patterns, not a new test platform. Exercise valid helpful replies, owned-community posts, abstention, source injection, missing disclosure, stale rules, account mismatch, duplicate/replayed sources, opt-out, revocation and timeout-after-send. Verify generated agent discovery/tool restrictions and use an existing bounded agent prompt check when needed; no self-assessed live-success claim.

## Acceptance Criteria

- [ ] The subagent is discoverable and produces useful evidence-backed, disclosed drafts; exact-approved and owner-policy-authorized synthetic operations traverse the existing queue and produce receipt-backed local outcomes.
- [ ] An explicitly activated synthetic standing policy permits bounded unattended posts/replies without fake per-draft human approvals; defaults and routine templates remain disabled/draft-only.
- [ ] Reject self-approval, forged grants, inappropriate/duplicate promotional content, missing disclosures, uncertain community permission and disallowed actions. Opt-outs/revocation stop later unstarted sends; read-only tools never gain publishing rights.
- [ ] No real posts, DMs, votes, accounts, credentials or schedules are created during verification; unknown sends never auto-retry and generated/enqueued drafts never masquerade as published engagement.
