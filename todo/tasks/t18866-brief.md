<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t18866: profile README publication sweep still preserves clean trees on macOS after #36721

Ref: GH#36741. Residual from GH#36715.

## What

PR #36721 (merged 2026-11-04T23:49Z, `86456a192e`) fixed the two `legacy profile recovery retains source and canonical files` cases. One macOS case in `.agents/scripts/tests/test-profile-readme-boundary.sh` still fails at a base that includes #36721 (`07801b21cb`): `profile update sweeps earlier clean publication trees and preserves dirty ones`. The suite result is 29/30.

## Why (evidence)

Captured output (2026-11-05T02:02Z, macOS):

```text
FAIL profile update sweeps earlier clean publication trees and preserves dirty ones
     expected only the dirty earlier tree to remain (a=profile-repo-profile-readme-<stamp-a> b=profile-repo-profile-readme-<stamp-b>)
     | Profile publication sweep: retired 0 earlier worktree(s); 2 preserved for guarded recovery
```

The sweep keeps the clean earlier publication tree as well as the dirty one. Before #36721, the legacy-recovery cases failed with `producer:evidence-unavailable; cause=stderr/unclassified`. The sweep probably still goes through a producer or archive path that #36721 did not cover (unverified). On real macOS hosts, clean profile publication worktrees would then pile up instead of being retired.

### Files Scope

- `.agents/scripts/tests/test-profile-readme-boundary.sh`
- `.agents/scripts/profile-readme-helper.sh`
- `.agents/scripts/worktree_archive_deletions.py`
- `.agents/scripts/worktree_recovery_retire.py`

## How

1. Run only the sweep case on macOS (system Python 3.9) and capture the producer stderr for the clean tree it preserves.
2. Compare it with the #36721 fix in `.agents/scripts/worktree_archive_deletions.py`, and apply the same Python 3.9 or macOS portability repair to the path the sweep uses.
3. Change the fixture only if the product behaviour is correct.

## Acceptance

- `bash .agents/scripts/tests/test-profile-readme-boundary.sh` passes 30/30 on macOS and on Linux CI.

## Verification

```bash
bash .agents/scripts/tests/test-profile-readme-boundary.sh
```
