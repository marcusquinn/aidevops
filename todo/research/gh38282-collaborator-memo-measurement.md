<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# GH#38282 collaborator memo measurement

## Reproduced loss and focused verification

The existing process-only memo loses writes made by command substitution.
The cache suite now exercises a substitution followed by a parent lookup for
the same key: without the optional memo file it makes two requests; with the
per-run file it makes one, recording `hits=1 misses=1`. This is controlled
runtime evidence, not a production 30-minute quota measurement.

The continuation preserves the draft instrumentation and adds per-run sharing
in `shared-gh-collaborator-permission.sh` and lifecycle ownership in
`pulse-merge-routine.sh`. It does not add a cross-run TTL. A fresh run observes
changed permissions. Failed/deferred lookups are not stored. File acceptance
requires a regular, owned non-symlink path physically under the temp root.

Verification on 2026-11-15:

- Cache suite: 29 assertions pass, including the loss/reuse comparison,
  failure/defer handling, unsafe paths and next-run permission changes.
- Standalone suite: 37/37 pass, including run/dry-run sharing, summary and EXIT
  cleanup after failure. Run with `env -u AIDEVOPS_GH_PR_VIEW_CACHE_DIR` so the
  worker's inherited absolute cache path does not invalidate the existing
  isolated-HOME cache-directory assertion.
- Timeout suite: 9/9 pass.
- Current-user permission suite passes; approval guard: 14/14 pass.
- Bash syntax, shell portability, mktemp portability, whitespace and pre-commit
  quality ratchets pass for the changed scripts.
- Local ShellCheck binary is unavailable. Covering CI job: Code Quality
  Analysis / ShellCheck (ubuntu-latest), delegated under GH#34758.

## Initial live attempt

The local worktree routine was invoked with `--dry-run --repo
marcusquinn/aidevops`. Initial attempts skipped the scheduled routine's lock;
the scheduled run was not interrupted. The final attempt acquired that lock
at **2026-11-15T00:16:17Z**, then the existing quota gate deferred the pass:

```text
[pulse-budget] Deferring optional REST work at worker reserve (698/5000, reserve=20%)
[WARN] Worker REST reserve reached; deferring optional merge routine
[INFO] collab_memo hits=0 misses=0
[INFO] collab_memo distinct_miss_keys=0
```

The runner log confirms live summary emission, but no permission lookup was
admitted. Zero lookups are not evidence of memo effectiveness or distinct-pair
volume. No 30-minute production reduction is claimed.

**Initial infrastructure blocker, resolved below:** the worker REST reserve
prevented the operational measurement. The PR stayed draft until a normal
quota-admitted pass could establish either the requested reduction or
distinct-pair remaining misses. The reserve was not bypassed.

## Continuation verification

At 2026-11-15T00:59Z, PR #38284 still pointed to
`2c54f12f5baaf303e16d4b8440da7bfd66b5cfd4`. Its reported CI checks were
successful or skipped, including the previously delegated
[ShellCheck job](https://github.com/marcusquinn/aidevops/actions/runs/43657626428/job/132641209895)
and
[Bash 3.2 compatibility job](https://github.com/marcusquinn/aidevops/actions/runs/43657626428/job/132641209859).
The cache suite's 29 assertions and standalone suite's 37/37 checks passed
again using the commands above. No implementation changes were needed for
this continuation.

### Scope correction for measurement

The admitted `--dry-run --repo marcusquinn/aidevops` passes at
01:07:05–01:07:09Z and 01:17:25–01:17:30Z completed with zero lookups. A further
attempt at 01:20:33Z deferred at 311/5000. The authoritative rate probe at
01:21:36Z reported 259 remaining and reset epoch 1794706054. After waiting for
that reset, a pass at 01:27:36–01:27:41Z again completed with zero lookups.
None of those zero samples proves effectiveness.

The empty scoped runs have a separate configuration explanation:
`pulse-merge-routine.sh` synthesizes a `--repo` entry without `role` or
`maintainer`. `get_repo_role_by_slug` in `pulse-repo-meta.sh` conservatively
defaults that entry to contributor for a non-owner runner, before any
collaborator permission lookup. The authenticated user was verified as
`vladimirdulov`, not the repo owner. The operator's real target entry explicitly
configures that user as maintainer and has `role=maintainer`.

For a valid bounded measurement, copy only the existing target entry into a
private `REPOS_JSON` file, verify JSON equality with the source entry, and use
the normal `--dry-run` path without `--repo`. Point
`PULSE_MERGE_CHECKPOINT_FILE` and `PULSE_MERGE_PR_CURSOR_FILE` at private scratch
paths to avoid changing the scheduled pass's cursor. This preserves configured
authority; it does not substitute for the live collaborator permission check
or bypass quota admission. Temporary provenance and execution-line diagnostics
were removed, leaving the implementation identical to the published head.

### Follow-up brief: preserve scoped repo metadata

The pre-existing `--repo` metadata loss is outside this memo-sharing change.
No additional issue was opened under the bounded continuation contract.

- Files: `pulse-merge-routine.sh` single-repo entry construction and the
  existing `tests/test-pulse-merge-routine-standalone.sh` suite.
- Pattern: preserve the matching configured entry's role/maintainer metadata
  when narrowing scope; keep unknown repos conservative. Never infer elevated
  authority from the CLI slug or remove `repo_allows_pulse_write_actions`.
- Verification: configured non-owner maintainer reaches the live permission
  gate; unknown/contributor repos remain blocked; an explicit repo filter never
  includes another repo. Run the existing standalone suite and ShellCheck.

## Successful live candidate measurement

The unchanged candidate implementation ran against the live target repository
from **2026-11-15T01:40:11Z to 01:44:02Z**, after acquiring the normal routine
lock and passing normal quota admission. It used the target's existing
configuration as described above, with private cursor/checkpoint files and
`--dry-run`; no global installation or release was performed.

Runner receipt:

```text
[2026-11-15T01:40:11Z] [INFO] DRY-RUN mode: merge routine (pid=863961, timeout=600s)
[2026-11-15T01:44:02Z] [INFO] DRY-RUN merge routine completed (exit=0)
[2026-11-15T01:44:02Z] [INFO] collab_memo hits=0 misses=3
[2026-11-15T01:44:02Z] [INFO] collab_memo distinct_miss_keys=3
```

The API ledger was filtered to the inclusive epoch window
`1794706811..1794707042`, consumer `pulse-merge-routine.sh`, stage
`collaborator-permission-rest`, and event `attempt`. It contains exactly:

| Attempt epoch | HTTP status |
| --- | --- |
| 1794706813 | 200 |
| 1794706959 | 200 |
| 1794706979 | 200 |

Later scheduled-run attempts at epochs 1794707056 and 1794707060 were excluded.
During the run, the owned scratch memo contained a successful write verdict;
after exit, `test ! -e <observed-run-scratch-directory>` succeeded, confirming
that both memo and stats were removed.

**Acceptance conclusion:** this sample meets the issue's distinct-pair evidence
alternative: all three remaining permission misses are distinct `(repo, login)`
keys, with three successful REST attempts and no repeated miss in this run.
There were no live hits, so this sample alone does not demonstrate API savings.
The existing mirrored test independently proves that a repeated substitution
lookup is reused with one request instead of two. No 30-minute reduction is
extrapolated from this single configured-repo dry-run. The prior quota blocker
is cleared for this measurement; operational evidence is sufficient to mark
the draft ready, with issue closure linked to the PR's eventual merge.
