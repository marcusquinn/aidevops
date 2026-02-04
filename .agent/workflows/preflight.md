---
description: Quality checks before version bump and release
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

# Preflight Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Auto-run**: Called by `version-manager.sh release` before version bump
- **Manual**: `.agent/scripts/linters-local.sh`
- **Skip**: `version-manager.sh release [type] --force --skip-preflight`
- **Fast mode**: `.agent/scripts/linters-local.sh --fast`

**Check Phases** (fast → slow):
1. Version consistency (~1s, blocking)
2. ShellCheck + Secretlint (~10s, blocking)
3. Markdown + return statements (~20s, blocking)
4. SonarCloud status (~5s, advisory)

<!-- AI-CONTEXT-END -->

## Purpose

Preflight ensures code quality before version bumping and release. It catches issues early, preventing broken releases.

## What Preflight Checks

### Phase 1: Instant Blocking (~2s)

| Check | Tool | Blocking |
|-------|------|----------|
| Version consistency | `version-manager.sh validate` | Yes |
| Uncommitted changes | `git status` | Warning |

### Phase 2: Fast Blocking (~10s)

| Check | Tool | Blocking |
|-------|------|----------|
| Shell script linting | ShellCheck | Yes |
| Secret detection | Secretlint | Yes |
| Return statements | linters-local.sh | Yes |

### Phase 3: Medium Blocking (~30s)

| Check | Tool | Blocking |
|-------|------|----------|
| Markdown formatting | markdownlint | Advisory |
| Positional parameters | linters-local.sh | Advisory |
| String literal duplication | linters-local.sh | Advisory |

### Phase 4: Slow Advisory (~60s+)

| Check | Tool | Blocking |
|-------|------|----------|
| SonarCloud status | API check | Advisory |
| Codacy grade | API check | Advisory |

## Running Preflight

### Automatic (Recommended)

Preflight runs automatically during release:

```bash
# Preflight runs before version bump
.agent/scripts/version-manager.sh release minor
```text

### Manual

Run quality checks independently:

```bash
# Full quality check
.agent/scripts/linters-local.sh

# Fast checks only (ShellCheck, secrets, returns)
.agent/scripts/linters-local.sh --fast

# Specific checks
shellcheck .agent/scripts/*.sh
npx secretlint "**/*"
```text

## Integration with Release

```text
release command
    │
    ▼
┌─────────────┐
│  PREFLIGHT  │ ◄── Fails here = no version changes
└─────────────┘
    │ pass
    ▼
┌─────────────┐
│  CHANGELOG  │ ◄── Validates changelog content
└─────────────┘
    │ pass
    ▼
┌─────────────┐
│ VERSION BUMP│ ◄── Updates VERSION, README, etc.
└─────────────┘
    │
    ▼
   ... tag, release ...
```text

## Bypassing Preflight

For emergency hotfixes only:

```bash
# Skip preflight (use with caution)
.agent/scripts/version-manager.sh release patch --skip-preflight

# Skip both preflight and changelog
.agent/scripts/version-manager.sh release patch --skip-preflight --force
```text

**When to skip:**
- Critical security hotfix that can't wait
- CI/CD is down but release is urgent
- False positive blocking release

**Never skip for:**
- Convenience
- "I'll fix it later"
- Avoiding legitimate issues

## Check Details

### ShellCheck

Lints all shell scripts for common issues:

```bash
# Run manually
shellcheck .agent/scripts/*.sh

# Check specific file
shellcheck .agent/scripts/version-manager.sh
```text

**Must pass**: Zero violations (errors are blocking)

### Secretlint

Detects accidentally committed secrets:

```bash
# Run manually
npx secretlint "**/*"

# With helper
.agent/scripts/secretlint-helper.sh scan
```text

**Detects**: AWS keys, GitHub tokens, OpenAI keys, private keys, database URLs

### Version Consistency

Ensures VERSION file matches all references:

```bash
.agent/scripts/version-manager.sh validate
```text

**Checks**: VERSION, README badge, sonar-project.properties, setup.sh

### SonarCloud Status

Checks current quality gate status:

```bash
# Via linters-local.sh
.agent/scripts/linters-local.sh

# Direct API (requires SONAR_TOKEN)
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops"
```

### SonarCloud Security Hotspots

Security hotspots are code patterns that require human review. They are NOT automatically bugs - they need individual assessment.

**Preferred approach**: Review and resolve each hotspot individually in SonarCloud:

1. Open the hotspot in SonarCloud UI
2. Review the code and context
3. Mark as one of:
   - **Safe**: The code is secure (add comment explaining why)
   - **Fixed**: You've made code changes to address it
   - **Acknowledged**: Known issue, accepted risk (add justification)

**Common hotspot types and typical resolutions**:

| Rule | Description | Typical Resolution |
|------|-------------|-------------------|
| `shell:S5332` | HTTP instead of HTTPS | Safe if localhost/internal; Fix if external |
| `shell:S6505` | npm install without --ignore-scripts | Safe if trusted packages; scripts needed for setup |
| `shell:S6506` | Package manager security | Safe if from trusted registries |

**Do NOT**:
- Blanket-dismiss all hotspots without review
- Disable rules globally without justification
- Ignore hotspots hoping they'll go away

**Why individual review matters**:
- Catches real security issues mixed with false positives
- Documents security decisions for audit trails
- Prevents rule fatigue from hiding actual vulnerabilities

```bash
# View current hotspots
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=marcusquinn_aidevops&status=TO_REVIEW" | \
  jq '.hotspots[] | {file: .component, line: .line, message: .message}'

# Group by rule to prioritize review
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=marcusquinn_aidevops&status=TO_REVIEW" | \
  jq '[.hotspots[] | .ruleKey] | group_by(.) | map({rule: .[0], count: length})'
```

## Troubleshooting

### ShellCheck Violations

```bash
# See specific issues
shellcheck -f gcc .agent/scripts/problem-script.sh

# Auto-fix some issues (with shellcheck-fix if available)
# Or manually fix based on SC codes
```text

### Secretlint False Positives

Add to `.secretlintignore`:

```text
# Ignore test fixtures
tests/fixtures/*

# Ignore specific file
path/to/false-positive.txt
```text

### Version Mismatch

```bash
# Check current state
.agent/scripts/version-manager.sh validate

# Fix by re-running bump
.agent/scripts/version-manager.sh bump patch
```text

## Worktree Awareness

When running preflight in a worktree, checks run against the **worktree's files**, not the deployed `~/.aidevops/agents/` version. This means:

- Pre-existing issues in the deployed version won't be fixed by worktree changes
- Issues will only be resolved after merge and redeployment (`./setup.sh`)
- Focus on issues introduced by your changes, not inherited technical debt

## Pre-existing vs New Issues

Preflight checks report ALL issues, including pre-existing ones. When the loop hits max iterations or you see many violations:

### Identifying New vs Pre-existing Issues

```bash
# See what files you changed
git diff main --name-only

# Check issues only in your changed files
shellcheck $(git diff main --name-only -- '*.sh')
```

### When to Proceed Despite Issues

If all remaining issues are **pre-existing** (not introduced by your PR):

1. Verify your changes don't add new violations
2. Document pre-existing issues for future cleanup
3. Proceed with PR creation
4. Note in PR description: "Pre-existing issues not addressed in this PR"

### When to Fix Issues

Fix issues that are:
- Introduced by your changes
- In files you're already modifying
- Quick wins (< 5 minutes to fix)

Defer issues that are:
- Pre-existing in untouched files
- Require significant refactoring
- Outside the scope of your PR

## Related Workflows

- **Version bumping**: `workflows/version-bump.md`
- **Changelog**: `workflows/changelog.md`
- **Release**: `workflows/release.md`
- **Postflight**: `workflows/postflight.md` (after release)
- **Code quality tools**: `tools/code-review/`
