# Preflight Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Auto-run**: Called by `version-manager.sh release` before version bump
- **Manual**: `.agent/scripts/quality-check.sh`
- **Skip**: `version-manager.sh release [type] --force --skip-preflight`
- **Fast mode**: `.agent/scripts/quality-check.sh --fast`

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
| Return statements | quality-check.sh | Yes |

### Phase 3: Medium Blocking (~30s)

| Check | Tool | Blocking |
|-------|------|----------|
| Markdown formatting | markdownlint | Advisory |
| Positional parameters | quality-check.sh | Advisory |
| String literal duplication | quality-check.sh | Advisory |

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
```

### Manual

Run quality checks independently:

```bash
# Full quality check
.agent/scripts/quality-check.sh

# Fast checks only (ShellCheck, secrets, returns)
.agent/scripts/quality-check.sh --fast

# Specific checks
shellcheck .agent/scripts/*.sh
npx secretlint "**/*"
```

## Integration with Release

```
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
```

## Bypassing Preflight

For emergency hotfixes only:

```bash
# Skip preflight (use with caution)
.agent/scripts/version-manager.sh release patch --skip-preflight

# Skip both preflight and changelog
.agent/scripts/version-manager.sh release patch --skip-preflight --force
```

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
```

**Must pass**: Zero violations (errors are blocking)

### Secretlint

Detects accidentally committed secrets:

```bash
# Run manually
npx secretlint "**/*"

# With helper
.agent/scripts/secretlint-helper.sh scan
```

**Detects**: AWS keys, GitHub tokens, OpenAI keys, private keys, database URLs

### Version Consistency

Ensures VERSION file matches all references:

```bash
.agent/scripts/version-manager.sh validate
```

**Checks**: VERSION, README badge, sonar-project.properties, setup.sh

### SonarCloud Status

Checks current quality gate status:

```bash
# Via quality-check.sh
.agent/scripts/quality-check.sh

# Direct API (requires SONAR_TOKEN)
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops"
```

## Troubleshooting

### ShellCheck Violations

```bash
# See specific issues
shellcheck -f gcc .agent/scripts/problem-script.sh

# Auto-fix some issues (with shellcheck-fix if available)
# Or manually fix based on SC codes
```

### Secretlint False Positives

Add to `.secretlintignore`:

```
# Ignore test fixtures
tests/fixtures/*

# Ignore specific file
path/to/false-positive.txt
```

### Version Mismatch

```bash
# Check current state
.agent/scripts/version-manager.sh validate

# Fix by re-running bump
.agent/scripts/version-manager.sh bump patch
```

## Related Workflows

- **Version bumping**: `workflows/version-bump.md`
- **Changelog**: `workflows/changelog.md`
- **Release**: `workflows/release.md`
- **Postflight**: `workflows/postflight.md` (after release)
- **Code quality tools**: `tools/code-review/`
