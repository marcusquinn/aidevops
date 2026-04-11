---
description: Run memory audit pulse — dedup, prune, graduate, scan for improvements
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Arguments: $ARGUMENTS

## Usage

```bash
# Default — run all phases
memory-audit-pulse.sh run --force
# Dry run — preview changes without applying
memory-audit-pulse.sh run --force --dry-run
# Status — show last run results
memory-audit-pulse.sh status
```

## Phases

1. **Dedup** — removes exact and near-duplicate memories
2. **Prune** — removes stale entries (>90 days, never accessed)
3. **Graduate** — promotes high-value memories to shared docs
4. **Scan** — identifies self-improvement opportunities
5. **Report** — summary with JSONL history

Runs automatically as Phase 9 of the supervisor pulse cycle (self-throttles to once per 24h).

## Related

`/remember` · `/recall` · `/memory-log` · `/graduate-memories` · `memory-helper.sh {validate|dedup|stats}`
