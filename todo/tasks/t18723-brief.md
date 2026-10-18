## What

`badges-check-helper.sh` and `badges-sync-helper.sh` classify registered repos as `EXTERNAL` (skipped by check and sync) whenever the slug's org is not in a hard-coded allowlist (`_DEFAULT_OWNED_ORGS`: three orgs) or `~/.config/aidevops/badge-orgs.conf`. Repos the user maintains in any other org are silently excluded from drift detection and sync, even when `repos.json` registers them with `maintainer` = the user and they carry an aidevops-managed badge block.

Observed: 28 registered repos in an org where the user is an active org admin (`gh api user/memberships/orgs/<org>` → `role: admin`) reported `EXTERNAL  badge block present` while their blocks were stale (inline languages chart, dead badges). They were only found by checking each README directly with `readme-badges-helper.sh check`.

## Why

Ownership should come from facts the framework already records, not a framework-shipped org list that every other user would also need to override. Hard-coded org names also don't belong in shared defaults.

## How

Locations: in `badges-check-helper.sh`, `_load_owned_orgs`, `_is_owned_org` and the `_is_external` classification (~line 188); in `badges-sync-helper.sh`, `_load_owned_orgs`/`_is_owned_org` (~lines 100–125) and the caller near line 533.

### Files Scope

- `.agents/scripts/badges-check-helper.sh`
- `.agents/scripts/badges-sync-helper.sh`
- `.agents/aidevops/badges.md`

### Approach

Approach (reuse one shared function in both helpers):

1. A repo is owned when it is not `contributed: true`/`role: contributor` AND either (a) its `repos.json` `maintainer` equals the slug owner or the authenticated user, or (b) its org is listed in `badge-orgs.conf`.
2. Keep `badge-orgs.conf` as an additive override (append to derived ownership, do not replace it).
3. Replace the hard-coded default org list with the derived rule; keep no personal org names in shared code.
4. Update the header comments in both helpers and `aidevops/badges.md` if it documents the allowlist.

## Verification

- `shellcheck` both helpers.
- `bash .agents/scripts/tests/test-readme-badges-resilience.sh` and `bash .agents/scripts/tests/test-maintenance-repo-selection.sh` pass.
- With `badge-orgs.conf` absent, `badges-check-helper.sh --repo <org-repo maintained by the user>` reports CURRENT/DRIFTED, not EXTERNAL; a `contributed: true` entry still reports EXTERNAL.

## Context

Found during the fleet re-render for GH#35019 (PR #35021). Related: GH#35020 (worktree-safe sync and scheduled remediation) depends on correct ownership classification.
