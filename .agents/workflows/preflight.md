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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Preflight Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Auto-run**: Called by `version-manager.sh release` before version bump
- **Manual**: `.agents/scripts/linters-local.sh`
- **Skip**: `version-manager.sh release [type] --force --skip-preflight`
- **Fast mode**: `.agents/scripts/linters-local.sh --fast`

**Check Phases** (fast -> slow):
1. Version consistency (~1s, blocking)
2. ShellCheck + Secretlint (~10s, blocking)
3. Markdown + return statements (~20s, blocking)
4. SonarCloud status (~5s, advisory)

<!-- AI-CONTEXT-END -->

## Check Phases

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

## Commands

```bash
# Automatic (recommended) — runs before version bump
.agents/scripts/version-manager.sh release minor

# Full quality check
.agents/scripts/linters-local.sh

# Fast checks only (ShellCheck, secrets, returns)
.agents/scripts/linters-local.sh --fast

# Individual checks
shellcheck .agents/scripts/*.sh
npx secretlint "**/*"
.agents/scripts/secretlint-helper.sh scan
.agents/scripts/version-manager.sh validate
```

## Release Integration

```text
release command → PREFLIGHT (fail = no version changes) → CHANGELOG → VERSION BUMP → tag, release
```

## Bypassing Preflight

For emergency hotfixes only:

```bash
.agents/scripts/version-manager.sh release patch --skip-preflight
.agents/scripts/version-manager.sh release patch --skip-preflight --force  # skip changelog too
```

**Skip when**: critical security hotfix, CI/CD down + urgent release, false positive blocking release.
**Never skip for**: convenience, "I'll fix it later", avoiding legitimate issues.

## Check Details

### ShellCheck

Zero violations required (errors are blocking).

```bash
shellcheck .agents/scripts/*.sh                        # all scripts
shellcheck .agents/scripts/version-manager.sh          # specific file
shellcheck -f gcc .agents/scripts/problem-script.sh    # detailed output
```

### Secretlint

Detects: AWS keys, GitHub tokens, OpenAI keys, private keys, database URLs.

False positives: add to `.secretlintignore`:

```text
tests/fixtures/*
path/to/false-positive.txt
```

### Version Consistency

Checks VERSION matches: README badge, sonar-project.properties, setup.sh.

```bash
# Fix mismatches by re-running bump
.agents/scripts/version-manager.sh bump patch
```

### SonarCloud Status

```bash
curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops"
```

### SonarCloud Security Hotspots

Security hotspots require individual human review — they are NOT automatically bugs.

**Resolution options** (in SonarCloud UI):
- **Safe**: code is secure (add comment explaining why)
- **Fixed**: code changes made to address it
- **Acknowledged**: known issue, accepted risk (add justification)

**Common hotspot types**:

| Rule | Description | Typical Resolution |
|------|-------------|-------------------|
| `shell:S5332` | HTTP instead of HTTPS | Safe if localhost/internal; Fix if external |
| `shell:S6505` | npm install without --ignore-scripts | Safe if trusted packages; scripts needed for setup |
| `shell:S6506` | Package manager security | Safe if from trusted registries |

**Do NOT** blanket-dismiss hotspots, disable rules without justification, or ignore them.

```bash
# View current hotspots
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=marcusquinn_aidevops&status=TO_REVIEW" | \
  jq '.hotspots[] | {file: .component, line: .line, message: .message}'

# Group by rule to prioritize review
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=marcusquinn_aidevops&status=TO_REVIEW" | \
  jq '[.hotspots[] | .ruleKey] | group_by(.) | map({rule: .[0], count: length})'
```

## Worktree and Pre-existing Issues

Preflight in a worktree checks **worktree files**, not deployed `~/.aidevops/agents/`. Issues resolve only after merge + `./setup.sh` redeployment.

Preflight reports ALL issues including pre-existing ones. To isolate your changes:

```bash
git diff main --name-only                                          # files you changed
git diff main --name-only -z -- '*.sh' | xargs -0 shellcheck      # your shell changes only
```

**Fix**: issues introduced by your changes, issues in files you're modifying, quick wins (< 5 min).
**Defer**: pre-existing issues in untouched files, significant refactoring, out-of-scope work. Note in PR: "Pre-existing issues not addressed in this PR".

## Related Workflows

- **Version bumping**: `workflows/version-bump.md`
- **Changelog**: `workflows/changelog.md`
- **Release**: `workflows/release.md`
- **Postflight**: `workflows/postflight.md` (after release)
- **Code quality tools**: `tools/code-review/`
