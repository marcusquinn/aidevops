## What

Give each pulse normalization pass (`reassign_self`, `unassign_stale`, `unassign_stampless_interactive`, `label_invariants`) a persisted per-pass repo cursor. A pass interrupted by the stage watchdog then resumes at the next repo on its next turn instead of restarting at the first repo in `repos.json`.

## Why

Production evidence (first pulse cycle after the v3.39.159 reaper-budget deploy, 2026-11-10):

- `substage:normalize/reap_dead_stamps` now completes (61s; 30 stamps examined, 6 released). GH#37565 works.
- `normalize_active_issue_assignments` (budget 229s) then started `unassign_stampless_interactive`. The watchdog killed it at 229s without a completion line. `preflight_ownership_reconcile` failed again with rc=124 (597s).
- The last full run of that pass took 168s. Normalization had 229s - 61s = 168s left, so it missed by about one repo.
- Every pass walks repos in fixed `repos.json` order. Pass rotation (`_normalize_pass_order`) gives each pass a turn, but a pass that cannot finish in one turn always restarts at repo 1. Repos late in the list are visited much less often: across the retained log, 19 repos have about 17 `reassign_self` per-repo timings while others have 30-37.

This is the same starvation pattern GH#37555 fixed for the PR scanners.

## How

- `.agents/scripts/pulse-issue-reconcile.sh`:
  - Add `_normalize_rotated_slugs <pass> <slugs>`: when `_NORMALIZE_REPO_CURSOR_DIR` is set and holds a cursor for the pass, print the slug list starting after the cursor slug (wrapping). Otherwise print it unchanged.
  - Add `_normalize_mark_repo_started <pass> <slug>`: write the slug to the pass cursor before the repo is scanned (best effort; no-op when the dir is unset).
  - `normalize_active_issue_assignments`: set `_NORMALIZE_REPO_CURSOR_DIR` (default `~/.aidevops/cache/normalize-repo-cursor`, override `AIDEVOPS_NORMALIZE_REPO_CURSOR_DIR`) for the run and clear it afterwards.
  - Wrap the repo loops in `_normalize_reassign_self` and `_normalize_unassign_stampless_interactive`.
- `.agents/scripts/pulse-issue-reconcile-stale.sh` (`_normalize_unassign_stale`) and `.agents/scripts/pulse-issue-reconcile-normalize.sh` (`_normalize_label_invariants`): wrap the repo loops the same way.
- Keep each inline `jq` repo filter in its function body; `test-maintenance-selector-contract.sh` checks those predicates.
- Direct calls outside the driver keep the canonical order (cursor dir unset), so existing unit tests are unaffected.
- Reference pattern: `_pulse_scanner_rotated_slugs` / `_pulse_scanner_mark_started` in `.agents/scripts/pulse-simplification-review.sh` (GH#37555).

### Files Scope

- .agents/scripts/pulse-issue-reconcile.sh
- .agents/scripts/pulse-issue-reconcile-stale.sh
- .agents/scripts/pulse-issue-reconcile-normalize.sh

## Acceptance

- A pass killed mid-sweep resumes after the last repo it started on its next turn.
- Across cycles, every pulse repo is visited by every pass (no fixed-order coverage skew).
- Existing normalize tests pass: `test-issue-reconcile.sh`, `test-reassign-self-normalization.sh`, `test-label-invariants.sh`, `test-stampless-non-task-filter.sh`, `test-maintenance-selector-contract.sh`.

## Verification

- `shellcheck` on the three files.
- Run the tests above.
- After deploy: `~/.aidevops/cache/normalize-repo-cursor/<pass>` files appear and change between cycles; `rg "substage:normalize/" ~/.aidevops/logs/pulse.log | tail`.
