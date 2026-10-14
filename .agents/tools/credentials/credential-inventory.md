---
description: Non-secret credential registry - which account each stored secret opens, its reach, owner, expiry and provider defaults
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Credential Inventory

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: answer, without live API calls, which account a credential opens, what it reaches, who it is for, when it expires, and which credential is each provider's default.
- **File**: `~/.config/aidevops/credential-inventory.json` (600; override with `AIDEVOPS_CREDENTIAL_INVENTORY`). Template: `configs/credential-inventory.json.txt`.
- **Commands**: `aidevops secret describe|record|account|default|alias|resolve` (`secret-helper.sh` delegates to `credential_inventory.py`).
- **Never stored**: secret values, raw provider account IDs. Store the *name* of the secret that holds an account ID (`account_id_env`). Free-text fields that look like secrets are refused.
- **Rule for sessions**: whenever you store a credential, record its account, **even for the operator's first and only account at that provider**: `aidevops secret set NAME --provider P --account REF --purpose "..."`.

<!-- AI-CONTEXT-END -->

## Model

| Section | Holds |
|---------|-------|
| `provider_accounts.<ref>` | `provider`, human `name`, optional `account_id_env`, `ownership` (`type`, `owner`, `confirmed`, `evidence`) |
| `credentials.<SECRET_NAME>` | `provider`, `account_ref`, `kind`, `purpose`, `reach` (`zones`, `resources` as `type:name`), `expires_at` (`YYYY-MM-DD`, `never`, or `null` = unknown), `aliases`, timestamps |
| `defaults.<provider>` | a recorded secret name, or explicit `null` = "deliberately no default". A missing key means **undeclared**. |

Ownership types match the site inventory (`reference/site-operations.md`): `client`, `former-client`, `business`, `personal`, `partner`, `community`, `unknown`. Agents may infer ownership from evidence but must record `confirmed: false` with the evidence, and never present an inference as fact.

## Workflow

```bash
# 1. Name the account once (human name; never paste the account ID)
aidevops secret account add cloudflare-acme --provider cloudflare --name "Acme Ltd" \
  --ownership-type client --owner "Acme Ltd" --confirmed

# 2. Store the token with its identity (value entered at the hidden prompt)
aidevops secret set CLOUDFLARE_ACME_API_TOKEN --provider cloudflare --account cloudflare-acme \
  --purpose "DNS for acme.com" --zones acme.com --expires 2027-10-01

# Already stored? Describe it without touching the value
aidevops secret record CLOUDFLARE_ACME_API_TOKEN --provider cloudflare --account cloudflare-acme

# 3. Make the default explicit, or explicitly absent
aidevops secret default cloudflare CLOUDFLARE_ACME_API_TOKEN
aidevops secret default cloudflare --none

# 4. Ask
aidevops secret describe                 # grouped by provider, plus undescribed stored secrets
aidevops secret describe NAME --json
aidevops secret resolve cloudflare       # prints default; exit 3 = explicitly none, 4 = undeclared
```

Consumers must use `resolve`: never infer a default from an unlabelled variable, and never create one implicitly.

## Aliases instead of renames

`aidevops secret alias NAME OLD_NAME` records that `OLD_NAME` is a retired name for `NAME`, so you can describe the current name without breaking anything that still uses the old one.
