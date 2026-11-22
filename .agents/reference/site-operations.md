<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Site Operations Inventory

Before requesting browser authentication for website or application work, query the
local inventory and readiness first:

```bash
site-context-helper.sh readiness example.com
site-context-helper.sh lookup example.com
```

The working inventory is `~/.config/aidevops/site-inventory.json`; copy the
placeholder-only template from `configs/site-inventory.json.txt`. It is local and
uncommitted. Store credential *values* in the secret store. Inventory may hold only
a credential variable name, account reference, and non-secret connection metadata.

### Protected SSH connection metadata

When SSH host, port, or username values belong in the secret store, use
`ssh_host_env`, `ssh_port_env`, and `ssh_user_env` on the hosting account. Each
holds an uppercase secret variable name, never a value or shell expression.
Do not configure both a literal and a reference for the same field.

`lookup` preserves these references without reading the secret backend.
`readiness` checks declared references against `aidevops secret inventory`, the
existing names-only metadata command. A missing reference, invalid metadata,
backend error, or conflicting literal/reference remains a `gap`; absent freshness
remains `stale`. No secret values are decrypted, injected, printed, or persisted.
Older literal connection records do not require a secret-inventory query.

`readiness_scope: "configuration_only"` explicitly limits a ready result: it
does not prove backend unlockability, nonempty secret values, SSH-agent identity,
connectivity, application health, login, permissions, or operation authorization.
Verify those separately through the operation's approved process; never mark
runtime checks complete from a names-only inventory result. Record what was
actually verified when updating inventory/account freshness.

## Pre-change server backups

Before changing a site, store server-side backups (settings JSON, database dumps,
and copies of `wp-config.php` or `.htaccess`) in `~/backups/`, verified to be
outside the web root. Use directory mode `700` and file mode `600`. Never put
backups under `public_html`, `wp-content/uploads`, or any other web-served path;
web-server or security-plugin blocking is not a substitute for private storage.
Treat backups already on a web-served path as findings, whether older aidevops
ones (`wp-content/uploads/aidevops-backups/`) or a plugin's leftovers (such as
an old updater's plugin backups): move them to `~/backups/` with the same modes,
or delete stale ones after the user confirms. Integrity alerts about PHP in
uploads often point to them.

## Record model and precedence

Each `sites` entry identifies a canonical hostname, aliases, platform, environment,
DNS provider/zone reference, hosting provider/account boundary, deployment path,
provenance, freshness, and optional multisite `children`. `hosting_accounts` holds
reusable connection metadata once per account. The helper matches an exact site key
or canonical hostname first, then an alias, then a child hostname or child `aliases`.
Children may have an `aliases` array, matched after their hostname. A child inherits
its parent hosting account and path unless it overrides the path. Its `dns` record
overrides the parent DNS record when present; otherwise it inherits parent DNS.

Optional `purpose` describes what the site is for in one line. Optional `ownership`
records `type`, `owner` (person or organisation), `managed_by`, `confirmed`, and
`evidence`. Allowed types are `client`, `former-client`, `business` (the operator's
own business), `personal`, `partner`, `community`, and `unknown`. Agents may infer
ownership from evidence, but must record `confirmed: false`, explain that evidence,
and never present an inference as fact. Set `confirmed: true` only after ownership
has been confirmed. A child's `purpose` and whole `ownership` object override the
parent's when present; absent values inherit from the parent, without merging
individual ownership fields.

Top-level `dns_accounts` holds reusable DNS account metadata. The effective `dns`
record's optional `account_ref` must name a key in that map or, failing that, a
`provider_accounts` ref in the credential registry
(`tools/credentials/credential-inventory.md`). Lookup resolves it into
`dns.account` with `name`, `credential_env`, `account_id_env`, and `last_verified`;
`dns_accounts` always wins. A registry-resolved account adds
`source: "credential-registry"` and its recorded `credentials`. It sets
`credential_env` only when the choice is unambiguous: either one credential is
recorded for that account, or the provider default belongs to it. `last_verified`
comes from `aidevops secret verify`.
A child's own DNS record is selected before resolving the account reference; it
does not merge fields from parent DNS. Store only secret variable names in
`credential_env` and `account_id_env`, never tokens or secret account IDs. These
fields are additive and optional; inventory version remains `1`, and inventories
without them retain their existing lookup output. Validation checks ownership
types, boolean confirmation flags, and DNS account references on sites and children.

The helper is read-only. `discover` reports configured local evidence and gaps but
does not call providers or persist anything; provider discovery must be explicitly
implemented and authorized separately. Missing or stale records are evidence gaps,
not a reason to fabricate access or request browser login before checking available
SSH/API configuration.

## Commands

```bash
site-context-helper.sh lookup HOSTNAME
site-context-helper.sh readiness HOSTNAME
site-context-helper.sh discover HOSTNAME
site-context-helper.sh validate
```

`lookup` prints privacy-safe JSON and returns non-zero for an unknown hostname.
`readiness` returns `ready`, `stale`, or `gap`. `validate` checks schema essentials
without contacting a provider. Output never contains credential values.

## WordPress compatibility

Keep WordPress connection definitions in `wordpress-sites.json` and use
`server_ref` for account-level SSH fields. The inventory is an operational lookup
layer; it does not replace `wp-helper.sh` or duplicate secrets. The inventory
identifies a hostname and mapped child while `wordpress-sites.json` remains the
source for WP-CLI connection execution.

For Cloudron, an expired local CLI token requires a capability-first check:
preserve valid scoped access, verify authorised root SSH, and inspect installed
recovery-tool help/version before requesting browser login. This does not authorise
credential extraction, password resets, authentication bypass, or destructive
server operations; see `services/hosting/cloudron.md`.
