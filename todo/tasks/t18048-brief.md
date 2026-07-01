<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18048: Reach profile and cookie broker with leases and pinning

## Pre-flight

- [x] Memory recall: `aidevops reach capture profile cookie broker leases` → 0 hits — no relevant prior lesson found.
- [x] Discovery pass: no t18048 brief/open related PR found; profile and cookie docs are present.
- [x] File refs verified: `.agents/tools/browser/browser-profiles.md`, `.agents/tools/browser/sweet-cookie.md`, and t18047 target files are present or declared blockers.
- [x] Tier: `tier:standard` — private state, leases, route integration, and sanitization tests.
- [x] Seeded draft PR decision recorded: skipped — depends on t18047.

## Origin

- **Created:** 2026-07-01
- **Session:** OpenCode interactive reach/capture planning
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** t18047
- **Conversation context:** After reach routing, authenticated captures need safe profile/cookie reuse without leaking secrets or corrupting shared profile state.

## What

Extend reach with a profile/cookie broker that reserves an aidevops-managed browser profile for a target class, pins it for a bounded lease, records safe metadata, and exposes cookie-session availability without printing cookie values or unsafe paths.

## Why

Parallel workers can otherwise reuse or mutate the same persistent profile, rotate sessions mid-flow, or leak cookie/proxy details into transcripts and issues.

## Tier

**Selected tier:** `tier:standard` — stateful helper behavior with privacy rules.

## PR Conventions

Leaf task. Worker PR should resolve this task's own issue only.

## How

### Progressive Context Plan

- **Read first:** `.agents/tools/browser/browser-profiles.md:18-60` — profile storage and types.
- **Read first:** `.agents/tools/browser/sweet-cookie.md:22-33` and `:123-136` — cookie reuse and security constraints.
- **Read first:** `.agents/aidevops/reach-capture.md` and `.agents/scripts/reach-helper.sh` from t18047.
- **Stop when:** broker commands manage private lease metadata and `reach route` can reference safe profile/cookie policy.

### Files to Modify

- `EDIT: .agents/scripts/reach-helper.sh` — add `profile` and `cookie` subcommands plus route integration.
- `EDIT: .agents/aidevops/reach-capture.md` — document lease schema, cookie policy, and safe logging.
- `NEW: .agents/scripts/tests/test-reach-profile-broker.sh` — lease/sanitization tests.

### Implementation Steps

1. Store private state under `~/.aidevops/.agent-workspace/reach/leases/` and `~/.aidevops/.agent-workspace/reach/cookie-sessions/`.
2. Lease JSON fields: `schema_version`, `target_key`, `profile_name`, `profile_type`, `auth_mode`, `cookie_source`, `owner`, `created_at`, `expires_at`, `sensitivity`, and safe `notes`.
3. Add `reach profile lease|release|status` and `reach cookie status|register|clear`. Refuse to overwrite an unexpired lease unless `--force` is present.
4. `cookie register` may store a private file path in workspace metadata, but command output may show only a safe label/hash.
5. Integrate `reach route --auth cookie|profile|manual` so route decisions include `profile_policy` and `cookie_policy` from the broker.

### Verification

```bash
shellcheck .agents/scripts/reach-helper.sh .agents/scripts/tests/test-reach-profile-broker.sh
.agents/scripts/tests/test-reach-profile-broker.sh
./aidevops.sh reach profile lease --target-key test-target --type persistent --ttl 30m --format json
./aidevops.sh reach route --objective "logged-in dashboard export" --auth profile --format json
```

### Files Scope

- `.agents/scripts/reach-helper.sh`
- `.agents/aidevops/reach-capture.md`
- `.agents/scripts/tests/test-reach-profile-broker.sh`

## Acceptance Criteria

- [ ] Profile leases are written under the private reach workspace with TTL, owner, type, and target key.
- [ ] Unexpired leases prevent parallel reuse unless forced.
- [ ] Cookie commands never print cookie values, bearer tokens, proxy credentials, or unsafe paths.
- [ ] `reach route --auth cookie|profile` includes broker-derived policy fields.
- [ ] Tests cover lease create/status/release, forced overwrite, expired reuse, and sanitization.

## Dependencies

- **Blocked by:** t18047.
- **Blocks:** t18050 and profile-aware portions of t18052.
