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

## Live attempt and remaining acceptance

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

**Infrastructure blocker:** the worker REST reserve prevents the required
operational measurement. Keep PR #38284 draft until the normal quota gate
admits a representative pass. Then inspect its hit/miss and distinct-miss
summary and the `collaborator-permission-rest` attempts in the API ledger.
Report a measurable reduction against the issue's 56–77 attempts/30-minute
baseline, or evidence that the remaining misses are distinct pairs, before
marking operational acceptance complete. Do not bypass the reserve.
