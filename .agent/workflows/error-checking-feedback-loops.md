# Error Checking and Feedback Loops

This document outlines processes for error checking, debugging, and establishing feedback loops for autonomous CI/CD operation.

The goal is to enable AI assistants to identify, diagnose, and fix issues with minimal human intervention.

## Table of Contents

- [GitHub Actions Workflow Monitoring](#github-actions-workflow-monitoring)
- [Local Build and Test Feedback](#local-build-and-test-feedback)
- [Code Quality Tool Integration](#code-quality-tool-integration)
- [Automated Error Resolution](#automated-error-resolution)
- [Feedback Loop Architecture](#feedback-loop-architecture)
- [When to Consult Humans](#when-to-consult-humans)

## GitHub Actions Workflow Monitoring

### Checking Workflow Status via GitHub CLI

```bash
# Get recent workflow runs
gh run list --limit 10

# Get failed runs only
gh run list --status failure --limit 5

# Get details for a specific run
gh run view {run_id}

# Get logs for a failed run
gh run view {run_id} --log-failed

# Watch a running workflow
gh run watch {run_id}
```

### Checking via GitHub API

```bash
# Get recent workflow runs
gh api repos/{owner}/{repo}/actions/runs --jq '.workflow_runs[:5] | .[] | "\(.name): \(.conclusion // .status)"'

# Get failed runs
gh api repos/{owner}/{repo}/actions/runs?status=failure

# Get jobs for a specific run
gh api repos/{owner}/{repo}/actions/runs/{run_id}/jobs
```

### Common GitHub Actions Errors and Solutions

| Error | Solution |
|-------|----------|
| Missing action version | Update to latest: `uses: actions/checkout@v4` |
| Deprecated action | Replace with recommended alternative |
| Secret not found | Verify secret name in repository settings |
| Permission denied | Check workflow permissions or GITHUB_TOKEN scope |
| Timeout | Increase timeout or optimize slow steps |
| Cache miss | Verify cache keys and paths |

#### Example Fixes

**Outdated Action:**

```yaml
# Before
uses: actions/upload-artifact@v3

# After
uses: actions/upload-artifact@v4
```

**Concurrency Control:**

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

## Local Build and Test Feedback

### Running Local Tests

```bash
# JavaScript/Node.js
npm test
npm run test:coverage

# Python
pytest
pytest --cov=module/

# PHP
composer test
vendor/bin/phpunit

# Go
go test ./...

# Rust
cargo test
```

### Capturing Test Output

```bash
# Capture output for analysis
npm test > test-output.log 2>&1

# Parse for errors
grep -i 'error\|fail\|exception' test-output.log

# Get structured results (if available)
cat test-results.json | jq '.failures'
```

### Common Local Test Errors

| Error Type | Diagnosis | Solution |
|------------|-----------|----------|
| Dependency missing | Check error for package name | `npm install` / `pip install` |
| Port in use | Check error for port number | Kill process or use different port |
| Timeout | Test takes too long | Increase timeout or optimize |
| Database connection | DB not running | Start database service |
| Permission denied | File/directory access | Check permissions, run with proper user |

## Code Quality Tool Integration

### Running Quality Checks

```bash
# Universal quality check (aidevops)
bash ~/git/aidevops/.agent/scripts/quality-check.sh

# ShellCheck (bash scripts)
shellcheck script.sh

# ESLint (JavaScript)
npx eslint . --format json

# Pylint (Python)
pylint module/ --output-format=json

# PHP CodeSniffer
composer phpcs
```

### Auto-Fixing Issues

```bash
# Codacy auto-fix
bash ~/git/aidevops/.agent/scripts/codacy-cli.sh analyze --fix

# Qlty auto-format
bash ~/git/aidevops/.agent/scripts/qlty-cli.sh fmt --all

# ESLint auto-fix
npx eslint . --fix

# PHP Code Beautifier
composer phpcbf
```

### Monitoring PR Feedback

```bash
# Get PR comments
gh pr view {pr_number} --comments

# Get PR reviews
gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews

# Get check runs for PR
gh pr checks {pr_number}
```

### Processing Code Quality Feedback

1. **Collect all feedback:**

   ```bash
   gh pr view {number} --comments --json comments
   gh api repos/{owner}/{repo}/pulls/{number}/reviews
   ```

2. **Categorize issues:**
   - Critical: Security, breaking bugs
   - High: Quality violations, potential bugs
   - Medium: Style issues, best practices
   - Low: Documentation, minor improvements

3. **Prioritize fixes:**
   - Address critical issues first
   - Group related issues for efficient fixing
   - Consider dependencies between issues

## Automated Error Resolution

### Error Resolution Workflow

```text
1. Identify Error
   ↓
2. Categorize Error (type, severity)
   ↓
3. Search for Known Solution
   ↓
4. Apply Fix
   ↓
5. Verify Fix (run tests)
   ↓
6. Document Solution
```

### Processing Workflow Failures

```bash
# 1. Get failed workflow
gh run list --status failure --limit 1

# 2. Get failure details
gh run view {run_id} --log-failed

# 3. Identify the failing step and error

# 4. Apply fix based on error type

# 5. Push fix and monitor
git add . && git commit -m "Fix: CI error description"
git push origin {branch}
gh run watch
```

### Common Fix Patterns

**Dependency Issues:**

```bash
# Update lockfile
npm ci  # or: npm install
composer install

# Clear caches
npm cache clean --force
composer clear-cache
```

**Test Failures:**

```bash
# Run specific failing test
npm test -- --grep "failing test name"

# Run with verbose output
npm test -- --verbose

# Update snapshots if intentional changes
npm test -- --updateSnapshot
```

**Linting Errors:**

```bash
# Auto-fix what's possible
npm run lint:fix

# Review remaining issues
npm run lint -- --format stylish
```

## Feedback Loop Architecture

### Complete Feedback Loop System

```text
Code Changes ──► Local Testing ──► GitHub Actions
     │                │                  │
     ▼                ▼                  ▼
AI Assistant ◄── Error Analysis ◄── Status Check
     │
     ▼
Fix Generation ──► Verification ──► Human Review (if needed)
```

### Key Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| Code Changes | Initial modifications | Git |
| Local Testing | Immediate feedback | npm test, pytest |
| GitHub Actions | Remote validation | gh CLI |
| Status Check | Monitor workflows | gh run list |
| Error Analysis | Parse and categorize | grep, jq |
| AI Assistant | Central intelligence | This guide |
| Fix Generation | Create solutions | Edit, Write tools |
| Verification | Confirm fix works | Tests, CI |
| Human Review | Complex decisions | When needed |

### Implementing the Loop

```bash
#!/bin/bash
# Continuous monitoring script pattern

check_and_fix() {
    # Check for failures - declare and assign separately per SC2155
    local failures
    failures=$(gh run list --status failure --limit 1 --json conclusion -q '.[].conclusion')
    
    if [[ "$failures" == "failure" ]]; then
        # Get failure details - declare and assign separately per SC2155
        local run_id
        local logs
        run_id=$(gh run list --status failure --limit 1 --json databaseId -q '.[].databaseId')
        logs=$(gh run view "$run_id" --log-failed)
        
        # Analyze and report
        echo "Failure detected in run $run_id"
        echo "$logs" | grep -i 'error\|fail' | head -20
        
        # Suggest fixes based on error patterns
        analyze_error "$logs"
    fi
}

analyze_error() {
    local logs="$1"
    
    if echo "$logs" | grep -q "npm ERR!"; then
        echo "Suggestion: Run 'npm ci' to reinstall dependencies"
    elif echo "$logs" | grep -q "EACCES"; then
        echo "Suggestion: Check file permissions"
    elif echo "$logs" | grep -q "timeout"; then
        echo "Suggestion: Increase timeout or optimize slow operations"
    fi
}
```

## When to Consult Humans

### Scenarios Requiring Human Input

| Scenario | Reason | What to Provide |
|----------|--------|-----------------|
| Product design decisions | Requires business context | Options with trade-offs |
| Security-critical changes | Risk assessment needed | Security implications |
| Architectural decisions | Long-term impact | Architecture options |
| Deployment approvals | Production risk | Deployment plan |
| Novel problems | No precedent | Research findings |
| External service issues | Out of control | Status and workarounds |
| Ambiguous requirements | Clarification needed | Questions and assumptions |

### Effective Human Consultation

When consulting humans, provide:

**Issue Summary:** Brief description of the problem.

**Context:**

- What were you trying to accomplish?
- What happened instead?

**Error Details:** Include specific error messages or logs.

**Attempted Solutions:**

1. Tried X - Result: Y
2. Tried Z - Result: W

**Questions:**

1. Specific question requiring human input
2. Another specific question

**Recommendations:** Based on analysis, suggest options with pros/cons and ask which approach they prefer.

### Contributing Fixes Upstream

When issues are in external dependencies:

```bash
# 1. Clone the repository
cd ~/git
git clone https://github.com/owner/repo.git
cd repo
git checkout -b fix/descriptive-name

# 2. Make and commit changes
git add -A
git commit -m "Fix: Description

Detailed explanation.
Fixes #issue-number"

# 3. Fork and push
gh repo fork owner/repo --clone=false --remote=true
git remote add fork https://github.com/your-username/repo.git
git push fork fix/descriptive-name

# 4. Create PR
gh pr create --repo owner/repo \
  --head your-username:fix/descriptive-name \
  --title "Fix: Description" \
  --body "## Summary
Description of changes.

Fixes #issue-number"
```

## Quick Reference

### Daily Monitoring Commands

```bash
# Check all workflow status
gh run list --limit 10

# Check for failures
gh run list --status failure

# View specific failure
gh run view {id} --log-failed

# Check PR status
gh pr checks

# Run local quality check
bash ~/git/aidevops/.agent/scripts/quality-check.sh
```

### Common Fix Commands

```bash
# Dependency issues
npm ci && npm test

# Linting issues
npm run lint:fix

# Type issues
npm run typecheck

# Quality issues
bash ~/git/aidevops/.agent/scripts/codacy-cli.sh analyze --fix
bash ~/git/aidevops/.agent/scripts/qlty-cli.sh fmt --all
```
