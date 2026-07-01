<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18047: Reach/capture capability registry, doctor, and router

## Pre-flight

- [x] Memory recall: `aidevops reach capture auto-dispatch task briefs TODO issue-sync worker-ready` → 0 hits — no relevant prior lesson found.
- [x] Discovery pass: prework found the claim commit and no recently merged/open reach-capture PRs; adjacent `_inbox`, `_knowledge`, `_performance`, `_feedback`, and `/auto-browse` planes exist.
- [x] File refs verified: `aidevops.sh`, `/auto-browse`, browser profile/proxy/cookie docs, and inbox/knowledge/performance/feedback docs are present at HEAD.
- [x] Tier: `tier:standard` — new helper, docs, CLI dispatch, and tests.
- [x] Seeded draft PR decision recorded: skipped — issue-only task is safer until a worker owns the implementation branch.

## Origin

- **Created:** 2026-07-01
- **Session:** OpenCode interactive reach/capture planning
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** We chose an aidevops-native reach/capture layer over cloning Agent-Reach, using existing browser/profile/proxy/inbox/knowledge/performance/feedback primitives.

## What

Create the reach/capture foundation: `.agents/aidevops/reach-capture.md`, `.agents/scripts/reach-helper.sh`, `aidevops reach ...` dispatch, and focused tests. The first helper commands are `doctor`, `capabilities`, and `route`; capture/profile/proxy/logging behavior is deferred to follow-up tasks.

## Why

Agents currently rediscover which browser/data-mining tool to use, which local capabilities exist, and whether a target should be fetched, crawled, automated, or blocked. A deterministic registry and router reduce repeated discovery and give later tasks a stable contract.

## Tier

**Selected tier:** `tier:standard` — bounded shell/docs/test work, but route decisions require judgment.

## PR Conventions

Leaf task. Worker PR should resolve this task's own issue only.

## How

### Progressive Context Plan

- **Read first:** `.agents/workflows/auto-browse.md:73-147` — minimum-agency routing and graduation ladder.
- **Read first:** `.agents/tools/browser/browser-profiles.md:18-60`, `.agents/tools/browser/proxy-integration.md:89-109`, `.agents/tools/browser/sweet-cookie.md:22-33` — registry inputs.
- **Read first:** `aidevops.sh:1715-1725` — top-level command dispatch insertion point.
- **Stop when:** `reach-helper.sh doctor|capabilities|route` work locally and no capture/profile/proxy mutation is implemented.

### Files to Modify

- `NEW: .agents/aidevops/reach-capture.md` — capability registry and route decision schema.
- `NEW: .agents/scripts/reach-helper.sh` — CLI entry point for doctor/capabilities/route.
- `EDIT: aidevops.sh:1715-1725` — dispatch `aidevops reach ...`.
- `NEW: .agents/scripts/tests/test-reach-helper.sh` — focused helper tests.

### Implementation Steps

1. Document the capability registry in `.agents/aidevops/reach-capture.md`. Include existing capabilities only: fetch/static parse, Crawl4AI/WaterCrawl crawler, deterministic browser, persistent profile, cookie-session reuse, anti-detect profile, proxy/VPN, `_inbox` capture, `_knowledge` staging, `_performance` logging, and `_feedback` mining.
2. Define a route decision JSON schema with `backend`, `agency_level`, `mode`, `headed`, `profile_policy`, `cookie_policy`, `proxy_policy`, `offload`, `capture_destination`, `safety_notes`, `expected_artifacts`, and `blocked_reason`.
3. Create `reach-helper.sh` following existing shell style: source `shared-constants.sh`, `set -euo pipefail`, use `local var="$1"`, and give every function explicit `return 0` or `return 1`.
4. Implement:
   - `capabilities --format json` — lists registry entries and local availability.
   - `doctor --format json` — checks local helper/binary readiness without contacting arbitrary targets.
   - `route --objective <text> [--auth none|cookie|profile|manual] [--scope public|private] --format json` — chooses minimum agency from `/auto-browse` rules.
5. Wire `reach) _dispatch_helper "reach-helper.sh" "reach-helper.sh" "$@" ;;` into `aidevops.sh`.
6. Add tests covering help, JSON registry, missing-tool doctor output, minimum-agency route choice, unknown command failure, and output sanitization.

### Verification

```bash
shellcheck .agents/scripts/reach-helper.sh .agents/scripts/tests/test-reach-helper.sh
.agents/scripts/tests/test-reach-helper.sh
./aidevops.sh reach doctor --format json
./aidevops.sh reach route --objective "capture public documentation" --scope public --format json
```

### Files Scope

- `.agents/aidevops/reach-capture.md`
- `.agents/scripts/reach-helper.sh`
- `.agents/scripts/tests/test-reach-helper.sh`
- `aidevops.sh`

## Acceptance Criteria

- [ ] `aidevops reach doctor --format json` reports capability health without contacting arbitrary targets.
- [ ] `aidevops reach capabilities --format json` lists fetch/crawler/browser/profile/cookie/proxy/inbox/knowledge/performance/feedback capabilities.
- [ ] `aidevops reach route ... --format json` emits backend, agency level, headed/headless recommendation, profile/cookie/proxy policy, offload recommendation, and blocked reason.
- [ ] Output sanitizes credentials, cookie values, proxy auth, private paths, and raw private targets.
- [ ] ShellCheck and focused tests pass.

## Dependencies

- **Blocks:** t18048, t18049, t18050, t18051, t18052.
