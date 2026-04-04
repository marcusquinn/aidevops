<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1386: Post-Merge Review Feedback Scanner

## Session Origin

Interactive session, 2026-03-03. Discovered during t1385 code quality review fixes — after actioning review feedback on PR #2784, observed that ~84% of merged PRs have review comments that were never actioned. Sampled 50 recent PRs: 42 had review comments. Extrapolating to 1,636 total merged PRs = ~1,374 PRs with potentially unactioned feedback.

## What

A `scan-merged` command for `quality-feedback-helper.sh` that systematically scans merged PRs for unactioned review feedback and creates GitHub issues for workers to fix.

## Why

Review bots (CodeRabbit, Gemini Code Assist) post valuable feedback on PRs — security vulnerabilities, code quality issues, best practice violations. Currently this feedback is lost after merge because nobody goes back to check it. The t1385 review fixes proved this is a real problem: critical command injection vulnerabilities were flagged by reviewers but never fixed until we manually went through the comments.

## How

### quality-feedback-helper.sh changes

- New `cmd_scan_merged()` function with flags: `--repo`, `--batch N`, `--create-issues`, `--min-severity`, `--json`
- `_scan_single_pr()` helper: fetches inline review comments (`/pulls/{pr}/comments`) and review bodies (`/pulls/{pr}/reviews`), extracts severity from known patterns (Gemini SVG markers: `security-critical.svg`, `critical.svg`, `high-priority.svg`, `medium-priority.svg`; CodeRabbit labels), checks if affected files still exist on HEAD via tree API
- `_create_quality_debt_issues()` helper: groups findings by file, creates one issue per file with `quality-debt` label, deduplicates against existing open issues
- State tracking: `~/.aidevops/logs/review-scan-state-{slug}.json` stores scanned PR numbers to avoid re-processing
- Fixed argument parsing bug in `main()` (was using stale `$_arg1` variable inside while loop instead of `$1`)

### pulse-wrapper.sh integration

- Section 6 added to `_quality_sweep_for_repo()`: calls `quality-feedback-helper.sh scan-merged --repo <slug> --batch 10 --create-issues --json`
- Results included in the daily quality sweep comment on the persistent quality review issue
- `SCRIPT_DIR` variable added for helper script discovery

### pulse.md (supervisor dispatch guidance)

- Quality-debt concurrency cap: `quality-debt` issues may consume at most 30% of `MAX_WORKERS` slots
- Added to priority order as priority 7 (above oldest issues, below smaller/simpler tasks)
- Calculation: `QUALITY_DEBT_MAX = floor(MAX_WORKERS * 0.30)`, minimum 1

## Acceptance Criteria

1. `quality-feedback-helper.sh scan-merged --repo <slug> --batch 5` runs without error and outputs scan results
2. `--json` flag produces valid JSON with `scanned`, `findings`, `issues_created`, `details` fields
3. `--create-issues` creates GitHub issues with `quality-debt` label
4. Re-running the same command skips already-scanned PRs (state file works)
5. Files that no longer exist on HEAD are filtered out of findings
6. ShellCheck passes on both modified scripts (quality-feedback-helper.sh, pulse-wrapper.sh)
7. pulse-wrapper.sh daily sweep includes the scanner as section 6
8. pulse.md includes 30% concurrency cap guidance for quality-debt dispatch

## Context

- GitHub issue: #2785
- Worktree: `~/Git/aidevops-feature-t1386-review-scanner`
- Branch: `feature/t1386-review-scanner`
- Related: t1385 (chat platform agents — the review feedback that triggered this), PR #2784 (manual review fixes)
- Review bot comment formats: Gemini uses `<details>` blocks with SVG severity markers; CodeRabbit uses inline suggestions with severity labels
