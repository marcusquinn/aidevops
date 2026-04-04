<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Smart Placement Gotchas

## `INSUFFICIENT_INVOCATIONS`

Not enough traffic for analysis. Ensure consistent global traffic; wait up to 15 min; send test traffic from multiple regions; verify Worker has a `fetch` event handler.

## `UNSUPPORTED_APPLICATION` (Making Things Slower)

Worker doesn't benefit from Smart Placement — likely no backend calls (runs faster at edge), backend calls are cached, or backend has poor global distribution. Disable Smart Placement; consider a caching strategy to reduce backend calls.

## No Request Duration Metrics

Dashboard chart missing. Confirm Smart Placement is enabled in config, wait 15+ min after deploy, verify sufficient traffic, and check `placement_status: "SUCCESS"`.

## `cf-placement` Header Missing

Smart Placement not enabled, Worker not yet analyzed, or beta feature removed — check latest docs.

## Monolithic Full-Stack Worker

Frontend + backend in one Worker: Smart Placement optimises for backend latency but hurts frontend response time. Split into two Workers — frontend (no Smart Placement, runs at edge) and backend (Smart Placement, runs near database).

## Local Development (`wrangler dev`)

Smart Placement only activates in production. Test in staging: `wrangler deploy --env staging`.

## Baseline 1% Traffic

Expected behavior — not a bug. Smart Placement routes 1% of requests without optimisation for performance comparison.

## Analysis Time

Up to 15 min after enabling. Worker runs at default edge location during analysis. Monitor `placement_status`.

> Requirements, eligibility, and "when NOT to use" guidance: [smart-placement.md](./smart-placement.md).
