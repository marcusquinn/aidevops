<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Discovery pass: GH#34839 (closed) added `_merge_handle_already_merged_provenance` for a release PR merged before the helper starts. No open issue covers a merge that lands during the run.
- [x] Tier: `tier:standard`. A narrow retry of an existing, trust-checked path; no new trust boundary.

## What

`full-loop-helper.sh merge <release-PR>` fails closed with `PR #N is not open` when GitHub native auto-merge lands the protected release PR (`chore/release-vX.Y.Z-provenance`) while the helper is running. The helper should then take its existing already-merged path (`_merge_handle_already_merged_provenance`: verify the merge SHA, no merge write, reconcile the source lane) instead of failing.

GH#34839 added that path for a PR that was already merged **before** the helper started. This issue covers the remaining time-of-check race: the PR is open at that first check and merged before the readiness gate.

## Why

Observed 2026-11-14 on release v3.39.194 (release PR #38314, source PR #38312):

- `wait-checks 38314` returned PASS when the last required check finished.
- `merge 38314` started at 18:38:38Z. `_merge_handle_already_merged_provenance` read the PR while it was still open and returned 2 (not applicable).
- Native auto-merge (armed by the release helper, method MERGE) merged at 18:38:55Z.
- The readiness gate (`_full_loop_verify_pr_readiness`, `full-loop-helper-readiness.sh:446`) then read `state=CLOSED` and the helper exited 1 at 18:38:59Z: `PR #38314 is not open` / `Merge blocked by the pre-merge safety gate`.
- The documented fallback `aidevops release reconcile 38312` worked, but `workflows/release.md` says the merge helper "also handles a PR already merged by native auto-merge without another merge write".

Auto-merge fires as soon as the last required check succeeds, which is exactly when `wait-checks` returns. So this race is likely the common case for every protected release, not a rare one. Each hit adds a failed command, a manual diagnosis and a fallback step to every release close-out.

## How

1. In `cmd_merge` (`.agents/scripts/full-loop-helper-merge.sh`, around the `_merge_handle_already_merged_provenance` call at ~line 1798), when the later pre-merge readiness/gate step fails, re-run `_merge_handle_already_merged_provenance "$pr_number" "$repo"` once. If it returns 0 or 1, return that status; if 2, keep the original failure. Keep the ordinary-PR behaviour fail-closed: the function already returns 2 for anything that is not a merged same-repo `chore/release-v*-provenance` PR into `main`.
2. Alternative with the same effect: have the readiness gate's `state != "OPEN"` branch call the already-merged handler for provenance heads only. Pick whichever keeps the trust-boundary checks (`#aidevops:trust-boundary` jq at ~line 1552) as the single authority.
3. Keep the reconcile idempotent: `_merge_reconcile_provenance_release` must not run twice in one invocation.
4. `full-loop-helper-readiness.sh` changes only under option 2. Extend the existing merge-helper test that covers `_merge_handle_already_merged_provenance` (find it with `rg -l '_merge_handle_already_merged_provenance' .agents/scripts/tests/`).

### Files Scope

- `.agents/scripts/full-loop-helper-merge.sh`
- `.agents/scripts/full-loop-helper-readiness.sh`

## Acceptance

- A provenance PR that is open at the first check and merged before the readiness gate ends in `LIFECYCLE_STATE=MERGED ... (already merged; no merge write)` and a single source-lane reconcile, exit 0.
- An ordinary PR that closes or merges mid-run still fails closed with `is not open`.
- A provenance PR closed without merging still fails closed.
- ShellCheck is clean; the existing merge-helper tests pass.

## Verification

```bash
rg -l '_merge_handle_already_merged_provenance' .agents/scripts/tests/
bash <that test file>
shellcheck -x .agents/scripts/full-loop-helper-merge.sh .agents/scripts/full-loop-helper-readiness.sh
```
