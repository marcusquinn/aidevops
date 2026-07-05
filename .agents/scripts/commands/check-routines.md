---
description: Check and safely repair aidevops routine scheduler health
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Check aidevops routine scheduler health across macOS launchd and Linux systemd.

Arguments: $ARGUMENTS

## Use the routines-health subagent

Delegate interpretation to `@routines-health` when the report shows stale units, failed scheduler state, version drift, or migration symptoms.

## Default command

```bash
~/.aidevops/agents/scripts/routines-health-helper.sh check $ARGUMENTS
```

## Common invocations

```bash
# Read-only status
~/.aidevops/agents/scripts/routines-health-helper.sh check

# Machine-readable summary
~/.aidevops/agents/scripts/routines-health-helper.sh check --json

# Explain likely causes and repair commands
~/.aidevops/agents/scripts/routines-health-helper.sh explain

# Safe self-healing only: stale unmanaged dashboard launchd/systemd cleanup
~/.aidevops/agents/scripts/routines-health-helper.sh repair-safe

# Focus dashboard routine migration checks
~/.aidevops/agents/scripts/routines-health-helper.sh check --routine r912
```

## Report expectations

- Platform scheduler state: launchd pulse on macOS, user systemd pulse on Linux.
- Routines source of truth: routines TODO enabled/disabled entries.
- Deployment drift: deployed agents version versus source checkout version.
- Known stale scheduler hazards: dashboard `r912` disabled/unmanaged while legacy scheduler files still exist.

## Repair policy

- `check` and `explain` are read-only.
- `repair-safe` may stop/disable and move/remove stale unmanaged dashboard scheduler files only when `r912` is disabled or unmanaged.
- Broader destructive repairs require explicit operator review and should be implemented through `/full-loop`.
