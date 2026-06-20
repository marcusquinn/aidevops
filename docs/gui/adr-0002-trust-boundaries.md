<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# ADR 0002: GUI Trust Boundaries and Command Authority

## Status

Accepted for planning. Implementation remains gated by the verification items
below.

## Context

The aidevops GUI/control plane is intended to make setup, status, repositories,
infrastructure, routines, OpenCode sessions, Cloudron operation, and
multi-machine delegation understandable from one visual surface. That surface
will sit near sensitive local state: credentials, account routing, git working
trees, issue/PR automation, Cloudron apps, provider APIs, and future paired
machines.

The main security design problem is avoiding a convenient GUI becoming an
ambient command shell. A browser page, hosted Cloudron app, VPN connection, or
paired machine must not automatically inherit unrestricted local command
authority. The control plane needs explicit trust boundaries before write
actions or pairing flows are built.

## Decision

The GUI control plane uses typed, least-privilege boundaries:

1. **Local API enforcement:** the local API is the enforcement boundary, not
   the browser UI.
2. **Typed browser requests:** browser requests map only to allowlisted read
   routes or allowlisted action manifests.
3. **No arbitrary shell:** arbitrary shell endpoints are banned.
4. **Secret references only:** secret values remain outside the GUI data model;
   the GUI handles references and status only.
5. **Cloudron containment:** Cloudron-hosted mode is a coordination surface and
   cannot directly execute unrestricted local commands.
6. **Scoped machine pairing:** paired machines receive revocable, scoped
   capabilities through task capsules; trust is non-transitive.
7. **Transport is not authorization:** VPN, NetBird, Nostr, tunnels, LAN
   reachability, and Cloudron tenancy are transport or hosting properties, not
   authorization decisions.
8. **Confirmed high-risk actions:** high-risk and destructive actions require
   server-enforced confirmation and audit logging.

## Boundary Model

### Browser Boundary

The browser is treated as partially trusted. UI state may improve ergonomics,
but every action must be authorized and validated again by the local API.
Client-side disabled buttons, hidden fields, or route names are not security
controls.

### Local API Boundary

The local API owns command authority. It must expose explicit resources and
actions instead of a remote shell abstraction. Each route declares:

- Operation identifier.
- Read/write/destructive classification.
- Accepted parameters and schemas.
- Required local authorization state.
- Confirmation requirement.
- Audit fields.
- Exact helper adapter or internal function used.

The API must reject unknown actions, unknown parameters, raw shell syntax,
browser-provided helper names, browser-provided environment variables, and
browser-provided paths unless the route schema explicitly allows and validates
that path class.

### Helper Boundary

Existing aidevops helpers remain the mechanism for deterministic operations,
but the GUI does not expose them directly. Helper calls must be wrapped by
server-side adapters that construct exact argument vectors from validated
fields. The adapter layer is responsible for dry-run support, risk labels,
output parsing, and audit emission.

### Secret Boundary

Secret values stay in the existing secret-management layer. GUI data structures
may include only:

- Secret reference name.
- Configured/missing state.
- Validation status and timestamp.
- Owning integration or capability.
- Rotation/check helper reference.
- Non-sensitive error class.

They must not include secret values, partial values, diffs, copied clipboard
payloads, raw credential file contents, or logs that include credentials. Secret
entry and rotation continue through secure storage flows such as `aidevops
secret set NAME` or documented credential files with restrictive permissions.

### Cloudron Boundary

Cloudron-hosted mode cannot be trusted as if it were the local machine. It may
host UI, coordination state, and scoped intent queues. It must not hold reusable
local execution credentials or secret values. Local agents initiate connections,
authenticate the Cloudron identity, fetch scoped intents, and enforce local
authorization before doing anything.

Cloudron compromise containment goal: an attacker controlling the hosted app may
see or tamper with coordination data available to that app, but cannot run
arbitrary commands on local machines, cannot read local secret values, and
cannot expand capabilities beyond previously granted scopes without local
approval.

### Paired-Machine Boundary

Each machine has its own identity and capability grants. Delegation is expressed
as a task capsule that includes:

- Issuer and target machine identities.
- Repository and issue/PR scope.
- Branch/worktree scope where applicable.
- Allowed operation classes and helper adapters.
- Risk ceiling.
- Expiry and replay protection.
- Audit and result-return requirements.

Paired-machine compromise containment goal: an attacker controlling one paired
machine can misuse only that machine's unexpired capsules and local resources;
the attacker cannot mint new capabilities for other machines, cannot retrieve
global secrets, and cannot silently mutate unrelated repos or infrastructure.

## Allowed Local API Command Patterns

Allowed patterns:

- Fixed read-only status routes such as `GET /api/status`, `GET /api/repos`, or
  `GET /api/capabilities` that call predetermined read-only adapters.
- Manifest-backed action routes such as `POST /api/actions/{action_id}` where
  `action_id` exists in a server-side allowlist.
- Schema-validated parameters converted to an exact argument vector without a
  shell whenever possible.
- Operation-specific dry-run routes for high-risk changes.
- Server-side audit entries for every write action.

Banned patterns:

- `POST /shell`, `POST /exec`, `POST /terminal`, `POST /run-command`, or any
  equivalent arbitrary command endpoint.
- Browser-provided command strings, helper names, shell flags, environment
  variables, working directories, or install commands.
- Passing unsanitized issue/PR/web content into execution paths.
- Cloudron-to-local direct command execution.
- Trusting VPN, NetBird, Nostr, or network locality as authorization.

## Confirmation and Audit Requirements

High-risk and destructive operations require server-enforced confirmation. The
confirmation must be tied to the resolved action, target, and risk class, not to
free-form UI text. Audit logs must record:

- Actor and local session identity.
- Operation identifier and risk class.
- Target resource.
- Confirmation result.
- Helper adapter or internal function used.
- Start/end time and outcome.
- Non-sensitive error class and evidence pointer.

Audit logs must not include credential values, private key material, raw secret
files, or private data beyond what is required for local traceability.

## Consequences

Positive consequences:

- The first GUI phase can ship a useful read-only dashboard without taking on
  local command-execution risk.
- Future write actions have a repeatable manifest, confirmation, and audit
  pattern.
- Cloudron and paired-machine designs can scale without centralizing all trust
  or secrets.
- A compromised machine, hosted app, or transport layer has explicit blast-radius
  limits.

Costs and trade-offs:

- Generic terminal convenience is intentionally excluded from the GUI.
- Each new write action needs an adapter, schema, risk classification, tests,
  and audit coverage.
- Pairing is more complex because capability grants, revocation, expiry, and
  replay protection are required before delegation.

## Implementation Gates

Before read-only local dashboard release:

- API binds locally by default.
- Routes are read-only and typed.
- Secret responses contain references/status only.
- Untrusted content rendering is sanitized.

Before local write actions:

- Action manifest format exists.
- Arbitrary shell endpoints are absent and tested as forbidden.
- Confirmation and audit infrastructure exists.
- High-risk operations have dry-run or preview where practical.

Before Cloudron-hosted control:

- Cloudron stores no secret values or reusable local execution credentials.
- Local agents initiate outbound connections.
- Local agents enforce action manifests and risk gates.
- Tests prove Cloudron cannot submit arbitrary local commands.

Before paired-machine delegation:

- Per-machine identity and revocation exist.
- Task capsules are scoped, expiring, and replay-protected.
- Capabilities are non-transitive by default.
- Results return through git/audit artifacts.

## Verification

Each implementation phase that touches these boundaries must include evidence
for the relevant gates. At minimum, CI or local verification must cover:

- No route or adapter accepts arbitrary shell commands.
- Unknown action IDs and unknown parameters are rejected.
- Secret values are not present in API responses, UI state, logs, or exported
  artifacts.
- High-risk and destructive actions cannot run without confirmation.
- Cloudron intents are scoped and locally authorized before execution.
- Pairing capsules cannot be replayed after expiry or revocation.

## Related

- `docs/gui/threat-model.md`
- Issue #25231
- Parent issue #25229
