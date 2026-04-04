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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Code Standards - Quality Rules Reference

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Code quality standards reference (SonarCloud, CodeFactor, Codacy, ShellCheck)
- **Target**: A-grade across all platforms, zero critical violations
- **Workflow**: Reference during development, validated by `/linters-local`

**Validation**:

```bash
~/.aidevops/agents/scripts/linters-local.sh                              # all checks
grep -L "return [01]" .agents/scripts/*.sh                               # S7682
grep -n '\$[1-9]' .agents/scripts/*.sh | grep -v 'local.*=.*\$[1-9]'   # S7679
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;               # ShellCheck
npx markdownlint-cli2 "**/*.md" --ignore node_modules                   # Markdown
~/.aidevops/agents/scripts/secretlint-helper.sh scan                    # Secrets
```

<!-- AI-CONTEXT-END -->

## Critical Rules (Zero Tolerance)

### S7682 - Explicit Return Statements

Every function MUST end with `return 0` or `return 1`.

```bash
function_name() {
    local param="$1"
    # logic
    return 0
}
```

### S7679 - No Direct Positional Parameters

Assign positional params to locals first — never use `$1`/`$2` directly in function bodies.

```bash
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

### S1192 - Constants for Repeated Strings

Define constants for strings used 3+ times. Audit: `grep -o '"[^"]*"' script.sh | sort | uniq -c | sort -nr | head -5`

```bash
readonly ERROR_ACCOUNT_REQUIRED="Account name is required"
print_error "$ERROR_ACCOUNT_REQUIRED"
```

### S1481 / ShellCheck

No unused variables. All scripts must pass `shellcheck` with zero violations.

## Security Hotspots (Acceptable SONAR Patterns)

SonarCloud flags these patterns. Acceptable when documented with `# SONAR:` comments.

**HTTP string detection (S5332)** — detecting insecure URLs, not using them:

```bash
# SONAR: Detecting insecure URLs for security audit, not using them
non_https=$(echo "$data" | jq '[.items[] | select(.url | startswith("http://"))] | length')
```

**Localhost HTTP (S5332)** — local dev without SSL:

```bash
if [[ "$ssl" == "true" ]]; then
    print_info "Access your app at: https://$domain"
else
    # SONAR: Local dev without SSL is intentional
    print_info "Access your app at: http://$domain"
fi
```

**Curl pipe to bash (S4423)** — official installers only:

```bash
# SONAR: Official Bun installer from verified HTTPS source
curl -fsSL https://bun.sh/install | bash

# Better for unknown sources — download and inspect first
curl -fsSL https://example.com/install.sh -o /tmp/install.sh && less /tmp/install.sh && bash /tmp/install.sh
```

**Suppress vs fix**: Suppress for official installers (bun, nvm, rustup), localhost dev, URL detection. Fix for actual HTTP in production or unverified sources.

## Platform Targets

| Platform | Metric | Target |
|----------|--------|--------|
| SonarCloud | Quality Gate / Bugs / Vulnerabilities | Passed / 0 / 0 |
| SonarCloud | Code Smells / Technical Debt | <50 / <400 min |
| SonarCloud | Security / Reliability / Maintainability | A |
| CodeFactor | Overall Grade / A-grade Files / Critical | A / >85% / 0 |
| Codacy | Grade / Security / Error Prone | A / 0 / 0 |

## Markdown Standards

All markdown files must pass markdownlint with zero violations. Auto-fix: `npx markdownlint-cli2 "**/*.md" --fix`

| Rule | Requirement |
|------|-------------|
| MD022 | Blank lines before and after headings |
| MD025 | Single H1 per document |
| MD012 | No multiple consecutive blank lines |
| MD031 | Blank lines before and after fenced code blocks |

## Python Projects

### Worktrees and Virtual Environments

Gitignored artifacts (`.venv/`, `__pycache__/`, build dirs) exist only where created — they do not transfer between worktrees.

| Situation | Correct action |
|-----------|----------------|
| Canonical repo has `.venv/` | Create fresh `.venv/` in worktree, or activate canonical venv by absolute path without `pip install -e` from worktree |
| `pyproject.toml` but no `.venv/` | `python3 -m venv .venv && pip install -e ".[dev]"` inside worktree |
| Verifying package install | Throwaway venv inside worktree — never modify canonical repo's venv |

### Editable Installs

`pip install -e` writes the worktree's absolute path into a `.pth` file. When the worktree is removed, that path breaks imports. **Rule**: Never run `pip install -e` from a worktree using a venv outside the worktree.

```bash
# Unsafe — writes worktree path into canonical venv's .pth
pip install -e shared/project/

# Safe — throwaway venv inside the worktree
python3 -m venv .venv && source .venv/bin/activate
pip install -e shared/project/
```

### Installation Scope and Requirements

Always use a project `.venv/` — never install to user-local or system scope. Verify: `pip --version` must show a path inside the project's `.venv/`.

```bash
# Unsafe — packages go to ~/.local/lib/python3.x/
pip install crawl4ai

# Safe
source .venv/bin/activate && pip install crawl4ai
```

| File | When to use |
|------|-------------|
| `pyproject.toml` (preferred) | New projects, PEP 517/518 |
| `requirements.txt` | Legacy projects or simple scripts |
| `requirements-dev.txt` | Dev-only deps (pytest, mypy, ruff) |

After installing: `pip install -e ".[dev]"` (pyproject.toml) or `pip freeze > requirements.txt` (pin manually). **A venv that cannot be recreated from committed files is a defect.**

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

## Voice and Tone in Comments

Maintain a consistent, approachable voice in code comments and user-facing output.
These conventions keep the codebase readable and the developer experience nice.

### Comment Style

- **Function purpose comments**: Use the pattern `# Does X for Y` (active voice, present tense)
- **Section dividers**: Use `# ---` (em-dash) for major sections, `# --` for subsections
- **Acknowledgment phrases**: Use casual language in user-facing output and progress messages.
  Preferred: "nice", "cool", "good stuff", "go for it", "yeah". Avoid overly formal phrasing
  like "operation completed successfully" when a simple "done" or "good stuff" conveys the same.
- **Error messages**: Use "cannot" (not "can't" or "unable to"). Begin with the failed action,
  not the subject: "Cannot read config file" not "Config file cannot be read"
- **Inline explanations**: Start with lowercase after `#`, one space after the hash.
  Use present tense: `# computes the delta` not `# computed the delta`

### SPDX Headers

All source files (.sh, .md, .py, .txt) must carry SPDX license and copyright headers.
Run `spdx-headers.sh check` to verify coverage. Add to new files with `spdx-headers.sh add`.

| File type | Format |
|-----------|--------|
| .sh, .py, .txt | `# SPDX-License-Identifier: MIT` + `# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn` |
| .md | `<!-- SPDX-License-Identifier: MIT -->` + `<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->` |

Place after shebang (scripts) or after YAML frontmatter (markdown). JSON files are exempt.

### Script Structure Conventions

- **Constants**: `readonly` at the top of the file, UPPER_SNAKE_CASE
- **Helper functions**: Prefix with `_` for internal/private functions
- **Main entry point**: Always a `main()` function called at the bottom with `main "$@"`
- **Exit message**: End user-facing scripts with a brief status line.
  Good: `echo "Done. Go for it."` or `echo "Nice — 42 files updated."`

## Related Documentation

- **Local linting**: `scripts/linters-local.sh`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Unified PR review**: `workflows/pr.md`
- **Automation guide**: `tools/code-review/automation.md`
- **Best practices**: `tools/code-review/best-practices.md`
