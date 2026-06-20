<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GUI Control Plane Threat Model

## Scope

This threat model covers the aidevops GUI/control plane before write actions,
Cloudron-hosted operation, pairing flows, and multi-machine delegation are
implemented. It applies to these planned surfaces:

- Local browser UI served by a local aidevops API.
- Local setup/status, repository, routine, session, account, and capability
  views.
- Secret-status UX that references existing secret stores without exposing
  secret values.
- Cloudron-hosted coordination mode.
- Future paired-machine task delegation.

The first implementation phase must remain read-only. Write actions, remote
control, and machine pairing require the phase gates in this document and
`docs/gui/adr-0002-trust-boundaries.md`.

## Non-Goals

- No arbitrary shell terminal in the GUI.
- No API endpoint that accepts free-form commands, shell snippets, or helper
  names from the browser.
- No storage, rendering, syncing, or export of secret values.
- No assumption that VPNs, NetBird, tunnels, Nostr relays, Cloudron, or a LAN
  connection imply authorization.
- No direct mutation of git repositories, local setup state, Cloudron apps,
  routines, paired machines, or provider accounts until a dedicated ADR and
  tests define that action class.

## Assets

| Asset | Security objective |
|-------|--------------------|
| Secret stores and credential files | Never expose values; show only presence, age, scope, source, and health metadata. |
| GitHub/GitLab tokens and app keys | Prevent leakage and prevent unintended writes through overbroad GUI actions. |
| Local aidevops configuration | Protect setup state, account routing, repo inventory, routine schedules, and model preferences from unauthorized changes. |
| Git working trees and issue/PR history | Preserve git as the audit trail; avoid silent local mutation and misleading public comments. |
| OpenCode/aidevops sessions | Prevent session transcript exfiltration, prompt injection replay, and unauthorized control. |
| Routine automation | Prevent unreviewed scheduling, destructive operations, and comment storms. |
| Cloudron instance | Prevent hosted UI compromise from becoming local command execution. |
| Paired machines | Contain compromise to the affected machine and delegated task capsule. |
| Audit logs | Preserve who/what/when/why for high-risk or destructive actions without credential values. |

## Actors

| Actor | Trust level | Notes |
|-------|-------------|-------|
| Local interactive user | Primary authority | Must still confirm high-risk and destructive actions. |
| Local browser origin | Partially trusted | Browser compromise, extensions, XSS, CSRF, and localhost drive-by requests are in scope. |
| Local aidevops API | Trusted computing base | Must enforce allowlisted routes and authorization independent of UI controls. |
| Cloudron-hosted GUI | Untrusted for local execution | May coordinate state, but cannot directly execute unrestricted local commands. |
| Paired machine agent | Scoped trust | Authorized only for explicit capabilities and task capsules. |
| Git platform | Source-of-truth collaborator surface | Issues, PRs, checks, and comments remain auditable external records. |
| VPN/NetBird/tunnel/Nostr transport | Transport only | Provides reachability or encryption, not application authorization. |
| External issue/PR/content author | Untrusted content source | Text may contain prompt injection, malicious install commands, and misleading URLs. |
| Cloud/provider API | External dependency | Access must be mediated by existing credential handling and least privilege. |

## Attacker Goals

- Read or exfiltrate secret values, tokens, private paths, transcripts, or
  private repository names.
- Turn a browser request into arbitrary local shell execution.
- Use Cloudron-hosted mode as a pivot into a developer machine.
- Pair a rogue machine or escalate a paired machine from one task to full host
  control.
- Trigger destructive actions such as deleting worktrees, revoking accounts,
  changing DNS, deploying apps, rotating credentials, or altering routine
  schedules without confirmation.
- Forge audit records, issue comments, approvals, or merge summaries.
- Abuse automation loops to comment-storm, exhaust API budgets, or bypass
  maintainer gates.
- Replay a valid task capsule outside its intended machine, repo, branch,
  time window, or operation set.

## Trust Boundaries

### Browser to Local API

The browser is not a command boundary. The local API must reject any operation
that is not represented as a typed, allowlisted route with validated parameters.
Required controls:

- Bind read-only development APIs to loopback by default.
- Require origin, CSRF, and session checks for browser-initiated actions.
- Return structured data, not raw helper output, where possible.
- Sanitize external issue/PR/web content before display and never execute
  instructions embedded in that content.
- Gate write actions behind explicit route-level authorization, confirmation,
  and audit logging.

### Local API to Helpers

The API may call existing aidevops helpers only through command adapters that
declare operation, arguments, risk level, read/write classification, and audit
requirements. It must not expose helper names or shell fragments as user input.

Allowed patterns:

- `GET /status` style routes that map to fixed read-only helpers and return
  parsed status.
- `POST /actions/{action_id}` routes where `action_id` is an allowlisted
  operation, arguments are schema-validated, and the adapter owns the exact
  helper invocation.
- Action manifests that define required confirmation text, dry-run support,
  audit fields, and rollback guidance.

Banned patterns:

- `POST /shell`, `POST /exec`, `POST /terminal`, `POST /run-command`, or any
  equivalent arbitrary command endpoint.
- Passing browser-provided helper names, flags, environment variables, paths,
  or command strings directly to a shell.
- Streaming unrestricted terminal sessions through the GUI.
- Treating client-side hidden controls or disabled buttons as security gates.

### Secret References

Secrets are modeled as references and status only. The GUI may show metadata
such as configured/missing, source name, last validation time, scope, and the
helper that can validate the value. It must not show, copy, diff, export, log,
or sync secret values. Secret entry and rotation must use existing secure
storage flows such as `aidevops secret set NAME` or documented credential files
with restrictive permissions.

### Cloudron to Local Machine

Cloudron-hosted mode is a coordination surface, not a local command authority.
A compromised Cloudron app must not be able to execute unrestricted commands on
local agents. Required controls:

- Local agents initiate outbound connections and pin the Cloudron instance or
  pairing identity.
- Cloudron queues signed, scoped intents; local agents decide whether an intent
  is authorized for their machine.
- Local agents enforce the same allowlisted action manifests as the local API.
- High-risk local actions still require local confirmation unless an explicit,
  pre-approved automation policy covers the exact action class.
- Cloudron stores no secret values and no reusable local execution credentials.

### Paired Machines

Pairing grants scoped capabilities, not ambient trust. Compromise of one
machine must not imply compromise of every machine. Required controls:

- Pairing establishes per-machine identity and revocable capability grants.
- Delegation uses task capsules scoped by repo, issue/PR, branch/worktree,
  operation class, allowed helpers, expiry, and maximum risk level.
- Machines cannot mint capabilities for other machines unless explicitly
  delegated by the owner.
- Results return as signed/audited artifacts or git commits/PRs, not as hidden
  state mutation.
- Revocation of one machine invalidates its future capsules without rotating
  every other machine.

## Threats and Mitigations

| Threat | Mitigation |
|--------|------------|
| Localhost drive-by request from a malicious site | Loopback binding is insufficient alone; require origin checks, CSRF protection, and an authenticated local session. |
| XSS in rendered issue, PR, transcript, or web content | Render untrusted content as sanitized text/Markdown; block scriptable HTML; never let displayed content trigger helper calls. |
| Arbitrary shell execution through a generic API route | Ban generic shell endpoints; use typed allowlisted action manifests and server-owned helper invocations. |
| Secret disclosure in setup/status pages | Show only reference/status metadata; never return secret values from API responses or logs. |
| Cloudron compromise pivots to laptops | Cloudron can queue scoped intents only; local agents verify identity, capability, route, risk, expiry, and confirmation policy. |
| Paired machine compromise spreads laterally | Capability grants are per-machine, revocable, scoped, and non-transitive. |
| Destructive action without informed consent | Require confirmation, dry-run where available, risk labels, audit logs, and rollback guidance. |
| Prompt injection from external issues or web pages | Treat external text as data; scan/sanitize before acting; never pass unsanitized content into execution paths. |
| Forged or missing audit trail | Write actions produce append-only local audit entries and, where appropriate, git issues/PRs/comments with traceable task IDs. |
| API budget exhaustion or comment storm | Rate-limit action routes, reuse existing circuit breakers, and separate pending CI from failed CI before repair feedback. |

## Risk Classes

| Class | Examples | Minimum gate |
|-------|----------|--------------|
| Read-only | Status, repo inventory, routine list, secret presence, capability browser | Authenticated local session; no secret values. |
| Low-risk write | Dismiss UI notice, save UI preference | Schema validation and audit event. |
| Medium-risk write | Create local plan draft, start read-only scan, open non-destructive issue draft | Confirmation and audit event. |
| High-risk write | Change routine schedule, modify repo/worktree, deploy Cloudron app, alter provider config | Explicit confirmation, dry-run when possible, audit event, and rollback guidance. |
| Destructive/credential action | Delete data, revoke/rotate credentials, remove app, close/merge public work | Strong confirmation, operation-specific validator, audit event without credential values, and git/API evidence. |

## Phase Gates

1. **Read-only local dashboard:** may ship with loopback API, structured
   read-only routes, sanitized rendering, and secret status only.
2. **Local write actions:** require action manifests, confirmation UX,
   route-level authorization, audit logging, and tests for banned shell routes.
3. **Cloudron-hosted mode:** requires outbound local-agent protocol, scoped
   intents, no stored secret values, and proof that Cloudron cannot execute
   arbitrary local commands.
4. **Pairing:** requires per-machine identity, revocation, task-capsule scope,
   replay protection, and compromise-containment tests.
5. **Delegation at scale:** requires rate limits, API-budget controls,
   source-of-truth git traces, and cross-machine failure isolation.

## Verification Requirements

Future implementation PRs that touch these boundaries must include tests or
documented checks for:

- No route accepts arbitrary shell commands, helper names, or raw flags from the
  browser.
- Secret API responses contain only references/status metadata.
- High-risk and destructive actions require server-enforced confirmation and
  produce audit entries.
- Cloudron-hosted mode cannot execute unrestricted local commands.
- Paired-machine capsules are scoped, expiring, revocable, and non-transitive.
- VPN/NetBird/Nostr transport identity is not treated as authorization.
