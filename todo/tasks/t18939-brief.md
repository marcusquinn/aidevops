## What

Stop the public-write privacy guard from treating known-public repositories as private ten minutes after their last visibility probe. `privacy_enumerate_private_slugs` must honour a cached public observation for a long enumeration window (default 7 days, `PRIVACY_ENUM_PUBLIC_TTL`), not the 10-minute push-probe TTL. Unknown visibility (no cache entry) still fails closed for pulse-enabled repos, as GH#37508 intended.

## Why (evidence)

- GH#37508 / PR #37513 (merged 2026-11-10 02:12Z, hot-deployed) added cached visibility to `privacy_enumerate_private_slugs` (`.agents/scripts/privacy-guard-helper.sh:240-268`). It nulls any public cache entry older than `PRIVACY_CACHE_TTL` (600 s, `:40`; expiry at `:258`), and a null entry on a pulse-enabled repo is enumerated as private (`:262`). Nothing on the enumeration path refreshes the cache: only a push or write *target* probe does (`privacy_is_target_public`, `:85-162`).
- Result: every pulse-enabled public repo becomes "private" ten minutes after its last probe. Local snapshot: of 68 pulse-enabled repos, 14 public entries were expired and enumerated as private; only 2 fresh-public repos were excluded.
- The bare-basename scan (`privacy_scan_bare_basenames`, `:561-606`) then blocks any public write that mentions those basenames. The framework signature footer links the public site `aidevops.sh`, which is also the basename of a public pulse-enabled repo, and the framework repo's basename `aidevops` appears in most bodies.
- Impact since deploy: `pulse.log` shows 63 `[privacy-scan][BLOCK]` lines, all on public targets ("aidevops.sh (basename of …/aidevops.sh)" ×40, "aidevops (basename of …/aidevops)" ×9). Each is a failed dispatch claim comment (`failed to post claim comment … after 3 attempt(s)`), which aborts the dispatch. The pulse dispatched 0–1 of 12–17 candidates per cycle, with 0 of 20 worker slots in use. Interactive PR creation is blocked the same way.

## How

### Files to modify

- EDIT: `.agents/scripts/privacy-guard-helper.sh`
  - Add `PRIVACY_ENUM_PUBLIC_TTL="${PRIVACY_ENUM_PUBLIC_TTL:-604800}"` next to `PRIVACY_CACHE_TTL`, with a comment: enumeration needs last-known visibility, not push-time freshness.
  - Pass it as the enumeration `ttl` (`:253`). Update the comment block (`:240-244`).
  - Private entries stay protected after expiry, and no-entry pulse repos still fail closed (unchanged).
- EDIT: `.agents/scripts/test-privacy-guard.sh`: add cases.
  - A public entry older than `PRIVACY_CACHE_TTL` but younger than `PRIVACY_ENUM_PUBLIC_TTL` is not enumerated.
  - A public entry older than `PRIVACY_ENUM_PUBLIC_TTL` is enumerated (fail closed).

### Files Scope

- `.agents/scripts/privacy-guard-helper.sh`
- `.agents/scripts/test-privacy-guard.sh`

### Reference pattern

- Existing GH#37508 cases in `.agents/scripts/test-privacy-guard.sh` and `.agents/scripts/test-privacy-guard-shim.sh`.

## Acceptance criteria

- A pulse-enabled repo with a public cache entry checked 1 hour ago is not in the private-slug list; one checked 8 days ago is.
- Cached-private and no-entry pulse repos are still enumerated.
- After deploy, `pulse.log` shows no new `[privacy-scan][BLOCK]` lines for known-public basenames, and dispatch claim comments post again.

## Verification

- `shellcheck .agents/scripts/privacy-guard-helper.sh .agents/scripts/test-privacy-guard.sh`
- `bash .agents/scripts/test-privacy-guard.sh`; `bash .agents/scripts/test-privacy-guard-shim.sh`; `bash .agents/scripts/tests/test-gh-public-privacy-guard.sh`
- Runtime: `privacy_enumerate_private_slugs` against the live config no longer lists the 14 expired-public slugs.
