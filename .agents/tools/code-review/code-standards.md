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
# Run all local quality checks
~/.aidevops/agents/scripts/linters-local.sh

# Check specific rules
grep -L "return [01]" .agents/scripts/*.sh          # S7682
grep -n '\$[1-9]' .agents/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'  # S7679
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;  # ShellCheck
npx markdownlint-cli2 "**/*.md" --ignore node_modules      # Markdown
~/.aidevops/agents/scripts/secretlint-helper.sh scan       # Secrets
```

**Workflow Position**: Reference during development, validated by `/linters-local`

<!-- AI-CONTEXT-END -->

## Purpose

Authoritative code quality standards for the aidevops framework.

**Related commands**:
- `/linters-local` — validates these standards locally
- `/code-audit-remote` — validates via external services
- `/pr` — orchestrates all checks

## Critical Standards (Zero Tolerance)

### S7682 - Return Statements

Every function MUST have an explicit `return 0` or `return 1`.

```bash
# Correct
function_name() {
    local param="$1"
    # logic
    return 0
}

# Violation — missing return
function_name() {
    local param="$1"
    # logic
}
```

### S7679 - Positional Parameters

Never use positional parameters directly. Always assign to local variables first.

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

# Violation — direct $1/$2 usage
main() {
    case "$1" in
        "list") list_items "$2" ;;
    esac
}
```

### S1192 - String Literals

Define constants for strings used 3 or more times.

```bash
# Correct — constants at file top
readonly ERROR_ACCOUNT_REQUIRED="Account name is required"
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"

print_error "$ERROR_ACCOUNT_REQUIRED"

# Violation — repeated string literals
print_error "Account name is required"  # repeated 3+ times
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

```bash
# Correct
function_name() {
    local used_param="$1"
    echo "$used_param"
    return 0
}

# Violation — unused_param declared but never referenced
function_name() {
    local used_param="$1"
    local unused_param="$2"
    echo "$used_param"
    return 0
}
```

### ShellCheck Compliance

All shell scripts must pass ShellCheck with zero violations.

```bash
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;
shellcheck script.sh  # single file
```

## Security Hotspots (Acceptable Patterns)

SonarCloud flags these patterns as security hotspots. They are acceptable when properly documented.

### HTTP String Detection (S5332)

When checking for insecure URLs, not using them:

```bash
# Correct — comment documents intent
# SONAR: Detecting insecure URLs for security audit, not using them
non_https=$(echo "$data" | jq '[.items[] | select(.url | startswith("http://"))] | length')
```

### Localhost HTTP Output (S5332)

Local development environments often lack SSL:

```bash
if [[ "$ssl" == "true" ]]; then
    print_info "Access your app at: https://$domain"
else
    # SONAR: Local dev without SSL is intentional
    print_info "Access your app at: http://$domain"
fi
```

### Curl Pipe to Bash (S4423)

For official installers from verified sources:

```bash
# Correct — documented official installer
# SONAR: Official Bun installer from verified HTTPS source
curl -fsSL https://bun.sh/install | bash

# Better for new/unknown sources — download and inspect first
curl -fsSL https://example.com/install.sh -o /tmp/install.sh
less /tmp/install.sh
bash /tmp/install.sh
```

**When to suppress vs fix:**

- **Suppress**: Official installers (bun, nvm, rustup), localhost dev, URL detection
- **Fix**: Actual HTTP usage in production, unverified installer sources

## Platform Targets

### SonarCloud

| Metric | Target |
|--------|--------|
| Quality Gate | Passed |
| Bugs | 0 |
| Vulnerabilities | 0 |
| Code Smells | <50 |
| Technical Debt | <400 minutes |
| Security Rating | A |
| Reliability Rating | A |
| Maintainability Rating | A |

### CodeFactor

| Metric | Target |
|--------|--------|
| Overall Grade | A |
| A-grade Files | >85% |
| Critical Issues | 0 |

### Codacy

| Metric | Target |
|--------|--------|
| Grade | A |
| Security Issues | 0 |
| Error Prone | 0 |

## Markdown Standards

All markdown files must pass markdownlint with zero violations.

### MD022 - Headings Surrounded by Blank Lines

```markdown
<!-- Correct -->
Some content.

### Heading Title

Content after heading.

<!-- Violation — missing blank line after heading -->
### Heading Title
Content after heading.
```

### MD025 - Single Top-Level Heading

Each document should have only ONE H1 (`#`) heading.

### MD012 - No Multiple Blank Lines

Use only single blank lines between elements.

### MD031 - Fenced Code Blocks Surrounded by Blank Lines

Code blocks MUST have blank lines before AND after them.

````markdown
<!-- Correct -->
Some text.

```bash
echo "hello"
```

More text.

<!-- Violation — missing blank line before code block -->
Some text.
```bash
echo "hello"
```
````

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

Rules for Python projects using the worktree-based workflow. Workers encounter these regularly — the worktree model creates specific failure modes that differ from single-checkout development.

### Worktrees and Virtual Environments

**Gitignored artifacts do not transfer between worktrees.** `.venv/`, `__pycache__/`, build dirs, and compiled extensions are gitignored and exist only in the directory where they were created. A worker operating in a worktree cannot assume the canonical repo's `.venv/` is usable from that worktree path.

| Situation | Correct action |
|-----------|----------------|
| Project has `.venv/` in canonical repo | Create a fresh `.venv/` inside the worktree, or activate the canonical venv by absolute path and do NOT run `pip install -e` from the worktree |
| Project has `pyproject.toml` but no `.venv/` | Create `.venv/` inside the worktree: `python3 -m venv .venv && pip install -e ".[dev]"` |
| Verifying that a package installs correctly | Create a throwaway venv inside the worktree — never modify the canonical repo's venv from a worktree context |

### Editable Installs in Worktrees

**`pip install -e` writes the worktree's absolute path into a `.pth` file.** When the worktree is removed after PR merge, that path no longer exists. Any code that imports the package via the editable install will fail silently.

```bash
# Unsafe — from inside a worktree, using the canonical repo's venv
pip install -e shared/project/  # Writes worktree path into canonical venv's .pth

# Safe — create a throwaway venv inside the worktree
python3 -m venv .venv
source .venv/bin/activate
pip install -e shared/project/  # .pth path is inside the worktree, removed with it
```

**Rule**: Never run `pip install -e` from a worktree using a venv that lives outside the worktree.

### Installation Scope

**Never install packages to user-local or system scope.** If a project has a `.venv/`, use it. If it doesn't, create one. Never let `pip install` fall through to `~/.local/lib/` or system Python.

```bash
# Unsafe — no venv active, packages go to ~/.local/lib/python3.x/
pip install crawl4ai

# Safe — activate venv first
source .venv/bin/activate
pip install crawl4ai

# Safe — explicit venv pip
.venv/bin/pip install crawl4ai
```

Verify scope before installing: `pip --version` should show a path inside the project's `.venv/`, not `~/.local/` or `/usr/`.

### Requirements File Discipline

Every Python project must have a reproducible dependency declaration. Workers must not create venvs and install packages without updating the dependency file.

| File | When to use |
|------|-------------|
| `pyproject.toml` (preferred) | New projects, PEP 517/518 compliant |
| `requirements.txt` | Legacy projects or simple scripts |
| `requirements-dev.txt` | Dev-only deps (pytest, mypy, ruff) |

After installing any package:

```bash
# pyproject.toml projects
pip install -e ".[dev]"  # installs from declared deps — no manual update needed

# requirements.txt projects
pip freeze > requirements.txt  # or pin manually — never leave venv unreproducible
```

**A venv that cannot be recreated from committed files is a defect.** Workers must not leave venvs in a state where `git clone` + `pip install -r requirements.txt` would produce a different environment.

### Project AGENTS.md / Plan: Development Environment Section

When working on a Python project that lacks a "Development Environment" section in its `AGENTS.md` or plan, add one. This prevents the next worker from repeating the same discovery. Minimum content:

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
