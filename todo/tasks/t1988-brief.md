---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1988: Add /build-agent slash command and ubicloud hosting agent

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:t1988-interactive
- **Created by:** ai-interactive (user-directed)
- **Parent task:** none
- **Conversation context:** User thought we already had a `/build-agent` slash command (we don't — only the `tools/build-agent/build-agent.md` design subagent exists). User then requested a new ubicloud service agent covering hosted vs managed trade-offs, GitHub Actions runner integration, and cross-references to related hosting agents. These two deliverables ship together because the command is the harness that would normally produce the ubicloud agent — building both in one pass exercises the command via the first real use.

## What

Two deliverables land together:

1. **`/build-agent` slash command** at `.agents/scripts/commands/build-agent.md` — the missing command harness around the existing `tools/build-agent/build-agent.md` design doc. Invocation pattern mirrors `/new-task` and `/add-skill`: takes a target description, runs a short discovery pass over the existing agent tree (duplicate check, placement decision, cross-reference scan), drafts an agent file with YAML frontmatter that matches the project conventions, and offers tier-lifecycle options (draft / custom / shared). After creation it reminds the user to run `setup.sh` and `subagent-index-helper.sh generate`.

2. **`ubicloud` service agent** at `.agents/services/hosting/ubicloud.md` — new subagent covering Ubicloud's full product surface: managed GitHub Actions runners (x64 + arm64, one-line workflow change, ~10x cheaper than GitHub-hosted), managed PostgreSQL, managed Kubernetes, elastic compute VMs (standard + burstable), networking (firewalls, load balancers, private subnets), and the AI inference API. Includes the hosted-service-on-bare-metal decision framework: when to use Ubicloud's managed SaaS vs self-hosting the open-source control plane on your own Hetzner / Leaseweb / Latitude.sh bare metal. Cross-references `tools/git/github-actions.md`, `services/hosting/hetzner.md` (underlying bare-metal provider), `services/database/postgres.md` (if present), and `services/hosting/cloudflare.md` (alternative edge platform).

Two cross-reference edits extend the link:

- `.agents/tools/git/github-actions.md` — add "Managed runners" section listing ubicloud alongside the default GitHub-hosted runners, with workflow-label examples and the one-line migration pattern.
- `.agents/services/hosting/hetzner.md` — add a "Related" pointer noting that Ubicloud layers IaaS on top of Hetzner bare metal, so Hetzner customers who want a cloud-control-plane experience have that option.

## Why

- The `/build-agent` command has been assumed to exist (user referenced it from memory). The absence causes every new agent to be hand-built from the `tools/build-agent/build-agent.md` checklist without a dispatchable harness — costly in tokens and error-prone for tier placement (draft / custom / shared), frontmatter, and cross-reference discovery. Having the slash command closes a known framework gap and makes agent creation a first-class, repeatable operation.
- Ubicloud specifically matters right now because it is the only credible path to cut our GitHub Actions runner bill by ~10x with a one-line workflow change. Our git workflow commands (`/full-loop`, `/preflight`, `/postflight`) all depend on CI — a cheaper runner option needs agent-level documentation so future sessions can propose it without re-researching from scratch. The managed PostgreSQL and managed Kubernetes offerings are adjacent, lower-priority wins that belong in the same agent file.
- Hosted-vs-managed is a recurring decision point for infrastructure agents (cloudflare, cloudron, hetzner already expose this tension). Ubicloud uniquely offers both modes from the same open-source codebase, so the agent doc is the right place to codify the decision framework instead of re-deriving it each time.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — 5 files (2 new + 3 edits including TODO.md).
- [x] **Complete code blocks for every edit?** Yes — exact content written in this session.
- [ ] **No judgment or design decisions?** No — the ubicloud agent is a greenfield design (frontmatter tool set, AI-CONTEXT block content, cross-reference scope all require judgment).
- [x] **No error handling or fallback logic to design?** N/A (documentation work).
- [ ] **Estimate 1h or less?** No — ~2h including cross-reference edits and lint.
- [x] **4 or fewer acceptance criteria?** Yes.

**Selected tier:** `tier:standard`

**Tier rationale:** Greenfield design work across 5 files with deliberate judgment on scope, frontmatter, and cross-references. Not `tier:simple` (multi-file, design decisions). Not `tier:reasoning` — this follows the well-established service agent pattern (see `hetzner.md`, `cloudflare.md`, `cloudron.md`), so a standard tier can execute from the existing templates.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/commands/build-agent.md` — the `/build-agent` slash command. Model on `scripts/commands/new-task.md` (frontmatter style, step-by-step workflow, user interaction pattern) and `scripts/commands/add-skill.md` (quick-reference block with copy-pasteable invocations).
- `NEW: .agents/services/hosting/ubicloud.md` — the Ubicloud subagent. Model on `.agents/services/hosting/hetzner.md` (compact single-file service agent with AI-CONTEXT quick reference, curl-based API usage, no MCP dependency) and borrow the "hosted vs self-managed" decision-table pattern from `cloudflare.md` / `cloudron.md`.
- `EDIT: .agents/tools/git/github-actions.md` — append a "Managed runners (alternatives)" section listing Ubicloud with the ~10x savings data point, x64 + arm64 label table, and the one-line workflow migration snippet. Link back to `services/hosting/ubicloud.md#github-actions-runners`.
- `EDIT: .agents/services/hosting/hetzner.md` — append one line to the end pointing at `services/hosting/ubicloud.md` as the managed-cloud layer on top of Hetzner bare metal.
- `EDIT: TODO.md` — add the t1988 entry under the active queue with `#interactive` and `pr:#NNN` (populated after PR open).

### Implementation Steps

1. **Write `scripts/commands/build-agent.md`** — YAML frontmatter (`description`, `agent: Build+`, `mode: subagent`), `$ARGUMENTS` intake section, 5-step workflow (parse target → discover duplicates → pick tier/placement → draft agent file → post-create hooks), and a Quick Reference table of invocation patterns matching `/new-task` and `/add-skill`.

2. **Write `services/hosting/ubicloud.md`** — Full agent with AI-CONTEXT Quick Reference, product table, auth setup (`UBI_TOKEN` env var, curl base URL `https://api.ubicloud.com`), major resource endpoints, GitHub Actions runner integration (this section gets top billing given the workflow savings), hosted-vs-self-managed decision matrix, and a Related Agents cross-reference table.

3. **Edit `tools/git/github-actions.md`** — add a new second-to-last section "Managed runner alternatives" with a single subsection on Ubicloud (label examples + ~10x cost multiplier + pointer to ubicloud agent).

4. **Edit `services/hosting/hetzner.md`** — add one pointer line under a new "Related" subsection at the end linking to the Ubicloud agent.

5. **Update `TODO.md`** — add the `- [ ] t1988 ...` line.

6. **Lint** — `markdownlint-cli2` on the two new files and the two edited files, `.agents/scripts/linters-local.sh` before commit.

### Verification

```bash
# New files exist, parse as markdown, lint cleanly
test -f .agents/scripts/commands/build-agent.md
test -f .agents/services/hosting/ubicloud.md
bunx markdownlint-cli2 .agents/scripts/commands/build-agent.md .agents/services/hosting/ubicloud.md .agents/tools/git/github-actions.md .agents/services/hosting/hetzner.md

# Cross-references resolve
grep -q 'ubicloud' .agents/tools/git/github-actions.md
grep -q 'ubicloud' .agents/services/hosting/hetzner.md
grep -q 'github-actions' .agents/services/hosting/ubicloud.md
grep -q 'hetzner' .agents/services/hosting/ubicloud.md

# TODO.md has the entry
grep -q 't1988' TODO.md
```

## Acceptance Criteria

- [ ] `/build-agent` slash command file exists at `.agents/scripts/commands/build-agent.md` with valid YAML frontmatter (`description`, `agent`, `mode`) and a 5-step workflow matching the pattern used by `/new-task` and `/add-skill`.
- [ ] `.agents/services/hosting/ubicloud.md` exists with AI-CONTEXT block, GitHub Actions runners section (prominent — labels, price, migration snippet), hosted-vs-self-managed decision framework, and a Related Agents cross-reference table with at least 3 entries.
- [ ] `tools/git/github-actions.md` references Ubicloud managed runners as an alternative with the one-line label migration pattern.
- [ ] `services/hosting/hetzner.md` references Ubicloud as the managed cloud layer option.
- [ ] `markdownlint-cli2` passes on all four touched agent files.
- [ ] Tests pass (no tests affected — docs only).
- [ ] Lint clean (`.agents/scripts/linters-local.sh`).

## Context & Decisions

- **Distinct from `/autoagent`:** The existing `/autoagent` command runs a self-improvement research loop that *modifies* existing framework files to find wins. `/build-agent` is for *creating* new agents — no overlap. Both can coexist.
- **Agent placement:** Ubicloud is hosting infrastructure → `services/hosting/ubicloud.md`. Not `tools/` (not a cross-domain utility) and not `workflows/` (not a process).
- **Scope limits (explicit non-goals):**
  - No `ubicloud-helper.sh` script in this task — follow the hetzner.md pattern of pure curl/ubi-CLI documentation. A helper can be added later if usage warrants it (log a follow-up task if the agent is frequently invoked).
  - No MCP server setup — Ubicloud has no official MCP yet and the agent is accessible via the `ubi` CLI + REST API.
  - Not touching the Managed PostgreSQL or Managed Kubernetes sections in depth — the agent mentions them and points to Ubicloud's docs, but our first use-case is GitHub Actions runners, so that section gets the investment.
- **Prior art consulted:**
  - `services/hosting/hetzner.md` — structural template (API base, curl patterns, output formatters, multi-project auth).
  - `services/hosting/cloudron.md` — structural template for hosted-vs-managed tension and "Related Skills and Subagents" table.
  - `services/hosting/cloudflare.md` + `cloudflare-platform-skill/` — an example of a service agent split into a main file plus an extended skill directory. Ubicloud does not need this split yet (single-file agent is sufficient).
  - `scripts/commands/new-task.md` + `scripts/commands/add-skill.md` — structural templates for the slash command.
  - Ubicloud docs fetched live during this session (overview, API reference, runner types, pricing, regions, build-your-own-cloud, CLI).
- **Agent self-assessment:** While building this the session noticed `tools/build-agent/build-agent.md` quick-reference block could point at the new `/build-agent` command, but making that edit is out of scope for this task (would change a core contributor doc). Logged as a follow-up observation, not a TODO — the command is discoverable via `ls scripts/commands/`.

## Relevant Files

- `.agents/tools/build-agent/build-agent.md` — existing agent-design subagent. The new slash command is a dispatch harness that invokes it.
- `.agents/services/hosting/hetzner.md` — structural template for the ubicloud agent.
- `.agents/services/hosting/cloudron.md` — hosted-vs-managed pattern reference.
- `.agents/scripts/commands/new-task.md` — structural template for the slash command.
- `.agents/scripts/commands/add-skill.md` — quick-reference block pattern for the slash command.
- `.agents/tools/git/github-actions.md` — where the ubicloud runner cross-reference lands.

## Dependencies

- **Blocked by:** none
- **Blocks:** future tasks that want to propose Ubicloud runners in CI cost-reduction work
- **External:** none (docs only; no Ubicloud account needed for this task)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Fetch Ubicloud docs, read template agents |
| Implementation | 80m | Two new files + two cross-reference edits |
| Lint + verify | 10m | markdownlint + linters-local.sh |
| PR + brief | 10m | Commit, push, PR body |
| **Total** | **~2h** | |
