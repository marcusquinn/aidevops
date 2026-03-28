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

- **Purpose**: Reference documentation for code quality standards
- **Platforms**: SonarCloud, CodeFactor, Codacy, ShellCheck
- **Target**: A-grade across all platforms, zero critical violations

**Critical Rules (Zero Tolerance)**:

| Rule | Description | Pattern |
|------|-------------|---------|
| S7682 | Explicit return statements | `return 0` or `return 1` in every function |
| S7679 | No direct positional params | `local param="$1"` not `$1` directly |
| S1192 | Constants for repeated strings | `readonly MSG="text"` for 3+ uses |
| S1481 | No unused variables | Remove or use declared variables |
| ShellCheck | Zero violations | All scripts pass `shellcheck` |

**Validation Commands**:

```bash
~/.aidevops/agents/scripts/linters-local.sh                              # all checks
grep -L "return [01]" .agents/scripts/*.sh                               # S7682
grep -n '\$[1-9]' .agents/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'   # S7679
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;               # ShellCheck
npx markdownlint-cli2 "**/*.md" --ignore node_modules                   # Markdown
~/.aidevops/agents/scripts/secretlint-helper.sh scan                    # Secrets
```

**Workflow Position**: Reference during development, validated by `/linters-local`

<!-- AI-CONTEXT-END -->

## Critical Standards (Zero Tolerance)

### S7682 - Return Statements

Every function MUST end with `return 0` or `return 1`.

```bash
# Correct
function_name() {
    local param="$1"
    # logic
    return 0
}
```

### S7679 - Positional Parameters

Always assign positional params to locals first — never use `$1`/`$2` directly.

```bash
# Correct
main() {
    local command="${1:-help}"
    local account_name="$2"
    local target="$3"
    case "$command" in
        "list") list_items "$account_name" ;;
    esac
    return 0
}
```

### S1192 - String Literals

Define constants for strings used 3+ times.

```bash
readonly ERROR_ACCOUNT_REQUIRED="Account name is required"
print_error "$ERROR_ACCOUNT_REQUIRED"
```

**Validation**:

```bash
for file in .agents/scripts/*.sh; do
    echo "=== $file ==="
    grep -o '"[^"]*"' "$file" | sort | uniq -c | sort -nr | head -5
done
```

### S1481 - Unused Variables

Only declare variables that are actually used.

### ShellCheck Compliance

```bash
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;
shellcheck script.sh  # single file
```

## Security Hotspots (Acceptable Patterns)

SonarCloud flags these patterns. They are acceptable when documented with `# SONAR:` comments.

### HTTP String Detection (S5332)

```bash
# SONAR: Detecting insecure URLs for security audit, not using them
non_https=$(echo "$data" | jq '[.items[] | select(.url | startswith("http://"))] | length')
```

### Localhost HTTP Output (S5332)

```bash
if [[ "$ssl" == "true" ]]; then
    print_info "Access your app at: https://$domain"
else
    # SONAR: Local dev without SSL is intentional
    print_info "Access your app at: http://$domain"
fi
```

### Curl Pipe to Bash (S4423)

```bash
# SONAR: Official Bun installer from verified HTTPS source
curl -fsSL https://bun.sh/install | bash

# Better for unknown sources — download and inspect first
curl -fsSL https://example.com/install.sh -o /tmp/install.sh && less /tmp/install.sh && bash /tmp/install.sh
```

**When to suppress vs fix:**

- **Suppress**: Official installers (bun, nvm, rustup), localhost dev, URL detection
- **Fix**: Actual HTTP usage in production, unverified installer sources

## Platform Targets

| Platform | Metric | Target |
|----------|--------|--------|
| SonarCloud | Quality Gate | Passed |
| SonarCloud | Bugs / Vulnerabilities | 0 |
| SonarCloud | Code Smells | <50 |
| SonarCloud | Technical Debt | <400 min |
| SonarCloud | Security / Reliability / Maintainability | A |
| CodeFactor | Overall Grade | A |
| CodeFactor | A-grade Files | >85% |
| CodeFactor | Critical Issues | 0 |
| Codacy | Grade | A |
| Codacy | Security / Error Prone | 0 |

## Markdown Standards

All markdown files must pass markdownlint with zero violations.

| Rule | Requirement |
|------|-------------|
| MD022 | Blank lines before and after headings |
| MD025 | Single H1 per document |
| MD012 | No multiple consecutive blank lines |
| MD031 | Blank lines before and after fenced code blocks |

**Auto-fix**:

```bash
npx markdownlint-cli2 "**/*.md" --fix
```

## Quality Scripts

| Script | Purpose |
|--------|---------|
| `linters-local.sh` | Run all local quality checks |
| `quality-fix.sh` | Auto-fix common issues |
| `pre-commit-hook.sh` | Git pre-commit validation |
| `secretlint-helper.sh` | Secret detection |

## Python Projects

Worktree-specific failure modes differ from single-checkout development.

### Worktrees and Virtual Environments

Gitignored artifacts (`.venv/`, `__pycache__/`, build dirs) exist only where created — they do not transfer between worktrees.

| Situation | Correct action |
|-----------|----------------|
| Project has `.venv/` in canonical repo | Create fresh `.venv/` inside the worktree, or activate canonical venv by absolute path without running `pip install -e` from the worktree |
| Project has `pyproject.toml` but no `.venv/` | `python3 -m venv .venv && pip install -e ".[dev]"` inside the worktree |
| Verifying package install | Throwaway venv inside the worktree — never modify canonical repo's venv from a worktree |

### Editable Installs in Worktrees

`pip install -e` writes the worktree's absolute path into a `.pth` file. When the worktree is removed, that path breaks any code importing via the editable install.

```bash
# Unsafe — writes worktree path into canonical venv's .pth
pip install -e shared/project/

# Safe — throwaway venv inside the worktree
python3 -m venv .venv && source .venv/bin/activate
pip install -e shared/project/
```

**Rule**: Never run `pip install -e` from a worktree using a venv outside the worktree.

### Installation Scope

Never install to user-local or system scope. Always use a project `.venv/`.

```bash
# Unsafe — packages go to ~/.local/lib/python3.x/
pip install crawl4ai

# Safe
source .venv/bin/activate && pip install crawl4ai
# or
.venv/bin/pip install crawl4ai
```

Verify scope: `pip --version` must show a path inside the project's `.venv/`.

### Requirements File Discipline

| File | When to use |
|------|-------------|
| `pyproject.toml` (preferred) | New projects, PEP 517/518 |
| `requirements.txt` | Legacy projects or simple scripts |
| `requirements-dev.txt` | Dev-only deps (pytest, mypy, ruff) |

After installing any package:

```bash
pip install -e ".[dev]"          # pyproject.toml — no manual update needed
pip freeze > requirements.txt    # requirements.txt — pin manually
```

**A venv that cannot be recreated from committed files is a defect.**

### Project AGENTS.md — Development Environment Section

When a Python project lacks a "Development Environment" section, add one:

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
