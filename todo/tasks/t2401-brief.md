# t2401: add version=X.Y.Z to DISPATCH_CLAIM body for version-gated override filter

## Session origin

- Date: 2026-04-19
- Context: Post-ship follow-up from t2400 (PR #19965). t2400 ships a login-based override; this generalizes to version-based override which is more robust.
- Sibling tasks: t2400 (login-gated tactical override, shipped), t2402 (stats-dashboard auto-override, future).

## What

Extend the `DISPATCH_CLAIM` comment body format and the override filter in `dispatch-claim-helper.sh` to include a `version=X.Y.Z` field, enabling a version-gated filter that ignores claims from runners older than a configurable floor — complementing t2400's login-gated list.

## Why

t2400 shipped a tactical login-based circuit breaker (`DISPATCH_CLAIM_IGNORE_RUNNERS`). Login-based filtering has two structural limits:

1. **Peer identity bleeds across versions.** If a peer updates their runner, the filter still ignores them until an operator manually removes them. Operators forget.
2. **Can't express "ignore runners older than N"** — which is the more robust primitive. A degraded runner is degraded because of code it runs, not who runs it.

A version field in the claim + `DISPATCH_CLAIM_MIN_VERSION` config lets the filter auto-sunset: once a peer upgrades, their claims pass the floor and dispatch resumes without operator action.

## How

### Files to modify

- **EDIT**: `.agents/scripts/dispatch-claim-helper.sh`
  - `_post_claim` (~line 155): read framework version from `~/.aidevops/agents/VERSION`; append `version=X.Y.Z` to the claim body template. Backward-compatible — consumers tolerate missing field.
  - `_fetch_claims` parse step (~line 260): extend the jq `capture()` regex with `version=(?<version>[^ ]+)?` (optional). Emit `version` in the parsed JSON; default to `"unknown"` when absent.
  - `_apply_ignore_filter` (~line 303): extend filter to also strip claims where `version < DISPATCH_CLAIM_MIN_VERSION`. Compose AND with login filter. `"unknown"` treated as below-floor.

- **EDIT**: `.agents/configs/dispatch-override.conf.txt` — document `DISPATCH_CLAIM_MIN_VERSION=X.Y.Z` alongside existing fields.

- **EDIT**: `.agents/scripts/tests/test-dispatch-override.sh` — add assertions:
  - Claim emit includes `version=X.Y.Z` field with correct value.
  - Parse extracts the field, defaults to `"unknown"` when missing.
  - `_apply_ignore_filter` with `DISPATCH_CLAIM_MIN_VERSION=3.9.0` removes 3.8.78 claim, keeps 3.9.1 claim.
  - Semver comparison: `3.8.100` > `3.8.78` (numeric, not lexicographic).

### Reference patterns

- Version read: `cat ~/.aidevops/agents/VERSION` or source from `shared-constants.sh` if it exposes a constant.
- Filter composition: model on t2400's `_apply_ignore_filter`, extend the jq chain.
- Semver compare: `sort -V` or a jq helper — whichever is already used elsewhere in the codebase.

## Acceptance criteria

- [ ] `_post_claim` emits `version=X.Y.Z` field with framework version.
- [ ] `_fetch_claims` parses `version` field; legacy claims parse as `"unknown"`.
- [ ] `_apply_ignore_filter` supports `DISPATCH_CLAIM_MIN_VERSION`.
- [ ] Semver comparison handles `3.8.78` vs `3.8.100` correctly.
- [ ] Filter log line indicates the reason: `Filtered N claim(s) older than MIN_VERSION`.
- [ ] Test harness asserts emit, parse, and filter.
- [ ] Shellcheck + complexity gate clean.

## Context

- PR #19965 (t2400): ships the login-based filter; look at `_apply_ignore_filter` as the extension point.
- #19967: audit-trail issue for t2400.
- t2402 (#19969): longer-term replacement via supervisor dashboards; t2401 and t2402 are complementary — t2401 is a smaller step that's useful even if t2402 never lands.
