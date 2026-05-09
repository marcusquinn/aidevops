---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3574: Design `/auto-browse` agent factory for browser operations and web data mining

## Pre-flight

- [x] Memory recall: `aidevops auto-browse autobrowse browser operations agent command workflows private user data todo issue` → 0 hits — no prior lessons found.
- [x] Discovery pass: existing tracked browser/data docs reviewed; no existing `auto-browse`/`autobrowse` brief or command found.
- [x] File refs verified: `.agents/tools/browser/browser-automation.md`, `.agents/tools/browser/playwright.md`, `.agents/tools/browser/playwright-cli.md`, `.agents/tools/browser/agent-browser.md`, `.agents/tools/browser/dev-browser.md`, `.agents/tools/browser/chromium-debug-use/SKILL.md`, `.agents/tools/browser/playwriter.md`, `.agents/tools/browser/crawl4ai.md`, `.agents/tools/browser/watercrawl.md`, `.agents/tools/browser/stagehand.md`, `.agents/tools/browser/browser-use.md`, `.agents/tools/browser/skyvern.md`, `.agents/tools/browser/curl-copy.md`, `.agents/tools/browser/sweet-cookie.md`, `.agents/tools/browser/browser-profiles.md`, `.agents/tools/browser/anti-detect-browser.md`, `.agents/tools/browser/browser-benchmark.md`, `.agents/tools/autoresearch/autoresearch.md`, `.agents/seo/site-crawler.md` — all present at HEAD.
- [x] Tier: `tier:thinking` — new meta-agent/command design with safety gates, profile persistence, tool routing, private/shared artifact boundaries, and subagent decomposition.
- [x] Seeded draft PR decision recorded: skipped — this is a planning/brief artifact only; implementation should be split after maintainer review.

## Origin

- **Created:** 2026-05-08
- **Session:** opencode:interactive
- **Created by:** marcusquinn (human, with ai-interactive design)
- **Conversation context:** User reviewed Browserbase's Autobrowse concept and asked how to adapt it for aidevops. Discussion concluded that aidevops already has many browser/data-mining primitives, but lacks a learning-and-graduation agent that can orchestrate those tools, persist profiles safely, and produce reusable private workflows or repo-shareable briefs.

## What

Design and implement an aidevops `/auto-browse` command plus an `auto-browse` meta-agent and supporting subagents that can turn messy browser operations and web data-mining goals into reliable, cost/time-efficient repeatable workflows.

The agent must support both modes:

1. `/auto-browse <instruction>` — start from a concrete user objective.
2. `/auto-browse` — start a guided intake conversation that gathers missing information before running or generating a plan.

The system must be able to interact with websites when authorized, including account creation, login/logout, profile population, navigation, feature interaction, content engagement, content/comment posting, form completion, payments/checkouts, file upload/download, admin dashboards, and authenticated data exports. Successful custom workflows belong in the private aidevops user data area. Shareable design briefs, generalized workflows, and implementation tasks can be filed in `todo/`.

## Why

Browser operations currently require repeated rediscovery: choosing tools, figuring out login/session handling, finding selectors/API endpoints, deciding when to use a browser versus fetch/crawl/API extraction, and preserving knowledge for future runs. Existing aidevops browser tools cover many primitives, but no single agent coordinates them into a deliberate loop that optimizes for cost, runtime, reliability, safety, and reusability.

An `auto-browse` agent would let aidevops convert one-off browser successes into durable private workflow agents or shareable framework improvements, reducing repeated token/browser cost and improving operational reliability.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** This is a new framework capability spanning command routing, agent design, safety policy, browser profile storage, private/public artifact boundaries, and tool-selection strategy. It requires decomposition and design decisions before implementation.

## PR Conventions

If implemented as a parent-task issue, PRs for child phases should use `For #NNN` or `Ref #NNN` until the final phase. Leaf implementation issues can use normal closing keywords.

## Phases

- Phase 1 — Design docs and command contract [auto-fire:on-prior-merge]
- Phase 2 — Implement `/auto-browse` command/intake workflow and agent/subagent docs [auto-fire:on-prior-merge]
- Phase 3 — Add templates for strategy logs, run logs, profile policies, and generated private workflow agents [auto-fire:on-prior-merge]
- Phase 4 — Add optional helper script for deterministic scaffolding and validation after workflow patterns stabilize

## How (Approach)

### Files to Modify

Likely targets; adjust after implementation discovery:

- `ADD: .agents/scripts/commands/auto-browse.md` — slash command entrypoint; resolves `/auto-browse` with or without arguments.
- `ADD: .agents/workflows/auto-browse.md` — orchestration workflow, intake questions, state model, safety gates, and graduation rules.
- `ADD: .agents/tools/browser/auto-browse.md` — meta-agent guidance for browser operations and web data mining.
- `ADD: .agents/tools/browser/auto-browse-subagents.md` — focused role contracts for intake, routing, exploration, operation, profile management, safety, graduation, and verification.
- `ADD: .agents/templates/auto-browse-strategy-template.md` — per-run `strategy.md` template.
- `ADD: .agents/templates/auto-browse-profile-policy-template.md` — profile/cookie/proxy/container policy template.
- `ADD: .agents/templates/auto-browse-workflow-agent-template.md` — private generated workflow agent template.
- `ADD/EDIT: .agents/reference/agent-routing.md` or relevant command/domain index — route `/auto-browse` and browser-ops triggers without bloating always-loaded guidance.
- `OPTIONAL ADD: .agents/scripts/auto-browse-helper.sh` — only if deterministic scaffolding is small and stable enough; otherwise defer.

### Implementation Steps

1. **Document the command contract.**
   - `/auto-browse <instruction>` starts from the supplied objective.
   - `/auto-browse` starts an intake conversation.
   - Intake must gather: target site(s), objective, authorized account/profile, allowed actions, final-submit/payment/posting limits, data scope, persistence needs, proxy/VPN/container needs, output format, verification criteria, and whether artifacts are private or shareable.

2. **Define artifact boundaries.**
   - Private custom workflows, profiles, cookies, account-specific notes, downloaded private files, and site/account-specific generated agents live under `~/.aidevops/.agent-workspace/` or another documented private aidevops user data path.
   - Shareable/generalized briefs, design docs, and implementation tasks can live under `todo/`.
   - No secrets, cookies, private repo names, client names, private basenames, or private local paths in public issues/PRs/comments/reviews.

3. **Create the tool-selection ladder.**
   The agent should use the cheapest viable level first:
   - Direct fetch/API/static parse.
   - DevTools network, `curl-copy`, `sweet-cookie`, browser cookies/session reuse.
   - Crawl4AI, WaterCrawl, site-crawler, structured extraction schemas.
   - Playwright, playwright-cli, agent-browser for deterministic browser operations.
   - dev-browser for aidevops-managed persistent profiles.
   - chromium-debug-use / Playwriter for user-approved existing browser sessions.
   - Stagehand, browser-use, or Skyvern for fuzzy/dynamic/vision-based discovery, then compress discoveries into deterministic flows.
   - Anti-detect/proxy/profile/container stack only for authorized legitimate workflows and with explicit user approval.

4. **Design subagents.**
   Suggested subagents:
   - `auto-browse-intake` — asks only materially blocking questions; converts vague goals into a bounded objective and safety policy.
   - `auto-browse-router` — chooses the minimum-agency tool and escalation path.
   - `auto-browse-explorer` — discovers UI flows, selectors, network calls, auth requirements, and file/download behavior.
   - `auto-browse-data-miner` — optimizes extraction via APIs, fetches, crawlers, parsers, and schemas.
   - `auto-browse-operator` — executes authorized interactions such as login, profile updates, form fills, uploads/downloads, posting, and workflow navigation.
   - `auto-browse-profile-manager` — manages private profile directories, cookies/storage state, proxy/VPN/container metadata, and sandboxing rules.
   - `auto-browse-safety-gate` — blocks or asks confirmation for account creation, posting/messaging, payments, destructive/admin changes, anti-detect/proxy use, and personal data extraction.
   - `auto-browse-graduator` — writes the private custom agent/helper or repo-shareable generalized brief after convergence.
   - `auto-browse-verifier` — runs fresh verification, records evidence, and flags fragile assumptions.

5. **Define run state.**
   Private per-workflow state should use a structure like:

   ```text
   ~/.aidevops/.agent-workspace/auto-browse/<workflow-id>/
   ├── objective.md
   ├── constraints.md
   ├── strategy.md
   ├── runs.tsv
   ├── profile-policy.md
   ├── credentials-needed.md
   ├── traces/
   ├── screenshots/
   ├── downloads/
   ├── helpers/
   ├── generated-agent.md
   └── verification.md
   ```

   Shareable planning artifacts can use:

   ```text
   todo/auto-browse/<sanitized-workflow>/
   ├── brief.md
   ├── generalized-strategy.md
   └── implementation-plan.md
   ```

6. **Define browser profile model.**
   Support profile classes:
   - `persistent` — logged-in recurring workflows.
   - `sandbox` — isolated client/task testing.
   - `disposable` — one-off research or mining.
   - `warm` — preconditioned legitimate recurring workflow profiles.
   - `containerized` — stronger isolation for risky/untrusted sites.

   The profile manager must record profile purpose, allowed domains, credential source references only (not values), cookie/storage state location, proxy/VPN/container metadata, and cleanup/expiry policy.

7. **Define safety gates.**
   Require explicit confirmation before:
   - creating accounts or identities;
   - posting/commenting/messaging/reacting/following where not pre-approved;
   - final submit on forms with legal/financial impact;
   - payments, purchases, subscriptions, or checkout completion;
   - destructive/admin changes;
   - anti-detect/proxy/VPN/profile rotation for a target;
   - extracting personal/private data beyond the stated scope.

8. **Define convergence and graduation.**
   Each iteration should log success, runtime, browser steps, tool calls, token/cost estimate, fragility, failure reason, and discovered cheaper path. Stop after 3-5 iterations or when recent runs no longer improve materially. Graduate to the lowest-agency reliable artifact: API recipe, parser, Crawl4AI/WaterCrawl schema, Playwright script, private custom agent, or shareable repo brief.

9. **Keep always-loaded guidance minimal.**
   Add only a short pointer to routing docs if needed. Detailed design belongs in workflow/tool docs and templates.

### Files Scope

- `.agents/scripts/commands/auto-browse.md`
- `.agents/workflows/auto-browse.md`
- `.agents/tools/browser/auto-browse.md`
- `.agents/tools/browser/auto-browse-subagents.md`
- `.agents/templates/auto-browse-strategy-template.md`
- `.agents/templates/auto-browse-profile-policy-template.md`
- `.agents/templates/auto-browse-workflow-agent-template.md`
- `.agents/reference/agent-routing.md` or equivalent routing index
- Optional: `.agents/scripts/auto-browse-helper.sh`
- This brief: `todo/tasks/t3574-brief.md`

### Verification

Planning/doc phase:

```bash
# Verify new docs are discoverable and command file exists
git ls-files '.agents/scripts/commands/auto-browse.md' '.agents/workflows/auto-browse.md' '.agents/tools/browser/auto-browse.md'

# Check command resolution docs reference the workflow
grep -n "auto-browse" .agents/scripts/commands/auto-browse.md .agents/workflows/auto-browse.md .agents/tools/browser/auto-browse.md

# Run framework quality checks if scripts/docs changed
.agents/scripts/linters-local.sh
```

Behavioral smoke tests for implementation phase:

```text
1. `/auto-browse` with no args asks intake questions and does not browse before enough context exists.
2. `/auto-browse extract public pricing from <authorized URL>` chooses fetch/crawl before browser.
3. `/auto-browse log in and download invoices from <authorized site>` requests credential/profile handling and uses private state paths.
4. `/auto-browse post this comment...` stops for explicit final confirmation before posting.
5. `/auto-browse buy...` stops before payment/checkout finalization.
6. Generated custom workflow goes to private aidevops user data; generalized shareable brief goes to `todo/` only after sanitization.
```

## Acceptance Criteria

- [ ] `/auto-browse` command exists and resolves to the new workflow.
- [ ] `/auto-browse` with no instruction starts a guided intake conversation.
- [ ] `/auto-browse <instruction>` starts from the instruction and asks only materially blocking questions.
- [ ] Workflow documents the minimum-agency tool ladder and cites existing browser/data tools.
- [ ] Workflow supports browser interactions: account creation, login/logout, profile population, navigation, feature interaction, content engagement/posting/comments, form completion, payments/checkouts, uploads/downloads, and authenticated exports.
- [ ] Safety gates require confirmation for account creation, posting/messaging, payments, destructive/admin changes, anti-detect/proxy/VPN use, and scoped personal/private data extraction.
- [ ] Private custom workflows and browser profile state are stored under private aidevops user data, not repo `todo/`.
- [ ] Shareable/generalized briefs and implementation plans can be stored under `todo/` after sanitization.
- [ ] Templates exist for strategy logs, profile policies, generated private workflow agents, and verification logs.
- [ ] Design keeps `.agents/AGENTS.md` minimal and uses progressive disclosure.

## Context & Decisions

- Existing aidevops browser docs already cover the primitives. This task should not replace them; it should orchestrate them.
- The first-class product is not a browser wrapper; it is a browser workflow learning-and-graduation loop.
- High-agency tools such as Stagehand/browser-use/Skyvern should be used primarily for discovery when deterministic methods fail, then compressed into lower-cost repeatable flows.
- Custom workflow agents tied to accounts/sites/clients are private user data. Repo `todo/` is for generalized plans and implementation tasks only.
- Credentials and cookies must be referenced by secure storage location, never copied into repo files or chat.

## Open Questions for Implementer

- Which private path should be canonical for generated custom workflow agents: `~/.aidevops/.agent-workspace/auto-browse/`, `~/.aidevops/agents/custom/`, or a split between run state and promoted private agents?
- Should `/auto-browse` initially be documentation-only or include a deterministic `auto-browse-helper.sh init` scaffolder in phase 1?
- Should Browserbase/remote browsers be supported as optional providers, or should v1 remain local-first using existing aidevops browser tooling?
- Should generated private agents be hot-loaded automatically, or only written for user review first?
