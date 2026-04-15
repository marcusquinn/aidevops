<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2102: Pull aidevops worktree fresh before ratchet-check in pulse simplification

## Origin

- **Created:** 2026-04-15
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** t2100 / #19035
- **Conversation context:** Fix 2 of the #19024 post-mortem. Secondary cause of the duplicate: `_complexity_scan_ratchet_check` runs against whatever state the pulse's simplification workspace has, which may not reflect a just-merged threshold change.

## What

In `.agents/scripts/pulse-simplification.sh` `_complexity_scan_ratchet_check` (around line 1673), add a `git -C "$aidevops_path" pull --ff-only origin main` step immediately before the `ratchet-check` invocation at line 1682. If the pull fails (offline, non-main HEAD, or conflict), skip the ratchet-check this cycle and log — don't crash the pulse.

Full target code and edge cases are in the GitHub issue body at **#19037**.

## Why

Without the fresh pull, the pulse can propose a ratchet-down that has already landed on main, which is what happened with #19024 (the pulse fired ~1 minute after #19017 merged). Fix 1 closes the dedup race; this fix closes the stale-read race.

## Tier

**tier:simple** — single file, ~3-5 lines, verbatim target code in the issue body, exact line references, <30m estimate.

### Tier checklist

- [x] Single file only (`pulse-simplification.sh`)
- [x] Exact line range known
- [x] Verbatim target code provided
- [x] Edge cases enumerated (offline, non-main HEAD, conflict)
- [x] ≤4 acceptance criteria
- [x] No judgment keywords

## Reference

- Parent: #19035
- Incident: #19024
- Full worker guidance: issue body of #19037

## Acceptance

- `git pull --ff-only origin main` called before ratchet-check
- Pull failure logged and causes skip-with-return-0 (never crash the pulse)
- Branch safety check: if HEAD isn't main, skip and log
- Shellcheck clean
