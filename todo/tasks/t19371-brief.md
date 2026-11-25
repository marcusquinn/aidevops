## What

`full-loop-helper.sh commit-and-pr` runs the Platform Fix Regression Evidence
gate (`_commit_and_pr_platform_evidence_gate`, GH#39136) only after the native
macOS suites (`macos_checks_evidence`). Check the gate before those suites so a
missing `--regression-evidence` rationale fails in seconds, not after the full
macOS run. Keep the existing final gate as the authoritative check.

## Why (evidence, 2026-11-25)

- t19368 / GH#40332 (sandbox change, title contains `macOS`, no test file
  changed) ran `commit-and-pr` on a loaded macOS runner. All macOS suites passed
  after ~31 minutes (`op_1795604312182`, 1,859 s elapsed), then the gate
  refused: `Platform Fix Regression Evidence would fail in CI ... Nothing was
  pushed.` The rerun with `--regression-evidence` must repeat the whole suite.
- The gate's verdict cannot depend on the macOS suites. It reads the title, the
  changed paths, and body prose outside `Files Changed`/`Testing`/`Runtime
  Testing`/`Regression Evidence` headings
  (`platform-fix-regression-evidence.sh` `_platform_trigger_text`). The suites
  only append to `summary_testing`, which renders under `## Runtime Testing`.
- Every macOS-sensitive PR (`macos_checks_sensitive` paths: sandbox, platform
  detect, git guards, setup, ...) whose title or summary names a platform term
  and changes no test hits this, interactive sessions and workers alike.

## How

File: `.agents/scripts/full-loop-helper.sh`, `_commit_and_pr_prepare_metadata`.

1. Resolve `pr_title` (the existing `_compose_pr_title` /
   `_validate_explicit_pr_title` block) before `macos_checks_evidence`.
2. Add `_commit_and_pr_platform_evidence_preflight <pr_title>
   <comparison_base>` that builds a subset body from the same prose the final
   body renders in gate-visible sections (`## Summary` = `summary_what`,
   `## Decisions` = `summary_decisions`, `## Regression Evidence` =
   `summary_regression`). It then calls the existing
   `_commit_and_pr_platform_evidence_gate`. All of that prose appears in the
   final body under the same headings, so a preflight failure implies a final
   failure. It must never refuse a body the final gate would accept.
3. Call it before `macos_checks_evidence`. Keep
   `_commit_and_pr_prepare_metadata` at or under 100 lines (the function-length
   gate in `linters-local.sh`).
4. Tests that `eval` `_commit_and_pr_prepare_metadata` must also load the new
   helper: `test-full-loop-closed-issue-bookkeeping.sh` (extract_function list)
   and `test-full-loop-runtime-risk.sh` (sed eval list).

Reference pattern: the existing gate call at the end of
`_commit_and_pr_prepare_metadata` and the GH#39136 helper in
`full-loop-helper-commit.sh`.

### Files Scope

- `.agents/scripts/full-loop-helper.sh`
- `.agents/scripts/tests/test-full-loop-closed-issue-bookkeeping.sh`
- `.agents/scripts/tests/test-full-loop-runtime-risk.sh`

## Acceptance

- With a macOS-sensitive diff, a platform term in the title, no test change and
  no `--regression-evidence`, commit-and-pr fails with the existing gate error
  before any `macOS suite:` line is printed.
- With `--regression-evidence` (or a changed test), behaviour is unchanged: the
  suites run and the final gate passes.
- Existing suites pass: `test-full-loop-closed-issue-bookkeeping.sh`,
  `test-full-loop-runtime-risk.sh`, `test-platform-fix-regression-evidence.sh`.
- `shellcheck` clean on changed files.

## Verification

```bash
shellcheck .agents/scripts/full-loop-helper.sh
bash .agents/scripts/tests/test-full-loop-closed-issue-bookkeeping.sh
bash .agents/scripts/tests/test-full-loop-runtime-risk.sh
bash .agents/scripts/tests/test-platform-fix-regression-evidence.sh
```
