<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1535: Fix aidevops pulse start silently succeeds on Linux without scheduler installed

## Origin
Pulse session 2026-03-16. Filed as GH#5085.

## What
Add scheduler verification to `pulse-session-helper.sh` so `aidevops pulse start` warns when no scheduler (launchd/cron) is configured, and replace hardcoded "launchd" strings with OS-appropriate terminology.

## Why
On Linux, `pulse start` reports success but the pulse never fires — no cron entry exists. User has no indication anything is wrong. Output says "launchd" on a system that doesn't have launchd.

## How
1. Add `check_scheduler()` function that detects OS and checks for the appropriate scheduler entry
2. In `cmd_start()` (line ~170-212): call `check_scheduler()`, warn if missing, provide install command
3. In `cmd_status()` (line ~445): replace "launchd cycle" with OS-appropriate term
4. Replace hardcoded "launchd" at lines 207, 209, 445 with a variable set from `uname -s`
5. Reference `onboarding-helper.sh` which already correctly checks both launchd and crontab

## Acceptance Criteria
- `pulse start` on Linux without cron entry shows warning with install instructions
- `pulse start` on macOS without launchd plist shows warning
- `pulse status` shows OS-appropriate scheduler name
- All output strings use correct OS terminology
- ShellCheck clean
- Bash 3.2 compatible

## Context
- File: `.agents/scripts/pulse-session-helper.sh`
- Issue: GH#5085 (full reproduction steps and root cause analysis)
- Related: GH#5084 (same class of bug in worker-watchdog.sh)
- Related: GH#2927/PR#2935 (session-based pulse control design)
