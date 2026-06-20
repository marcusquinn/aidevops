<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# ADR 0001: GUI product scope, stack, and repo layout

## Status

Accepted.

## Context

aidevops needs a GUI/control plane that helps users set up, understand, manage,
and scale local machines, Cloudron installs, git platforms, infrastructure
providers, routines, and AI-agent workflows.

The first architecture decision must preserve these constraints:

- Local-first use must work before any hosted or paired-machine service exists.
- Cloudron deployment must remain a first-class target.
- Future Tauri desktop packaging must not require a rewrite.
- Integration should stay aidevops-helper-first: existing helper scripts,
  workflow docs, issue/PR state, and git history remain the authority.
- The first scaffold must avoid secrets centralisation and destructive write
  actions.

The aidevops repository root is a public contract. New top-level paths require a
repo-layout policy entry before they are introduced, and documentation belongs
under the existing `docs/` planning surface.

## Decision

Build the first GUI/control-plane implementation as a local-first web/API
product in this repository, introduced in staged package subtrees during the
implementation phase.

The initial stack is:

- Vite React for the browser UI.
- Hono for the local API boundary.
- SQLite-first local storage for cached status, projections, and user-owned
  control-plane data.
- aidevops helper scripts, git providers, and repo files as authoritative
  integration sources.
- Cloudron packaging after the local web/API scaffold is stable.
- Tauri desktop packaging after the web/API contract and local trust model are
  proven.

The first code phase should create package subtrees in this repository, not a
separate repository. The expected shape is a future `packages/` root containing
separate web, API, and shared contract packages. The phase that introduces that
root must update `.agents/configs/repo-layout-policy.conf` before adding it.

No first-use path may require code signing, VPN access, a hosted aidevops
control plane, or a central secrets store controlled by the GUI.

## Alternatives considered

### Next.js application first

Next.js would provide routing, server actions, and deployment conventions, but
it couples the first product to a web server framework and makes hosted/server
assumptions easy to introduce accidentally. That is misaligned with local-first
operation, Cloudron packaging as a later target, and future Tauri embedding.

### Vite React web app first

Vite keeps the UI as a portable browser bundle that can be served by the local
API, packaged into Cloudron, or embedded by Tauri later. It avoids unnecessary
server-rendering decisions while still allowing a strong component and testing
workflow. This is accepted.

### Fastify API first

Fastify is mature and well suited to Node services, but its plugin ecosystem and
Node-oriented conventions are heavier than the first local API needs. It is a
reasonable fallback if Hono blocks required helper integration, streaming, or
testing ergonomics.

### Hono API first

Hono gives a small Web-standard request/response boundary that can run in local
Node/Bun-style environments and remain easy to wrap for Cloudron or desktop
packaging. It is sufficient for a read-only helper/status API and keeps the
surface area small. This is accepted.

### Hosted database or network service first

A hosted database would simplify multi-machine access later, but it would make
first use depend on external infrastructure and raise secret custody questions
too early. SQLite-first storage preserves user ownership, offline operation, and
testability. Multi-machine sync or task capsules require a later ADR.

### Separate repository first

A separate repository would isolate GUI dependencies, but it would split product
memory, helper contracts, tests, and issue context before the architecture is
stable. The first implementation should live with the aidevops helpers it wraps.

### Ad hoc root-level app files

Adding root-level `web/`, `api/`, or similar paths without a package policy would
violate the repository root contract. Staged package subtrees with an explicit
repo-layout policy entry are preferred.

## Repo layout policy impact

This ADR only adds documentation under `docs/`, which is already an allowed
docs-planning surface.

The implementation phase that creates code should add a top-level `packages/`
entry to `.agents/configs/repo-layout-policy.conf` before adding package
subtrees. The policy rationale should state that `packages/` contains staged
GUI/control-plane application packages and shared contracts for local, Cloudron,
and future desktop surfaces.

Expected future package boundaries:

- `packages/gui-web/` for the Vite React UI.
- `packages/gui-api/` for the Hono local API.
- `packages/gui-shared/` for typed contracts, schemas, and test fixtures shared
  across the UI and API.

## Consequences

- Phase 6 may begin coding the read-only local API and dashboard scaffold after
  the security, data model, helper/API contract, and testing/CI ADRs are in
  place.
- First implementation work should call existing aidevops helpers rather than
  reimplementing helper logic inside the GUI.
- Write actions remain out of scope until trust-boundary and helper-contract
  documentation define authorization, audit logging, destructive-operation
  safeguards, and secret handling.
- Cloudron packaging can target the same web/API packages once the local
  scaffold is stable.
- Tauri packaging can wrap the accepted web/API contract later without changing
  the first UI framework.

## Decisions still gated

- Security threat model and trust boundaries for write actions, secret access,
  Cloudron deployment, and machine pairing.
- Data model for infrastructure graph projections, local cache invalidation, and
  ownership of user annotations.
- Helper/API contract for command execution, streaming status, errors, and audit
  evidence.
- GUI testing and CI/CD strategy, including which checks are required for package
  changes.
- Multi-machine pairing and scoped task capsules.
- Desktop wrapper details, including whether Tauri launches the local API as a
  sidecar or connects to an already-running local service.

## Verification

Run:

```bash
git diff --check
npx --yes markdownlint-cli2@0.22.0 docs/gui/adr-0001-product-scope-stack-repo-layout.md docs/gui/control-plane.md
```
