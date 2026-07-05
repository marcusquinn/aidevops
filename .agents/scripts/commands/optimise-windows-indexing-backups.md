---
description: Audit native Windows indexing and backup exclusions without changing settings by default
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh windows scan $ARGUMENTS
```

## Modes

| Invocation | Result |
|------------|--------|
| `/optimise-windows-indexing-backups` | Dry-run audit of native Windows indexing, backup/sync tools, and high-churn path patterns |
| `/optimise-windows-indexing-backups --json` | Emit machine-readable recommendations with placeholder paths only |
| `/optimise-windows-indexing-backups --apply` | Write a reusable recommendation file under `~/.aidevops/configs/` without mutating Windows settings |
| `/optimise-windows-indexing-backups status` | Show last successful run and reminder state |

Native Windows support is limited to this experimental optimisation command. WSL2 remains the recommended Windows path and should use `/optimise-linux-indexing-backups`.
