<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18049: Reach proxy, VPN, fingerprint health, and failover classification

## Pre-flight

- [x] Memory recall: `aidevops reach proxy vpn fingerprint failover classification` → 0 hits — no relevant prior lesson found.
- [x] Discovery pass: no t18049 brief/open related PR found; proxy and anti-detect docs are present.
- [x] File refs verified: `.agents/tools/browser/proxy-integration.md`, `.agents/tools/browser/anti-detect-browser.md`, and t18047 target files are present or declared blockers.
- [x] Tier: `tier:standard` — failure taxonomy, failover policy, and tests.
- [x] Seeded draft PR decision recorded: skipped — depends on t18047.

## Origin

- **Created:** 2026-07-01
- **Session:** OpenCode interactive reach/capture planning
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** t18047
- **Conversation context:** Reach needs to distinguish temporary blocks from permanent auth/scope failures so workers stop retrying bad paths and choose safe failover.

## What

Add network/fingerprint health checks and a failure classifier. The helper should summarize proxy/VPN/fingerprint readiness, classify failures as temporary or permanent, and recommend the next safe route without retrying the same blocked identity.

## Why

Timeouts, empty pages, CAPTCHA, 403, login walls, selector drift, and proxy blocks need different actions. A shared taxonomy makes retries cheaper and safer.

## Tier

**Selected tier:** `tier:standard` — one helper/doc/test set with policy decisions.

## PR Conventions

Leaf task. Worker PR should resolve this task's own issue only.

## How

### Progressive Context Plan

- **Read first:** `.agents/tools/browser/proxy-integration.md:89-109` — health and rotation.
- **Read first:** `.agents/tools/browser/anti-detect-browser.md:30-43` and `:95-115` — fingerprint/profile decision tree and ethical constraints.
- **Read first:** t18047 reach docs/helper.
- **Stop when:** health/classifier commands work with stubbed inputs and route output includes failure/failover policy.

### Files to Modify

- `EDIT: .agents/scripts/reach-helper.sh` — add `network doctor`, `fingerprint doctor`, and `classify-failure` commands.
- `EDIT: .agents/aidevops/reach-capture.md` — document failure classes and failover rules.
- `NEW: .agents/scripts/tests/test-reach-failover.sh` — classifier and sanitization tests.

### Implementation Steps

1. Document failure classes: `success`, `network_timeout`, `proxy_unhealthy`, `rate_limited`, `captcha_required`, `bot_block`, `auth_required`, `scope_forbidden`, `selector_drift`, `content_empty`, and `unknown`.
2. Add helper commands: `reach network doctor --format json`, `reach fingerprint doctor --format json`, and `reach classify-failure --http-status <code> --has-login-wall <bool> --has-captcha <bool> --timeout <bool> --format json`.
3. Classifier output fields: `failure_class`, `temporary`, `retry_after_seconds`, `next_action`, `safe_to_failover`, `requires_authorization`, and safe `notes`.
4. Health output may show provider class/profile type/check status. Default output must not show IP addresses, proxy credentials, session IDs, cookies, or private paths.
5. Update route decisions with `failure_policy` and `failover_order`; never recommend failover for `scope_forbidden` or `auth_required` without new authorization.

### Verification

```bash
shellcheck .agents/scripts/reach-helper.sh .agents/scripts/tests/test-reach-failover.sh
.agents/scripts/tests/test-reach-failover.sh
./aidevops.sh reach network doctor --format json
./aidevops.sh reach classify-failure --http-status 429 --format json
```

### Files Scope

- `.agents/scripts/reach-helper.sh`
- `.agents/aidevops/reach-capture.md`
- `.agents/scripts/tests/test-reach-failover.sh`

## Acceptance Criteria

- [ ] Network/fingerprint doctors report local readiness without leaking IPs, proxy auth, cookies, or private paths by default.
- [ ] Classifier distinguishes temporary retryable failures from permanent auth/scope blockers.
- [ ] Route output contains failure policy and failover order.
- [ ] Failover recommendations never retry the same blocked identity or bypass authorization.
- [ ] Tests cover 403, 429, timeout, CAPTCHA, login-wall, selector drift, empty-content, and unknown cases.

## Dependencies

- **Blocked by:** t18047.
- **Blocks:** t18050 and t18051.
