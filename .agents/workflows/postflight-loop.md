---
description: Monitor release health for a specified duration
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Monitor release health after deployment. Use after `/release`, a manual release, or CI/CD verification. Arguments: `$ARGUMENTS`

## Usage

```bash
/postflight-loop [--monitor-duration 5m] [--max-iterations 5]
```

Options: `--monitor-duration <t>` (window: `5m`, `10m`, `1h`; default `5m`) · `--max-iterations <n>` (default `5`)

## Core Contract

1. Parse `$ARGUMENTS` into `monitor_duration` and `max_iterations`.
2. On each pass, use `gh` to verify the latest CI status, release tag presence, and `VERSION` ↔ release-tag match.
3. Record status, iteration, elapsed time, last check, and per-check results in `.agents/loop-state/quality-loop.local.md`.
4. Emit `<promise>RELEASE_HEALTHY</promise>` only when every check passes inside the monitoring window.

## Examples

```bash
/postflight-loop --monitor-duration 10m
/postflight-loop --monitor-duration 1h --max-iterations 10
```

## Related

- `/postflight` — single postflight check
- `/release` — full release workflow
- `/preflight` — quality checks before release
- `/preflight-loop` — iterative preflight until passing
- `workflows/postflight.md` — broader release-health checks and rollback guidance
