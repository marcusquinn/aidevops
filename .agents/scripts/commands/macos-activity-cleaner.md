---
description: Audit macOS activity and plan capability-preserving cleanup
agent: macos-activity-cleaner
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Execute this request with `tools/automation/macos-activity-cleaner.md`.

Request: $ARGUMENTS

## Modes

| Request | Behaviour |
|---------|-----------|
| Empty or `audit` | Bounded, read-only audit with ranked recommendations |
| `audit --quick` | Pressure, processes, persistence, and listeners only |
| `audit --deep` | Add applications, architecture, extensions, and legacy inventory |
| `plan` | Compose itemized actions and verification without changing the host |
| `verify` | Repeat the read-only audit and compare selected findings |
| `routine` | Non-interactive read-only audit; never prompt, elevate, plan, or mutate |

## Required behaviour

- Confirm the host is macOS before collecting evidence.
- Default to read-only, unprivileged inspection and state clearly that no changes
  were made.
- Do not collect full process arguments, environments, shell history, serial
  numbers, usernames, or unredacted home paths.
- Treat classifications as evidence, never as permission to quit, disable, move,
  uninstall, firewall, or restart anything.
- This initial release is audit/plan-only. Never execute remediation, even after
  approval; provide a reviewed transaction plan for a human or future
  deterministic helper.
- A remediation plan must bind exact argv, canonical identities, capability
  impact, administrator requirements, verification, rollback state, and a digest
  before asking for approval.
- Use durable aidevops quarantine, never Trash as the sole rollback store.
- Do not interrupt active developer services or wildcard listeners merely because
  they are old, large, long-running, or externally bound.

For TCC or host-app access gaps, use `/local-permissions-check`. For Spotlight,
Time Machine, or backup exclusions, use `/optimise-macos-indexing-backups`.
