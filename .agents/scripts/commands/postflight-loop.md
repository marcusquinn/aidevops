---
description: Monitor release health for a specified duration
agent: Build+
mode: subagent
---

Monitor release health after deployment. Arguments: `$ARGUMENTS`

## Usage

```bash
/postflight-loop [--monitor-duration 5m] [--max-iterations 5]
```

## Core Contract

1. Parse `$ARGUMENTS` into `monitor_duration` and `max_iterations`.
2. On each iteration, use `gh` to verify:
   - latest CI workflow status
   - release tag exists
   - `VERSION` matches the release tag
3. Track progress in `.agents/loop-state/quality-loop.local.md` with status, iteration, elapsed time, last check, and per-check results.
4. Emit `<promise>RELEASE_HEALTHY</promise>` only when every check passes within the monitoring window.

## Options

| Option | Purpose | Default |
|--------|---------|---------|
| `--monitor-duration <t>` | Total monitoring window such as `5m`, `10m`, or `1h` | `5m` |
| `--max-iterations <n>` | Max monitoring passes | `5` |

## Typical Invocations

```bash
/postflight-loop --monitor-duration 10m
/postflight-loop --monitor-duration 1h --max-iterations 10
/postflight-loop --monitor-duration 2m --max-iterations 3
```

Use the default command for quick verification, extend the duration for slower release pipelines, and lower iterations only when you need a bounded smoke check.

## Use When

- After `/release`
- After a manual release
- During CI/CD verification

## Related

- `/postflight` - single postflight check
- `/release` - full release workflow
- `/preflight` - quality checks before release
- `/preflight-loop` - iterative preflight until passing
- `workflows/postflight.md` - broader release-health checks and rollback guidance
