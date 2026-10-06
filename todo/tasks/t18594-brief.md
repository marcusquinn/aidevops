## Origin

Interactive session: stale premium plugins on two WordPress sites sharing one shared-hosting account were refreshed by ad-hoc scripts (version inventory across all installs on the account, then per-plugin folder swaps with health check and revert). 66 plugin folders were updated without regressions. The procedure is documented in `.agents/tools/wordpress/premium-plugin-updates.md` ("Refreshing Stale Plugins From Sibling Sites", added by t18593 / GH#33734); this task turns it into a reusable helper.

## What

Add `.agents/scripts/wp-plugin-parity-helper.sh` with two subcommands that run **on the hosting account** (uploaded via `scp` or streamed with `ssh <alias> bash -s -- ...`):

- `inventory --target <domain> [--domains-root <dir>]`: list every WordPress install under the domains root (default `$HOME/domains/*/public_html`), collect `name,version,status` per plugin with `wp --skip-plugins --skip-themes plugin list`, and print TSV rows `slug  target_version  newest_version  source_domain  target_status` only where a sibling has a strictly newer version (`sort -V`). Exclude must-use and drop-in entries.
- `sync --target <domain> --stash <dir> [--check-path <path>] [--dry-run] <slug:source-domain>...`: for each pair, copy the source folder to `<slug>.new`, move the old folder into the stash, rename into place, and for **active** plugins request `https://<target><check-path>` (default `/`) expecting HTTP 200 with no "fatal error" or "critical error on this website" text; on failure restore the stashed folder and report `REVERTED`. Print `OK|SKIP|FAIL|REVERTED slug old -> new (status)` per plugin. Abort before any change if the target fails the health check.

## Why

GPLVault Updater requests updates only for active plugins, and vendor update channels break per domain; licensed newer copies often already exist on sibling sites. Rewriting the inventory and swap logic each time is slow and error-prone (process substitution unavailable on some hosts, homepages that redirect, empty status fields).

## Tier

`tier:standard` — one new self-contained shell helper plus a doc pointer; no shared contracts.

## How (Approach)

### Files to Modify

- NEW: `.agents/scripts/wp-plugin-parity-helper.sh` — model the structure (sourcing `shared-constants.sh`, `help` subcommand, `local var="$1"`, explicit `return 0/1`) on `.agents/scripts/wp-plugin-release-helper.sh`.
- EDIT: `.agents/tools/wordpress/premium-plugin-updates.md` — in "Refreshing Stale Plugins From Sibling Sites", point steps 1, 4 and 5 at the helper with a usage example using placeholders only.

### Implementation Steps

1. `inventory`: write all rows to a `mktemp -d` file, then filter with `awk`; do not use process substitution (`<(...)`), which fails on hosts without `/dev/fd`.
2. Compatibility hint: for slugs ending in `-pro`, `pro`, or known add-on pairs (`fluentformpro`→`fluentform`, `fluentcampaign-pro`→`fluent-crm`, `fluent-support-pro`→`fluent-support`, `seo-by-rank-math-pro`→`seo-by-rank-math`, `wp-social-ninja-pro`→`wp-social-reviews`), print a warning column when the target's base plugin version differs from the source site's base version.
3. `sync`: guard every `rm -rf` with `${var:?}`; never delete the stash; `--dry-run` prints the plan without copying.
4. Never read or print `wp-config.php` secrets; the helper does not take database backups (document running the backup first, see `services/hosting/hostinger.md` "Database backups without WP-CLI").

### Hazards and Compatibility

- Bash 3.2 compatibility and ShellCheck zero violations (`reference/bash-compat.md`).
- Swapping an active plugin briefly exposes a partial state; keep copy-then-rename ordering so the live folder is replaced by two `mv` calls.
- Do not run upgrade routines or activate plugins.

### Scope Boundaries

- No changes to `wp-fleet-helper.sh` / `wp-fleet-runner.py` (release-asset trust model is intentionally separate).
- No new test runner or CI gate.

### Files Scope

- .agents/scripts/wp-plugin-parity-helper.sh
- .agents/tools/wordpress/premium-plugin-updates.md

## Acceptance Criteria

- `shellcheck .agents/scripts/wp-plugin-parity-helper.sh` reports zero violations.
- `wp-plugin-parity-helper.sh help` documents both subcommands and options.
- With a temporary stub `wp` on `PATH` (not committed) and two fake docroots, `inventory` lists only strictly newer versions and `sync --dry-run` makes no filesystem changes.
- Doc pointer added; `markdownlint-cli2` clean on the changed doc.

## Verification

```bash
shellcheck .agents/scripts/wp-plugin-parity-helper.sh
bash .agents/scripts/wp-plugin-parity-helper.sh help
npx --no-install markdownlint-cli2 .agents/tools/wordpress/premium-plugin-updates.md
```

Real-host verification is operator-run and out of worker scope.
