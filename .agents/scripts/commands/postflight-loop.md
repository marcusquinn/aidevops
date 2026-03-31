---
description: Monitor release health for a specified duration
agent: Build+
mode: subagent
---

Monitor release health after deployment. Arguments: `$ARGUMENTS`

## Usage

```bash
/postflight-loop [--monitor-duration Nm] [--max-iterations N]
```

## Options

| Option | Purpose | Default |
|--------|---------|---------|
| `--monitor-duration <t>` | Total monitoring window (`5m`, `10m`, `1h`) | `5m` |
| `--max-iterations <n>` | Max monitoring passes | `5` |

## Workflow

1. Parse `$ARGUMENTS` into `monitor_duration` and `max_iterations`.
2. Use `gh` CLI to check release health iteratively.
3. On each pass verify:
   - CI workflow status
   - release tag exists
   - `VERSION` matches the release tag
4. Emit `<promise>RELEASE_HEALTHY</promise>` only when all checks pass.

## Examples

```bash
/postflight-loop --monitor-duration 10m
/postflight-loop --monitor-duration 1h --max-iterations 10
/postflight-loop --monitor-duration 2m --max-iterations 3
```

## State Tracking

Progress is tracked in `.agents/loop-state/quality-loop.local.md`.

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

## Use When

- After `/release`
- After a manual release
- During CI/CD verification

## Related

| Command | Purpose |
|---------|---------|
| `/preflight` | Quality checks before release |
| `/release` | Full release workflow |
| `/postflight` | Single postflight check |
| `/preflight-loop` | Iterative preflight until passing |
