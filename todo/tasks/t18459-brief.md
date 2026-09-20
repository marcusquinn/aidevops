<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18459: Native conversational prospecting and Reddit SEO workbench

## Pre-flight

- [x] Memory recall: prospecting/brief queries returned no relevant hits.
- [x] Discovery pass: source 39cde6c59; planning PR #32071 merged; no open Lurk/prospecting/Reddit duplicates or related open PRs found.
- [x] File refs verified: Reddit collection, social store/leases, search-provider guidance, routines and DESIGN.md exist; new feature paths are child-owned.
- [x] Tier: thinking roadmap coordinator only; parent-task permanently excludes implementation dispatch.
- [x] Seeded draft PR skipped: this publication briefs background work, not a code seed.

## Origin

2026-09-20 OpenCode interactive. The maintainer explicitly requests native replication of Lurk's offered workflows, not a Lurk integration. General AnyAPI capabilities/site-scraping replication is reserved for another session. Implementation leaves default to auto-dispatch after canonical publication and dependency verification.

## What

A native aidevops project-to-conversation prospecting workflow: URL onboarding, evidence-backed buyer-language discovery, incremental Reddit posts/comments/rules, ranked lead inbox, Google-ranked Reddit opportunities, competitor/pain insights, budgeted schedules/digests, scoped read-only REST/MCP, and a self-hostable operator workbench. Feature parity concerns useful outcomes, not vendor branding, pricing tiers, hosted wallets or codebase cloning.

## Why

Existing #32065 covers analysis of supplied conversations, not discovery or the app around it. Extend the shared decision work already briefed rather than duplicating classifiers, reporting, provider routing or scraping infrastructure.

## Source study and prior art

Source: https://lurk.so/ (including its self-host section) and https://github.com/getanyapi-com/lurk at commit `cd53087e88ed2087a2b9d01ca3b289acf6917930`. Twelve source/deployment files were fetched through GitHub and scanned clean; no repository code was installed or executed. This is source evidence, not measured performance or runtime verification.

- `src/lib/profile.ts`: product capabilities/geography/budget and evidence-grounded exclusions; a homepage omission must not become a product limitation. Relevant same-site product/pricing pages can contribute evidence.
- `src/lib/discovery/plan.ts`: queries and active/candidate communities derive from observed conversations, not only model suggestions.
- `src/lib/scan/retrieve.ts`: bounded search/listing/Google discovery with explicit incomplete windows; budget exhaustion does not advance a fully-covered watermark.
- `src/lib/scan/score.ts`: cheap title triage before full thread/comment scoring; unscored is not rejected. The source uses Jev, but our implementation must use existing approved model routing and remain provider-neutral.
- `src/db/schema/tenant.ts`: project profile and discovery-plan versions are separate; product edits invalidate judgments differently from search-plan changes.
- `src/lib/seo/refresh.ts`: retain query, position, observed thread and competitor presence; old threads can remain valuable when still ranked, rather than applying the fresh-lead age cutoff to SEO.
- `src/jobs/insights.ts`, `src/jobs/scheduler.ts`, `src/lib/alerts/send.ts`: derived themes, bounded recurring jobs and email/Slack/Discord/webhook digests.
- `src/lib/api/mcpTools.ts`: project/lead/SEO/theme/usage reads, score/reason/matching phrase and local hidden/not-fit filters. A score orders human attention, not probability of purchase.
- `docker-compose.yml`: the reference app's deployment depends on hosted auth/data/model services. Native aidevops must not inherit those dependencies.

Current aidevops reuse: `.agents/content/social-reddit.md:71-118`, `.agents/scripts/knowledge_social_reddit.py:16-62`, `.agents/scripts/knowledge_social_store.py`, `.agents/scripts/_knowledge_social_lease.py`, `.agents/seo/serper.md`, `.agents/seo/dataforseo.md`, `.agents/reference/routines.md`, `.agents/aidevops/knowledge-plane/05-social-operations.md`, `DESIGN.md`. Reddit account-history ingestion is not proof that public keyword search/subreddit rules are implemented; the collection child must verify that distinction.

## Children and dependencies

| Task | Outcome | Tier | Blocked by |
| --- | --- | --- | --- |
| t18460 / #32078 | Project/lead store and native service contract | thinking | t18446 / #32058 |
| t18461 / #32079 | URL onboarding and evidence-backed discovery plan | standard | t18460, t18448 / #32059 |
| t18462 / #32077 | Incremental Reddit discovery and triage orchestration | standard | t18461, t18453 / #32065 |
| t18463 / #32081 | Google-ranked Reddit discovery and position history | standard | t18462 |
| t18464 / #32080 | Competitor, recommendation and pain-theme insights | standard | t18462 |
| t18465 / #32082 | Budgeted routines, usage ledger and internal alert delivery | standard | t18463,t18464 |
| t18466 / #32085 | Scoped service APIs, read-only MCP and operator boundary | thinking | t18465 |
| t18467 / #32083 | Native operator web workbench | standard | t18465,t18466 |
| t18468 / #32084 | Self-host packaging, agent routing and parity verification | standard | t18467,t18458 / #32070 |

Roadmap issue: #32076. These are explicitly filed children, not phase-auto-file requests. Native dependencies serialize shared state and final root routing. Siblings after t18462 have disjoint write surfaces; the service waits for delivered job/usage contracts from t18465. Existing t18444 children remain unchanged; #32065 stays a reusable non-contacting analysis component.

## Non-negotiable boundaries

- No Lurk package/service/SDK, AnyAPI account/SDK/API, vendor wallet or hosted-auth dependency. Independently implement workflow behavior; do not vendor the reference app, assets or branding.
- No general scraping engine, proxy fleet, browser-fingerprint/anti-bot bypass, broad platform expansion or replacement for existing collectors. A narrow Reddit/search adapter around existing authorized capabilities is in scope; future scraping work plugs into its versioned interface.
- Native local/self-hosted operator tool, not a new paid multi-tenant SaaS. Start with Python domain helpers and project-isolated private SQLite/read models; a lightweight web UI is an optional runtime surface, not a mandatory cloud stack. Record deviations and evidence before introducing runtime dependencies.
- No automatic public posts, replies, DMs, votes, moderation, prospect contact, response drafting or user profiling. Display only minimal source-provided author context needed to distinguish a post/comment. Internal alerts go solely to operator-approved destinations.
- No service activation, spending, secret acquisition, schedule installation or public deployment during worker verification. Recorded/synthetic transports must prove the paths offline; live reads require existing readiness, data/terms approval and explicit budgets.
- No guaranteed ranking/citation/leads/revenue claims. Measure observed SERPs separately from actual AI citations (#32064) and financial outcomes (#32066); unknown costs stay unknown.

## How

### Files to Modify

- `EDIT: TODO.md` — coordinator-owned task/ref/dependency ledger.
- `EDIT: todo/tasks/t18459-brief.md` — roadmap evidence and completion state.

### Files Scope

- `TODO.md`
- `todo/tasks/t18459-brief.md`

### Complete Write Surface

- **Callers/readers:** child briefs and `TODO.md` share this scope/exclusion contract.
- **Writers/mutation paths:** coordinator bookkeeping updates `TODO.md`, not implementation code.
- **Tests/fixtures:** `.agents/scripts/verify-brief-helper.sh` validates publication; each child owns focused implementation evidence.
- **Schemas/config:** `.agents/templates/brief-template.md` defines planning shape; no runtime configuration is changed here.
- **Generated/deployed mirrors:** GitHub roadmap #32076 mirrors `todo/tasks/t18459-brief.md`; all child/dependency edges are native relationships.
- **Migrations/backfills:** N/A because this is a planning-only tracker.
- **Cleanup/rollback paths:** retain IDs/refs in `TODO.md`; explicit cancellation or scope revision must preserve evidence.

### Implementation Steps

1. Publish canonical briefs and exact issue mappings; verify blockers and enable dependency-gated auto-dispatch.
2. Reuse predecessor outputs and existing provider capabilities; preserve disjoint ownership and exclusions.
3. Verify all workflow families and self-host/operator boundaries before reconciling parent completion.

### Hazards and Compatibility

- **Concurrency/atomicity:** one planning publication; preserve concurrent TODO changes and existing child ownership.
- **Migration/rollback:** no implementation migration; record cancellations rather than deleting task history.
- **Mixed-version/backward compatibility:** current brief/task lifecycle, not a new dispatch system.
- **Idempotency/retry:** reuse issue mappings and native edges on publication retries.
- **Partial failure/recovery:** publication:pending remains until the default-branch snapshot is verified; retry through a planning PR.

### Verification Before Dispatch

```bash
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18459-brief.md
git diff --check
```

- **Surface mapping:** readiness/diff validate canonical planning; live GitHub reads verify all native relationships, tiers and ownership before dispatch.
- **Recoverability:** keep task IDs, local briefs and pending issues after any safety stop; publish the same snapshot through the protected-branch path.

## Acceptance Criteria

- [ ] Nine children deliver documented, callable native workflows with a verified offline end-to-end workbench demonstration.
- [ ] Product onboarding, discovery, leads, Reddit SEO, insights, alerts, usage, REST/MCP and self-hosting each have implementation evidence and coverage limitations.
- [ ] No Lurk/AnyAPI integration or general scraping-platform work is included, and no public engagement is automated.
- [ ] Parent remains open until all child implementation evidence is reconciled; planning publication alone never completes implementation.
