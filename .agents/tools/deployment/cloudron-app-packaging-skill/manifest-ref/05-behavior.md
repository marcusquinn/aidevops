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
| `backupCommand` | string | Command run at backup to dump persistent data into `/app/data`. Requires `minBoxVersion: 9.1.0` |
| `restoreCommand` | string | Command run at restore to populate `persistentDirs` from `/app/data`. Requires `minBoxVersion: 9.1.0` |
