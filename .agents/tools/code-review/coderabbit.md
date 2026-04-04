---
description: CodeRabbit AI code review - CLI and PR integration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# CodeRabbit AI Code Review

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI-powered code review via CLI (local) and PR (GitHub/GitLab)
- **CLI Install**: `curl -fsSL https://cli.coderabbit.ai/install.sh | sh` then `coderabbit auth login`
- **Helper script**: `~/.aidevops/agents/scripts/coderabbit-cli.sh [install|auth|review|status]`
- **PR reviews**: Automatic via [CodeRabbit GitHub App](https://github.com/apps/coderabbitai) on every PR (`@coderabbitai` in comments)
- **Rate limits**: Free 2/hr, Pro 8/hr (learnings-powered)
- **Docs**: https://docs.coderabbit.ai/cli/overview

## CLI Usage

| Mode | Command | Use Case |
|------|---------|----------|
| Plain | `coderabbit --plain` | Scripts, AI agents |
| Prompt-only | `coderabbit --prompt-only` | AI agent integration (minimal output) |
| Interactive | `coderabbit` | Manual review with TUI |

**Review scope flags:** `--type all` (default, committed + uncommitted), `--type uncommitted`, `--type committed`. Compare branch: `--base develop`.

**AI agent integration:** `coderabbit --prompt-only` in background, fix critical issues, ignore nits.

**Helper script commands:**

```bash
coderabbit-cli.sh install                # install CLI
coderabbit-cli.sh auth                   # browser OAuth
coderabbit-cli.sh review                 # plain mode review
coderabbit-cli.sh review prompt-only     # AI agent mode
coderabbit-cli.sh review plain develop   # compare vs develop
coderabbit-cli.sh status                 # check CLI status
```

**Analyzes:** race conditions, memory leaks, security vulnerabilities, logic errors, code style, documentation quality. Typical fixes: variable quoting, error handling, SQL injection, credential exposure, resource cleanup, markdown formatting.

<!-- AI-CONTEXT-END -->

## Daily Code Quality Review (Multi-Tool, Multi-Repo)

The supervisor pulse runs a daily code quality sweep across ALL pulse-enabled repos in `repos.json`. CodeRabbit is one of several tools in this sweep.

**Implementation**: `pulse-wrapper.sh` function `run_daily_quality_sweep()` runs once per 24h (timestamp-guarded). For each repo it:

1. Ensures a persistent "Daily Code Quality Review" issue exists (labels: `quality-review`, `persistent`; pinned).
2. Runs all available quality tools and posts a single summary comment:
   - **ShellCheck** — local analysis of `.sh` files
   - **Qlty** — maintainability smells (if `~/.qlty/bin/qlty` installed)
   - **SonarCloud** — quality gate status + open issues (public API, no auth)
   - **Codacy** — open issues count (requires `CODACY_API_TOKEN` in gopass)
   - **CodeRabbit** — `@coderabbitai` mention triggers full codebase review
3. On the next pulse, the supervisor reads findings and creates actionable GitHub issues (title: `quality: <description>`, labels: `auto-dispatch`).

**Do not close the "Daily Code Quality Review" issue** in any repo — it is the persistent trigger point for daily reviews.

**Legacy**: Issue #2386 in `marcusquinn/aidevops` was the original single-repo CodeRabbit-only review issue. Superseded by multi-repo persistent quality review issues from `run_daily_quality_sweep()`.

> **Archived (t1336):** `review-pulse-helper.sh`, `coderabbit-pulse-helper.sh`, and `coderabbit-task-creator-helper.sh` archived to `scripts/archived/`. The daily review now uses the supervisor to create issues from quality tool findings.

## Resources

- CLI Docs: https://docs.coderabbit.ai/cli/overview
- Claude Code Integration: https://docs.coderabbit.ai/cli/claude-code-integration
- Cursor Integration: https://docs.coderabbit.ai/cli/cursor-integration
