---
description: Monitor release health for a specified duration
agent: Build+
mode: subagent
---

Monitor release health after deployment using iterative checks.

Arguments: $ARGUMENTS

## Usage

```bash
/postflight-loop [--monitor-duration Nm] [--max-iterations N]
```

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--monitor-duration <t>` | How long to monitor (e.g., 5m, 10m, 1h) | 5m |
| `--max-iterations <n>` | Max checks during monitoring | 5 |

## Workflow

### Step 1: Parse Arguments

Extract from $ARGUMENTS:
- `monitor_duration` - Duration string (e.g., "10m", "1h")
- `max_iterations` - Number of check iterations

### Step 2: Run Postflight Loop

Execute the quality loop helper:

```bash
~/.aidevops/agents/scripts/quality-loop-helper.sh postflight $ARGUMENTS
```

### Step 3: Report Results

The script performs these checks each iteration:

1. **CI Workflow Status** - Latest GitHub Actions workflow state
2. **Release Tag Exists** - Verify the release tag was created
3. **Version Consistency** - VERSION file matches release tag

## Completion Promise

When all checks pass: `<promise>RELEASE_HEALTHY</promise>`

## Examples

**Monitor for 10 minutes:**

```bash
/postflight-loop --monitor-duration 10m
```

**Extended monitoring with more checks:**

```bash
/postflight-loop --monitor-duration 1h --max-iterations 10
```

**Quick verification:**

```bash
/postflight-loop --monitor-duration 2m --max-iterations 3
```

## State Tracking

Progress is tracked in `.claude/quality-loop.local.md`:

```markdown
## Postflight Loop State

- **Status:** monitoring
- **Iteration:** 3/5
- **Elapsed:** 180s/600s
- **Last Check:** 2025-01-11T14:30:00Z

### Check Results
- [x] CI workflow: passing
- [x] Release tag: v2.44.0 exists
- [x] Version consistency: matched
```

## When to Use

- After running `/release` to verify deployment health
- After manual releases to confirm everything is working
- As part of CI/CD pipeline verification

## Related Commands

| Command | Purpose |
|---------|---------|
| `/preflight` | Quality checks before release |
| `/release` | Full release workflow |
| `/postflight` | Single postflight check (no loop) |
| `/preflight-loop` | Iterative preflight until passing |
