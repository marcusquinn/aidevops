<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1534: Fix worker-watchdog.sh --install crashes on Linux (launchd-only)

## Origin
Pulse session 2026-03-16. Filed as GH#5084.

## What
Add Linux (cron) support to `worker-watchdog.sh` scheduler management commands (`--install`, `--uninstall`, `--status`). Currently only macOS launchd is supported — `launchctl` calls crash on Linux.

## Why
Linux users who dispatch workers have no automated stuck-worker detection. A hung worker sits indefinitely consuming resources.

## How
1. Add OS detection (`uname -s`) to `cmd_install()` (line ~862), `cmd_uninstall()`, and status display
2. macOS path: existing launchd plist logic (unchanged)
3. Linux path: add cron entry via `crontab -l | ... | crontab -` pattern (reference `cron-helper.sh sync_crontab()`)
4. Cron entry: `*/2 * * * * /bin/bash ~/.aidevops/agents/scripts/worker-watchdog.sh --check >> ~/.aidevops/logs/worker-watchdog.log 2>&1 # aidevops: worker-watchdog`
5. Replace hardcoded `LAUNCHD_LABEL` references in status with OS-appropriate output

## Acceptance Criteria
- `--install` succeeds on Linux, adds cron entry
- `--uninstall` removes cron entry on Linux
- `--status` shows correct scheduler type on both OS
- Core `--check` functionality unchanged
- ShellCheck clean
- Bash 3.2 compatible (no associative arrays, no mapfile)

## Context
- File: `.agents/scripts/worker-watchdog.sh`
- Issue: GH#5084 (full reproduction steps and root cause analysis)
- Related: GH#5085 (same class of bug in pulse-session-helper.sh)
