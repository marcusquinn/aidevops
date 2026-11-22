## What

`release_snapshot_sources` must resolve a merged squash commit whose GitHub commit-to-PR association is missing. Use the PR number in the commit subject as a hint, and accept it only when that PR's own GitHub record names this exact commit as its merge commit on the release branch. Every other case stays fail-closed.

## Why

Releases are blocked. On 2026-11-18, `aidevops release patch 38929 incremental` stopped at `release-run-capture-authorization` with `jq: error: ambiguous or unmerged snapshot commit`. The commit was `f20bbfcabf` ("GH#38872: … (#38890)"). PR #38890 is `MERGED` into `main` with `mergeCommit.oid` exactly `f20bbfcabf3a65c94ce49913ee73d1c2263f44e0`. Yet `repos/marcusquinn/aidevops/commits/f20bbfcabf/pulls` returns `[]`, as does GraphQL `associatedPullRequests`, more than 3 hours after the merge. Search by SHA returns only #38900, which contains the commit but did not introduce it.

The commit landed after v3.39.225 was cut from its parent `132062a7d9`, so every snapshot release includes it until the release is fixed. No retry can succeed while GitHub's association stays missing.

## How

- EDIT: `.agents/scripts/release-snapshot-helper.sh` `release_snapshot_sources` (~line 152-183).
  - Compute the filtered merged-PR list first, then branch on its length:
    - 1 → current behaviour.
    - more than 1 → fail closed (ambiguous).
    - 0 → new `_release_snapshot_hinted_record`.
  - The hint helper extracts PR numbers from the subject (`(#N)` and `Merge pull request #N`). It reads each hinted PR through `_release_snapshot_gh_read … pr view N --json state,mergedAt,mergeCommit,baseRefName`.
  - It accepts only `state == MERGED`, `mergedAt != null`, `baseRefName == branch` and `mergeCommit.oid == commit`. Two distinct verified hints fail closed, and a read failure fails closed. Mark the check `#aidevops:trust-boundary`.
  - The existing ancestry checks and the second `pr view` verification still run on the hinted record.
- EDIT: `.agents/scripts/tests/test-release-snapshot-helper.sh`. Keep the existing `empty` association case fail-closed (its subjects have no hint). Add:
  - a hinted subject with a matching PR merge commit, which is accepted;
  - a hinted subject whose PR names a different merge commit, which is rejected (a forged hint on a direct push).

### Files Scope

- `.agents/scripts/release-snapshot-helper.sh`
- `.agents/scripts/tests/test-release-snapshot-helper.sh`

## Acceptance

- The `v3.39.225..origin/main` snapshot resolves, with `f20bbfcabf` mapped to PR #38890.
- A commit with no association and no subject hint, or with a hint whose PR merge commit differs, still fails closed.
- A direct push to `main` cannot be laundered into a release by writing `(#N)` in its subject.

## Verification

```bash
bash .agents/scripts/tests/test-release-snapshot-helper.sh
bash .agents/scripts/tests/test-release-provenance-helper.sh
shellcheck .agents/scripts/release-snapshot-helper.sh .agents/scripts/tests/test-release-snapshot-helper.sh
# Live read-only resolution of the blocked range:
bash -c 'source .agents/scripts/release-snapshot-helper.sh && release_snapshot_sources marcusquinn/aidevops main "$(git rev-parse 132062a7d9)" "$(git rev-parse origin/main)"'
```
