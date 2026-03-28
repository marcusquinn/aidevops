---
description: Documented code quality standards for compliance checking
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

# Code Standards - Quality Rules Reference

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Code quality standards reference — SonarCloud, CodeFactor, Codacy, ShellCheck
- **Target**: A-grade across all platforms, zero critical violations
- **Workflow**: Reference during development → validated by `linters-local.sh`

**Validation**:

```bash
~/.aidevops/agents/scripts/linters-local.sh                              # all checks
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;               # ShellCheck
npx markdownlint-cli2 "**/*.md" --ignore node_modules                   # Markdown
~/.aidevops/agents/scripts/secretlint-helper.sh scan                    # Secrets
```

**Quality scripts**: `linters-local.sh` (all checks), `quality-fix.sh` (auto-fix), `pre-commit-hook.sh` (git hook), `secretlint-helper.sh` (secret detection).

<!-- AI-CONTEXT-END -->

## Critical Standards (Zero Tolerance)

| Rule | Requirement | Check |
|------|-------------|-------|
| S7682 | Explicit `return 0` or `return 1` in every function | `grep -L "return [01]" .agents/scripts/*.sh` |
| S7679 | `local param="$1"` — never use `$1` directly | `grep -n '\$[1-9]' *.sh \| grep -v 'local.*=.*\$[1-9]'` |
| S1192 | `readonly` constants for strings used 3+ times | Manual review |
| S1481 | No unused variables — remove or use declared vars | Linter-detected |
| ShellCheck | Zero violations on all `.sh` files | `shellcheck script.sh` |

### S7682 + S7679 — Canonical Pattern

```bash
function_name() {
    local param="$1"
    local command="${1:-help}"
    # logic
    return 0
}
```

### S1192 — String Constants

```bash
readonly ERROR_ACCOUNT_REQUIRED="Account name is required"
print_error "$ERROR_ACCOUNT_REQUIRED"
```

## Security Hotspots (SonarCloud Suppressions)

SonarCloud flags these patterns. Acceptable when documented with `# SONAR:` comments.

| Pattern | Rule | When to suppress |
|---------|------|-----------------|
| HTTP string detection | S5332 | Detecting insecure URLs for audit, not using them |
| Localhost HTTP output | S5332 | Local dev without SSL is intentional |
| Curl pipe to bash | S4423 | Official installers (bun, nvm, rustup) from verified HTTPS |

```bash
# SONAR: Detecting insecure URLs for security audit, not using them
non_https=$(echo "$data" | jq '[.items[] | select(.url | startswith("http://"))] | length')

# SONAR: Official Bun installer from verified HTTPS source
curl -fsSL https://bun.sh/install | bash
```

**Fix** (don't suppress): actual HTTP in production, unverified installer sources. For unknown sources, download and inspect first: `curl -fsSL URL -o /tmp/install.sh && less /tmp/install.sh && bash /tmp/install.sh`.

## Platform Targets

| Platform | Target |
|----------|--------|
| SonarCloud | Quality Gate passed, 0 bugs/vulnerabilities, <50 code smells, <400 min debt, A on security/reliability/maintainability |
| CodeFactor | A overall, >85% A-grade files, 0 critical issues |
| Codacy | A grade, 0 security/error-prone issues |

## Markdown Standards

All markdown files must pass markdownlint with zero violations.

| Rule | Requirement |
|------|-------------|
| MD022 | Blank lines before and after headings |
| MD025 | Single H1 per document |
| MD012 | No multiple consecutive blank lines |
| MD031 | Blank lines before and after fenced code blocks |

Auto-fix: `npx markdownlint-cli2 "**/*.md" --fix`

## Python Projects

Worktree-specific failure modes differ from single-checkout development. Gitignored artifacts (`.venv/`, `__pycache__/`, build dirs) exist only where created — they do not transfer between worktrees.

### Venvs in Worktrees

| Situation | Correct action |
|-----------|----------------|
| Canonical repo has `.venv/` | Create fresh `.venv/` in worktree, or activate canonical venv by absolute path (never `pip install -e` from worktree) |
| `pyproject.toml` but no `.venv/` | `python3 -m venv .venv && pip install -e ".[dev]"` inside worktree |
| Verifying package install | Throwaway venv inside worktree — never modify canonical venv from a worktree |

### Editable Installs (.pth Hazard)

`pip install -e` writes the worktree's absolute path into a `.pth` file. When the worktree is removed, that path breaks imports.

**Rule**: Never run `pip install -e` from a worktree using a venv outside the worktree. Always use a throwaway venv inside the worktree:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e shared/project/
```

### Installation Scope

Never install to user-local or system scope. Always use a project `.venv/`. Verify: `pip --version` must show a path inside the project's `.venv/`.

### Requirements Discipline

| File | When to use |
|------|-------------|
| `pyproject.toml` (preferred) | New projects, PEP 517/518 |
| `requirements.txt` | Legacy projects or simple scripts |
| `requirements-dev.txt` | Dev-only deps (pytest, mypy, ruff) |

**A venv that cannot be recreated from committed files is a defect.**

### Project AGENTS.md — Dev Environment Section

When a Python project lacks a "Development Environment" section, add:

```markdown
## Development Environment

- **Python**: 3.x (specify version)
- **Venv**: `python3 -m venv .venv && source .venv/bin/activate`
- **Install**: `pip install -e ".[dev]"` (or `pip install -r requirements.txt`)
- **Tests**: `pytest` (or project-specific command)
- **Do NOT**: install globally, run `pip install -e` from a worktree using the canonical venv
```

## Related Documentation

- **Local linting**: `scripts/linters-local.sh`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Unified PR review**: `workflows/pr.md`
- **Automation guide**: `tools/code-review/automation.md`
- **Best practices**: `tools/code-review/best-practices.md`
