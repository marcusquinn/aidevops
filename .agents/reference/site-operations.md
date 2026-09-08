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

## Record model and precedence

Each `sites` entry identifies a canonical hostname, aliases, platform, environment,
DNS provider/zone reference, hosting provider/account boundary, deployment path,
provenance, freshness, and optional multisite `children`. `hosting_accounts` holds
reusable connection metadata once per account. The helper matches an exact site key
or canonical hostname first, then an alias, then a child hostname. A child inherits
its parent hosting account and path unless it overrides the path.

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
