<!-- aidevops:brief-schema=v2 -->

# fix(cloudron): honour monitor_upstream/monitor_compatibility false in the package monitor

## Pre-flight

- [x] Memory recall: `cloudron app packaging upstream version update routine` → 0 hits — no relevant lessons
- [x] Discovery pass: last change to `cloudron-package-monitor-helper.sh` was #29488 (reset-aware); 0 open PRs touch it
- [x] File refs verified: `.agents/scripts/cloudron-package-monitor-helper.sh:470` and `:533` present at HEAD
- [x] Tier: `tier:simple` — exact oldString/newString supplied, no design choice left
- [x] Seeded draft PR decision recorded: skipped — two-line edit

## Origin

- **Created:** 2026-10-08
- **Created by:** ai-interactive
- **Conversation context:** While auditing whether r916/r917 keep Cloudron packages current, a dry run (`cloudron-package-monitor-helper.sh upstream`) reported errors for packages registered with `monitor_upstream: false`.

## What

Registrations with `cloudron_package.monitor_upstream: false` or `monitor_compatibility: false` are skipped by the r916 and r917 monitors. Omitted fields keep their current defaults.

## Why

jq's `//` operator treats `false` as missing, so `.monitor_upstream // (<default>)` returns the default even when the value is explicitly `false` (`jq -n '{a:false} | .a // true'` → `true`). `aidevops-repos-lib.sh:647` deliberately registers new, unscaffolded Cloudron repos with `monitor_upstream: false`. The monitor ignores that flag and fails on them.

Evidence (2026-10-08 dry run): `marcusquinn/cloudron-nostr-vpn-app` (`Could not fetch the remote manifest`, because no `CloudronManifest.json` exists yet) and `marcusquinn/cloudron-nostr-relay-app` (`No stable semantic releases tag for hoytech/strfry`) both have `monitor_upstream: false` but were still processed. Each of these errors makes the whole r916 run exit 1, so the routine records `failure` and is subject to the failure backoff, even though the real packages were checked.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** Exact replacement of two jq expressions, with focused verification and a trivial rollback.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/cloudron-package-monitor-helper.sh:470` — upstream opt-out
- `EDIT: .agents/scripts/cloudron-package-monitor-helper.sh:533` — compatibility opt-out

### Complete Write Surface

- **Callers/readers:** `_cloudron_monitor_upstream_entry` and `_cloudron_monitor_compatibility_entry`, called from the loop at `:560-575`.
- **Writers/mutation paths:** `aidevops-repos-lib.sh:546` (defaults `monitor_upstream` only when null) and `:647` (registers with `false`). Both stay unchanged.
- **Existing verification/tests:** `.agents/scripts/tests/test-cloudron-package-monitor.sh` (fixture at about line 264 uses `monitor_upstream: true`).
- **Schemas/config:** `.agents/reference/repos-json-fields.md:219` already documents the intended semantics; no change.
- **Generated/deployed mirrors:** deployed copy under `~/.aidevops/agents/scripts/`, updated by release.
- **Migrations/backfills:** none. Existing `true` and omitted values behave the same.
- **Cleanup/rollback paths:** revert the two lines.

### Implementation Steps

1. Line 470, oldString:

   ```bash
   	monitor_enabled=$(jq -r '.cloudron_package.monitor_upstream // ((.cloudron_package.upstream_slug // "") != "")' <<<"$entry")
   ```

   newString:

   ```bash
   	monitor_enabled=$(jq -r 'if (.cloudron_package.monitor_upstream | type) == "boolean" then .cloudron_package.monitor_upstream else ((.cloudron_package.upstream_slug // "") != "") end' <<<"$entry")
   ```

2. Line 533, oldString:

   ```bash
   	monitor_enabled=$(jq -r '.cloudron_package.monitor_compatibility // true' <<<"$entry")
   ```

   newString:

   ```bash
   	monitor_enabled=$(jq -r 'if (.cloudron_package.monitor_compatibility | type) == "boolean" then .cloudron_package.monitor_compatibility else true end' <<<"$entry")
   ```

3. Run shellcheck and the existing test.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only jq evaluation; no change.
- **Migration/rollback:** none needed. Rollback restores the current behaviour.
- **Mixed-version/backward compatibility:** omitted or `null` fields keep their defaults; only explicit `false` changes behaviour, which matches the documented contract.
- **Idempotency/retry:** unchanged.
- **Partial failure/recovery:** opted-out packages no longer add failures, so r916/r917 exit 0 when every monitored package succeeds.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/cloudron-package-monitor-helper.sh
bash .agents/scripts/tests/test-cloudron-package-monitor.sh
bash .agents/scripts/cloudron-package-monitor-helper.sh upstream   # no errors for monitor_upstream:false repos
```

- **Surface mapping:** the dry run proves the production path skips opted-out registrations; the existing test proves enabled packages are unchanged.
- **Broad verification trigger:** not required.

### Files Scope

- `.agents/scripts/cloudron-package-monitor-helper.sh`

## Acceptance Criteria

- [ ] A registration with `monitor_upstream: false` produces no output and no failure from `cloudron-package-monitor-helper.sh upstream`; the same holds for `monitor_compatibility: false` with `compatibility`.
- [ ] Registrations with `monitor_upstream: true`, or with the field omitted and `upstream_slug` set, are still checked and still produce findings (existing test passes).

  ```yaml
  verify:
    method: codebase
    pattern: "monitor_upstream // "
    path: ".agents/scripts/cloudron-package-monitor-helper.sh"
    expect: absent
  ```

## Context & Decisions

- Non-goal: enabling monitoring for the unscaffolded nostr-vpn/nostr-relay/headscale packages. When strfry packaging is scaffolded, its registration will need `upstream_source: "tags"`, because `hoytech/strfry` publishes tags (1.1.3) but no GitHub releases.
