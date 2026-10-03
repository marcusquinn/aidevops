<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

## What

Accept authoritative `SKIPPED` required-check results in full-loop readiness while
continuing to block failed, cancelled, unknown, pending and drifted evidence.

## Why

Documentation-only PRs intentionally skip non-applicable source gates. GitHub
permits these completed checks, but the full-loop wrapper labels every bucket
other than `pass` a terminal failure. This prevents a valid planning PR from
finishing without a forbidden raw merge.

## Reproducer

**Symptom command:** `bash .agents/scripts/full-loop-helper.sh pre-merge-gate 33450 marcusquinn/aidevops`

**Actual output:** `[ERROR] PR #33450 has terminal required-check failures at the current head`

- Reproduced on main `45b6fdf609` against PR head
  `40fb6e6ca33a6700445cbc235a52dbc58bc636ff`, before the candidate repair.
- `gh pr checks 33450 --repo marcusquinn/aidevops --required --json name,bucket,state,link`
  returns four passing required checks and two `bucket=skipping,state=SKIPPED`
  results: Framework Validation and Complexity Analysis. No required check failed.
- The cancelled older optional maintainer job is not the cause; diagnosis must
  use the selected required set, not the entire historical status rollup.

## How

Update `_full_loop_verify_pr_readiness` in
`.agents/scripts/full-loop-helper-commit.sh` at the `non_passing` jq predicate.
Accept only the exact completed skipped state in the matching bucket, in addition
to existing passes. Keep required-context discovery, exact-head verification,
unknown-read, pending, review, authority and merge guards unchanged.

Reference pattern: `passish` in `.agents/scripts/full-loop-helper-merge.sh`
already recognizes skipped terminal checks. Extend the existing fixtures in
`.agents/scripts/tests/test-full-loop-remote-evidence.sh`; no new runner or interface.

## Acceptance Criteria

- The existing remote-evidence test accepts a selected SKIPPED required check.
- Required cancellation, failure, unknown skipping state and pending still block.
- ShellCheck, bash syntax, existing remote-evidence suite and affected gates pass.
- The committed worktree helper verifies PR #33450 without a gate bypass.

## Files Scope

- EDIT: .agents/scripts/full-loop-helper-commit.sh
- EDIT: .agents/scripts/tests/test-full-loop-remote-evidence.sh
