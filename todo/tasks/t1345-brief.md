# t1345: Fix markdown-formatter MCP tool -- 100% error rate

## Session Origin

Issue #2440, session-miner pulse 2026-02-27 (131 signals, 6/6 failures).

## What

Fix the markdown-formatter MCP tool which had a 100% error rate across all uses.

## Why

Every agent call to markdown-formatter failed, wasting tool calls and preventing markdown quality checks. The build.txt error prevention guidance was based on an incorrect root cause diagnosis, perpetuating the problem.

## How

### Root Cause (three bugs)

1. **Action mismatch**: MCP tool exposed `["format", "lint", "fix", "check"]` but bash script only handled `["format", "advanced", "cleanup", "help"]`. Actions `lint`, `check`, `fix` hit the `*` default case and returned exit 1.

2. **Return value bug**: `fix_markdown_file()` returned `$changes_made` (1 when changes were made). With `set -euo pipefail`, returning 1 = failure. Dead `return 0` on next line was unreachable.

3. **MCP wrapper**: Used `Bun.$\`...\`.text()` which throws `ShellError` on non-zero exit, so agents never saw the output.

### Files Changed

- `.agents/scripts/markdown-formatter.sh` -- Added `lint`/`check`/`fix` actions, fixed return value bug
- `.agents/scripts/markdown-lint-fix.sh` -- Fixed same return value bug in `apply_manual_fixes()`
- `.opencode/tool/markdown-formatter.ts` -- Use `Bun.spawn()` to capture output on non-zero exit
- `.agents/prompts/build.txt` -- Updated error prevention section with correct root cause

## Acceptance Criteria

- [x] Root cause of 100% failure rate identified (two bugs + wrapper issue)
- [x] All MCP actions (format, fix, lint, check) return exit 0 on success
- [x] ShellCheck zero violations on both scripts
- [x] build.txt updated with correct diagnosis
- [ ] Session miner shows improvement in next pulse (post-merge verification)
