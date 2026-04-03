---
description: Quality management and monitoring specification
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

# Quality Management Specification

<!-- AI-CONTEXT-START -->

## Quick Reference

- Goal: zero technical debt through systematic resolution
- Rule: enhance functionality; never delete behavior to silence a warning
- Priority: S7679 (critical) → S1481 → S1192 → S7682 → ShellCheck
- S7679: `printf 'Price: %s50/month\n' '$'`, not `echo "Price: $50/month"`
- S1481: improve variable usage before deleting; do not remove to silence
- S1192: lift repeated literals (3+) to top-level `readonly` constants
- Key scripts: `linters-local.sh`, `quality-fix.sh`, `quality-cli-manager.sh`
- Baseline: 349 → 42 issues (88% reduction), 100% critical resolved
- Targets: zero S7679/S1481, <10 S1192, 100% feature retention

<!-- AI-CONTEXT-END -->

> Supplementary to [AGENTS.md](../AGENTS.md). AGENTS.md takes precedence on conflicts.

## Core Rules

1. **Enhance, never delete** — fix violations by adding value, not removing behavior.
2. **Use the priority order** — resolve S7679 before S1481, then S1192, S7682, ShellCheck.
3. **Automate first** — batch fixes; keep quality gates in the workflow.

## Fix Patterns

| Issue | Root cause | Fix |
|-------|-----------|-----|
| S7679 | Shell expands `$50`/`$200` as positional params | `printf 'Price: %s50/month\n' '$'` |
| S1481 | Unused variable | Add meaningful usage (e.g., conditional branch) before considering removal |
| S1192 | String literal repeated 3+ times | `readonly CONTENT_TYPE_JSON="Content-Type: application/json"` |

## Tools

| Tool | Purpose |
|------|---------|
| `linters-local.sh` | Multi-platform quality validation |
| `quality-fix.sh` | Batch automated fixes |
| `fix-content-type.sh` | Consolidate `Content-Type` headers |
| `fix-auth-headers.sh` | Standardize authorization headers |
| `fix-error-messages.sh` | Extract common error-message constants |
| `markdown-formatter.sh` | Enforce Markdown quality |
| `quality-cli-manager.sh` | Manage CodeRabbit, Codacy, and SonarScanner |

## Success Criteria

| Metric | Target |
|--------|--------|
| S7679 and S1481 violations | 0 |
| S1192 violations | <10 |
| ShellCheck critical findings per file | <5 |
| Feature retention | 100% |
| SonarCloud issues | 42 (down from 349, 88% reduction) |
