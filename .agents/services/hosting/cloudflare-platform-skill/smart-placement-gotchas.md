# Smart Placement Gotchas

## "INSUFFICIENT_INVOCATIONS" Status

**Problem:** Not enough traffic for Smart Placement to analyze.

**Solutions:**
- Ensure Worker receives consistent global traffic
- Wait longer (analysis takes up to 15 minutes)
- Send test traffic from multiple global locations
- Check Worker has fetch event handler

## Smart Placement Making Things Slower

**Problem:** `placement_status: "UNSUPPORTED_APPLICATION"`

**Likely Causes:**
- Worker doesn't make backend calls (runs faster at edge)
- Backend calls are cached (network latency to user more important)
- Backend service has poor global distribution

**Solutions:**
- Disable Smart Placement for this Worker
- Review whether Worker actually benefits from Smart Placement
- Consider caching strategy to reduce backend calls

## No Request Duration Metrics

**Problem:** Request duration chart not showing in dashboard.

**Solutions:**
- Ensure Smart Placement enabled in config
- Wait 15+ minutes after deployment
- Verify Worker has sufficient traffic
- Check `placement_status` is `SUCCESS`

## cf-placement Header Missing

**Problem:** Header not present in responses.

**Possible Causes:**
- Smart Placement not enabled
- Beta feature removed (check latest docs)
- Worker hasn't been analyzed yet

## Monolithic Full-Stack Worker

**Problem:** Frontend and backend logic in single Worker with Smart Placement enabled.

**Impact:** Smart Placement optimizes for backend latency but hurts frontend response time to users.

**Solution:** Split into two Workers:
- Frontend Worker (no Smart Placement) - runs at edge
- Backend Worker (Smart Placement) - runs near database

## Local Development Confusion

**Issue:** Smart Placement doesn't work in `wrangler dev`.

**Explanation:** Smart Placement only activates in production deployments, not local development.

**Solution:** Test Smart Placement in staging environment: `wrangler deploy --env staging`

## Baseline 1% Traffic

Smart Placement routes 1% of requests without optimization for performance comparison. This is expected behavior — not a bug.

## Analysis Time

Up to 15 min after enabling. Worker runs at default edge location during analysis. Monitor `placement_status`.

> **Note:** Requirements, eligibility criteria, and "when NOT to use" guidance are in [smart-placement.md](./smart-placement.md).
