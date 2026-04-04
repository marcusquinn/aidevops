<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1835: Fix pool mark-failure to use server Retry-After header

**Session origin**: Headless worker dispatch
**GitHub issue**: marcusquinn/aidevops#15187

## What

Propagate the HTTP `Retry-After` header from provider-auth.mjs 429 responses to the shell mark-failure path, and reduce the blind fallback from 900s to 60s.

## Why

Both pool accounts get 15-minute cooldowns from worker 429s, blocking interactive sessions even though Anthropic rate limits clear in 10-60 seconds.

## How

1. `provider-auth.mjs`: Add `parseRetryAfterMs()` to parse the `Retry-After` header (integer seconds or HTTP-date). On 429, use the parsed value for `cooldownUntil` in `patchAccount()`.
2. `headless-runtime-helper.sh`: In `parse_retry_after_seconds()`, check `oauth-pool.json` for an existing server-sourced cooldown before falling back to text parsing.
3. Reduce the blind 429 fallback from 900s to 60s in both `parse_retry_after_seconds()` and `attempt_pool_recovery()`.

## Acceptance Criteria

- [x] Retry-After header parsed and used for cooldownUntil in provider-auth.mjs
- [x] `parse_retry_after_seconds()` checks oauth-pool.json for server-sourced cooldown
- [x] Blind 429 fallback reduced from 900s to 60s in all call sites
- [x] Interactive sessions no longer blocked by stale worker cooldowns

## Files

- `.agents/plugins/opencode-aidevops/provider-auth.mjs:549-700`
- `.agents/scripts/headless-runtime-helper.sh:413-445, 518-522`
