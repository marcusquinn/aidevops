# t18590: Transport governor keeps stale low core quota across a new rate-limit window

Ref: GH#33651

## What

The REST transport governor keeps a stale, low `core` balance for the full remainder of an old reset window, even when every fresh response from the same credential reports a new window with full quota. The result is about 5-7.5 s of admission pacing per REST read. That pushes `_gh_with_timeout read` (15 s default) calls over their budget, so framework helpers fail with spurious read errors. Once the pacing delay exceeds 5 s, the shim defers the read outright (rc 75), which release-lane reads treat as a hard failure.

## Why

Observed in an interactive session on 2026-10-05 (aidevops v3.38.10):

- Governor state (`~/.aidevops/state/gh-transport/admission.sqlite3`, single scope): `core remaining=540 limit=5000 reset=1791221743`, `observed` refreshed every few seconds, `remaining` frozen at 540 across 16 admissions in 5 minutes.
- Live `gh api rate_limit` for the same session credential: `core remaining=5000 used=0`, with a reset that slides forward (`1791223154` → `1791223298`), the GitHub signature of an unused window.
- `AIDEVOPS_GH_SHIM_TIMING=1 gh api repos/<owner>/<repo>/issues/<n> --jq ...`: `sqlite_admission elapsed_ms=15.3 pacing_ms=7543.3`, `native_gh elapsed_ms=380.7`.
- Downstream failures in the same session: `approval-helper.sh verify` → `API_ERROR`; `full-loop-helper.sh commit-and-pr` failed in turn at origin-label readback (`_verify_pr_origin_label`, rc=124 from `_gh_with_timeout read`), open-PR linkage evidence, and recovered-PR body verification, although the PR, labels, and body were correct on GitHub. `claim-task-id.sh` also exceeded a 180 s caller timeout.
- Later in the same session (about 17:37Z), the row was still `core remaining=540 reset=1791224609`, while `GET /rate_limit` (governor bypassed) reported `remaining=5000 used=0 reset=1791225407`. `aidevops release reconcile <PR>` and `aidevops release status <PR>` then failed repeatedly with only `Cannot verify repository release lane`. The underlying `gh api .../contents/.aidevops-release-lane.json` read was deferred: `error_kind=github-api-read-deferred attempted=false deferred_by=local_admission`, rc 75. Workaround: `AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE=1`.

Mechanism: `Budget.finish` (`.agents/scripts/gh_transport_budget.py:270-274`). When the stored row's reset is still in the future and `probe_recovers(...)` is false, it sets `available = min(header_remaining, row_remaining)` and `reset_at = max(header_reset, row_reset)`. A response from a newer window (header reset later than the stored reset, higher remaining) therefore can never raise the balance until the stale reset passes. `capacity_wait` / `primary_wait` (`.agents/scripts/gh_transport_capacity.py:14-70`) then pace against the stale 540. `_gh_transport_local_retry_delay` (`.agents/scripts/gh-transport-controls.sh:70-85`) waits inline only when `0 <= delay <= 5`; otherwise the read is deferred.

## How

### Files to Modify

- `EDIT: .agents/scripts/gh_transport_budget.py:248-307` (`Budget.finish`): when a valid response for a bound/attributed credential reports a reset epoch strictly later than the stored reset, treat it as a newer window and accept its remaining value instead of `min()`/`max()`. Keep the conservative merge for same-window late replies and for shared/unresolved owners. Decide whether to do this directly or through `probe_recovers`; reuse its credential-binding checks.
- `EDIT: .agents/scripts/gh_transport_recovery.py:91` (`probe_recovers`), only if the newer-window rule belongs with the existing credential-bound recovery logic.
- `EDIT: .agents/scripts/release-lane-helper.sh:104-125` (`release_lane_read`): distinguish a local admission deferral (rc 75 / `github-api-read-deferred`) from an unverifiable lane. Either wait once until `retry_at` within a bounded budget, or return a distinct code that `full-loop-release-helper.sh:580-603` reports as `deferred, retry at <epoch>` instead of `Cannot verify repository release lane`.
- `EDIT: .agents/scripts/tests/test-gh-transport-budget.py`: add a newer-window recovery case next to the existing `finish()` cases.

### Implementation Steps

1. Reproduce with a temp `AIDEVOPS_GH_TRANSPORT_STATE_DIR`: seed a `core` row with low remaining and a future reset, then call `finish()` with headers for the same credential reporting a later reset and high remaining. Confirm the row stays low today.
2. Change the merge so the newer-window evidence wins for bound credentials, and keep the existing conservative rules for ambiguous owners. `capacity_wait` should need no change once the stored row is correct.
3. Make `release_lane_read` deferral-aware (see Files to Modify).
4. Verify that pacing drops to ~0 on a real read (`AIDEVOPS_GH_SHIM_TIMING=1` plus a cheap REST GET; `gh api rate_limit` does not count) after one response.

### Hazards

- Do not let `/rate_limit` act as a grant (existing invariant in the comment at `gh_transport_budget.py:268`).
- Shared owners with several credentials must keep conservative accounting; the newer-window rule applies only to a bound credential.
- Self-heals at the stale reset, so impact is bounded to under one hour per occurrence, but it recurs whenever a window rolls over while the row is low.
- A deferral-aware release-lane read must never treat a deferred read as "no lane" (rc 2); absence and deferral are different states.

### Files Scope

- `.agents/scripts/gh_transport_budget.py`
- `.agents/scripts/gh_transport_recovery.py`
- `.agents/scripts/release-lane-helper.sh`
- `.agents/scripts/full-loop-release-helper.sh`
- `.agents/scripts/tests/test-gh-transport-budget.py`

## Acceptance Criteria

- [ ] After one valid response for a bound credential with a later reset epoch and higher remaining, the stored `core` row reflects the new window and admission pacing returns to near zero.
- [ ] Same-window late responses and shared/unresolved-owner scopes keep the existing conservative `min()` behaviour.
- [ ] `_gh_with_timeout read` REST reads complete within the default 15 s budget after window rollover.
- [ ] A locally deferred release-lane read reports a deferral with `retry_at` (or succeeds after a bounded wait), never `Cannot verify repository release lane`.
- [ ] Existing governor/budget and release-lane tests pass; ShellCheck/ruff clean on changed files.

## Context

- Workarounds used in the reporting session: `AIDEVOPS_GH_READ_TIMEOUT=30` for wrapper reads; `AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE=1` for `aidevops release reconcile`.
- Related: `full-loop-helper-commit.sh:1399-1447` (`_verify_pr_origin_label`), `shared-gh-wrappers.sh:472` (`_gh_with_timeout`), `gh-transport-governor.py:206-219` (`_acquire`).
- Evidence comment: GH#33651 issuecomment-5999806180.
