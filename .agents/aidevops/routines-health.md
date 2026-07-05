---
description: Diagnose aidevops routine scheduler health across launchd, systemd, TODO.md, and deployed agents
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Routines Health

Use this subagent for `/check-routines` follow-up, routine scheduler failures, stale launchd/systemd units, and migrated-host routine drift.

## Primary helper

Run deterministic checks first:

```bash
~/.aidevops/agents/scripts/routines-health-helper.sh check
~/.aidevops/agents/scripts/routines-health-helper.sh explain
~/.aidevops/agents/scripts/routines-health-helper.sh repair-safe
```

## Diagnose in this order

1. Source of truth: routines TODO enabled state, especially `r912` dashboard.
2. Deployment: `~/.aidevops/agents/VERSION` versus canonical source version.
3. Scheduler: macOS launchd labels or Linux user systemd timers/services.
4. Known stale-unit hazards: `com.aidevops.dashboard`, `sh.aidevops.dashboard`, `aidevops-dashboard`.
5. Logs: recent files under `~/.aidevops/logs/` for `EX_CONFIG`, `EX_TEMPFAIL`, Bash 3.2 syntax, missing shared modules, stale locks, and GitHub secondary rate limits.

## Repair boundaries

- Safe: restart/reload current aidevops schedulers, run canonical `./setup.sh --non-interactive`, and run `routines-health-helper.sh repair-safe`.
- Requires confirmation: disabling/removing scheduler files outside known stale unmanaged dashboard units.
- Requires `/full-loop`: code changes, new scheduler migrations, or repeated failure patterns not covered by the helper.

## Response format

Return:

- health summary
- evidence: command output, files, labels, unit names
- likely cause
- safe repair attempted or exact next command
- verification command
