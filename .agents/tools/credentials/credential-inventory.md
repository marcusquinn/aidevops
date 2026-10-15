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
- **Commands**: `aidevops secret describe|record|account|default|alias|resolve|validate|dependents|drift|owner` (`secret-helper.sh` delegates to `credential_inventory.py`); `aidevops secret verify cloudflare [NAME...]` is the only command that calls a provider, and only when invoked.
- **Which account holds a zone or resource?** `aidevops secret owner RESOURCE`; `unknown` means verify first, never guess.
- **Already inconsistent?** `aidevops secret organise` plans the cleanup; `--apply-drafts` writes only unconfirmed drafts (see "Organise").
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

## Verify, drift and owner

`aidevops secret verify cloudflare [NAME...]` checks recorded Cloudflare credentials, or every one when no names are given. Unrecorded names are refused. Each token is injected through the normal `NAME -- CMD` path (environment only, output redacted), then `credential_inventory_cloudflare.py` makes **GET-only** calls:

- token verification (user tokens, with a fallback for account tokens);
- accounts and paginated zones;
- best-effort Workers scripts, Pages projects and R2 buckets.

A 403 response is cached as `unreadable`, not as absent. The result is cached in `credentials.<NAME>.verification`: `verified_at`, token status and expiry, account names, zones with their status, and resources. Accounts appear only as `sha256:` fingerprints (16 hex digits), never raw IDs; the registry schema rejects anything else.

`aidevops secret drift [--json]` runs offline from the registry and that cache. It reports these checks:

| Check | Meaning |
|-------|---------|
| `expiry-unknown` / `never-expires` | Expiry is not recorded or reported, or it is `never` |
| `expiring-soon` / `expired` | The recorded or provider-reported expiry is within 30 days or has passed |
| `identical-reach` / `overlapping-reach` | Same-provider credentials share zones (observed zones if verified, else recorded zones) |
| `zone-in-multiple-accounts` / `zone-not-active` | A zone is seen under two accounts, or a status such as `moved` |
| `account-mismatch` | The recorded account name is not among the accounts the token sees |
| `unverified` / `stale-verification` | A verifiable credential was never verified, or was verified more than 30 days ago |
| `undescribed` / `default-undeclared` | A stored secret has no record, or a provider has no `defaults` key |

## Organise

`aidevops secret organise [--json] [--apply-drafts] [--no-dependents]` is the guided path for an install whose credentials are already inconsistent. It combines the names-only stored listing, the registry and the verification cache, and proposes:

| Proposal | From |
|----------|------|
| Draft record per undescribed secret | Known name prefix (`CLOUDFLARE_`, `CF_`, `GITHUB_`, `HCLOUD_`, …) gives provider and kind; an account tag matching an existing `<provider>-<tag>` ref links that account; otherwise it is only a hint. Unrecognised names are listed for manual recording. |
| Account ref | A recorded credential with no account whose verified token sees exactly one account name |
| Alias, never rename | Identical reach: keep the account-tagged, more-referenced name; the steps are dependents → move consumers → delete the old entry → `alias`. Overlapping reach: review only. |
| Default decision | Each provider without a `defaults` key: the candidate `default` commands plus `--none` |
| Dependents count | One local scan for all names (`dependents NAME` remains the per-credential check before any change) |

Nothing is renamed, deleted, aliased or made default automatically, because those change what gets injected. `--apply-drafts` writes only draft metadata: records for undescribed secrets, account refs from verified names, and new accounts with `ownership.confirmed: false`. Each written record carries `draft: {confirmed: false, evidence}` and shows as `[draft, unconfirmed]` in `describe`. Secret names and values are never touched. Confirm a draft by running `aidevops secret record NAME --provider P --account REF`, which clears the draft flag.

## Owner lookup

`aidevops secret owner RESOURCE [--json]` matches a zone, subdomain, resource name, or `type:name`. Observed cache entries come first; recorded `reach` zones are used only for unverified credentials. The result is `found`, `ambiguous` (several accounts), or `unknown` (exit 1). Re-run `verify` rather than guessing.
