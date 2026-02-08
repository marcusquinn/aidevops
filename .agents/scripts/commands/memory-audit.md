---
description: Run memory audit pulse — dedup, prune, graduate, scan for improvements
agent: Build+
mode: subagent
---

Run the memory audit pulse to clean up and improve the memory database.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Run Audit Pulse

```bash
~/.aidevops/agents/scripts/memory-audit-pulse.sh run --force
```

### Step 2: Apply Options (if requested)

| Argument | Command |
|----------|---------|
| (none) | `memory-audit-pulse.sh run --force` |
| `--dry-run` | `memory-audit-pulse.sh run --force --dry-run` |
| `status` | `memory-audit-pulse.sh status` |

### Step 3: Present Results

The audit runs 5 phases:

1. **Dedup** — removes exact and near-duplicate memories
2. **Prune** — removes stale entries (>90 days, never accessed)
3. **Graduate** — promotes high-value memories to shared docs
4. **Scan** — identifies self-improvement opportunities
5. **Report** — summary with JSONL history

## Integration

The audit pulse runs automatically as Phase 9 of the supervisor pulse cycle.
It self-throttles to run at most once every 24 hours.

## Related Commands

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store a memory |
| `/recall {query}` | Search memories |
| `/memory-log` | Show auto-captured memories |
| `/graduate-memories` | Promote high-value memories to shared docs |
| `memory-helper.sh validate` | Check memory health |
| `memory-helper.sh dedup` | Remove duplicates |
| `memory-helper.sh stats` | Show statistics |
