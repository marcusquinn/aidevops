---
description: Automated quality checks and CI/CD integration
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Quality Automation Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- Master script: `bash .agents/scripts/linters-local.sh` (multi-platform validation)
- Fix script: `bash .agents/scripts/quality-fix.sh [file|dir]`
- SonarCloud rules: S7679 (positional params), S1481 (unused vars), S1192 (strings), S7682 (returns)
- Specialized fixes:
  - `fix-content-type.sh` — Content-Type header constants (S1192)
  - `fix-auth-headers.sh` — Authorization header patterns
  - `fix-error-messages.sh` — Error message consolidation
  - `markdown-formatter.sh` — Markdown linting/formatting
- CLI manager: `bash .agents/scripts/quality-cli-manager.sh install|analyze|status all`
- Platform CLIs: CodeRabbit, Codacy, SonarScanner
- Achievement: 349 → 42 issues (88% reduction), A-grade platforms

<!-- AI-CONTEXT-END -->

## Core Scripts

| Script | Purpose | Key checks |
|--------|---------|------------|
| `linters-local.sh` | Multi-platform validation | S7679, S1481, S1192, S7682, ShellCheck, return statements |
| `quality-fix.sh [file\|dir]` | Auto-fix common issues | Missing returns, positional params, ShellCheck basics |
| `markdown-formatter.sh` | Markdown formatting | Trailing whitespace, list markers, Codacy violations |
| `markdown-lint-fix.sh` | markdownlint-cli integration | `.markdownlint.json` config, auto-install |

## Specialized Fix Scripts

| Script | Targets | Creates |
|--------|---------|---------|
| `fix-content-type.sh` | `"Content-Type: application/json"` (24+ occurrences) | `readonly CONTENT_TYPE_JSON` |
| `fix-auth-headers.sh` | `"Authorization: Bearer"` patterns | `readonly AUTH_BEARER_PREFIX` |
| `fix-error-messages.sh` | `Unknown command:`, `Usage:` patterns | Error message constants |

## Platform CLIs

```bash
# Install / analyze / status all platforms
bash .agents/scripts/quality-cli-manager.sh install all
bash .agents/scripts/quality-cli-manager.sh analyze all
bash .agents/scripts/quality-cli-manager.sh status all

# Individual platforms
bash .agents/scripts/coderabbit-cli.sh review
bash .agents/scripts/codacy-cli.sh analyze
bash .agents/scripts/sonarscanner-cli.sh analyze
```

## Pre-Commit Workflow

```bash
bash .agents/scripts/linters-local.sh          # check
bash .agents/scripts/quality-fix.sh .          # fix
bash .agents/scripts/markdown-formatter.sh .   # format
bash .agents/scripts/linters-local.sh          # verify
```

## Quality Metrics & Targets

- **SonarCloud**: 349 → 42 issues (88% reduction)
- **Critical**: S7679 & S1481 = 0 (100% resolved); 50+ S1192 violations eliminated
- **Platform ratings**: A-grade across CodeFactor, Codacy

```bash
# linters-local.sh thresholds
readonly MAX_TOTAL_ISSUES=100
readonly MAX_RETURN_ISSUES=0
readonly MAX_POSITIONAL_ISSUES=0
readonly MAX_STRING_LITERAL_ISSUES=0
```

## Issue Resolution Priority

1. **Critical (S7679, S1481)** — immediate
2. **High (S1192)** — target 3+ occurrences for maximum impact
3. **Medium (S7682)** — systematic function standardization
4. **Low (ShellCheck)** — style and best practice improvements

Rules: batch similar patterns; never remove features to fix issues; always verify fixes don't break functionality.
