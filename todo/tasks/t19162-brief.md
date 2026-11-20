# fix(full-loop): privacy pre-scan is stricter than the pre-push hook and blocks already-public content

## Origin

Interactive productivity mission session, 2026-11-19. Evidence from three headless workers that finished a starter-template core sync, committed it locally, and were then blocked by the full-loop privacy pre-scan, so no PR was opened.

## What

Make `_commit_and_pr_privacy_scan` in `.agents/scripts/full-loop-helper-commit.sh` call `privacy_scan_public_diff` with the same public head (`$4`) and target slug (`$5`) that the authoritative pre-push hook passes (`.agents/hooks/privacy-guard-pre-push.sh`, `rg -n "privacy_scan_public_diff" .agents/hooks/privacy-guard-pre-push.sh`). The pre-scan is meant to preview the hook before running expensive validators. Because it called the scanner with only three arguments, it had no public-tree exemption, so it blocked terms the target repository's own verified public default branch already contains.

## Why

- 2026-11-19: `wpallstars/seoprostack#1712`, `wpallstars/seoprocookieconsent#220` and `wpallstars/seoprocustom#33` each synced core files from a public starter template, passed lint and smoke tests, committed, and stopped at `[privacy-guard] Scanning public diff before validators...` → `[privacy-guard][BLOCK]`. The workers correctly refused `PRIVACY_GUARD_DISABLE=1` and labelled each issue `needs-maintainer-input`, so each one waited on the maintainer for a false positive.
- Reproduced against the blocked seoprostack commit using the deployed helper:
  - three-argument call (the pre-scan): `rc=1`, 62 hit lines;
  - four-argument call with the target's public default tip (the hook's view): `rc=0`, 0 hits.
- Calling `_commit_and_pr_privacy_scan` itself on that commit: the deployed library gives `rc=1` (62 block lines); the fixed library gives `rc=0`.

## Scope decision

An earlier draft of this task proposed a new same-owner sibling-repo disclosure exemption in `privacy-guard-helper.sh`. Reproduction showed it is unnecessary: the existing target-tree exemption already clears this content once the pre-scan passes the same arguments as the hook. The guard's trust boundary does not change. The public head is used only when the target is verified public (`privacy_is_target_public`) and the fetch remote is the push target, the same condition the hook applies.

## How (Approach)

- `.agents/scripts/full-loop-helper-commit.sh` `_commit_and_pr_privacy_scan`: derive `target_repo` from the push URL. When the fetch URL resolves to the same repository, resolve `refs/remotes/origin/<base>^{commit}` as `public_head`. Pass both to `privacy_scan_public_diff`.

### Files Scope

- `.agents/scripts/full-loop-helper-commit.sh`

## Acceptance Criteria

- `shellcheck .agents/scripts/full-loop-helper-commit.sh` is clean.
- Existing suites pass: `test-privacy-guard.sh`, `test-privacy-guard-shim.sh`, `tests/test-privacy-diff-fast-path.sh`, `tests/test-full-loop-closed-issue-bookkeeping.sh`. Terms absent from the target's public tree stay blocked, as already covered by the "Only a verified public tree" case in `test-privacy-guard.sh`.
- On the blocked seoprostack commit, the fixed `_commit_and_pr_privacy_scan` returns 0.
- After deploy, the three blocked starter-sync issues are released for redispatch and reach PRs without any guard bypass.
