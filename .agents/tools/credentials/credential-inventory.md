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
- **Commands**: `aidevops secret describe|record|account|default|alias|resolve|validate|dependents` (`secret-helper.sh` delegates to `credential_inventory.py`).
- **Before renaming, rotating or revoking**: run `aidevops secret dependents NAME`; never treat a name as unused unless it reports `complete: true`.
- **Never stored**: secret values, raw provider account IDs. Store the *name* of the secret that holds an account ID (`account_id_env`). Free-text fields that look like secrets are refused.
- **Rule for sessions**: whenever you store a credential, record its account, **even for the operator's first and only account at that provider**: `aidevops secret set NAME --provider P --account REF --purpose "..."`.
- **Naming new secrets**: `<PROVIDER>_<ACCOUNT>_<KIND>` (see "Naming new credentials"). Never store the bare conventional variable (`CLOUDFLARE_API_TOKEN`, `GITHUB_TOKEN`) as an implicit default.

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

## Naming new credentials

This is the single convention for new secret names; other credential docs point here.

```text
<PROVIDER>_<ACCOUNT>[_<PURPOSE>]_<KIND>
```

| Part | Rule | Examples |
|------|------|----------|
| `PROVIDER` | The provider's conventional prefix | `CLOUDFLARE`, `GITHUB`, `HCLOUD`, `OPENAI`, `AWS` |
| `ACCOUNT` | Short account tag; matches the `account add` ref (`cloudflare-acme` → `ACME`). Use one **even for the first and only account** | `ACME`, `PERSONAL`, `WORK`, `PROJECT_A` |
| `PURPOSE` | Optional, when one account has several tokens. Add a developer/device discriminator (`DEV_B`, `LAPTOP_2`) here when a shared store holds several | `DNS`, `PRODUCTS_SYNC`, `PRODUCTS_SYNC_DEV_B` |
| `KIND` | Last, so the variable reads naturally | `API_TOKEN`, `TOKEN`, `API_KEY`, `ACCOUNT_ID`, `ACCESS_TOKEN` / `TOKEN_NAME` (sensitive value / non-sensitive provider label pair) |

Use SCREAMING_SNAKE_CASE; tags must not reveal private repositories, private customers or local paths. Examples: `CLOUDFLARE_ACME_API_TOKEN`, `CLOUDFLARE_ACME_ACCOUNT_ID`, `GITHUB_WORK_TOKEN`, `HCLOUD_PROJECT_A_TOKEN`, `PROVIDER_ORG_PRODUCTS_SYNC_ACCESS_TOKEN` with `..._TOKEN_NAME`.

- **Record identity at creation**: `aidevops secret set NAME --provider P --account REF --purpose "..."`. The name helps humans; the registry is the source of truth.
- **The bare conventional variable is never stored directly.** `CLOUDFLARE_API_TOKEN`, `GITHUB_TOKEN` etc. resolve at injection only through an explicit `aidevops secret default PROVIDER NAME` (see "Resolution at injection").
- **Provider dashboard token label**: `aidevops-<account>-<purpose>` (e.g. `aidevops-acme-dns`); record the same purpose with `--purpose`.
- **Existing names stay valid.** Do not rename working secrets to match; describe them with `record`, and if a new name is wanted use `alias NEW OLD` plus `dependents` before retiring the old one.
- Names a specific tool requires verbatim (for example `OPENAI_IMAGE_API_KEY_<ALIAS>` in `api-key-setup.md`) follow that tool's documentation.

## Aliases instead of renames

`aidevops secret alias NAME OLD_NAME` records that `OLD_NAME` is a retired name for `NAME`, so you can describe the current name without breaking anything that still uses the old one.

## Resolution at injection

When a requested name is **not itself stored**, `aidevops secret NAME -- CMD`, `run`, `get` and `check` resolve it through the registry and inject the source value under the requested name (output stays redacted):

| Requested | Resolves to |
|-----------|-------------|
| A declared alias (`OLD_NAME`) | the credential that declares it |
| A provider's conventional variable (`CLOUDFLARE_API_TOKEN`, `GITHUB_TOKEN`, `HCLOUD_TOKEN`, `VERCEL_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`) | `defaults.<provider>` — **only when explicitly set** |

A stored name always wins. With no default, or `--none`, the conventional variable stays unavailable exactly as before. `run` (inject all) also adds aliases and conventional defaults for injected credentials. Without a registry file nothing changes. Inspect the mapping with `python3 ~/.aidevops/agents/scripts/credential_inventory.py injection-map`.

To retire a name safely: store the new name, `alias NEW OLD`, move consumers to `NEW`, then delete the old stored entry; until it is deleted, the stored `OLD` value still wins.

## Dependents

`aidevops secret dependents NAME [--json]` is a local, read-only search for the name and its declared aliases. It makes no network calls and outputs locations only, never line text, so values in scanned files cannot leak.

| Source | How |
|--------|-----|
| Repos in `~/.config/aidevops/repos.json` and all their linked worktrees | `git grep -F --untracked` (honours `.gitignore`), bounded per worktree |
| `~/.aidevops/agents/custom/` | bounded file walk |
| `~/.config/aidevops/*.json\|conf\|toml\|yaml` (e.g. `site-inventory.json` `credential_env`) | file scan; the registry itself is excluded |
| `~/Library/LaunchAgents/*.plist`, `~/.config/systemd/user/*`, `crontab -l` | file/command scan (binary plists decoded) |

Lines that build the name dynamically (e.g. `"CLOUDFLARE_${ACCOUNT}_API_TOKEN"`, concatenation, f-strings, `%s`) are reported as `possible-dynamic`. They, timeouts, truncation and unreadable files all set `complete: false`. Only a complete result with no matches prints "No references found"; remote-only consumers (CI secrets, deployed servers) are outside this search.
