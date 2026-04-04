<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Cron Triggers

Schedule Workers on Cloudflare's global network. 5-field cron syntax with Quartz extensions (L, W, #). At-least-once delivery — make handlers idempotent.

## Quick Start

**wrangler.jsonc:**

```jsonc
{
  "name": "my-cron-worker",
  "triggers": { "crons": ["*/5 * * * *", "0 2 * * *"] }
}
```

**Handler:**

```typescript
export default {
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    console.log("Cron:", controller.cron, "Time:", new Date(controller.scheduledTime));
    ctx.waitUntil(asyncTask(env)); // Non-blocking
  },
};
```

**Test locally:** `npx wrangler dev` — see [gotchas.md](./cron-triggers-gotchas.md) "Local Testing" for curl commands and alternative paths.

## Cron Syntax

```text
 ┌─────────── minute (0-59)
 │ ┌───────── hour (0-23)
 │ │ ┌─────── day of month (1-31)
 │ │ │ ┌───── month (1-12, JAN-DEC)
 │ │ │ │ ┌─── day of week (1-7, SUN-SAT, 1=Sunday)
 * * * * *
 * (any)  , (list)  - (range)  / (step)  L (last)  W (weekday)  # (nth)
```

```bash
*/5 * * * *            # Every 5 minutes
0 * * * *              # Hourly
0 2 * * *              # Daily 2am UTC (off-peak)
0 9 * * MON-FRI        # Weekdays 9am UTC
0 0 1 * *              # Monthly 1st midnight UTC
0 9 L * *              # Last day of month 9am UTC
0 10 * * MON#2         # 2nd Monday 10am UTC
*/10 9-17 * * MON-FRI  # Every 10min, 9am-5pm weekdays
```

## Limits

| Plan | Triggers/worker | CPU |
|------|----------------|-----|
| Free | 3 | 10ms |
| Paid | Unlimited | 50ms |

- **Propagation:** 15min global deployment
- **Timezone:** UTC only — see [gotchas.md](./cron-triggers-gotchas.md) for offset calculation

## See Also

- [patterns.md](./cron-triggers-patterns.md) — API sync, DB cleanup, batch processing, health checks
- [gotchas.md](./cron-triggers-gotchas.md) — timezone offsets, duplicate execution, debugging, security
