---
description: Error checking, debugging, and feedback loops for CI/CD
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

# Error Checking and Feedback Loops

Processes for error checking, debugging, and feedback loops for autonomous CI/CD operation.

## GitHub Actions Workflow Monitoring

```bash
gh run list --limit 10                          # recent runs
gh run list --status failure --limit 5          # failed runs only
gh run view {run_id} --log-failed               # failure logs
gh run watch {run_id}                           # watch live
```

Via API:

```bash
gh api repos/{owner}/{repo}/actions/runs --jq '.workflow_runs[:5] | .[] | "\(.name): \(.conclusion // .status)"'
gh api repos/{owner}/{repo}/actions/runs/{run_id}/jobs
```

### Common GitHub Actions Errors

| Error | Solution |
|-------|----------|
| Missing action version | Update: `uses: actions/checkout@v4` |
| Deprecated action | Replace with recommended alternative |
| Secret not found | Verify secret name in repository settings |
| Permission denied | Check workflow permissions or GITHUB_TOKEN scope |
| Timeout | Increase timeout or optimize slow steps |

**Concurrency control:**

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

## Local Build and Test Feedback

```bash
npm test && npm run test:coverage   # JS/Node
pytest --cov=module/                # Python
vendor/bin/phpunit                  # PHP
go test ./...                       # Go
cargo test                          # Rust
```

### Common Local Test Errors

| Error Type | Diagnosis | Solution |
|------------|-----------|----------|
| Dependency missing | Check error for package name | `npm install` / `pip install` |
| Port in use | Check error for port number | Kill process or use different port |
| Database connection | DB not running | Start database service |
| Permission denied | File/directory access | Check permissions |

## Code Quality Tool Integration

```bash
bash ~/Git/aidevops/.agents/scripts/linters-local.sh   # universal quality check
shellcheck script.sh                                    # bash scripts
npx eslint . --format json                              # JavaScript
pylint module/ --output-format=json                     # Python
```

**Auto-fix:**

```bash
bash ~/Git/aidevops/.agents/scripts/qlty-cli.sh fmt --all
npx eslint . --fix
composer phpcbf
```

## Efficient Quality Tool Feedback via GitHub API

The GitHub Checks API provides structured access to all code quality tool feedback (Codacy, CodeFactor, SonarCloud, CodeRabbit, etc.) without visiting each tool's dashboard.

```bash
# All check runs for current commit
gh api repos/{owner}/{repo}/commits/$(git rev-parse HEAD)/check-runs \
  --jq '.check_runs[] | {name: .name, status: .status, conclusion: .conclusion}'

# Failed checks only
gh api repos/{owner}/{repo}/commits/$(git rev-parse HEAD)/check-runs \
  --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "action_required") | {name: .name, conclusion: .conclusion}'

# Line-level annotations from a check run
gh api repos/{owner}/{repo}/check-runs/{check_run_id}/annotations \
  --jq '.[] | {path: .path, line: .start_line, level: .annotation_level, message: .message}'
```

**Quick status script:**

```bash
#!/bin/bash
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
COMMIT=$(git rev-parse HEAD)
gh api "repos/$REPO/commits/$COMMIT/check-runs" \
  --jq '.check_runs[] | "\(.conclusion // .status | ascii_upcase)\t\(.name)"' | sort
```

**Tool-specific:**

```bash
# Codacy
gh api repos/{owner}/{repo}/commits/{sha}/check-runs \
  --jq '.check_runs[] | select(.app.slug == "codacy-production") | {conclusion: .conclusion, summary: .output.summary}'

# CodeRabbit
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  --jq '.[] | select(.user.login | contains("coderabbit")) | {path: .path, line: .line, body: .body}'

# SonarCloud
gh api repos/{owner}/{repo}/commits/{sha}/check-runs \
  --jq '.check_runs[] | select(.name | contains("SonarCloud")) | {conclusion: .conclusion, url: .details_url}'
```

### Processing Code Quality Feedback

1. Collect: `gh pr view {number} --comments --json comments` + `gh api repos/{owner}/{repo}/pulls/{number}/reviews`
2. Categorize: Critical (security, breaking) → High (quality violations) → Medium (style) → Low (docs)
3. Fix critical first; group related issues for efficiency

## Automated Error Resolution

```bash
# 1. Get failed workflow
gh run list --status failure --limit 1
# 2. Get failure details
gh run view {run_id} --log-failed
# 3. Apply fix, then push and monitor
git add . && git commit -m "fix: CI error description"
git push origin {branch} && gh run watch
```

### Common Fix Patterns

```bash
# Dependency issues
npm ci && npm test
composer install

# Test failures
npm test -- --grep "failing test name"
npm test -- --updateSnapshot

# Linting
npm run lint:fix
```

## When to Consult Humans

| Scenario | What to Provide |
|----------|-----------------|
| Product design decisions | Options with trade-offs |
| Security-critical changes | Security implications |
| Architectural decisions | Architecture options |
| Deployment approvals | Deployment plan |
| Ambiguous requirements | Questions and assumptions |

**Effective consultation format:** Issue summary → context (goal + what happened) → error details → attempted solutions with results → specific questions → recommendations with pros/cons.

## Contributing Fixes Upstream

```bash
cd ~/git && git clone https://github.com/owner/repo.git
cd repo && git checkout -b fix/descriptive-name
git add -A && git commit -m "Fix: Description\n\nFixes #issue-number"
gh repo fork owner/repo --clone=false --remote=true
git remote add fork https://github.com/your-username/repo.git
git push fork fix/descriptive-name
gh pr create --repo owner/repo \
  --head your-username:fix/descriptive-name \
  --title "Fix: Description" \
  --body "## Summary\nDescription.\n\nFixes #issue-number"
```
