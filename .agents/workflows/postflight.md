---
description: Verify release health after tag and GitHub release
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

# Postflight Verification Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Verify release health after `release.md` completes
- **Trigger**: After tag creation and GitHub release publication
- **Timeouts**: CI/CD 10 min, code review tools 5 min
- **Commands**:
  - `gh run list --workflow=code-quality.yml --limit=5`
  - `gh api repos/{owner}/{repo}/commits/{sha}/check-runs`
  - `.agents/scripts/linters-local.sh`
- **Rollback**: See [Rollback Procedures](#rollback-procedures)

<!-- AI-CONTEXT-END -->

Postflight catches issues that pre-release checks miss: CI/CD failures triggered by the release tag, delayed code review analysis (CodeRabbit, Codacy, SonarCloud), security vulnerabilities detected post-merge, and integration issues only visible in production-like environments.

## Critical: Avoiding Circular Dependencies

Always exclude the postflight workflow itself when checking CI/CD status:

```bash
SELF_NAME="Verify Release Health"
gh api repos/{owner}/{repo}/commits/{sha}/check-runs \
  --jq "[.check_runs[] | select(.status != \"completed\" and .name != \"$SELF_NAME\")] | length"
```

## Checking Both Main and Tag Workflows

After a release, workflows run on two refs:

```bash
gh run list --branch=main --limit=5          # Main branch workflows
gh run list --branch=v{VERSION} --limit=5    # Tag-triggered workflows
gh run list --limit=10 --json name,status,conclusion,headBranch  # All recent
```

## Postflight Checklist

### 1. CI/CD Pipeline Status

| Check | Command | Expected |
|-------|---------|----------|
| GitHub Actions | `gh run list --limit=5` | All passing |
| Tag workflows | `gh run list --workflow=code-quality.yml` | Success |
| Version validation | `gh run list --workflow=version-validation.yml` | Success |

### 2. Code Quality Tools

| Tool | Threshold |
|------|-----------|
| SonarCloud | No new bugs, vulnerabilities, or code smells |
| Codacy | Grade maintained (A/B) |
| CodeRabbit | No blocking issues |
| Qlty | No new violations |

### 3. Security Scanning

| Tool | Threshold |
|------|-----------|
| Snyk | No new high/critical vulnerabilities |
| Secretlint | No exposed secrets |
| npm audit | No high/critical issues |
| Dependabot | No new alerts |

## Verification Commands

```bash
# GitHub Actions status
gh run list --limit=10
gh run list --workflow=code-quality.yml --limit=5
gh run list --workflow=postflight.yml --limit=1  # Verify postflight.yml itself passed
gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status

# SonarCloud
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" | jq '.projectStatus.status'
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&ps=1" | jq '.total'

# Codacy
./.agents/scripts/codacy-cli.sh status

# Security
./.agents/scripts/snyk-helper.sh test
secretlint "**/*" --format compact
npm audit --audit-level=high
```

**Important**: When running postflight locally after a release:
1. Wait for the GH Actions `postflight.yml` workflow to complete first
2. Only declare success if ALL workflows (including `postflight.yml`) passed

## Postflight Script

```bash
#!/bin/bash
set -euo pipefail
TIMEOUT_CI=600; POLL_INTERVAL=30; MAX_ATTEMPTS=20

echo "=== Postflight Verification === $(date)"

# 1. CI/CD
RUN_ID=$(gh run list --limit=1 --json databaseId -q '.[0].databaseId')
STATUS=$(gh run list --limit=1 --json status -q '.[0].status')
[[ "$STATUS" == "in_progress" || "$STATUS" == "queued" ]] && \
  timeout $TIMEOUT_CI gh run watch "$RUN_ID" --exit-status
CONCLUSION=$(gh run view "$RUN_ID" --json conclusion -q '.conclusion')
[[ "$CONCLUSION" != "success" ]] && { gh run view "$RUN_ID" --log-failed; exit 1; }
echo "CI/CD: PASSED"

# 2. SonarCloud
SONAR_STATUS=$(curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" | jq -r '.projectStatus.status')
[[ "$SONAR_STATUS" != "OK" ]] && echo "WARNING: SonarCloud: $SONAR_STATUS" || echo "SonarCloud: PASSED"

# 3. Security
command -v snyk &>/dev/null && \
  (snyk test --severity-threshold=high --json 2>/dev/null | jq -e '.vulnerabilities | length == 0' >/dev/null \
    && echo "Snyk: PASSED" || echo "WARNING: Snyk found vulnerabilities") || echo "Snyk: SKIPPED"

command -v secretlint &>/dev/null && \
  (secretlint "**/*" --format compact 2>/dev/null && echo "Secretlint: PASSED" || { echo "ERROR: secrets found"; exit 1; }) \
  || echo "Secretlint: SKIPPED"

echo "=== Postflight Complete === $(date)"
```

## Automated Postflight (GitHub Actions)

```yaml
# .github/workflows/postflight.yml
name: Postflight Verification
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag: { description: 'Tag to verify', required: false }

jobs:
  postflight:
    name: Verify Release Health
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
    - uses: actions/checkout@v4
      with:
        ref: ${{ github.event.inputs.tag || github.ref }}
        fetch-depth: 0

    - name: Wait for CI/CD
      env: { GH_TOKEN: "${{ secrets.GITHUB_TOKEN }}" }
      run: |
        sleep 60
        for i in {1..20}; do
          PENDING=$(gh api repos/${{ github.repository }}/commits/${{ github.sha }}/check-runs \
            --jq '[.check_runs[] | select(.status != "completed")] | length')
          [[ "$PENDING" == "0" ]] && break
          echo "Waiting for $PENDING check runs... ($i/20)"; sleep 30
        done

    - name: Verify CI/CD
      env: { GH_TOKEN: "${{ secrets.GITHUB_TOKEN }}" }
      run: |
        FAILED=$(gh api repos/${{ github.repository }}/commits/${{ github.sha }}/check-runs \
          --jq '[.check_runs[] | select(.conclusion == "failure")] | length')
        [[ "$FAILED" != "0" ]] && { echo "::error::$FAILED check runs failed"; exit 1; }
        echo "All CI/CD checks passed"

    - name: SonarCloud Quality Gate
      run: |
        STATUS=$(curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" \
          | jq -r '.projectStatus.status')
        [[ "$STATUS" != "OK" ]] && echo "::warning::SonarCloud: $STATUS" || echo "SonarCloud: PASSED"

    - name: Security Scan
      env: { SNYK_TOKEN: "${{ secrets.SNYK_TOKEN }}" }
      continue-on-error: true
      run: |
        npm install -g snyk
        snyk auth ${{ secrets.SNYK_TOKEN }} || true
        snyk test --severity-threshold=high || echo "::warning::Security vulnerabilities found"

    - name: Check for Secrets
      continue-on-error: true
      run: |
        npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
        secretlint "**/*" --format compact || { echo "::error::Potential secrets detected"; exit 1; }

    - name: Generate Report
      if: always()
      env: { GH_TOKEN: "${{ secrets.GITHUB_TOKEN }}" }
      run: |
        echo "## Postflight Report" >> $GITHUB_STEP_SUMMARY
        echo "**Release**: ${{ github.event.release.tag_name || github.ref_name }}" >> $GITHUB_STEP_SUMMARY
        echo "**Commit**: ${{ github.sha }}" >> $GITHUB_STEP_SUMMARY
        echo "### CI/CD Status" >> $GITHUB_STEP_SUMMARY
        gh api repos/${{ github.repository }}/commits/${{ github.sha }}/check-runs \
          --jq '.check_runs[] | "- **\(.name)**: \(.conclusion // .status)"' >> $GITHUB_STEP_SUMMARY
```

## Rollback Procedures

### Severity Assessment

| Severity | Indicators | Action |
|----------|------------|--------|
| **Critical** | Security vulnerability, data loss, service outage | Immediate rollback |
| **High** | Broken functionality, failed tests, quality gate failure | Rollback within 1 hour |
| **Medium** | Minor regressions, code smell increase | Hotfix in next release |
| **Low** | Style issues, documentation gaps | Fix in next release |

### Rollback Commands

```bash
# Option A: Revert the release commit
git revert <release-commit-hash> && git push origin main

# Option B: Delete tag and release (if not widely distributed)
gh release delete v{VERSION} --yes
git tag -d v{VERSION} && git push origin --delete v{VERSION}

# Option C: Hotfix release
git checkout -b hotfix/v{VERSION}.1
# Fix the issue
git commit -m "fix: resolve critical issue from v{VERSION}"
./.agents/scripts/version-manager.sh release patch
```

### Post-Rollback Verification

```bash
gh run list --limit=5
./.agents/scripts/linters-local.sh
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" | jq '.projectStatus.status'
```

## Handling SonarCloud Quality Gate Failures

### Security Hotspots (Most Common)

Security hotspots require **individual human review**, not blanket dismissal:

```bash
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=marcusquinn_aidevops&status=TO_REVIEW" | \
  jq '{total: .paging.total, by_rule: ([.hotspots[] | .ruleKey] | group_by(.) | map({rule: .[0], count: length}))}'
```

For each hotspot: open SonarCloud Security Hotspots page, review individually, mark as **Safe** (with comment), **Fixed** (code change), or **Acknowledged** (accepted risk with justification).

**Common patterns in aidevops:**

| Rule | Typical Resolution |
|------|--------------------|
| `shell:S5332` | Mark Safe: "Localhost HTTP is intentional for local dev servers" |
| `shell:S6505` | Mark Safe: "Postinstall scripts required for package setup" |
| `shell:S6506` | Mark Safe: "Installing from trusted npm registry" |

**Why NOT to blanket-dismiss**: Real vulnerabilities hide among false positives; audit trails require documented decisions.

### Bugs, Vulnerabilities, or Code Smells

```bash
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&types=BUG,VULNERABILITY" | \
  jq '.issues[] | {type, severity, message, file: .component}'
```

Fix in code, not dismissed, unless clear false positives.

## Worktree Cleanup

```bash
~/.aidevops/agents/scripts/worktree-helper.sh list
~/.aidevops/agents/scripts/worktree-helper.sh clean  # Auto-detects squash merges
```

## Related Workflows

- `release.md` - Pre-release and release process
- `code-review.md` - Code review guidelines
- `version-bump.md` - Version management
- `worktree.md` - Parallel branch development
