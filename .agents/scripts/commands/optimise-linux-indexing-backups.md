---
description: Audit and optionally apply safe Linux indexing and backup exclusions
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh linux scan $ARGUMENTS
```

## Modes

| Invocation | Result |
|------------|--------|
| `/optimise-linux-indexing-backups` | Dry-run audit of local indexers, backup tools, and high-churn paths |
| `/optimise-linux-indexing-backups --json` | Emit machine-readable recommendations |
| `/optimise-linux-indexing-backups --apply` | Write a reusable exclude file under `~/.aidevops/configs/` |
| `/optimise-linux-indexing-backups status` | Show last successful run and reminder state |

Default mode never requires sudo and does not rewrite unknown backup jobs. Use the generated exclude file from `--apply` in restic, borg, kopia, duplicity, rsnapshot, rclone, or other backup tooling as appropriate.
