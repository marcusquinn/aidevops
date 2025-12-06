---
description: Documented code quality standards for compliance checking
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Code Standards - Quality Rules Reference

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Reference documentation for code quality standards
- **Platforms**: SonarCloud, CodeFactor, Codacy, ShellCheck
- **Target**: A-grade across all platforms, zero critical violations

**Critical Rules (Zero Tolerance)**:

| Rule | Description | Pattern |
|------|-------------|---------|
| S7682 | Explicit return statements | `return 0` or `return 1` in every function |
| S7679 | No direct positional params | `local param="$1"` not `$1` directly |
| S1192 | Constants for repeated strings | `readonly MSG="text"` for 3+ uses |
| S1481 | No unused variables | Remove or use declared variables |
| ShellCheck | Zero violations | All scripts pass `shellcheck` |

**Validation Commands**:

```bash
# Run local linting
~/.aidevops/agents/scripts/linters-local.sh

# Check specific rules
grep -L "return [01]" .agent/scripts/*.sh  # S7682
grep -n '\$[1-9]' .agent/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'  # S7679
```

**Workflow Position**: Reference during development, validated by `/linters-local`

<!-- AI-CONTEXT-END -->

## Purpose

This document defines the **authoritative code quality standards** for the aidevops framework. Use this as a reference during development to ensure compliance.

**Related commands**:
- `/linters-local` - Validates these standards locally
- `/code-audit-remote` - Validates via external services
- `/pr` - Orchestrates all checks

## Critical Standards (Zero Tolerance)

### S7682 - Return Statements

Every function MUST have an explicit `return 0` or `return 1`.

```bash
# CORRECT - Always explicit return
function_name() {
    local param="$1"
    # Function logic
    return 0  # MANDATORY
}

# INCORRECT - Missing return statement
function_name() {
    local param="$1"
    # Function logic
}  # This causes S7682 violation
```

**Validation**:

```bash
grep -L "return [01]" .agent/scripts/*.sh
```

### S7679 - Positional Parameters

NEVER use positional parameters directly. Always assign to local variables first.

```bash
# CORRECT - Local variable assignment
main() {
    local command="${1:-help}"
    local account_name="$2"
    local target="$3"

    case "$command" in
        "list")
            list_items "$account_name"  # Use local variable
            ;;
    esac
    return 0
}

# INCORRECT - Direct positional parameter usage
main() {
    case "$1" in  # This causes S7679 violation
        "list")
            list_items "$2"  # This causes S7679 violation
            ;;
    esac
}
```

**Validation**:

```bash
grep -n '\$[1-9]' .agent/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'
```

### S1192 - String Literals

Define constants for strings used 3 or more times.

```bash
# CORRECT - Constants at file top
readonly ERROR_ACCOUNT_REQUIRED="Account name is required"
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly SUCCESS_OPERATION_COMPLETE="Operation completed successfully"

# Use constants instead of literals
print_error "$ERROR_ACCOUNT_REQUIRED"
print_error "$ERROR_CONFIG_NOT_FOUND"

# INCORRECT - Repeated string literals
print_error "Account name is required"  # Repeated 3+ times
print_error "Account name is required"  # Causes S1192 violation
```

**Validation**:

```bash
for file in .agent/scripts/*.sh; do
    echo "=== $file ==="
    grep -o '"[^"]*"' "$file" | sort | uniq -c | sort -nr | head -5
done
```

### S1481 - Unused Variables

Only declare variables that are actually used.

```bash
# CORRECT - Only used variables
function_name() {
    local used_param="$1"
    echo "$used_param"
    return 0
}

# INCORRECT - Unused variable declaration
function_name() {
    local used_param="$1"
    local unused_param="$2"  # This causes S1481 violation
    echo "$used_param"
    return 0
}
```

### ShellCheck Compliance

All shell scripts must pass ShellCheck with zero violations.

```bash
# Validate all scripts
find .agent/scripts/ -name "*.sh" -exec shellcheck {} \;

# Validate single script
shellcheck script.sh
```

## Platform Targets

### SonarCloud

| Metric | Target |
|--------|--------|
| Quality Gate | Passed |
| Bugs | 0 |
| Vulnerabilities | 0 |
| Code Smells | <50 |
| Technical Debt | <400 minutes |
| Security Rating | A |
| Reliability Rating | A |
| Maintainability Rating | A |

### CodeFactor

| Metric | Target |
|--------|--------|
| Overall Grade | A |
| A-grade Files | >85% |
| Critical Issues | 0 |

### Codacy

| Metric | Target |
|--------|--------|
| Grade | A |
| Security Issues | 0 |
| Error Prone | 0 |

## Pre-Commit Checklist

Before committing, verify:

```bash
# 1. Run local linting
~/.aidevops/agents/scripts/linters-local.sh

# 2. Check return statements
grep -L "return [01]" .agent/scripts/*.sh

# 3. Check positional parameters
grep -n '\$[1-9]' .agent/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'

# 4. Run ShellCheck
find .agent/scripts/ -name "*.sh" -exec shellcheck {} \;

# 5. Check for secrets
~/.aidevops/agents/scripts/secretlint-helper.sh scan
```

## Quality Scripts

| Script | Purpose |
|--------|---------|
| `linters-local.sh` | Run all local quality checks |
| `quality-fix.sh` | Auto-fix common issues |
| `pre-commit-hook.sh` | Git pre-commit validation |
| `secretlint-helper.sh` | Secret detection |

## Current Status

**Multi-Platform Excellence Achieved:**

- **SonarCloud**: A-grade maintained
- **CodeFactor**: A-grade overall
- **Codacy**: Enterprise-grade compliance
- **Critical Issues**: S7679 & S1481 = 0 (RESOLVED)

## Related Documentation

- **Local linting**: `scripts/linters-local.sh`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Unified PR review**: `workflows/pr.md`
- **Automation guide**: `tools/code-review/automation.md`
- **Best practices**: `tools/code-review/best-practices.md`
