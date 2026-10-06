## What

The GitHub transport governor keeps a stale low `core` balance in the shared
`unresolved` quota scope whenever more than one credential is bound to it. It
also keeps pushing that balance's reset epoch forward, so the stale state never
expires. Until this is fixed, every REST read on the host (pulse, workers,
interactive merges) is paced to about one call per 6.5s.

## Why

- Observed 2026-10-05 23:10Z–00:00Z on a host running v3.38.12 (includes
  t18590 / PR #33688). Local admission DB, scope `unresolved`:
  `core remaining=540`, with the reset rising from 1791246218 to 1791247191
  while `remaining` stayed at 540. `pacing.core` slots were about 6.5s apart.
  The `binding` table holds 5 credentials for that scope.
- Live GitHub for the active `gh` keyring PAT showed `core 5000/5000, used=0`.
  No GitHub App is configured (`github-app-auth-helper.sh status` reports
  `gh-pat`).
- Impact: `full-loop-helper.sh merge` failed 4 times in a row with
  `github-api-read-deferred` (`local primary pacing from observed demand and
  reset`). It passed only with the documented per-process rollback
  `AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE=1`. The same pacing throttles pulse
  dispatch (GH#33647).
- Mechanism: `gh_transport_recovery.py` `probe_recovers()` accepts a newer
  window only when `owners == 1`. The serialized-probe path also requires
  `owners == 1 or budget.attributed`, and nothing sets
  `AIDEVOPS_GH_QUOTA_OWNER`. `gh_transport_budget.py` `finish()` then applies
  `available = min(incoming, stored)` and `reset_at = max(incoming, stored)`.
  An idle PAT reports a sliding reset of about now+3600, so `row[1] > now`
  never becomes false and the clamp renews indefinitely.

## How

### Files to Modify

- `EDIT: .agents/scripts/gh_transport_recovery.py` (`probe_recovers`): accept a causally newer reset as a new window when the observing credential's owner is proven to match the stored observation (single owner, or an attributed owner shared by every bound PAT).
- `EDIT: .agents/scripts/gh_transport_budget.py` (`finish`, around the `min`/`max` clamp): do not extend a stale reset with `max()` while keeping the old `remaining`. When the incoming reset is newer, keep or replace the pair together; never combine a new reset with an old balance.
- `EDIT: .agents/scripts/gh_transport_identity.py`: optionally derive a trusted owner for PAT/OAuth tokens (cached authenticated login, never logged) so multi-PAT hosts become attributed. GitHub App installation tokens (`ghs_`) remain separate owners.
- `EDIT: .agents/scripts/tests/test-gh-transport-budget.py`: add regression cases (see Acceptance Criteria).
- `EDIT: .agents/reference/github-api-transport.md`: update the owner attribution and reconcile section.

### Implementation Steps

1. Reproduce in a test: bind two credentials to one scope, store `remaining=540` with a future reset, then feed an observation with a newer reset and `remaining=4999`.
2. Fix the `max(reset)` ratchet in `finish()`, then fix recovery for proven same-owner credentials.
3. Add `stale_multi_credential_scope` to `gh_transport_budget.py status` diagnostics.
4. Run `python3 .agents/scripts/tests/test-gh-transport-budget.py` and the transport shell cases.

### Hazards

- Never merge credentials belonging to different GitHub users or installations, and never let one owner inherit another owner's balance.
- Keep secondary-limit cooldowns, reservations, uncertain-request debt and atomic admission unchanged.
- `/rate_limit` responses are still never a grant.

### Files Scope

- `.agents/scripts/gh_transport_recovery.py`
- `.agents/scripts/gh_transport_budget.py`
- `.agents/scripts/gh_transport_identity.py`
- `.agents/scripts/tests/test-gh-transport-budget.py`
- `.agents/reference/github-api-transport.md`

## Acceptance Criteria

- [ ] Two bound credentials of one owner: stored `540` with a future reset, then an incoming newer-reset `4999`, results in `4999` being accepted and pacing cleared.
- [ ] Two different owners stay isolated: neither inherits nor clears the other's balance.
- [ ] A stale stored reset is never extended by `max()` while the old `remaining` is kept.
- [ ] `python3 .agents/scripts/tests/test-gh-transport-budget.py` passes.
- [ ] Runtime: with more than one bound credential and healthy live quota, `full-loop-helper.sh pre-merge-gate <PR> <repo>` does not return `github-api-read-deferred`.

Ref: GH#33701, GH#33647, GH#33651 (t18590, PR #33688), GH#31442, GH#31541.
