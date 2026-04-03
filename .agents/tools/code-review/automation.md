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

- **Check**: `bash .agents/scripts/linters-local.sh` — S7679, S1481, S1192, S7682, ShellCheck, returns
- **Fix**: `bash .agents/scripts/quality-fix.sh [file|dir]` — missing returns, positional params, ShellCheck basics
- **Format**: `bash .agents/scripts/markdown-formatter.sh .` — trailing whitespace, list markers, Codacy violations
- **Platforms**: `bash .agents/scripts/quality-cli-manager.sh install|analyze|status all` (CodeRabbit, Codacy, SonarScanner)
- **Achievement**: 349 → 42 issues (88% reduction), A-grade across CodeFactor, Codacy

<!-- AI-CONTEXT-END -->

## Pre-Commit Workflow

```bash
bash .agents/scripts/linters-local.sh          # check
bash .agents/scripts/quality-fix.sh .          # fix
bash .agents/scripts/markdown-formatter.sh .   # format
bash .agents/scripts/linters-local.sh          # verify
```

## Specialized Fix Scripts

| Script | Targets | Creates |
|--------|---------|---------|
| `fix-content-type.sh` | `"Content-Type: application/json"` (24+ occurrences) | `readonly CONTENT_TYPE_JSON` |
| `fix-auth-headers.sh` | `"Authorization: Bearer"` patterns | `readonly AUTH_BEARER_PREFIX` |
| `fix-error-messages.sh` | `Unknown command:`, `Usage:` patterns | Error message constants |

## Quality Metrics & Targets

- **SonarCloud thresholds** (from `linters-local.sh`): `MAX_TOTAL_ISSUES=100`, `MAX_RETURN_ISSUES=10`, `MAX_POSITIONAL_ISSUES=300`, `MAX_STRING_LITERAL_ISSUES=2300`
- **Critical**: S7679 & S1481 = 0 (100% resolved); 50+ S1192 violations eliminated

## Issue Resolution Priority

1. **Critical (S7679, S1481)** — immediate
2. **High (S1192)** — target 3+ occurrences for maximum impact
3. **Medium (S7682)** — systematic function standardization
4. **Low (ShellCheck)** — style and best practice improvements

Rules: batch similar patterns; never remove features to fix issues; always verify fixes don't break functionality.
