---
description: Identity, authentication, sessions, service accounts, API keys, impersonation, and security event standards
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Identity and Security Lifecycle

Keep identity separate from workspace membership, roles, contacts, and accounts. Standardise human users, service actors, sessions, keys, workspace invitations, recovery, impersonation, and security audit from the start.

## Identity objects

| Object | Purpose |
|--------|---------|
| `users` | Global human identity/profile used for login and ownership |
| `auth_accounts` | Provider-specific login account: password, OAuth/OIDC, SAML, LDAP, magic link |
| `sessions` | Active session/device/browser, expiry, IP/user-agent summary, revocation state |
| `auth_tokens` | Refresh/recovery/verification tokens stored hashed with purpose and expiry |
| `passkeys` | WebAuthn/passkey credentials, device label, counter, last used |
| `mfa_factors` | MFA methods, verified state, recovery codes, last challenge |
| `password_change_requests` | Recovery/change request metadata without raw token values |

Rules:

- Users are identity records; workspace memberships/roles grant access; contacts represent people in the business domain.
- Store token hashes and secret references, never raw tokens, recovery codes, or provider secrets.
- Auth logs and action history should capture enough evidence for security review while minimising raw IP/session data.
- Sensitive auth state changes require audit events and user/admin notification where appropriate.

## Access actors

| Object | Purpose |
|--------|---------|
| `workspace_memberships` | User-to-workspace membership, state, invited/accepted timestamps |
| `workspace_invitations` | Invite target, role/team defaults, expiry, acceptance state, inviter |
| `service_accounts` | Non-human actor for integrations, automations, imports, and jobs |
| `api_keys` | Hashed key credentials attached to user/client/service account with scopes |
| `oauth_connections` | User/workspace external OAuth connection metadata and secret references |
| `impersonation_sessions` | Admin/support access session with reason, approver, target user, expiry |

Rules:

- Service accounts need owner, purpose, scopes, rotation policy, last used, and disable path.
- API keys are scoped, expiring, rotatable, prefix-identifiable, and never shown after creation.
- Impersonation requires explicit reason, least privilege, visible audit trail, and optional user notification.
- Workspace invitations are not accounts; acceptance creates or links identity, then creates membership.

## Security events and policy

| Object | Purpose |
|--------|---------|
| `security_events` | Login, logout, MFA, key creation, privilege change, suspicious access, lockout |
| `auth_log_events` | Authentication attempt/result with actor/provider/client/IP summary |
| `policy_rules` | Password/session/MFA/API-key policy by system/workspace/plan |
| `risk_assessments` | Optional risk score and reason for auth/session/API events |

Rules:

- Security events are append-only, access-controlled, retention-aware, and excluded from casual exports.
- Privilege changes link to actor, affected user/team/role, reason, approval, and before/after summary.
- Use consistent lifecycle states: pending, active, suspended, disabled, expired, revoked.
- Field-level privacy and AI exposure rules apply to identity/security data by default.

## Verification

- Trace invite acceptance through identity/account linking, workspace membership, role assignment, audit, and notification.
- Trace API-key creation, one authenticated request, rotation, revocation, and audit/security event.
- Trace session creation, MFA challenge, logout/revocation, and stale session cleanup.
- Trace support impersonation from approval/reason to scoped session, audit event, and user-visible evidence.
