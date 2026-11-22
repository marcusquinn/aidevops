## What

`test-enrich-dedup-guard.sh` fails intermittently in "dry-run predicts forced parent-task enrichment". The test runs under `set -uo pipefail` and checks `_enrich_process_task ... 2>&1 | grep -q 'Would enrich'`. `grep -q` exits on the first match, so the writer's next line (`ENRICHED`) can hit a closed pipe. The writer then exits 141 (SIGPIPE), and `pipefail` reports the pipeline as failed even though the text matched. The fix captures the output first, so the result no longer depends on timing.

## Why

The "Affected script suites (advisory)" job reported this suite as a `regression` (head rc 1, base rc 0) on PR #38960. The failure repeated on rerun, although that PR does not touch the enrich path. The investigation used about 30 minutes of interactive time. Evidence, 2026-11-18:

- The PR head, the PR merge ref and the base (`0e53da6b7f`) all fail the same assertion when exported outside Git. The head passes in a linked worktree on macOS and on Linux arm64. The result depends on timing, not on the change under test.
- Replaying the same call 5 times with `grep -q` gave `PIPESTATUS=141 0` three times and `0 0` twice. Called directly, the call always prints `[DRY-RUN] Would enrich #123 (t30021)` and returns 0.
- `pipe-early-exit-check.sh --scan-files .agents/scripts/tests/test-enrich-dedup-guard.sh` flagged both dry-run checks. The gate checks only changed lines, so these lines from before the gate (GH#30289) were never swept.

## How

- `EDIT: .agents/scripts/tests/test-enrich-dedup-guard.sh`: both dry-run checks capture the helper output into `_dry_run_output` first, then match with a here-string (`grep -q -- 'Would enrich' <<<"$_dry_run_output"`). This is the pattern in `.agents/reference/shell-style-guide.md` § Early-Exit Pipe Readers (SIGPIPE). The first check still expects no `Would enrich` line. The second still requires exit 0 plus the line, as the pipeline did when no SIGPIPE occurred.

### Files Scope

- .agents/scripts/tests/test-enrich-dedup-guard.sh
- todo/tasks/t19093-brief.md
- TODO.md

## Acceptance Criteria

- [ ] `pipe-early-exit-check.sh --scan-files .agents/scripts/tests/test-enrich-dedup-guard.sh` reports no violations.
- [ ] The suite passes 42/42 on 10 consecutive runs, both in a linked worktree and when exported outside Git.
- [ ] ShellCheck is clean for the test file.

## Verification

- `bash .agents/scripts/pipe-early-exit-check.sh --scan-files .agents/scripts/tests/test-enrich-dedup-guard.sh`
- `for i in 1 2 3 4 5 6 7 8 9 10; do bash .agents/scripts/tests/test-enrich-dedup-guard.sh | tail -n 2 | head -n 1; done`
- `shellcheck .agents/scripts/tests/test-enrich-dedup-guard.sh`
