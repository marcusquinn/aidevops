<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Manifest Reference — Behavior

## Behavior

| Field | Type | Description |
|-------|------|-------------|
| `memoryLimit` | integer (bytes) | Max RAM + swap (default 256 MB / `268435456`) |
| `multiDomain` | boolean | Allow alias domains. Sets `CLOUDRON_ALIAS_DOMAINS` |
| `optionalSso` | boolean | Allow install without user management. Auth addon env vars absent when SSO is off |
| `configurePath` | URL path | Admin panel path shown in dashboard (e.g. `/wp-admin/`) |
| `logPaths` | string array | Log file paths when stdout is unavailable |
| `capabilities` | string array | Extra Linux capabilities: `net_admin`, `mlock`, `ping`, `vaapi` |
| `runtimeDirs` | string array | Writable subdirs of `/app/code` — not backed up, not persisted across updates |
| `persistentDirs` | string array | Writable dirs persisted across updates but excluded from filesystem backup. Use with `backupCommand`. Requires `minBoxVersion: 9.1.0` |
| `backupCommand` | string | Runs while the app is running to dump persistent data into `/app/data`. Requires `minBoxVersion: 9.1.0`. Cloudron 9.1.7 and 9.2.0 run it in a separate network namespace, so reaching the app via `localhost` can fail; use `minBoxVersion: 10.0.0` or later if the command needs `localhost` |
| `restoreCommand` | string | Runs before the app container starts to populate `persistentDirs` from `/app/data`; the app is not running and `localhost` cannot reach it. Requires `minBoxVersion: 9.1.0` |

### Adding an auth addon in an update

When an update adds an auth addon (`oidc`, `ldap`, `proxyAuth`), decide on `optionalSso` and document what happens to existing installations (observed on Cloudron 10.1.6):

- The app's `sso` flag (`GET /api/v1/apps`) is fixed at install time and cannot change later. An app installed from a version without an auth addon has `sso: false`.
- An app with the addon and `sso: false` gets no `CLOUDRON_OIDC_*` (or other auth addon) variables, so an update does **not** enable SSO for existing installations. State this in the release notes and make the app work without the variables.
- Without `"optionalSso": true`, `cloudron install --no-sso` is ignored: the app still gets `sso: true` and the variables. With it, `--no-sso` gives `sso: false` and no variables. Use this to test the "updated install" state when `cloudron update` is unavailable.
- `CLOUDRON_OIDC_PROVIDER_NAME` is the Cloudron's branding name, not "Cloudron". Apps that limit display-name length (for example Orbit: 50 characters, and it refuses to start) need a fallback for long names.
