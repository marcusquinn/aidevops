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

# CodeRabbit AI Code Review

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI-powered code review via CLI (local) and PR (GitHub/GitLab)
- **CLI Install**: `curl -fsSL https://cli.coderabbit.ai/install.sh | sh`
- **CLI Auth**: `coderabbit auth login` (browser-based OAuth)
- **Review uncommitted**: `coderabbit --plain` or `coderabbit --prompt-only`
- **Review all changes**: `coderabbit --plain --type all`
- **Compare branch**: `coderabbit --plain --base develop`
- **Helper script**: `~/.aidevops/agents/scripts/coderabbit-cli.sh`
- **PR reviews**: Automatic via CodeRabbit GitHub App on every PR
- **Docs**: https://docs.coderabbit.ai/cli/overview

## CLI Modes

| Mode | Command | Use Case |
|------|---------|----------|
| Plain | `coderabbit --plain` | Scripts, AI agents, readable output |
| Prompt-only | `coderabbit --prompt-only` | AI agent integration (minimal) |
| Interactive | `coderabbit` | Manual review with TUI |

## Review Types

| Type | Flag | Description |
|------|------|-------------|
| All | `--type all` | Committed + uncommitted (default) |
| Uncommitted | `--type uncommitted` | Only working directory changes |
| Committed | `--type committed` | Only committed changes |

## Rate Limits

- Free: 2 reviews/hour
- Pro: 8 reviews/hour
- Paid users get learnings-powered reviews from codebase history

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Install CLI
curl -fsSL https://cli.coderabbit.ai/install.sh | sh

# Restart shell or reload config
source ~/.zshrc

# Authenticate (opens browser)
coderabbit auth login
```

## Usage Examples

### Local Code Review (Before Commit)

```bash
# Review uncommitted changes (plain text for AI agents)
coderabbit --plain

# Review with minimal output for AI agent integration
coderabbit --prompt-only

# Review against specific base branch
coderabbit --plain --base develop

# Review only uncommitted changes
coderabbit --plain --type uncommitted
```

### AI Agent Integration

For Claude Code, Cursor, or other AI coding agents:

```text
Run coderabbit --prompt-only in the background, let it take as long as it needs,
and fix any critical issues it finds. Ignore nits.
```

### Helper Script

```bash
# Using aidevops helper script
~/.aidevops/agents/scripts/coderabbit-cli.sh install
~/.aidevops/agents/scripts/coderabbit-cli.sh auth
~/.aidevops/agents/scripts/coderabbit-cli.sh review              # plain mode
~/.aidevops/agents/scripts/coderabbit-cli.sh review prompt-only  # AI mode
~/.aidevops/agents/scripts/coderabbit-cli.sh review plain develop # vs develop
~/.aidevops/agents/scripts/coderabbit-cli.sh status
```

## PR-Based Reviews

CodeRabbit also provides automatic PR reviews on GitHub/GitLab:

1. Install CodeRabbit GitHub App: https://github.com/apps/coderabbitai
2. Reviews appear automatically on PRs
3. Use `@coderabbitai` commands in PR comments

## Analysis Scope

CodeRabbit analyzes:

- Race conditions, memory leaks, security vulnerabilities
- Logic errors, null pointer exceptions
- Code style and best practices
- Documentation quality

## Expected Fixes

| Category | Examples |
|----------|----------|
| Shell scripts | Variable quoting, error handling, return checks |
| Security | SQL injection, credential exposure, input validation |
| Performance | Memory leaks, inefficient loops, resource cleanup |
| Documentation | Markdown formatting, code blocks, broken links |

## Automated Reviews

CodeRabbit reviews every PR automatically via the GitHub App. No manual trigger
scripts are needed.

### Daily Code Quality Review (Multi-Tool, Multi-Repo)

The supervisor pulse runs a daily code quality sweep across ALL pulse-enabled
repos in `repos.json`. CodeRabbit is one of several tools in this sweep.

**Implementation**: `pulse-wrapper.sh` function `run_daily_quality_sweep()` runs
once per 24h (timestamp-guarded). For each repo it:

1. Ensures a persistent "Daily Code Quality Review" issue exists (labels:
   `quality-review`, `persistent`; pinned).
2. Runs all available quality tools and posts a single summary comment:
   - **ShellCheck** — local analysis of `.sh` files
   - **Qlty** — maintainability smells (if `~/.qlty/bin/qlty` installed)
   - **SonarCloud** — quality gate status + open issues (public API, no auth)
   - **Codacy** — open issues count (requires `CODACY_API_TOKEN` in gopass)
   - **CodeRabbit** — `@coderabbitai` mention triggers full codebase review
3. On the next pulse, the supervisor reads findings and creates actionable
   GitHub issues (title: `quality: <description>`, labels: `auto-dispatch`).

**Do not close the "Daily Code Quality Review" issue** in any repo — it is the
persistent trigger point for daily reviews.

**Legacy**: Issue #2386 in `marcusquinn/aidevops` was the original single-repo
CodeRabbit-only review issue. It has been superseded by the multi-repo
persistent quality review issues created by `run_daily_quality_sweep()`.

> **Archived (t1336):** `review-pulse-helper.sh`, `coderabbit-pulse-helper.sh`,
> and `coderabbit-task-creator-helper.sh` have been archived to `scripts/archived/`.
> The daily review now uses the supervisor to create issues from quality tool
> findings, replacing the old bash scripts for parsing and task creation.

## Troubleshooting

```bash
# Check CLI status
coderabbit --version

# Re-authenticate if token expired
coderabbit auth login

# Check if in git repo
git status
```

## Resources

- CLI Docs: https://docs.coderabbit.ai/cli/overview
- Claude Code Integration: https://docs.coderabbit.ai/cli/claude-code-integration
- Cursor Integration: https://docs.coderabbit.ai/cli/cursor-integration
