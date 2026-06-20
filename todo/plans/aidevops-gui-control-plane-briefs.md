<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# aidevops GUI Control Plane Brief Plan

Session origin: interactive OpenCode planning session on 2026-06-20.

Purpose: preserve the current product intent, live issue graph, and
worker-ready phase briefs for building the aidevops GUI/control plane over time.

Canonical product memory: `docs/gui/control-plane.md`.

## Current live issue graph

- Parent: `t3607` / GH#25229.
- Completed first-wave ADRs: `t3608` / GH#25230 via PR #25236 and `t3609` /
  GH#25231 via PR #25237.
- Open first-wave children: `t3610` / GH#25232, `t3611` / GH#25233, and
  `t17995` / GH#25234.
- Native sub-issue links are established from GH#25229 to GH#25230-GH#25234.
- Native blockers are synced: `t3611` is blocked by `t3608`, `t3609`, and
  `t3610`; `t17995` is blocked by `t3608` and `t3609`.

## Filing workflow

When creating or extending live issues:

1. Use aidevops issue/TODO wrappers, not raw `gh issue create`.
2. File the top-level program issue as `parent-task` and `tier:thinking`.
3. File phase epics as children or sub-issues of the program issue.
4. Add `auto-dispatch` only to leaf issues with clear deliverables,
   file scopes, verification, and no unresolved dependencies.
5. Use GitHub native `blockedBy` relationships for dependencies and keep text
   markers such as `blocked-by:GH#NNN` in issue bodies for reconciliation.
6. Parent/epic PRs use `For #NNN` or `Ref #NNN`; leaf implementation PRs use
   `Resolves #NNN`.
7. Keep all code and planning changes in linked worktrees.

## Program parent issue draft

Title:

```text
Build aidevops GUI control plane for setup, infrastructure, routines, and safe multi-machine AI-agent operations
```

Labels:

```text
parent-task,tier:thinking,enhancement,product,dashboard,infrastructure,origin:interactive
```

Body:

```markdown
## What

Build the aidevops GUI/control plane as the primary visual surface for setting
up, understanding, managing, and scaling aidevops across local machines,
Cloudron, git platforms, infrastructure providers, routines, and AI-agent
workflows.

The GUI should help users manage DevOps infrastructure for personal and business
growth: domains, DNS, git platforms, hosting, email, messaging, social accounts,
VPNs, proxies, VPSs, containers, orchestrators, OS/device fleets, server apps,
git runners, secrets, routines, projects, and OpenCode/aidevops instances.

## Why

aidevops has growing operational knowledge in agents, helpers, workflows, and
reference docs. New users need a guided setup surface; existing users need a
safe control plane to see state, manage infrastructure, oversee routines, and
scale AI-agent work across available compute without centralising trust or
secrets.

## How

Use `docs/gui/control-plane.md` as the canonical product memory. Develop in
phases:

1. Product/architecture ADRs.
2. Security and trust model.
3. Data model and infrastructure graph.
4. Helper/API contract.
5. GUI testing and CI/CD strategy.
6. Local read-only dashboard.
7. Safe write flows.
8. Infrastructure/provider/routine/catalog sections.
9. Cloudron package.
10. Multi-machine pairing/delegation.
11. OpenCode session UI and desktop wrapper.

## Acceptance Criteria

- [ ] Child issues exist for each phase with explicit dependencies.
- [ ] Architecture, threat model, and data model are documented before
      implementation scaffolding.
- [ ] The first implementation phase can ship a read-only local dashboard without
      secrets or destructive operations.
- [ ] Secrets, machine pairing, Cloudron, and multi-machine delegation have
      explicit trust-boundary docs before write actions are implemented.
- [ ] Git platforms remain the source of truth for issues, PRs, project history,
      and collaboration.
```

## Dependency graph

Live first-wave graph:

```text
GH#25229 / t3607
├── P1 Product, stack, and repo-layout ADR (done: GH#25230 / t3608)
├── P2 Security threat model and trust-boundary ADR (done: GH#25231 / t3609)
├── P3 Data model and infrastructure graph ADR (open: GH#25232 / t3610)
│   └── P14 Multi-machine pairing and scoped task capsules (also blocked by P2)
├── P4 Helper/API contract for existing aidevops surfaces (open: GH#25233 / t3611)
├── P17 GUI testing and CI/CD strategy (open: GH#25234 / t17995)
│   └── P5 Local read-only API and dashboard scaffold
│       ├── P6 Setup/status dashboard
│       ├── P7 Repos/Git source-of-truth dashboard
│       ├── P8 Infrastructure graph and identity/account inventory
│       ├── P9 Provider bookmarks and recommendation catalog
│       ├── P10 Routines dashboard
│       ├── P11 Nextcloud CalDAV/CardDAV setup guidance
│       ├── P12 Agent knowledgebase/capability browser
│       ├── P13 Cloudron package and hosted-control-plane mode (also blocked by P1, P2, P4)
│       ├── P15 OpenCode session/chat UI spike (also blocked by P2)
│       └── P16 Desktop wrapper, signing, and auto-update plan (also blocked by P1)
```

Recommended blockers:

- P5 blocked by P1, P2, P3, P4.
- P5 also blocked by P17 so scaffolded code has test scripts and CI expectations
  from the first implementation PR.
- P6-P12 blocked by P5.
- P13 blocked by P1, P2, P4, P5.
- P14 blocked by P2 and P3.
- P15 blocked by P2 and P5.
- P16 blocked by P1 and P5.
- P17 blocked by P1 and P2.

## Phase issue briefs

### P1: Product, stack, and repo-layout ADR

Status: complete via PR #25236.

Labels: `tier:thinking,documentation,architecture,product,dashboard,auto-dispatch`.

Blocked by: none.

Files to modify:

- `NEW: docs/gui/adr-0001-product-scope-stack-repo-layout.md`
- `EDIT: docs/gui/control-plane.md` only if the ADR changes the canonical
  product memory.

Deliverable:

- ADR choosing the first implementation stack and repo layout for the GUI.
- Explicit comparison of Vite vs Next.js, Hono vs Fastify, SQLite-first storage,
  Tauri later, and Cloudron packaging constraints.
- Decision on whether first code lands directly in this repo or as a staged
  package subtree.

Implementation steps:

1. Read `docs/gui/control-plane.md`.
2. Review existing aidevops repo layout policy in `.agents/aidevops/architecture.md`.
3. Review public inspiration at architecture level only; do not copy code without
   license review.
4. Write the ADR with context, decision, consequences, non-goals, and follow-up
   issues.

Verification:

```bash
git diff --check
```

Acceptance criteria:

- [ ] ADR explains the first stack choice and alternatives rejected.
- [ ] ADR defines repo layout and top-level directory policy impact.
- [ ] ADR states which phase can begin coding and which decisions remain gated.
- [ ] ADR does not require signing, VPN, or hosted control plane for first use.

### P2: Security threat model and trust-boundary ADR

Status: complete via PR #25237.

Labels: `tier:thinking,security,architecture,dashboard,auto-dispatch`.

Blocked by: none.

Files to modify:

- `NEW: docs/gui/threat-model.md`
- `NEW: docs/gui/adr-0002-trust-boundaries.md`

Deliverable:

- Threat model for local GUI, local daemon, Cloudron deployment, machine pairing,
  task delegation, account management, secrets, and provider catalogs.

Implementation steps:

1. Read `docs/gui/control-plane.md` trust-boundary and non-goal sections.
2. Read aidevops secret-handling references before proposing any secret UX.
3. Define assets, actors, trust boundaries, attacker goals, mitigations, and
   phase gates.
4. Specify allowed local API command patterns and explicitly ban arbitrary shell
   endpoints.
5. Define compromise containment goals for Cloudron and paired machines.

Verification:

```bash
git diff --check
```

Acceptance criteria:

- [ ] Compromise of one machine does not imply compromise of every machine.
- [ ] Cloudron-hosted mode cannot execute unrestricted commands on local agents.
- [ ] Secrets are modeled as references/status only.
- [ ] High-risk operations and destructive actions require confirmation/audit.
- [ ] VPN/NetBird/Nostr are treated as transport, not authorization.

### P3: Data model and infrastructure graph ADR

Labels: `tier:thinking,architecture,infrastructure,database,dashboard,auto-dispatch`.

Blocked by: none; P1 is complete and should be read before changing stack or
layout assumptions.

Files to modify:

- `NEW: docs/gui/data-model.md`
- `NEW: docs/gui/adr-0003-resource-graph.md`

Deliverable:

- Data model for identities, providers, accounts, resources, machines,
  projects, routines, bookmarks, capabilities, integrations, task capsules, and
  audit events.

Implementation steps:

1. Start from the data sketch in `docs/gui/control-plane.md`.
2. Define resource categories and relationship examples for domains, DNS, git,
   hosting, email, messaging, social, VPNs, proxies, servers, containers,
   orchestrators, OSs/devices, server apps, and git runners.
3. Define provider-specific metadata extension pattern.
4. Define migration/testing expectations for later implementation.

Verification:

```bash
git diff --check
```

Acceptance criteria:

- [ ] Model supports the infrastructure families listed in
      `docs/gui/control-plane.md`.
- [ ] Model separates provider, account, resource, project, routine, and machine.
- [ ] Model stores secret references, not secret values.
- [ ] Model supports future affiliate/provider-bookmark metadata.
- [ ] Model supports CalDAV/CardDAV and local app integrations.

### P4: Helper/API contract for existing aidevops surfaces

Labels: `tier:standard,api,setup,dashboard,auto-dispatch`.

Blocked by: P3 for native dependency tracking; P1 and P2 are complete and remain
required reading.

Files to modify:

- `NEW: docs/gui/helper-api-contract.md`
- `EDIT: docs/gui/control-plane.md` only if the source-of-truth map changes.

Deliverable:

- Contract for how the GUI calls existing aidevops helpers for setup, settings,
  repos, secrets, routines, OpenCode, Cloudron, and git platforms.

Implementation steps:

1. Inventory existing helpers and config surfaces: setup, settings/config,
   repos, secrets/gopass, routines, OpenCode plugin, Cloudron helper.
2. Define read-only JSON status endpoints/commands needed for Phase P5.
3. Define future write contract: dry-run, validate, apply, atomic backup,
   rollback, audit event.
4. Mark helpers that need new `--json` or validation output in later child
   issues; do not implement them in this phase.

Verification:

```bash
git diff --check
```

Acceptance criteria:

- [ ] Contract preserves config precedence and generated OpenCode config rules.
- [ ] `repos.json` writes require validation, backup, and atomic apply.
- [ ] Secret flows are write-only/status-only from the GUI perspective.
- [ ] The first dashboard can be read-only using existing or planned helper
      outputs.

### P5: Local read-only API and dashboard scaffold

Labels: `tier:standard,api,dashboard,testing,auto-dispatch`.

Blocked by: P1, P2, P3, P4, P17.

Files to modify:

- `NEW: apps/gui-web/**`
- `NEW: apps/gui-server/**`
- `NEW: packages/gui-core/**`
- `NEW: packages/gui-adapters/**`
- `EDIT: package.json` and workspace config files as required by the chosen ADR.

Deliverable:

- Minimal local read-only GUI that can show aidevops setup/status from typed
  mock or real adapter calls, with the SQLite database connection scaffolded.

Implementation steps:

1. Follow the P1 stack ADR exactly.
2. Add shared schemas and database connection/ORM initialization in
   `packages/gui-core` before UI code.
3. Add a read-only status route in `apps/gui-server`.
4. Add a basic dashboard shell in `apps/gui-web` with aidevops branding.
5. Add the test scripts and CI hooks required by P17 for the scaffolded packages.
6. Keep all command execution behind adapters; no arbitrary shell route.

Verification:

```bash
git diff --check
# plus ADR-selected lint/typecheck/test commands
```

Acceptance criteria:

- [ ] App starts locally in read-only mode.
- [ ] API contract is typed and validated.
- [ ] UI shows setup/status placeholders or real read-only data.
- [ ] No secret values are requested, displayed, or stored.
- [ ] No write/destructive routes exist.
- [ ] GUI-specific local test commands are documented and runnable.
- [ ] CI path filters or separate GUI jobs are prepared if required by P17.

### P6: Setup/status dashboard

Labels: `tier:standard,dashboard,setup,auto-dispatch`.

Blocked by: P5.

Files to modify:

- `EDIT: apps/gui-web/**`
- `EDIT: apps/gui-server/**`
- `EDIT: packages/gui-adapters/**`
- `EDIT: packages/gui-core/**`

Deliverable:

- Dashboard cards for aidevops, OpenCode, helper availability, config/settings,
  folder locations, routine scheduler, secret backend status, and repo registry
  health.

Acceptance criteria:

- [ ] User can see installed/missing/stale status for core setup areas.
- [ ] Each card links to the relevant aidevops helper/doc reference.
- [ ] Error states are actionable and include verification commands.
- [ ] Secret cards show configured/missing/invalid only, not values.

### P7: Repos and Git source-of-truth dashboard

Labels: `tier:standard,dashboard,git,auto-dispatch`.

Blocked by: P5.

Files to modify:

- `EDIT: apps/gui-web/**`
- `EDIT: apps/gui-server/**`
- `EDIT: packages/gui-adapters/**`
- `EDIT: packages/gui-core/**`

Deliverable:

- Read-only `repos.json` dashboard showing registered repos, platform, slug,
  local path status, pulse flags, maintainer/local-only flags, and validation
  errors.

Acceptance criteria:

- [ ] Malformed or missing repo registry state is visible and actionable.
- [ ] GUI does not write `repos.json` in this phase.
- [ ] GitHub/GitLab/Gitea/Forgejo are modeled as Git platform sources.
- [ ] Project progress links back to git issues/PRs rather than duplicating them.

### P8: Infrastructure graph and identity/account inventory

Labels: `tier:standard,dashboard,infrastructure,database,auto-dispatch`.

Blocked by: P3, P5.

Files to modify:

- `EDIT: apps/gui-web/**`
- `EDIT: apps/gui-server/**`
- `EDIT: packages/gui-core/**`

Deliverable:

- UI and schemas for adding/displaying infrastructure resources in a local
  inventory: identities, accounts, providers, resources, machines, projects,
  and integrations.

Acceptance criteria:

- [ ] Supports all first-class infrastructure families from the product doc.
- [ ] Stores secret references only.
- [ ] Resource relationships can be displayed as a list first; graph view can be
      a later enhancement.
- [ ] Accounts can be associated with identities and providers.

### P9: Provider bookmarks and recommendation catalog

Labels: `tier:standard,dashboard,content,infrastructure,auto-dispatch`.

Blocked by: P3, P5.

Files to modify:

- `EDIT: apps/gui-web/**`
- `EDIT: apps/gui-server/**`
- `EDIT: packages/gui-core/**`
- `NEW: docs/gui/provider-catalog.md`

Deliverable:

- Shared bookmarks/provider catalog with categories, recommendation status,
  rationale, notes, tags, and affiliate-link-ready metadata.

Acceptance criteria:

- [ ] Catalog supports provider categories for DNS, domains, VPS, email, VPN,
      proxy, AI/model APIs, app hosting, and server apps.
- [ ] Affiliate metadata is optional and separate from recommendation rationale.
- [ ] Provider entries can cite setup docs without executing instructions from
      untrusted content.
- [ ] UI distinguishes recommended, experimental, avoided, and user-owned.

### P10: Routines dashboard

Labels: `tier:standard,dashboard,automation,auto-dispatch`.

Blocked by: P4, P5.

Files to modify:

- `EDIT: apps/gui-web/**`
- `EDIT: apps/gui-server/**`
- `EDIT: packages/gui-adapters/**`
- `EDIT: packages/gui-core/**`
- `NEW: docs/gui/routines-ui.md`

Deliverable:

- Routines overview showing enabled/disabled state, schedule, runner type,
  linked resources/secrets, last run, next run, status, and failure reason.

Acceptance criteria:

- [ ] Read-only routine dashboard works before edit flows.
- [ ] Routine source-of-truth remains TODO/routine definitions and scheduler
      helpers unless a later ADR changes it.
- [ ] UI can distinguish script-backed and LLM-backed routines.
- [ ] Failures include logs or next diagnostic command.

### P11: Nextcloud CalDAV/CardDAV setup guidance

Labels: `tier:standard,dashboard,communications,automation,auto-dispatch`.

Blocked by: P3, P5.

Files to modify:

- `NEW: docs/gui/caldav-carddav-integrations.md`
- `EDIT: apps/gui-web/**`
- `EDIT: packages/gui-core/**`

Deliverable:

- Guided setup model and UI placeholder for Nextcloud, CalDAV, CardDAV, and
  local OS calendar/contact clients.

Implementation context:

- Load the `caldav-calendar` skill when implementing this phase.

Acceptance criteria:

- [ ] Distinguishes calendar/contact account setup from routine permissions.
- [ ] Supports Nextcloud plus generic CalDAV/CardDAV providers.
- [ ] Documents read/write scope and service-account boundaries.
- [ ] Does not store calendar/contact secrets in the GUI database.

### P12: Agent knowledgebase and capability browser

Labels: `tier:standard,dashboard,agents,reference,auto-dispatch`.

Blocked by: P5.

Files to modify:

- `NEW: docs/gui/capability-browser.md`
- `EDIT: apps/gui-web/**`
- `EDIT: apps/gui-server/**`
- `EDIT: packages/gui-core/**`

Deliverable:

- Browser for aidevops capabilities: agents, tools, services, workflows,
  setup requirements, verification commands, and preferred choices.

Acceptance criteria:

- [ ] Does not duplicate long agent instructions into app state.
- [ ] Links to docs and concise summaries.
- [ ] Supports filtering by domain: git, hosting, email, security, calendar,
      content, SEO, WordPress, Cloudron, routines, and infrastructure.
- [ ] Includes continuity guidance for which specialist agent/skill to load.

### P13: Cloudron package and hosted-control-plane mode

Labels: `tier:standard,cloudron,dashboard,deployment,auto-dispatch`.

Blocked by: P1, P2, P4, P5.

Files to modify:

- `NEW: cloudron/CloudronManifest.json`
- `NEW: cloudron/Dockerfile`
- `NEW: cloudron/start.sh`
- `NEW: docs/gui/cloudron.md`
- `EDIT: apps/gui-server/**` as needed for Cloudron mode.

Implementation context:

- Load the `cloudron-app-packaging` skill before implementation.

Deliverable:

- Cloudron packaging plan or first package for hosted GUI mode using Cloudron
  filesystem and addon conventions.

Acceptance criteria:

- [ ] Uses Cloudron writable `/app/data` correctly.
- [ ] Supports proxyauth/OIDC plan or documented first-phase auth fallback.
- [ ] Does not require centralising local machine secrets on Cloudron.
- [ ] Health check and backup/restore behavior are documented.
- [ ] Defines pull-based polling for local agents to retrieve signed task
      capsules from Cloudron without opening inbound ports on local machines.

### P14: Multi-machine pairing and scoped task capsules

Labels: `tier:thinking,security,orchestration,infrastructure,dashboard,auto-dispatch`.

Blocked by: P2, P3.

Files to modify:

- `NEW: docs/gui/multi-machine-delegation.md`
- `NEW: docs/gui/task-capsules.md`

Deliverable:

- Design for pairing user-owned machines, issuing scoped task capsules, and
  coordinating aidevops/OpenCode work across available compute.

Acceptance criteria:

- [ ] Per-machine identities and revocation are specified.
- [ ] Task capsules include repo scope, allowed actions, expiry, and approval
      requirements.
- [ ] Cloudron compromise and single-machine compromise are contained.
- [ ] Local agents use pull-based polling for signed task capsules rather than
      exposing inbound control-plane ports.
- [ ] NetBird/Nostr/VPN integration is deferred as transport and not required
      for authorization.

### P15: OpenCode session/chat UI spike

Labels: `tier:thinking,opencode,dashboard,auto-dispatch`.

Blocked by: P2, P5.

Files to modify:

- `NEW: docs/gui/opencode-session-ui.md`
- `EDIT: apps/gui-web/**` only for a prototype if explicitly scoped.
- `EDIT: apps/gui-server/**` only for a prototype if explicitly scoped.

Deliverable:

- Spike document and optional prototype for creating, listing, attaching to, and
  streaming OpenCode sessions through a safe typed API.

Acceptance criteria:

- [ ] Does not bypass OpenCode permissions or aidevops hooks.
- [ ] Streams logs/transcripts without leaking secrets.
- [ ] Defines session ownership, worktree scope, and stop/kill controls.
- [ ] Explicitly separates UI chat from worker dispatch and git audit trail.

### P16: Desktop wrapper, signing, and auto-update plan

Labels: `tier:thinking,release,auto-update,dashboard,auto-dispatch`.

Blocked by: P1, P5.

Files to modify:

- `NEW: docs/gui/desktop-packaging.md`
- `NEW: docs/gui/release-signing-updates.md`
- `NEW: apps/gui-desktop/**` only if the issue is scoped to prototype code.

Deliverable:

- Plan for macOS, Windows, Linux desktop builds with unsigned dev mode first,
  then signing and auto-updates later.

Acceptance criteria:

- [ ] Users can run local web mode without signing accounts.
- [ ] Desktop wrapper does not become the only supported mode.
- [ ] Signing requirements for Apple/Windows/Linux are documented.
- [ ] Auto-update trust chain and release artifact verification are specified.

### P17: GUI testing and CI/CD strategy

Labels: `tier:thinking,testing,ci,architecture,dashboard,auto-dispatch`.

Blocked by: P1, P2.

Files to modify:

- `NEW: docs/gui/testing-ci-cd.md`
- `EDIT: docs/gui/control-plane.md` only if the testing direction changes.

Deliverable:

- Test and CI/CD strategy for the GUI across local web, API/server, adapters,
  Cloudron packaging, future desktop wrapper, and multi-machine security flows.

Implementation steps:

1. Read `docs/gui/control-plane.md`, especially `Testing and CI/CD direction`.
2. Read the P1 stack ADR and P2 trust-boundary ADR before choosing tools.
3. Define local test layers: schema/unit, adapter fixture, API route, component,
   browser smoke, security/redaction, Cloudron package, and desktop package.
4. Define CI path filters and whether GUI jobs should be separate from existing
   framework shell/doc jobs.
5. Define the first implementation acceptance contract for P5: exact scripts,
   required vs advisory jobs, and artifact policy.

Verification:

```bash
git diff --check
```

Acceptance criteria:

- [ ] Strategy names required local commands for the scaffold phase.
- [ ] Strategy distinguishes required, advisory, and release-only checks.
- [ ] Strategy includes secret-redaction/security regression tests.
- [ ] Strategy covers Cloudron package checks once `cloudron/` exists.
- [ ] Strategy covers future desktop signing/auto-update artifact verification.
- [ ] Strategy avoids slowing unrelated shell/framework PRs unnecessarily.

## Agent continuity requirements

Create or update a progressive-disclosure reference only after the first two or
three GUI PRs reveal repeated context loss. Do not add long GUI rules to
`.agents/AGENTS.md`.

Potential future reference:

```text
.agents/reference/gui-control-plane.md
```

It should point to:

- `docs/gui/control-plane.md` for mission and product principles;
- ADRs for stack and trust decisions;
- `workflows/brief.md` for issue content;
- `reference/task-lifecycle.md` for parent/child/blocked-by workflow;
- `reference/secret-handling.md` for secrets;
- Cloudron and CalDAV skills for those phases.

Specialist context to load per phase:

| Phase | Specialist context | Primary references |
|-------|--------------------|--------------------|
| P1 | `architecture`, product planning context | `docs/gui/control-plane.md`, `.agents/aidevops/architecture.md` |
| P2 | `security`, threat-model context | `docs/gui/control-plane.md`, `.agents/reference/secret-handling.md`, `.agents/reference/pre-push-guards.md` |
| P3 | `architecture`, data-model context | `docs/gui/control-plane.md`, P1 ADR, P2 ADR |
| P4 | `code`, `architecture`, helper/API context | `.agents/scripts/`, `.agents/reference/services.md`, `.agents/reference/task-lifecycle.md` |
| P5 | `code`, `architecture`, TypeScript/app scaffold context | P1-P4 ADRs/contracts, P17 testing strategy |
| P6 | `code`, setup/status helper context | P4 helper/API contract, setup/config helper docs, secret-status rules |
| P7 | `git-workflow`, `github-cli`, Git source-of-truth context | P4 helper/API contract, `.agents/reference/repo-organization.md`, `.agents/reference/task-lifecycle.md` |
| P8 | `architecture`, infrastructure/resource graph context | P3 data-model ADR, `docs/gui/control-plane.md` infrastructure inventory sections |
| P9 | research/content context with source verification | `docs/gui/control-plane.md` provider catalog notes, `.agents/reference/secret-handling.md` |
| P10 | routines/automation context | `.agents/reference/routines.md`, `.agents/scripts/commands/routine.md`, P4 helper/API contract |
| P11 | `caldav-calendar` skill | `docs/gui/control-plane.md` CalDAV/CardDAV notes, `.agents/reference/secret-handling.md` |
| P12 | product/design and agent-capability context | `.agents/reference/agent-routing.md`, `.agents/reference/domain-index.md`, `.agents/reference/progressive-disclosure.md` |
| P13 | `cloudron-app-packaging` and `cloudron-server-ops` skills | P2 trust-boundary ADR, Cloudron package docs, `.agents/reference/secret-handling.md` |
| P14 | `security`, orchestration/multi-machine context | P2 trust-boundary ADR, P3 data-model ADR, `.agents/reference/worker-discipline.md` |
| P15 | `customize-opencode`, OpenCode/session context | `.agents/reference/session.md`, `.agents/reference/memory-lookup.md`, OpenCode plugin/session docs |
| P16 | `release`, desktop packaging/signing context | P1 stack ADR, `.agents/reference/ci-gate-policy.md`, `.agents/workflows/release.md` |
| P17 | `github-actions`, `qlty`, testing/security context | P1 stack ADR, P2 trust-boundary ADR, `.agents/reference/ci-gate-policy.md`, `.agents/reference/shell-style-guide.md` |

## First wave recommendation

File these first, then pause implementation until P1-P4 merge:

1. Program parent issue.
2. P1 Product, stack, and repo-layout ADR.
3. P2 Security threat model and trust-boundary ADR.
4. P3 Data model and infrastructure graph ADR.
5. P4 Helper/API contract.
6. P17 GUI testing and CI/CD strategy.

Once P1-P4 and P17 are merged and verified, file P5 as the first implementation
issue.
