<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# aidevops GUI control plane

This document is the canonical product memory for the aidevops GUI/control
plane. ADRs under `docs/gui/` record decisions that should not be re-litigated
by implementation workers without a new ADR.

## Product scope

The control plane is the primary visual surface for setting up, understanding,
managing, and scaling aidevops across local machines, Cloudron, git platforms,
infrastructure providers, routines, and AI-agent workflows.

The first usable product remains local-first:

- It must run without signing, VPN access, or a hosted aidevops service.
- It must not centralise secrets or make a remote control plane mandatory.
- It uses aidevops helper scripts and git platforms as sources of truth instead
  of duplicating orchestration state.
- It starts read-only for setup/status insight before adding write actions.

## Phase roadmap

1. Product, stack, and repo-layout ADR.
2. Security threat model and trust-boundary ADR.
3. Data model and infrastructure graph ADR.
4. Helper/API contract.
5. GUI testing and CI/CD strategy.
6. Local read-only API and dashboard scaffold.
7. Setup/status, repos/git, infrastructure, provider bookmarks, routines,
   CalDAV/CardDAV, and capability browser surfaces.
8. Cloudron package.
9. Multi-machine pairing and scoped task capsules.
10. OpenCode session/chat UI and desktop wrapper.

## Current architecture decisions

- ADR 0001 chooses a Vite React web app, Hono local API, and SQLite-first local
  storage for the first scaffold.
- First code should land in this repository as staged package subtrees, not as a
  separate repository and not as new root-level ad-hoc app files.
- Future phases that introduce new top-level directories must update
  `.agents/configs/repo-layout-policy.conf` before adding those paths.

## Implementation gates

- Coding may begin in Phase 6 after ADRs for product/stack, threat model, data
  model, helper/API contract, and testing/CI/CD strategy are complete.
- Write actions remain gated on explicit trust-boundary documentation, helper
  contracts, and tests for destructive-operation safeguards.
- Cloudron packaging, machine pairing, and desktop packaging remain later-phase
  deliverables, not prerequisites for first local use.

## Product principles

- Git platforms remain the primary source of truth for projects, planning,
  issues, pull requests, progress tracking, memory references, and
  collaboration.
- The GUI is a control surface over existing aidevops helpers and config, not a
  second source of truth.
- Secrets stay in aidevops secret storage, gopass, Vaultwarden, OS keychains, or
  provider-native secret stores. The GUI stores secret references and health
  status only, never raw secret values.
- A Cloudron-hosted control plane must not become a god box. Compromise of the
  control plane or one machine must not grant unrestricted access to every other
  machine.
- Local-first workflows must work before hosted/fleet workflows. Cloudron,
  desktop wrappers, VPNs, and multi-machine delegation are layered on top.
- The app should guide choices with aidevops preferences rather than hiding the
  underlying systems from power users.
- Every setup flow should teach the underlying file, helper, verification, and
  rollback path.

## Non-goals for early releases

- No arbitrary remote shell execution endpoint.
- No central plaintext credential database.
- No direct editing of generated OpenCode config entries.
- No requirement for VPN, signing certificates, or paid developer accounts for
  the first usable local web build.
- No replacement for GitHub, GitLab, Gitea, or Forgejo issue/PR workflows.

## Stack notes

The initial implementation is a web-first TypeScript stack with a local
daemon/API boundary and optional desktop wrapper later.

| Layer | Direction | Reason |
|-------|-----------|--------|
| Shared UI | React + TypeScript | Reusable across local web, Cloudron, and desktop wrapper |
| App shell | Vite | Chosen by ADR 0001 for the first scaffold |
| API server | Node.js TypeScript with Hono | Typed local/Cloudron API, simple deployment |
| Contracts | Zod plus generated OpenAPI/JSON Schema | Worker-friendly validation and docs |
| Storage | SQLite first | Local-first, Cloudron-friendly, easy backup |
| Desktop | Tauri v2 later | Smaller and safer than Electron for this use case |
| Cloudron | Same web/server app packaged with Cloudron conventions | One product surface, multiple deployment modes |
| Long-running local access | `aidevopsd` typed daemon | Browser UI never gets direct shell access |

Suggested repo layout from ADR 0001:

```text
apps/gui-web/              Shared React UI
apps/gui-server/           Local and Cloudron API server
apps/gui-desktop/          Tauri wrapper, added after web/server stabilises
packages/gui-core/         Types, schemas, policy model, API client
packages/gui-adapters/     aidevops helpers, OpenCode, git hosts, gopass, Cloudron
cloudron/                  CloudronManifest.json, Dockerfile, start.sh
docs/gui/                  Product, ADRs, threat model, data model, release docs
```

## Core product areas

### Setup and status

Show new and existing users what is installed, configured, missing, stale, or
unsafe:

- aidevops version and update status;
- OpenCode and supported runtime status;
- helper availability;
- folder locations and permissions;
- config, settings, and repo registry health;
- secret backend status by name only;
- local routines and scheduler status;
- local/Cloudron deployment mode.

### Infrastructure graph

Model DevOps infrastructure as a graph of identities, accounts, providers,
resources, projects, machines, routines, and agents.

Initial resource families:

- domains, registrars, DNS zones, DNS providers;
- GitHub, GitLab, Gitea, Forgejo, and git runners;
- hosting, VPS providers, servers, containers, proxies, VPNs;
- orchestrators: Cloudron, Coolify, Ubicloud, and similar platforms;
- operating systems and devices: macOS, Windows, Ubuntu, Arch, Omarchy, iOS,
  Android, GrapheneOS;
- server apps: Nextcloud, Collabora, pastebin apps, Docuseal, Postiz, EspoCRM,
  Odoo, Vaultwarden, Fider, Gitea, Forgejo;
- local aidevops/OpenCode instances and machines with available compute.

Every resource should support:

- owner identity;
- provider/account link;
- environment and purpose;
- health/update/backup status;
- linked secrets by reference only;
- related repos/projects/routines;
- trust scope and allowed operations;
- notes, setup guide, and verification command.

### Identities and accounts

Track which identities own which accounts without centralising credentials:

- personal/business identities;
- admin, automation, service, and recovery accounts;
- email and messaging accounts;
- social media accounts;
- git, hosting, DNS, VPN, proxy, app, and billing accounts;
- 2FA/passkey/recovery status;
- account risk, trust scope, and blast radius notes.

### Projects and Git source of truth

The GUI should index Git state and aidevops metadata, but Git platforms remain
canonical for work items and collaboration.

- Repos are read from and reconciled with `repos.json`.
- GitHub/GitLab/Gitea/Forgejo issues and PRs remain the audit trail.
- Parent/child issue relationships express phase dependencies.
- Worker-ready issue bodies follow `workflows/brief.md`.
- Multi-machine work still uses worktrees, PRs, CI, and review gates.

### Machines, runners, and sessions

Manage the local machine first, then paired machines later:

- local aidevops/OpenCode instance;
- machine identity and public key;
- available compute and OS capabilities;
- git runner status;
- OpenCode sessions and logs;
- allowed repos and dispatch limits;
- heartbeat, last seen, and safe-disable controls.

Future multi-machine delegation uses signed task capsules with expiry, repo
scope, allowed operations, and human-approval requirements where needed.

### Provider bookmarks and recommendations

Provide a shared bookmark catalog for recommended providers and setup patterns.

Use cases:

- compare DNS, domain, VPS, email, VPN, proxy, cloud, app hosting, and AI/model
  providers;
- store setup notes, pros/cons, price bands, open-source/privacy/freedom scores,
  and affiliate links later;
- mark providers as recommended, experimental, avoided, or user-owned;
- link providers to setup guides and relevant aidevops helpers.

Affiliate links are content metadata, not operational secrets. The schema should
support them later without requiring them in early builds.

### Routines

Expose setup, scheduling, status, and troubleshooting for aidevops routines.

The GUI should show:

- routine definitions;
- enabled/disabled state;
- schedule and next run;
- last run, duration, output, and failure reason;
- retry, pause, and edit actions;
- linked repos, services, and secrets;
- whether a routine runs as a script or LLM-backed agent.

The source of truth remains TODO/routine definitions and aidevops scheduler
helpers until a later ADR changes that contract.

### Calendar, contacts, and local apps

Guide integration setup for Nextcloud, local OS apps, and CalDAV/CardDAV:

- Nextcloud Calendar/Contacts;
- CalDAV/CardDAV credentials and sync status;
- local macOS/iOS/Android clients;
- service-account boundaries;
- which routines and agents may read or write which calendars/address books.

Use the existing CalDAV skill and service/account helpers as implementation
context when this area is designed.

### Agents and knowledgebase

The aidevops agents are the growing knowledgebase of capabilities and
opinionated choices. The GUI should make that knowledge discoverable without
bloating always-loaded prompts.

Show:

- capability cards for agents, tools, services, and workflows;
- when to use each capability;
- setup requirements;
- verification commands;
- linked docs and examples;
- preferred open-source/self-hosted/default choices.

Do not duplicate long agent instructions into the UI database. Store references
to docs and concise summaries, then load detailed guidance on demand.

## Data design sketch

Core entities should be stable and generic enough for ongoing evolution.

```text
Identity
  id, name, type, trust_level, recovery_notes_ref

Provider
  id, name, category, homepage_ref, recommendation_status, notes_ref

Account
  id, identity_id, provider_id, account_type, username_ref, secret_refs[], status

Resource
  id, resource_type, provider_id, account_id, environment, status, metadata_json

Machine
  id, resource_id, machine_identity_pubkey, os_family, capabilities[], scopes[]

Project
  id, git_remote, repo_slug, repos_json_ref, owner_identity_id, status

Routine
  id, source_ref, schedule, runner_type, linked_resources[], linked_secret_refs[]

Bookmark
  id, provider_id, category, recommendation, affiliate_ref, rationale, tags[]

Capability
  id, doc_ref, agent_ref, service_ref, setup_requirements[], verification_refs[]

Integration
  id, integration_type, account_id, resource_id, secret_refs[], health_status

TaskCapsule
  id, issuer_machine_id, target_machine_id, repo_scope, allowed_actions[], expires_at

AuditEvent
  id, actor_ref, machine_id, origin_ip_ref, action, target_ref, result,
  redacted_metadata, created_at
```

Implementation notes:

- Use stable IDs and typed resource categories rather than one table per
  provider.
- Keep provider-specific fields in validated metadata objects.
- Store secret references, not values.
- Store external references to Git issues/PRs/repos rather than duplicating their
  full state.
- Add migrations and schema tests before write flows.

## Trust boundaries

- Browser UI can call only the typed local/Cloudron API.
- Local API can call a small allowlist of aidevops helpers.
- No API route accepts arbitrary shell strings.
- High-risk operations require explicit confirmation and audit events.
- Cloudron control plane sends signed, scoped tasks to machines; machines keep
  their own secrets.
- Local agents poll for signed task capsules rather than exposing inbound
  control-plane ports.
- VPN or overlay networking is transport, not authorization.
- Pairing uses per-machine identity keys and explicit user approval.

## Testing and CI/CD direction

GUI development needs its own test and release lanes once code lands. The early
planning phases should define the contract before implementation workers create
app packages.

Local testing expectations:

- schema/unit tests for `packages/gui-core` data models and API contracts;
- adapter tests with fake aidevops helper outputs before calling real helpers;
- API route tests for every read/write endpoint, including redaction and error
  handling;
- component tests for setup, infrastructure, provider catalog, routines, and
  session UI surfaces;
- browser smoke tests for the local dashboard once routes exist;
- security tests proving secret values are never returned by API responses or
  rendered in the UI;
- fixture tests for `repos.json`, settings/config files, routine definitions,
  provider catalogs, and machine-pairing/task-capsule schemas.

CI/CD expectations:

- keep existing framework CI fast for docs/planning-only PRs;
- add GUI-specific lint/typecheck/unit/component jobs once GUI packages exist;
- gate only changed GUI paths where practical to avoid slowing unrelated
  framework work;
- add Cloudron packaging/build checks when `cloudron/` lands;
- add desktop/Tauri build/signing checks only after the desktop wrapper exists;
- treat E2E and visual tests as required for release/staging changes, advisory
  or path-scoped for ordinary development until the suite is fast enough;
- publish release artifacts only through signed/checksummed workflows once
  auto-update channels are introduced.

Distinct CI/CD for the GUI is likely warranted after the scaffold phase because
the GUI will introduce TypeScript workspace packages, web builds, Cloudron
packaging, and eventually desktop release artifacts that should not run on every
shell-only framework change.

The scaffold verification contract, path-scoped CI policy, and later Cloudron
and desktop release gates are defined in `docs/gui/testing-ci-cd.md`.

## Source-of-truth map

| Domain | Source of truth | GUI role |
|--------|-----------------|----------|
| Project work | Git platform issues/PRs/repos | Index, create guided briefs, show progress |
| aidevops settings | Existing config/settings helpers | Read, validate, call safe write helpers |
| Repo registry | `repos.json` | Validate, back up, edit through helper APIs |
| Secrets | aidevops secrets/gopass/Vaultwarden/OS keychain | Status and setup guidance only |
| Routines | TODO/routine definitions and scheduler helpers | Dashboard, editor, run history |
| OpenCode config | aidevops OpenCode plugin registry | Display generated state; edit upstream config only |
| Machine delegation | Future signed task capsule log | Pair, scope, audit, revoke |

## Inspiration to continue reviewing

Use external projects as inspiration only unless their license explicitly permits
reuse and compatibility is verified.

- Pierre: TypeScript monorepo discipline, package/app split, fast tooling.
- Public AI-agent GUI projects: session UI, background worker UX, local-first
  agent management.
- Public local-first desktop AI apps: Tauri packaging, local model UX, update
  flows.
- Public workflow platforms: turning scripts and tasks into safe web UIs.
- Public secret-manager projects: agent-safe secret use without disclosure.
- Public VPN/orchestrator projects: pairing, fleet inventory, device posture, and
  network-policy UX.
- Existing local starter-template repos mentioned in the planning session:
  dashboard, AI sidebar, audit log, vault, encryption, task progress, and data
  table patterns should be reviewed privately before implementation briefs cite
  any code.

## Agent continuity map

Future work should route to specialist context rather than adding broad rules to
always-loaded prompts.

| Area | Agent/skill context to load |
|------|-----------------------------|
| Product scope and UX | Product/design agents plus this document |
| TypeScript app architecture | Code/build agents, app-stack ADRs |
| Cloudron packaging | `cloudron-app-packaging` skill |
| Calendar/contact setup | `caldav-calendar` skill |
| Security and trust model | Security references, secret-handling docs |
| Git issue/PR lifecycle | `workflows/brief.md`, `reference/task-lifecycle.md`, `workflows/git-workflow.md` |
| Routines | `reference/routines.md`, routine command docs |
| OpenCode session UI | OpenCode plugin/reference docs |
| Provider catalogs/content | Research/content agents with source verification |

If this product area grows enough to need custom continuity, add a progressive
disclosure reference such as `.agents/reference/gui-control-plane.md` instead of
expanding `.agents/AGENTS.md`.
