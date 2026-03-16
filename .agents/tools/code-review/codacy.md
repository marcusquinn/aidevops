---
description: Codacy auto-fix for code quality issues
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

# Codacy Auto-Fix Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- Auto-fix command: `bash .agents/scripts/codacy-cli.sh analyze --fix`
- Via manager: `bash .agents/scripts/quality-cli-manager.sh analyze codacy-fix`
- Fix types: Code style, best practices, security, performance, maintainability
- Safety: Non-breaking, reversible, conservative (skips ambiguous)
- Metrics: 70-90% time savings, 99%+ accuracy, 60-80% violation coverage
- Cannot fix: Complex logic, architecture, context-dependent, breaking changes
- Best practices: Always review, test after, incremental batches, clean git state
- Workflow: quality-check -> analyze --fix -> quality-check -> commit with metrics

## Quality Gate Settings

**Current gate (PR and commits):** max 10 new issues, minimum severity Warning.

**Rationale (GH#4910, t1489):** The gate was originally set to 0 max new issues. This
tripped 4x during extract-function refactoring sessions — new helper functions count as
added complexity, and subprocess calls in new functions count as new Bandit warnings.
The project grade stays A throughout; these are not real regressions. Threshold raised
to 10 Warning+ to absorb refactoring noise while still blocking genuine security/error issues.

**Do not revert to 0.** A threshold of 0 makes extract-function refactoring impossible
without manual Codacy dashboard intervention on every PR. The project grade (A) is the
meaningful quality signal, not the per-PR new-issue count.

## Local Pre-Push Checks (GH#4939)

`linters-local.sh` now includes three checks aligned with Codacy's complexity engine,
catching the same issues locally before code reaches Codacy:

| Check | Codacy equivalent | Warning | Blocking | Gate |
|-------|-------------------|---------|----------|------|
| `function-complexity` | Function length | >50 lines | >100 lines | `function-complexity` |
| `nesting-depth` | Cyclomatic complexity | >5 levels | >8 levels | `nesting-depth` |
| `file-size` | File length | >800 lines | >1500 lines | `file-size` |

These gates are set above the current baseline to catch regressions. As existing debt
is paid down (via code-simplifier issues), reduce the thresholds. The gates also cover
Python files in `.agents/scripts/` for file-size checks.

Skip via bundle config: add `"function-complexity"`, `"nesting-depth"`, or `"file-size"`
to `skip_gates` in the project bundle.

**Updating via API:**

```bash
# Update PR gate
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/organizations/gh/marcusquinn/repositories/aidevops/settings/quality/pull-requests" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"issueThreshold":{"threshold":10,"minimumSeverity":"Warning"}}'

# Update commits gate
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/organizations/gh/marcusquinn/repositories/aidevops/settings/quality/commits" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"issueThreshold":{"threshold":10,"minimumSeverity":"Warning"}}'
```

<!-- AI-CONTEXT-END -->

## Automated Code Quality Fixes

### Overview

Codacy CLI v2 provides automated fix capabilities that mirror the "Fix Issues" functionality available in the Codacy web dashboard. This feature can automatically resolve many common code quality violations without manual intervention.

### Auto-Fix Capabilities

#### Supported Fix Types

- **Code Style Issues**: Formatting, indentation, spacing
- **Best Practice Violations**: Variable naming, function structure
- **Security Issues**: Basic security pattern fixes
- **Performance Issues**: Simple optimization patterns
- **Maintainability**: Code complexity reduction where safe

#### Safety Guarantees

- **Non-Breaking**: Only applies fixes guaranteed not to break functionality
- **Reversible**: All changes can be reverted via Git
- **Conservative**: Skips ambiguous cases requiring human judgment
- **Tested**: Fixes are based on proven patterns from millions of repositories

### Usage Methods

#### Method 1: Direct CLI Usage

```bash
# Basic auto-fix analysis
bash .agents/scripts/codacy-cli.sh analyze --fix

# Auto-fix with specific tool
bash .agents/scripts/codacy-cli.sh analyze eslint --fix

# Check what would be fixed (dry-run equivalent)
bash .agents/scripts/codacy-cli.sh analyze
```

#### Method 2: Quality CLI Manager

```bash
# Auto-fix via unified manager
bash .agents/scripts/quality-cli-manager.sh analyze codacy-fix

# Status check before auto-fix
bash .agents/scripts/quality-cli-manager.sh status codacy
```

#### Method 3: Integration with Quality Workflow

```bash
# Pre-commit auto-fix workflow
bash .agents/scripts/linters-local.sh
bash .agents/scripts/codacy-cli.sh analyze --fix
bash .agents/scripts/linters-local.sh  # Verify improvements
```

### Expected Results

#### Typical Fix Categories

- **String Literals**: Consolidation into constants
- **Variable Declarations**: Proper scoping and initialization
- **Function Returns**: Adding missing return statements
- **Code Formatting**: Consistent style application
- **Import/Export**: Optimization and organization

#### Performance Impact

- **Time Savings**: 70-90% reduction in manual fix time
- **Accuracy**: 99%+ accuracy for supported fix types
- **Coverage**: Handles 60-80% of common quality violations
- **Consistency**: Uniform application across entire codebase

### Workflow Integration

#### Recommended Development Workflow

1. **Pre-Development**: Run quality check to identify issues
2. **Auto-Fix**: Apply automated fixes where available
3. **Manual Review**: Address remaining issues requiring judgment
4. **Validation**: Re-run quality checks to verify improvements
5. **Commit**: Include before/after metrics in commit message

#### CI/CD Integration

```yaml
# GitHub Actions example
- name: Auto-fix code quality issues
  run: |
    bash .agents/scripts/codacy-cli.sh analyze --fix
    git add .
    git diff --staged --quiet || git commit -m "fix: applied Codacy automated fixes"
```

### Limitations and Considerations

#### What Auto-Fix Cannot Do

- **Complex Logic**: Business logic or algorithmic changes
- **Architecture**: Structural or design pattern modifications
- **Context-Dependent**: Fixes requiring domain knowledge
- **Breaking Changes**: Modifications that could affect functionality

#### Best Practices

- **Always Review**: Check auto-applied changes before committing
- **Test After**: Run tests to ensure functionality is preserved
- **Incremental**: Apply auto-fixes in small batches for easier review
- **Backup**: Ensure clean Git state before running auto-fix

### Success Metrics

#### Quality Improvement Tracking

- **Before/After Counts**: Track violation reduction
- **Fix Success Rate**: Monitor auto-fix effectiveness
- **Time Savings**: Measure development efficiency gains
- **Quality Trends**: Long-term code quality improvements
