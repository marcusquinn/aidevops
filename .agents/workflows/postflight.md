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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Postflight Verification Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Verify release health after `release.md` completes
- **Trigger**: After tag creation and GitHub release publication
- **Timeouts**: CI/CD 10 min, code review tools 5 min
- **Script**: `.agents/scripts/postflight-check.sh` (canonical implementation)
- **GH Actions**: `.github/workflows/postflight.yml` (automated on release publish)
- **Rollback**: See [Rollback Procedures](#rollback-procedures)

<!-- AI-CONTEXT-END -->

## Critical: Avoiding Circular Dependencies

Exclude the postflight workflow itself when checking CI/CD status:

```bash
SELF_NAME="Verify Release Health"
gh api repos/{owner}/{repo}/commits/{sha}/check-runs \
  --jq "[.check_runs[] | select(.status != \"completed\" and .name != \"$SELF_NAME\")] | length"
```

## Postflight Checklist

Check both `main` and tag refs: `gh run list --branch=main --limit=5` and `gh run list --branch=v{VERSION} --limit=5`.

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

## Running Postflight

Wait for `postflight.yml` GH Actions workflow to complete before running locally. Only declare success if ALL workflows passed.

**Local**: `.agents/scripts/postflight-check.sh` — runs CI/CD wait, SonarCloud gate, Snyk, and Secretlint checks with proper timeouts and error handling.

**Automated**: `.github/workflows/postflight.yml` — triggers on `release: published` and `workflow_dispatch`. Runs the same checks in CI with step summary reporting.

Do not duplicate these scripts inline — they are the source of truth. Read them directly when implementation details are needed.

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
# Option A: Revert commit
git revert <release-commit-hash> && git push origin main
# Option B: Delete tag+release (if not widely distributed)
gh release delete v{VERSION} --yes && git tag -d v{VERSION} && git push origin --delete v{VERSION}
# Option C: Hotfix release
git checkout -b hotfix/v{VERSION}.1 && git commit -m "fix: resolve critical issue" && ./.agents/scripts/version-manager.sh release patch
```

Post-rollback: `gh run list --limit=5 && .agents/scripts/linters-local.sh`

## Handling SonarCloud Quality Gate Failures

### Security Hotspots

Security hotspots require **individual human review**, not blanket dismissal.

```bash
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=marcusquinn_aidevops&status=TO_REVIEW" | \
  jq '{total: .paging.total, by_rule: ([.hotspots[] | .ruleKey] | group_by(.) | map({rule: .[0], count: length}))}'
```

Review each individually in SonarCloud — mark **Safe** (with comment), **Fixed**, or **Acknowledged** (accepted risk). Never blanket-dismiss; real vulnerabilities hide among false positives.

| Rule | Typical Resolution |
|------|--------------------|
| `shell:S5332` | Safe: "Localhost HTTP intentional for local dev" |
| `shell:S6505` | Safe: "Postinstall scripts required for package setup" |
| `shell:S6506` | Safe: "Installing from trusted npm registry" |

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
