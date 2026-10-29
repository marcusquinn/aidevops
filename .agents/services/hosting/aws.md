---
description: AWS operations - SSO profiles, least-privilege unattended keys, secret injection and SES
mode: subagent
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# AWS Operations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Preferred access**: AWS CLI v2 + IAM Identity Center, named profile `aidevops-<account>`; no long-lived key.
- **Unattended access**: workload roles/short-lived credentials first; least-privilege IAM user keys only when necessary, never root keys.
- **Secrets**: `AWS_<ACCOUNT>_ACCESS_KEY_ID`, `AWS_<ACCOUNT>_SECRET_ACCESS_KEY`, optionally `AWS_<ACCOUNT>_SESSION_TOKEN`, stored through `aidevops secret set`. Never request values in chat.
- **Verify**: `aidevops secret verify aws [AWS_<ACCOUNT>_ACCESS_KEY_ID...]` prints only account ID and caller ARN; no identity response is cached.
- **Email**: `services/email/ses.md`, `scripts/ses-helper.sh`; identities, quotas and suppression settings are regional.

<!-- AI-CONTEXT-END -->

## Access options (in order of preference)

### 1. IAM Identity Center with a named profile

An administrator assigns the user to the intended AWS account and a permission
set scoped to the task. Obtain the access portal/start URL and SSO region from
the administrator; do not guess them. These are metadata, not keys.

```bash
aws --version                         # AWS CLI v2; do not install silently
aws configure sso --profile aidevops-production
aws sso login --profile aidevops-production
aws --profile aidevops-production --region us-east-1 sts get-caller-identity
```

Complete browser authorization as the user. Select the intended account and role;
use per-command `--profile` without changing a shared default. Profile files hold
SSO metadata; let the CLI protect its short-lived credential cache. Do not export
the cache into chat or config. `aws sso logout` clears cached SSO sessions across
profiles. Use the workload's existing region; `us-east-1` is only an example
default, not an instruction to move resources. Confirm account and region before
writes; credential access does not authorize new spending or IAM changes.

### 2. Unattended credentials

Prefer workload roles or OIDC federation. If a long-lived IAM user is necessary,
name/tag it `aidevops-<account>-<purpose>`, separate production/staging, and grant
only the required actions and resources. Never borrow a website's application
key for account management. SES SMTP passwords are not AWS API secret keys.

Console handoff for the account administrator/user:

1. Sign in to the intended account, not as root. In **IAM → Users**, create/select
   the dedicated user and attach a scoped policy (`ses.md` has examples). Do not
   grant AdministratorAccess or enable console access just to create a key.
2. **Security credentials → Access keys → Create access key**: choose the actual
   workload use case and description/tag `aidevops-<account>-<purpose>`.
3. Store both values immediately at the hidden terminal prompts below; the secret
   is shown only once. Never paste values in chat, plaintext config, command
   arguments or source control. Remove any downloaded CSV after secure storage.
4. Record owner, purpose and rotation deadline in the credential inventory.

```bash
aidevops secret account add aws-production --provider aws --name "Production"
aidevops secret set AWS_PRODUCTION_ACCESS_KEY_ID --provider aws --account aws-production --purpose "SES operations"
aidevops secret set AWS_PRODUCTION_SECRET_ACCESS_KEY --provider aws --account aws-production --purpose "SES operations"
aidevops secret verify aws AWS_PRODUCTION_ACCESS_KEY_ID
aidevops secret verify aws             # all recorded access-key pairs
```

For externally obtained temporary credentials, also store/record the matching
`AWS_PRODUCTION_SESSION_TOKEN` with its expiry. Verification requires a recorded,
same-account pair, injects the optional recorded token, and calls only
`aws sts get-caller-identity` (no additional IAM permission is needed for that
action). Identity verification does not prove service permissions.

## Credential injection

Account-tagged names are not automatically recognized by the AWS CLI. Existing
explicit aliases support both variables; never store bare AWS variable names:

```bash
aidevops secret alias AWS_PRODUCTION_ACCESS_KEY_ID AWS_ACCESS_KEY_ID
aidevops secret alias AWS_PRODUCTION_SECRET_ACCESS_KEY AWS_SECRET_ACCESS_KEY
aidevops secret AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY -- aws --region us-east-1 sts get-caller-identity
```

Aliases are global metadata, not per-command account selection. Stored bare names
win over aliases: inspect `aidevops secret dependents NAME` before retiring legacy
entries. Do not switch aliases during parallel work. The generic `default` record
holds one secret, not an AWS tuple; use explicit paired aliases instead. With
temporary credentials, declare and inject the matching session-token alias too;
never mix it with another pair. Avoid inherited `AWS_SESSION_TOKEN` with long-lived
keys.

Multi-account SES needs no aliases: `credential_prefix` in SES metadata selects
the account-tagged pair and maps it inside each AWS child process, clearing
inherited profiles/session credentials. Or use a metadata `profile` / explicit
`ses-helper.sh --profile aidevops-production quota production`.

## Rotation and compromise

- Run `aidevops secret dependents` for both key names before rotation; inspect
  remote consumers too. Create the second IAM key, update both stored values,
  verify identity and actual service operations, then deactivate the old key.
  Delete it only after successful consumer observation. IAM allows two keys per
  user; keep the overlap short and follow the recorded rotation deadline.
- On compromise, immediately deactivate the affected key or revoke role/SSO
  sessions; notify the account security owner, inspect CloudTrail and billing,
  and rotate all affected credentials. Remove unauthorized resources/permissions
  through approved incident procedures. Deleting a local secret does not revoke
  AWS access. Do not print the compromised value in the incident report.
