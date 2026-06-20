<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# ADR 0003: GUI data model and infrastructure resource graph

## Status

Accepted for planning. Implementation remains gated by migrations, schemas, and
schema tests described below.

## Context

The aidevops GUI/control plane must help users understand and operate across
identities, provider accounts, resources, projects, machines, routines,
bookmarks, capabilities, integrations, task capsules, and audit events. The
initial product is local-first, uses SQLite for local storage, and keeps existing
aidevops helpers, git platforms, and provider systems as sources of truth where
they already own state.

The core design risk is overfitting the first database to one provider, one
hosting style, or one secret backend. The app needs to model domains, DNS, git,
hosting, email, messaging, social media, VPNs, proxies, servers, containers,
orchestrators, operating-system/device fleets, server apps, git runners,
provider bookmarks, affiliate metadata, CalDAV/CardDAV integrations, routines,
and machine delegation without centralizing credentials.

## Decision

Use a typed resource graph with generic core entities and validated metadata
extensions.

The accepted core entities are:

- `Identity`
- `Provider`
- `Account`
- `Resource`
- `Machine`
- `Project`
- `Routine`
- `Bookmark`
- `Capability`
- `Integration`
- `TaskCapsule`
- `AuditEvent`

The GUI will separate provider, account, resource, project, routine, and machine
records. Provider-specific details will be stored in schema-validated metadata
objects keyed by entity type, resource/provider type, provider slug, and schema
version. Secrets will be represented only by secret references and non-sensitive
health states.

Relationships between entities will be stored as typed graph edges or link
tables rather than one provider-specific table per resource family. The graph is
the primary model for cross-domain views such as “which routines touch this
domain,” “which machine can run this git runner,” or “which CalDAV collection is
safe for this agent to read.”

## Resource graph scope

The graph must support these resource families from the first schema plan:

- Domains, registrars, DNS zones, DNS records, and DNS providers.
- GitHub, GitLab, Gitea, Forgejo, repositories, organizations, apps, and git
  runners.
- Hosting, VPS providers, servers, serverless apps, object storage, databases,
  CDNs, backups, and monitoring resources.
- Email domains, mailboxes, aliases, SMTP/IMAP services, and mailing lists.
- Messaging accounts, messaging groups, social profiles, social pages, and social
  apps.
- VPN networks, VPN nodes, proxies, tunnels, and overlay networks as transport
  resources rather than authorization grants.
- Physical servers, VMs, laptops, desktops, mobile devices, and tablets.
- Container hosts, containers, compose stacks, images, volumes, and container
  networks.
- Orchestrators such as Cloudron, Coolify, Ubicloud, Kubernetes, Nomad, and
  similar app platforms.
- Operating systems and device fleets including macOS, Windows, Ubuntu, Arch,
  Omarchy, iOS, Android, GrapheneOS, package managers, and update channels.
- Server apps such as Nextcloud, Collabora, pastebin apps, Docuseal, Postiz,
  EspoCRM, Odoo, Vaultwarden, Fider, Gitea, Forgejo, and other self-hosted apps.
- Calendar/contact resources for CalDAV/CardDAV services, collections, local
  sync clients, service-account boundaries, and allowed routine/agent access.
- Local aidevops/OpenCode installs, helper sets, session logs, runtime status,
  and machines with available compute.
- AI/agent resources such as agent runtimes, model providers, model accounts,
  knowledge repositories, and task queues.

## Relationship examples

The graph supports these relationship patterns:

- An `Identity` owns an `Account` at a `Provider`.
- An `Account` administers a `Resource`.
- A `domain` resource delegates to one or more `dns_zone` resources.
- A `dns_zone` contains `dns_record` resources that point to hosting, email, or
  verification resources.
- A `Project` references a `git_repo` resource and can use domains, apps,
  routines, and machines.
- A `git_runner` resource is backed by a `Machine` and scoped to one or more
  projects or repos.
- A `server` runs containers, app resources, proxies, VPN nodes, and backup
  routines.
- A `cloudron_instance` owns app resources, domains, backups, update channels,
  and provider/account links.
- A `nextcloud_app` exposes `calendar_service` and `contacts_service` resources.
- A `caldav` or `carddav` `Integration` links an account, app resource, secret
  refs, collections, local sync clients, and routines with read/write scopes.
- A `Routine` reads or writes resources and uses secret references through
  helper adapters.
- A `Machine` can run routines, OpenCode sessions, git runners, and scoped task
  capsules.
- A `TaskCapsule` delegates limited actions from one machine to another with
  expiry, replay protection, and audit requirements.
- A `Bookmark` recommends a `Provider` and may include future affiliate metadata
  as content metadata.
- An `AuditEvent` records a non-secret action on any graph target.

These relationships make provider-specific dashboards possible without making
provider-specific data the core model.

## Provider-specific metadata

Core columns should represent identity, ownership, health, trust scope, and
graph relationships. Provider-specific values belong in validated metadata.

Metadata schema keys should follow this pattern:

```text
<entity>.<resource_or_provider_type>.<provider_slug>.<version>
```

Examples:

- `resource.dns_zone.cloudflare.v1`
- `resource.git_repo.github.v1`
- `resource.server_app.cloudron.v1`
- `integration.caldav.nextcloud.v1`
- `bookmark.provider_catalog.generic.v1`

Metadata may include provider IDs, non-secret endpoint references, product tiers,
regions, feature flags, plan names, sync direction, collection references,
backup policy, and adapter hints. It must not include API tokens, passwords,
private keys, recovery codes, raw credential files, cookie values, or logs that
may contain secrets.

Unknown metadata extension versions should be preserved for read-only display
and export, but write paths must validate or migrate them before mutation.

## Provider bookmarks and affiliate metadata

Provider bookmarks are first-class content records, not operational accounts.
The graph will support providers that are recommended, experimental, avoided,
user-owned, or unknown before any account is connected.

Bookmark metadata may include setup guide references, pros/cons, tags, price
bands, open-source/privacy/freedom scores, region notes, helper references,
verification references, and future affiliate references. Affiliate data is
content metadata and disclosure context; it is not a secret, not a provider API
credential, and not authorization for operations.

## CalDAV/CardDAV and local app integrations

Calendar and contact support is modeled through `Integration` plus resource
records for services, collections, address books, and local sync clients.

The model must represent:

- Nextcloud Calendar/Contacts and other CalDAV/CardDAV providers.
- Service-account boundaries and account ownership.
- Credential references and health state only.
- Local macOS/iOS/Android/desktop sync clients.
- Which routines and agents may read or write each calendar or address book.
- Sync status, last check, failure class, and setup guide references.

This keeps the calendar/contact model compatible with local apps and hosted
providers without special-casing one calendar service in the core schema.

## Routine and machine delegation support

Routine records link scheduler/source definitions to resources, projects,
machines, secret refs, run history, and audit events. The source of truth remains
existing routine definitions and scheduler helpers until a later ADR changes it.

Machine delegation is modeled through `Machine`, `TaskCapsule`, `Capability`,
and `AuditEvent` records. A task capsule must include issuer and target machine
identity, repo/project/resource scope, allowed action classes, risk ceiling,
expiry, replay protection, human-approval requirements where needed, and result
evidence. A capsule does not grant arbitrary shell access and must be enforced by
the target machine.

## Secret handling decision

The GUI data model stores secret references, not secret values. Any entity may
link to `secret_refs` that identify the backend, secret name/ID, purpose, health
state, last check time, and rotation/check helper reference. The GUI may show
configured/missing/invalid/unknown states and setup guidance. It must not load,
persist, render, export, diff, or audit raw secret values.

## Migration and schema-test requirements

Before implementation introduces write flows for this model, it must add:

- SQLite migrations for persisted core entities and relationship/link tables.
- Deterministic migration ordering and fixture upgrade tests.
- Schema validation for core entities, resource types, metadata extensions, and
  secret references.
- Fixtures for domains/DNS, git repos/runners, hosting/server/container,
  Cloudron/server apps, provider bookmarks, CalDAV/CardDAV, routines, local
  apps, machines, task capsules, and audit events.
- Tests proving API responses and audit records do not include secret values.
- Tests preserving unknown metadata extensions as read-only data until migrated.
- Tests rejecting metadata payloads with wrong provider, wrong version, missing
  required fields, or secret-shaped values.

The first read-only dashboard may use transient projections, but persistent
mutations require migrations and schema tests first.

## Alternatives considered

### One table per provider

Provider-specific tables would make the first provider integration simple, but
they would duplicate ownership, secret handling, health, audit, and relationship
logic. This would not scale across DNS, git, Cloudron, CalDAV/CardDAV, local
apps, and machine delegation.

### Free-form JSON inventory only

An unstructured JSON inventory would be flexible, but it would make schema
tests, migrations, redaction, relationship queries, and API contracts weak. The
accepted model allows provider metadata extensions while keeping core entities
and relationships typed.

### Treat provider accounts as resources

Flattening accounts into resources would blur identity, billing, MFA, recovery,
and blast-radius boundaries. The model keeps provider, account, and resource
separate so the GUI can explain who owns an account, what it can administer, and
which resources depend on it.

### Treat machines as generic resources only

Machines are resources, but they also enforce local authority and accept future
task capsules. Keeping a separate `Machine` entity avoids mixing compute posture,
identity keys, scopes, heartbeats, and delegation state into ordinary resources.

## Consequences

Positive consequences:

- The model covers the initial infrastructure families without committing to one
  provider or secret backend.
- Provider bookmarks and future affiliate metadata fit as content records.
- CalDAV/CardDAV, routines, local apps, and machine delegation share the same
  graph primitives as domains, git, hosting, and server apps.
- Secret redaction can be tested at the schema/API boundary.
- Future package code can generate OpenAPI/JSON Schema contracts from typed
  schemas.

Costs and trade-offs:

- Implementation needs relationship/link tables and metadata schemas before
  meaningful write flows.
- Provider adapters must map external IDs into generic graph entities.
- Query design is more complex than a small provider-specific dashboard.
- Migration discipline is required from the first persistent schema.

## Repo layout policy impact

This ADR only adds documentation under `docs/gui/`, which is already an allowed
planning surface. Future code packages for schemas, migrations, tests, and API
contracts must follow ADR 0001 and update repo-layout policy before adding new
top-level package paths.

## Verification

Run:

```bash
git diff --check
npx --yes markdownlint-cli2@0.22.0 docs/gui/data-model.md docs/gui/adr-0003-resource-graph.md
```

## Related

- `docs/gui/control-plane.md`
- `docs/gui/data-model.md`
- `docs/gui/adr-0001-product-scope-stack-repo-layout.md`
- `docs/gui/adr-0002-trust-boundaries.md`
- Issue #25232
- Parent issue #25229
