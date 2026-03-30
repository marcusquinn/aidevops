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

- Methodology: Zero technical debt through systematic resolution
- Core principle: Enhance functionality, never delete to fix issues
- Priority order: S7679 (critical) → S1481 → S1192 → S7682 → ShellCheck
- S7679 fix: `printf 'Price: %s50/month\n' '$'` — not `echo "Price: $50/month"`
- S1481 fix: Enhance variable usage or remove if truly unused
- S1192 fix: `readonly CONSTANT="repeated string"` at file top
- Key scripts: `linters-local.sh`, `quality-fix.sh`, `quality-cli-manager.sh`
- Achievement: 349 → 42 issues (88% reduction), 100% critical resolved
- Success criteria: Zero S7679/S1481, <10 S1192, 100% feature retention

<!-- AI-CONTEXT-END -->

> Supplementary to [AGENTS.md](../AGENTS.md). AGENTS.md takes precedence on conflicts.

## Core Principles

1. **Enhance, never delete** — fix violations by adding value, not removing functionality
2. **Priority order** — S7679 → S1481 → S1192 → S7682 → ShellCheck
3. **Automation-first** — batch-process violations; build quality gates into workflow

## Issue Resolution Patterns

### S7679 — Positional Parameters (RESOLVED)

Shell interprets `$50`, `$200` as positional parameters.

```bash
# ❌ BEFORE
echo "Price: $50/month"

# ✅ AFTER
printf 'Price: %s50/month\n' '$'
```

### S1481 — Unused Variables (RESOLVED)

Prefer enhancing usage over removal.

```bash
# ❌ BEFORE
local port; read -r port

# ✅ AFTER
local port; read -r port
if [[ -n "$port" && "$port" != "22" ]]; then ssh -p "$port" "$host"; else ssh "$host"; fi
```

### S1192 — String Literals (major progress)

Repeated literals (3+ occurrences) → `readonly` constant.

```bash
# ❌ BEFORE
curl -H "Content-Type: application/json"  # × 3

# ✅ AFTER
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
curl -H "$CONTENT_TYPE_JSON"  # × 3
```

## Tools & Scripts

| Tool | Purpose |
|------|---------|
| `linters-local.sh` | Multi-platform quality validation |
| `fix-content-type.sh` | Content-Type header consolidation |
| `fix-auth-headers.sh` | Authorization header standardization |
| `fix-error-messages.sh` | Common error message constants |
| `markdown-formatter.sh` | Markdown quality compliance |
| `quality-cli-manager.sh` | Unified CLI management (CodeRabbit, Codacy, SonarScanner) |

## Success Criteria

| Metric | Target |
|--------|--------|
| S7679, S1481 violations | 0 |
| S1192 violations | <10 |
| ShellCheck critical per file | <5 |
| Feature retention | 100% |
| SonarCloud issues | 42 (from 349, 88% reduction) |
