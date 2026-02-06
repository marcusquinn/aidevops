---
description: Show recent auto-captured memories with filtering
agent: Build+
mode: subagent
---

Show the auto-capture memory log - memories stored automatically by AI agents during sessions.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Show Auto-Capture Log

Run the log command:

```bash
~/.aidevops/agents/scripts/memory-helper.sh log
```

### Step 2: Apply Filters (if requested)

| Argument | Command |
|----------|---------|
| (none) | `memory-helper.sh log` (last 20 auto-captures) |
| `--limit N` | `memory-helper.sh log --limit N` |
| `--json` | `memory-helper.sh log --json` |

### Step 3: Present Results

If results found:

```text
Auto-Capture Log (last 20):

1. [WORKING_SOLUTION] Fixed CORS by adding nginx headers
   Tags: cors,nginx | 2 hours ago

2. [FAILED_APPROACH] setTimeout doesn't work for async coordination
   Tags: javascript,async | 1 day ago

---
Total auto-captured: 15
```

If no results:

```text
No auto-captured memories yet.

Auto-capture stores memories when AI agents detect:
  - Working solutions after debugging
  - Failed approaches to avoid
  - Architecture decisions
  - Tool configurations

Trigger auto-capture by using the --auto flag:
  memory-helper.sh store --auto --content "..."
```

## How Auto-Capture Works

AI agents automatically store memories using `--auto` flag when they detect:

| Trigger | Memory Type | Example |
|---------|-------------|---------|
| Solution found after debugging | `WORKING_SOLUTION` | "Fixed CORS with nginx headers" |
| Failed approach identified | `FAILED_APPROACH` | "setTimeout doesn't work for async" |
| Architecture decision made | `DECISION` | "Chose SQLite over Postgres" |
| Tool configuration worked | `TOOL_CONFIG` | "SonarCloud needs SONAR_TOKEN" |
| User states a preference | `USER_PREFERENCE` | "Prefers tabs over spaces" |
| Workaround discovered | `WORKING_SOLUTION` | "Use --legacy-peer-deps flag" |

## Privacy

Auto-captured memories are subject to privacy filters:

- `<private>...</private>` tags are stripped before storage
- Content matching secret patterns (API keys, tokens) is rejected
- Use `privacy-filter-helper.sh scan` for comprehensive scanning

## Related Commands

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Manually store a memory |
| `/recall {query}` | Search all memories |
| `/recall --auto-only` | Search only auto-captured memories |
| `/recall --manual-only` | Search only manually stored memories |
| `memory-helper.sh stats` | Show memory statistics (includes auto-capture counts) |
