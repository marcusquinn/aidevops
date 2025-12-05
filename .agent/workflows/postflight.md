# Postflight Verification Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Verify release health after `release.md` completes
- **Trigger**: After tag creation and GitHub release publication
- **Timeout**: 10 minutes for CI/CD, 5 minutes for code review tools
- **Mode**: Manual by default, can be automated via GitHub Actions
- **Commands**:
  - `gh run list --workflow=code-quality.yml --limit=5`
  - `gh api repos/{owner}/{repo}/commits/{sha}/check-runs`
  - `.agent/scripts/quality-check.sh`
- **Rollback**: See [Rollback Procedures](#rollback-procedures)

<!-- AI-CONTEXT-END -->

This workflow monitors CI/CD pipelines and code review feedback AFTER a release is published. It ensures no regressions, security issues, or quality degradations were introduced.

## Overview

Postflight verification is the final gate after release. While pre-release checks catch most issues, postflight catches:

- CI/CD failures triggered by the release tag
- Delayed code review tool analysis (CodeRabbit, Codacy, SonarCloud)
- Security vulnerabilities detected post-merge
- Integration issues only visible in production-like environments

## Postflight Checklist

### 1. CI/CD Pipeline Status

| Check | Command | Expected |
|-------|---------|----------|
| GitHub Actions | `gh run list --limit=5` | All workflows passing |
| Tag-triggered workflows | `gh run list --workflow=code-quality.yml` | Success status |
| Version validation | `gh run list --workflow=version-validation.yml` | Success status |

### 2. Code Quality Tools

| Tool | Check Method | Threshold |
|------|--------------|-----------|
| SonarCloud | API or dashboard | No new bugs, vulnerabilities, or code smells |
| Codacy | Dashboard or CLI | Grade maintained (A/B) |
| CodeRabbit | PR comments | No blocking issues |
| Qlty | CLI check | No new violations |

### 3. Security Scanning

| Tool | Check Method | Threshold |
|------|--------------|-----------|
| Snyk | `snyk test` | No new high/critical vulnerabilities |
| Secretlint | `secretlint "**/*"` | No exposed secrets |
| npm audit | `npm audit` | No high/critical issues |
| Dependabot | GitHub Security tab | No new alerts |

## Verification Commands

### Check GitHub Actions Status

```bash
# List recent workflow runs
gh run list --limit=10

# Check specific workflow
gh run list --workflow=code-quality.yml --limit=5

# Get detailed status for latest run
gh run view $(gh run list --limit=1 --json databaseId -q '.[0].databaseId')

# Check all workflows for a specific commit/tag
gh api repos/{owner}/{repo}/commits/{sha}/check-runs --jq '.check_runs[] | {name, status, conclusion}'

# Wait for workflows to complete (with timeout)
gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status
```

### Check SonarCloud Status

```bash
# Get project quality gate status
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" | jq '.projectStatus.status'

# Get current issues count
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&ps=1" | jq '.total'

# Get detailed metrics
curl -s "https://sonarcloud.io/api/measures/component?component=marcusquinn_aidevops&metricKeys=bugs,vulnerabilities,code_smells,security_hotspots" | jq '.component.measures'

# Compare with previous analysis
curl -s "https://sonarcloud.io/api/measures/search_history?component=marcusquinn_aidevops&metrics=bugs,vulnerabilities&ps=2" | jq '.measures'
```

### Check Codacy Status

```bash
# Using Codacy CLI (if configured)
./.agent/scripts/codacy-cli.sh status

# Check via API (requires CODACY_API_TOKEN)
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://api.codacy.com/api/v3/organizations/gh/marcusquinn/repositories/aidevops" | jq '.data.grade'
```

### Check Security Status

```bash
# Run Snyk security scan
./.agent/scripts/snyk-helper.sh test

# Check for secrets
secretlint "**/*" --format compact

# npm audit (if applicable)
npm audit --audit-level=high

# Full security scan
./.agent/scripts/snyk-helper.sh full
```

### Comprehensive Postflight Script

```bash
#!/bin/bash
# postflight-check.sh - Run all postflight verifications

set -euo pipefail

TIMEOUT_CI=600      # 10 minutes for CI/CD
TIMEOUT_TOOLS=300   # 5 minutes for code review tools
POLL_INTERVAL=30    # Check every 30 seconds

echo "=== Postflight Verification ==="
echo "Started: $(date)"
echo ""

# 1. Check GitHub Actions
echo "--- CI/CD Pipeline Status ---"
LATEST_RUN=$(gh run list --limit=1 --json databaseId,status,conclusion -q '.[0]')
RUN_ID=$(echo "$LATEST_RUN" | jq -r '.databaseId')
STATUS=$(echo "$LATEST_RUN" | jq -r '.status')

if [[ "$STATUS" == "in_progress" || "$STATUS" == "queued" ]]; then
    echo "Waiting for workflow $RUN_ID to complete..."
    timeout $TIMEOUT_CI gh run watch "$RUN_ID" --exit-status || {
        echo "ERROR: CI/CD pipeline failed or timed out"
        exit 1
    }
fi

CONCLUSION=$(gh run view "$RUN_ID" --json conclusion -q '.conclusion')
if [[ "$CONCLUSION" != "success" ]]; then
    echo "ERROR: CI/CD pipeline conclusion: $CONCLUSION"
    gh run view "$RUN_ID" --log-failed
    exit 1
fi
echo "CI/CD: PASSED"

# 2. Check SonarCloud
echo ""
echo "--- SonarCloud Status ---"
SONAR_STATUS=$(curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" | jq -r '.projectStatus.status')
if [[ "$SONAR_STATUS" != "OK" ]]; then
    echo "WARNING: SonarCloud quality gate: $SONAR_STATUS"
    curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&severities=BLOCKER,CRITICAL&ps=10" | jq '.issues[] | {rule, message, component}'
else
    echo "SonarCloud: PASSED"
fi

# 3. Check for new security issues
echo ""
echo "--- Security Status ---"
if command -v snyk &> /dev/null; then
    if snyk test --severity-threshold=high --json 2>/dev/null | jq -e '.vulnerabilities | length == 0' > /dev/null; then
        echo "Snyk: PASSED (no high/critical vulnerabilities)"
    else
        echo "WARNING: Snyk found high/critical vulnerabilities"
        snyk test --severity-threshold=high
    fi
else
    echo "Snyk: SKIPPED (not installed)"
fi

# 4. Check Secretlint
if command -v secretlint &> /dev/null; then
    if secretlint "**/*" --format compact 2>/dev/null; then
        echo "Secretlint: PASSED"
    else
        echo "ERROR: Secretlint found potential secrets"
        exit 1
    fi
else
    echo "Secretlint: SKIPPED (not installed)"
fi

echo ""
echo "=== Postflight Verification Complete ==="
echo "Finished: $(date)"
```

## Automated Postflight (GitHub Actions)

Add this workflow to run postflight checks automatically after releases:

```yaml
# .github/workflows/postflight.yml
name: Postflight Verification

on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to verify'
        required: false

jobs:
  postflight:
    name: Verify Release Health
    runs-on: ubuntu-latest
    timeout-minutes: 15
    
    steps:
    - name: Checkout
      uses: actions/checkout@v4
      with:
        ref: ${{ github.event.inputs.tag || github.ref }}
        fetch-depth: 0
    
    - name: Wait for CI/CD Pipelines
      run: |
        echo "Waiting for all check runs to complete..."
        sleep 60  # Initial wait for workflows to start
        
        # Poll for completion
        for i in {1..20}; do
          PENDING=$(gh api repos/${{ github.repository }}/commits/${{ github.sha }}/check-runs \
            --jq '[.check_runs[] | select(.status != "completed")] | length')
          
          if [[ "$PENDING" == "0" ]]; then
            echo "All check runs completed"
            break
          fi
          
          echo "Waiting for $PENDING check runs... (attempt $i/20)"
          sleep 30
        done
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    
    - name: Verify CI/CD Status
      run: |
        FAILED=$(gh api repos/${{ github.repository }}/commits/${{ github.sha }}/check-runs \
          --jq '[.check_runs[] | select(.conclusion == "failure")] | length')
        
        if [[ "$FAILED" != "0" ]]; then
          echo "::error::$FAILED check runs failed"
          gh api repos/${{ github.repository }}/commits/${{ github.sha }}/check-runs \
            --jq '.check_runs[] | select(.conclusion == "failure") | "FAILED: \(.name)"'
          exit 1
        fi
        
        echo "All CI/CD checks passed"
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    
    - name: Check SonarCloud Quality Gate
      run: |
        STATUS=$(curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" \
          | jq -r '.projectStatus.status')
        
        if [[ "$STATUS" != "OK" ]]; then
          echo "::warning::SonarCloud quality gate status: $STATUS"
          
          # Get new issues since last analysis
          curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&createdAfter=$(date -d '1 hour ago' -Iseconds)&ps=10" \
            | jq '.issues[] | "[\(.severity)] \(.message) (\(.component))"'
        else
          echo "SonarCloud quality gate: PASSED"
        fi
    
    - name: Security Scan
      run: |
        # Install Snyk
        npm install -g snyk
        
        # Run security scan
        snyk auth ${{ secrets.SNYK_TOKEN }} || true
        snyk test --severity-threshold=high || echo "::warning::Security vulnerabilities found"
      env:
        SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
      continue-on-error: true
    
    - name: Check for Secrets
      run: |
        npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
        secretlint "**/*" --format compact || {
          echo "::error::Potential secrets detected in codebase"
          exit 1
        }
      continue-on-error: true
    
    - name: Generate Postflight Report
      if: always()
      run: |
        echo "## Postflight Verification Report" >> $GITHUB_STEP_SUMMARY
        echo "" >> $GITHUB_STEP_SUMMARY
        echo "**Release**: ${{ github.event.release.tag_name || github.ref_name }}" >> $GITHUB_STEP_SUMMARY
        echo "**Commit**: ${{ github.sha }}" >> $GITHUB_STEP_SUMMARY
        echo "**Time**: $(date -u)" >> $GITHUB_STEP_SUMMARY
        echo "" >> $GITHUB_STEP_SUMMARY
        
        # Add check run summary
        echo "### CI/CD Status" >> $GITHUB_STEP_SUMMARY
        gh api repos/${{ github.repository }}/commits/${{ github.sha }}/check-runs \
          --jq '.check_runs[] | "- **\(.name)**: \(.conclusion // .status)"' >> $GITHUB_STEP_SUMMARY
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    
    - name: Notify on Failure
      if: failure()
      run: |
        echo "::error::Postflight verification failed for release ${{ github.event.release.tag_name }}"
        echo "Review the logs and consider rollback if critical issues found."
```

## Timeout Strategy

| Phase | Timeout | Rationale |
|-------|---------|-----------|
| CI/CD completion | 10 min | Most workflows complete in 5-7 minutes |
| SonarCloud analysis | 5 min | Analysis typically completes within 2-3 minutes |
| Security scans | 5 min | Snyk/Secretlint are fast for small-medium projects |
| Total postflight | 15 min | Allow buffer for retries and network latency |

### Polling Strategy

```bash
# Recommended polling intervals
INITIAL_WAIT=60     # Wait for workflows to start
POLL_INTERVAL=30    # Check every 30 seconds
MAX_ATTEMPTS=20     # 20 * 30s = 10 minutes max wait
```

## Manual vs Automatic Mode

### Manual Mode (Default)

Run postflight checks manually after release:

```bash
# After release.md completes
./.agent/scripts/postflight-check.sh

# Or individual checks
gh run list --limit=5
./.agent/scripts/quality-check.sh
```

**When to use manual mode:**

- First-time releases
- Major version releases
- When you want to review before declaring success

### Automatic Mode

Enable via GitHub Actions workflow (see above).

**When to use automatic mode:**

- Patch releases with high confidence
- Established CI/CD pipelines
- When rollback procedures are well-tested

## Rollback Procedures

If postflight verification fails, follow these rollback steps:

### 1. Assess Severity

| Severity | Indicators | Action |
|----------|------------|--------|
| **Critical** | Security vulnerability, data loss risk, service outage | Immediate rollback |
| **High** | Broken functionality, failed tests, quality gate failure | Rollback within 1 hour |
| **Medium** | Code smell increase, minor regressions | Hotfix in next release |
| **Low** | Style issues, documentation gaps | Fix in next release |

### 2. Rollback Commands

```bash
# Option A: Revert the release commit
git revert <release-commit-hash>
git push origin main

# Option B: Delete the tag and release (if not widely distributed)
gh release delete v{VERSION} --yes
git tag -d v{VERSION}
git push origin --delete v{VERSION}

# Option C: Create hotfix release
git checkout -b hotfix/v{VERSION}.1
# Fix the issue
git commit -m "fix: resolve critical issue from v{VERSION}"
./.agent/scripts/version-manager.sh release patch
```

### 3. Rollback Checklist

- [ ] Identify the specific issue causing failure
- [ ] Determine rollback strategy (revert, delete, or hotfix)
- [ ] Execute rollback commands
- [ ] Verify rollback was successful
- [ ] Notify stakeholders
- [ ] Document the incident
- [ ] Create follow-up issue for proper fix

### 4. Post-Rollback Verification

```bash
# Verify the rollback
gh run list --limit=5  # Check CI/CD passes
./.agent/scripts/quality-check.sh  # Verify quality restored

# Check SonarCloud
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" | jq '.projectStatus.status'
```

## Integration with release.md

Add postflight as the final step in the release workflow:

```markdown
## Release Workflow (Updated)

1. Bump version (see `workflows/version-bump.md`)
2. Run code quality checks
3. Update changelog
4. Commit version changes
5. Create version tags
6. Push to remote
7. Create GitHub/GitLab release
8. **Postflight verification** (see `workflows/postflight.md`)
```

### Suggested release.md Addition

Add to the "Post-Release Tasks" section:

```markdown
### Postflight Verification

After release publication, run postflight checks:

\`\`\`bash
# Wait for CI/CD and verify
gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status

# Or run full postflight
./.agent/scripts/postflight-check.sh
\`\`\`

See `workflows/postflight.md` for detailed verification procedures and rollback guidance.
```

## Troubleshooting

### CI/CD Stuck in Pending

```bash
# Check if workflows are queued
gh run list --status=queued

# Check GitHub Actions status
curl -s https://www.githubstatus.com/api/v2/status.json | jq '.status'

# Re-run failed workflow
gh run rerun <run-id>
```

### SonarCloud Analysis Delayed

```bash
# Trigger manual analysis (if configured)
curl -X POST "https://sonarcloud.io/api/project_analyses/create?project=marcusquinn_aidevops" \
  -H "Authorization: Bearer $SONAR_TOKEN"

# Check analysis queue
curl -s "https://sonarcloud.io/api/ce/component?component=marcusquinn_aidevops" | jq '.queue'
```

### Security Scan Timeout

```bash
# Run with increased timeout
snyk test --timeout=600

# Run specific scan type only
snyk test --all-projects=false
```

## Success Criteria

Postflight verification is successful when:

1. All CI/CD workflows show `success` conclusion
2. SonarCloud quality gate status is `OK`
3. No new high/critical security vulnerabilities
4. No exposed secrets detected
5. Code review tools show no blocking issues

## Related Workflows

- `release.md` - Pre-release and release process
- `code-review.md` - Code review guidelines
- `changelog.md` - Changelog management
- `version-bump.md` - Version management
