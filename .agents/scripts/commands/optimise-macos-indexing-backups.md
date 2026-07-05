---
description: Audit and optionally apply safe macOS indexing and backup exclusions
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh macos scan $ARGUMENTS
```

## Modes

| Invocation | Result |
|------------|--------|
| `/optimise-macos-indexing-backups` | Dry-run audit of Spotlight, Time Machine, Backblaze, and high-churn paths |
| `/optimise-macos-indexing-backups --json` | Emit machine-readable recommendations |
| `/optimise-macos-indexing-backups --apply` | Apply only safe writable exclusions after explicit flag |
| `/optimise-macos-indexing-backups status` | Show last successful run and reminder state |

Default mode never requires sudo and never edits backup configs. Use `--apply` only after reviewing the dry-run output.
