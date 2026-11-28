---
description: Audit and safely optimise macOS indexing and backup exclusions
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh macos scan $ARGUMENTS
```

## Safety contract

- Dry-run is the default.
- Do not exclude the whole home directory, project source trees, `Documents`, `Desktop`, `Downloads`, `.ssh`, `.gnupg`, or broad app support directories.
- Redact or avoid backup identity, login, token, and account fields in all output.
- Config-file mutation requires `--apply`, a backup copy, and XML/config validation.

## macOS coverage

- Spotlight: check `mdutil` status and create `.metadata_never_index` only in writable generated/cache directories.
- Time Machine: recommend `tmutil addexclusion`; verify with `tmutil isexcluded` when permissions allow.
- Backblaze: detect editable XML locations, recommend generic `bzexcluderules_editable.xml` rules, and avoid printing sensitive fields.
- Backblaze health (read-only): `optimise-indexing-backups-helper.sh macos health` reports `ok`, `stale:<hours>` (no upload for 48 h, override `AIDEVOPS_BACKBLAZE_STALE_HOURS`), `safety_frozen:<hint>`, `unknown` or `not-installed`; a non-ok result surfaces via `reminder` as a one-line user action (resolving a freeze needs the user's private encryption key, never AI).
- fseventsd health (read-only, macOS only): `macos health` also prints `fseventsd_health=ok`, `runaway:<rss_gib>` or `unknown` using `pgrep` and `ps` RSS/%CPU telemetry; `health --json` includes the `fseventsd_health` field. RSS above 2 GiB is runaway (override with a positive `AIDEVOPS_FSEVENTSD_RSS_GB`). Unavailable telemetry or an invalid threshold is `unknown`, not healthy. The existing `reminder` path surfaces a warning with observed RSS and `sysctl vm.swapusage` swap use, asking the user to run `sudo killall fseventsd` in a terminal or reboot; the helper never executes sudo. Reminder consumers also record runaway capacity loss through `throttle-report-helper.sh report` at most once per day after a successful report, without changing dispatch limits. Desktop notifications use the existing notification interval and respect `--no-notify` and headless mode; health itself never reports or notifies.
- High-churn paths: user caches, package caches, simulator caches, aidevops runtime cache/log/lock directories, and generated project directories such as `<repo-root>/**/node_modules/`, `<repo-root>/**/.turbo/`, `<repo-root>/**/dist/`, and `<repo-root>/**/coverage/`.

## Verification

Run:

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh macos scan --dry-run --json
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh macos status
```
