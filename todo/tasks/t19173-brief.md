# fix(pulse-merge): external check findings outside the PR diff no longer discard a green worker PR

## Origin

Interactive productivity mission session, 2026-11-19. Worker PRs #39226 and #39247 for #39222 were both closed by the deterministic merge pass ("CI repair feedback routed to issue #39222"). All required checks had passed on both, and so had the review-bot gate. A third worker PR, #39307, resubmits the same three files and is heading for the same outcome.

## What

The pre-merge snapshot (`_pmrc_nonrequired_failure_is_advisory`) gets one more advisory classifier. It applies to a non-required failure from a single external check run (a GitHub App other than `github-actions`) when the latest run's complete annotation set lies entirely outside the PR's changed paths, rename sources included. Such a failure no longer blocks the merge or routes CI repair. Everything else keeps today's fail-closed behaviour.

## Why

- `pulse.log`: `unclassified non-required check 'CodeFactor' is terminal-failure for PR #39247 ... merge blocked (GH#27137)`, then `_dispatch_ci_fix_worker`, then the PR was closed and its feedback routed back to the issue.
- The CodeFactor check run for #39247 at `bb6611ba4d` (`app.slug=codefactor-io`) reports 34 annotations: `dangerous-triggers`, `template-injection`, `excessive-permissions`, `bot-conditions` and `secrets-inherit` across about 20 `.github/workflows/*.yml` files. None of those files is in the PR, which changes only `.agents/scripts/affected-tests-helper.sh`, `.github/workflows/code-quality.yml` and `.github/workflows/shell-suite-main-health.yml`. CodeFactor labels pre-existing workflow findings as new once a PR edits any workflow file.
- The worker and the in-place repair worker made six commits chasing CodeFactor. The ones that fixed on-diff findings worked; the off-diff remainder cannot be fixed inside the PR's scope. The routed feedback then tells the next worker to "fix the source issue", which pushes it towards editing about 20 unrelated, security-sensitive workflow triggers.
- Cost per loop: a worker session, a repair worker session, a closed PR and a fresh redispatch, repeated (three PRs so far for one issue). This is the stall pattern that makes a person open an interactive session to push the issue through.
- On-diff findings still block. Example: #39294's CodeFactor failure was on its own lines and was repaired; it now passes.

## How (Approach)

- `.agents/scripts/pulse-merge-required-checks.sh`:
  - `_pmrc_off_diff_annotation_evidence repo head name`: read `commits/{head}/check-runs?check_name=<uri>&filter=latest`. Require exactly one run with that name, a positive integer `id`, a non-empty `app.slug` other than `github-actions`, `conclusion == failure`, and `0 < output.annotations_count <= PULSE_MERGE_OFF_DIFF_MAX_ANNOTATIONS` (default 500). Then page `check-runs/{id}/annotations` and require the fetched count to equal `annotations_count` and every annotation to have a non-empty `path`. Emit `{app, count, paths}`.
  - `_pmrc_pr_changed_paths_json repo pr`: page `pulls/{pr}/files` and emit unique `filename` and `previous_filename` values. An empty list, the 3000-file API cap, or a nameless entry fails closed.
  - `_pmrc_is_off_diff_external_failure`: requires a single `name@check_run` member. It is advisory only when no annotation path is in the changed set, and it logs `IGNORED non-required external check ... annotation(s) all outside the PR diff`.
  - `_pmrc_nonrequired_failure_is_advisory`: call it after the configured-advisory classifier.
- Safety: required checks, cancelled runs and the maintainer gate are untouched. GitHub Actions runs are excluded, because cross-file analysers such as type checkers can report a real regression in an untouched file. Missing or partial evidence, any read or parse failure, and any on-diff annotation keep the failure blocking. Merges stay head-pinned (`--match-head-commit`), and the snapshot validates the head before classifying.

### Files Scope

- `.agents/scripts/pulse-merge-required-checks.sh`

## Acceptance Criteria

- `shellcheck .agents/scripts/pulse-merge-required-checks.sh` is clean, and `tests/test-pulse-merge-preflight-snapshot.sh` passes unchanged (its stubbed CodeFactor failure has no external app evidence and still blocks).
- Live replay against #39247 head `bb6611ba4d`: the classifier returns advisory with 34 annotations outside the diff.
- Synthetic replay: an annotation on a changed path, an Actions app run, a partial annotation page, zero annotations and a failed read each return blocking.
- After deploy, `pulse.log` logs `IGNORED non-required external check 'CodeFactor'` instead of `unclassified non-required check 'CodeFactor'` for off-diff-only failures, and such PRs proceed to merge.
