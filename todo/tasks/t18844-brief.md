<!-- aidevops:brief-schema=v2 -->
## What

Worker-prepared Cloudron package bump PRs strand forever at the release gate. Give the existing half-hour `r924` routine (`cloudron-release-approval-helper.sh process --apply`) ownership of the release handoff the worker defers to it:

1. **Request retry.** For each managed package repo, when no open approval request exists for the newest held worker PR (`release-approval-required` + `origin:worker`, same repository, not a draft), run the existing `release_request` once its checks are terminal-green. Pending or failing checks wait for the next run; CI repair is pulse's job.
2. **Obsolete bump supersession.** Once the newest held PR has an open approval request, close each older held worker PR only when every one of these holds:
   - it has no open request, or only an unsigned one (`NO_APPROVAL`);
   - its linked package-monitor finding (trusted author, exact `aidevops:cloudron-package-monitor upstream-…` marker) is strictly older than the requested PR's finding.

   Close that finding as superseded too, with a link to the replacement. Signed, stale or unverifiable approvals, non-upstream PRs (for example compatibility fixes), forks and human PRs are never touched. Closing a PR keeps its branch for audit.

## Why

Evidence from `marcusquinn/aidevops-cloudron-app` on 2026-10-31:

- PR #225 (aidevops 3.39.72, conflicting), PR #233 (3.39.78, conflicting) and PR #236 (3.39.87, mergeable) all carry `hold-for-review` + `release-approval-required`.
- There are no open or closed approval-request issues, so the maintainer has nothing to sign.
- Each worker handoff says the `request` call "correctly refused while checks remain pending" and that "automation next runs" it. No automation does: `release_process` only iterates existing request issues.
- Findings #223/#232/#235 stay assigned + `status:in-review`, so `_cloudron_monitor_supersede_upstream` retains them as "claimed or assigned".
- The newest finding #239 (3.39.99) is footprint-deferred behind #223 every pulse (`FOOTPRINT_OVERLAP (issue=#223 …)`).
- The same stack was closed by hand on 2026-10-25 (GH#35651 evidence) and has rebuilt within five days.

## How

- `.agents/scripts/cloudron-release-approval-helper.sh`: add a held-PR reconcile pass to `release_process` after the issue loop. It needs one `gh pr list` per repo, `release_checks` for the newest candidate only, and REST reads of linked findings only when supersession is possible. Reuse `release_request`, `release_verify`, `release_metadata` and `release_comment`. Use the audited `gh_pr_close_safe` and `gh_pr_comment` wrappers. Dry runs (`process` without `--apply`) only print what would happen.
- Mark the trust checks with `#aidevops:trust-boundary`.
- `.agents/scripts/tests/test-cloudron-release-approval.sh`: default the new `gh pr list` stub to `[]` so existing cases are unchanged. Add focused cases covering: request on green checks; wait on pending checks; supersede an older unsigned upstream bump; retain signed, non-upstream, human and newer PRs; and dry run.
- `.agents/scripts/routines/core-routines.sh` (`describe_r924`): document that the routine also owns the deferred request handoff and obsolete-bump supersession.

## Files Scope

- `.agents/scripts/cloudron-release-approval-helper.sh`
- `.agents/scripts/tests/test-cloudron-release-approval.sh`
- `.agents/scripts/routines/core-routines.sh`

## Acceptance

- A held worker PR whose checks become green gets exactly one approval request within one routine run, with no duplicate on later runs.
- Older unsigned upstream-bump PRs and their findings close with a replacement link only after the replacement request exists. Signed approvals are never closed.
- Dry run performs no writes.
- After deployment, the `aidevops-cloudron-app` stack converges to one pending approval request. Its newest finding (#239) is no longer deferred behind #223.

## Verification

- `bash .agents/scripts/tests/test-cloudron-release-approval.sh`
- `shellcheck .agents/scripts/cloudron-release-approval-helper.sh .agents/scripts/tests/test-cloudron-release-approval.sh`
- `cloudron-release-approval-helper.sh process --repo marcusquinn/aidevops-cloudron-app` (dry run) lists the intended request and supersessions.
