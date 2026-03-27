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

# Codacy Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- Auto-fix: `bash .agents/scripts/codacy-cli.sh analyze --fix`
- Via manager: `bash .agents/scripts/quality-cli-manager.sh analyze codacy-fix`
- Fix types: code style, best practices, security, performance, maintainability
- Safety: non-breaking, reversible, conservative (skips ambiguous)
- Metrics: 70-90% time savings, 99%+ accuracy, 60-80% violation coverage
- Cannot fix: complex logic, architecture, context-dependent, breaking changes
- Best practices: always review, test after, incremental batches, clean git state
- Workflow: `quality-check` -> `analyze --fix` -> `quality-check` -> commit with metrics

## Quality Gate Settings

**Current gate (PR and commits):** max 10 new issues, minimum severity Warning.

**Rationale (GH#4910, t1489):** Originally set to 0 max new issues. Tripped 4x during
extract-function refactoring — new helper functions count as added complexity, subprocess
calls in new functions count as new Bandit warnings. Project grade stays A throughout;
these are not real regressions. Threshold raised to 10 Warning+ to absorb refactoring
noise while still blocking genuine security/error issues.

**Do not revert to 0.** A threshold of 0 makes extract-function refactoring impossible
without manual Codacy dashboard intervention on every PR. The project grade (A) is the
meaningful quality signal, not the per-PR new-issue count.

## Local Pre-Push Checks (GH#4939)

`linters-local.sh` includes checks aligned with Codacy's complexity engine:

| Check | Codacy equivalent | Warning | Blocking | Gate |
|-------|-------------------|---------|----------|------|
| `function-complexity` | Function length | >50 lines | >100 lines | `function-complexity` |
| `nesting-depth` | Cyclomatic complexity | >5 levels | >8 levels | `nesting-depth` |
| `file-size` | File length | >800 lines | >1500 lines | `file-size` |
| `python-complexity` | Lizard CCN | >8 (advisory) | — | `python-complexity` |

Gates are set above current baseline to catch regressions. As debt is paid down (via
code-simplifier issues), reduce thresholds. Python files in `.agents/scripts/` are
covered by file-size checks.

CI enforcement: `.github/workflows/code-quality.yml` runs the same checks on every PR
via the `complexity-check` job, blocking merges that exceed thresholds.

Skip via bundle config: add gate names to `skip_gates` in the project bundle.

## Codacy API Patterns (verified working)

```bash
# Commit delta statistics (new issues count + complexity delta)
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/commits/<SHA>/deltaStatistics"

# Per-file new issues (paginate with cursor)
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/commits/<SHA>/files?limit=100"
# Filter: .data[] | select(.quality.deltaNewIssues > 0)

# Search all issues (POST, filter by language)
curl -s -H "api-token: $CODACY_API_TOKEN" -H "Content-Type: application/json" \
  -X POST "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/issues/search?limit=50" \
  -d '{"languages": ["Python"]}'
```

**Updating quality gate via API:**

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

## Auto-Fix Usage

```bash
# Direct CLI
bash .agents/scripts/codacy-cli.sh analyze --fix          # Apply fixes
bash .agents/scripts/codacy-cli.sh analyze eslint --fix    # Specific tool
bash .agents/scripts/codacy-cli.sh analyze                 # Dry-run (check only)

# Via quality manager
bash .agents/scripts/quality-cli-manager.sh analyze codacy-fix
bash .agents/scripts/quality-cli-manager.sh status codacy
```

### CI/CD Integration

```yaml
# GitHub Actions example
- name: Auto-fix code quality issues
  run: |
    bash .agents/scripts/codacy-cli.sh analyze --fix
    git add .
    git diff --staged --quiet || git commit -m "fix: applied Codacy automated fixes"
```

### Workflow

1. Run `linters-local.sh` to identify issues
2. Apply auto-fixes: `codacy-cli.sh analyze --fix`
3. Re-run `linters-local.sh` to verify improvements
4. Commit with before/after metrics
