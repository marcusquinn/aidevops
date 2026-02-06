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
grep -L "return [01]" .agents/scripts/*.sh  # S7682
grep -n '\$[1-9]' .agents/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'  # S7679
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
grep -L "return [01]" .agents/scripts/*.sh
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
grep -n '\$[1-9]' .agents/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'
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
for file in .agents/scripts/*.sh; do
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
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;

# Validate single script
shellcheck script.sh
```

## Security Hotspots (Acceptable Patterns)

SonarCloud flags these patterns as security hotspots. They are acceptable when properly documented:

### HTTP String Detection (S5332)

When checking for insecure URLs, not using them:

```bash
# CORRECT - Detection with comment
# SONAR: Detecting insecure URLs for security audit, not using them
non_https=$(echo "$data" | jq '[.items[] | select(.url | startswith("http://"))] | length')

# INCORRECT - No documentation
non_https=$(echo "$data" | jq '[.items[] | select(.url | startswith("http://"))] | length')
```

### Localhost HTTP Output (S5332)

Local development environments often lack SSL:

```bash
# CORRECT - Intentional localhost HTTP
if [[ "$ssl" == "true" ]]; then
    print_info "Access your app at: https://$domain"
else
    # SONAR: Local dev without SSL is intentional
    print_info "Access your app at: http://$domain"
fi
```

### Curl Pipe to Bash (S4423)

For official installers from verified sources:

```bash
# CORRECT - Documented official installer
# SONAR: Official Bun installer from verified HTTPS source
curl -fsSL https://bun.sh/install | bash

# BETTER - Download and inspect first (for new/unknown sources)
curl -fsSL https://example.com/install.sh -o /tmp/install.sh
less /tmp/install.sh  # Review script
bash /tmp/install.sh
```

**When to suppress vs fix:**

- **Suppress**: Official installers (bun, nvm, rustup), localhost dev, URL detection
- **Fix**: Actual HTTP usage in production, unverified installer sources

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

## Markdown Standards

All markdown files must pass markdownlint with zero violations.

### MD022 - Headings Surrounded by Blank Lines

Headings MUST have blank lines before AND after them.

```markdown
<!-- CORRECT - Blank lines around headings -->
Some content here.

### Heading Title

Content after heading.

<!-- INCORRECT - Missing blank line after heading -->
Some content here.

### Heading Title
Content after heading.  <!-- This causes MD022 violation -->
```

### MD025 - Single Top-Level Heading

Each document should have only ONE H1 (`#`) heading.

```markdown
<!-- CORRECT - Single H1 -->
# Document Title

## Section One

## Section Two

<!-- INCORRECT - Multiple H1s -->
# First Title

# Second Title  <!-- This causes MD025 violation -->
```

### MD012 - No Multiple Blank Lines

Use only single blank lines between elements.

```markdown
<!-- CORRECT - Single blank lines -->
Paragraph one.

Paragraph two.

<!-- INCORRECT - Multiple blank lines -->
Paragraph one.


Paragraph two.  <!-- This causes MD012 violation -->
```

### MD031 - Fenced Code Blocks Surrounded by Blank Lines

Code blocks MUST have blank lines before AND after them.

````markdown
<!-- CORRECT - Blank lines around code blocks -->
Some text.

```bash
echo "hello"
```

More text.

<!-- INCORRECT - Missing blank line -->
Some text.
```bash
echo "hello"
```
````

**Validation**:

```bash
# Lint all markdown files
npx markdownlint-cli2 "**/*.md" --ignore node_modules

# Lint specific file
npx markdownlint-cli2 "path/to/file.md"

# Auto-fix issues
npx markdownlint-cli2 "**/*.md" --fix
```

## Pre-Commit Checklist

Before committing, verify:

```bash
# 1. Run local linting
~/.aidevops/agents/scripts/linters-local.sh

# 2. Check return statements
grep -L "return [01]" .agents/scripts/*.sh

# 3. Check positional parameters
grep -n '\$[1-9]' .agents/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'

# 4. Run ShellCheck
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;

# 5. Check for secrets
~/.aidevops/agents/scripts/secretlint-helper.sh scan

# 6. Lint markdown files
npx markdownlint-cli2 "**/*.md" --ignore node_modules
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
