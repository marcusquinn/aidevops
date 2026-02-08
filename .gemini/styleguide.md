# aidevops Shell Script Style Guide

## Overview

This is a Bash-heavy DevOps framework (~170 shell scripts). Reviews should focus on
shell scripting quality, not general software patterns.

## Shell Standards

- All scripts use `#!/usr/bin/env bash` and `set -euo pipefail`
- Use `local var="$1"` pattern in functions (declare and assign separately for exit code safety)
- All functions must have explicit `return` statements
- Use `|| true` guards for commands that may fail under `set -e` (grep, arithmetic)
- ShellCheck zero violations required -- targeted inline disables with reason comments only

## Shared Constants

- Scripts source `shared-constants.sh` for common functions (`print_info`, `print_error`, `print_success`, `sed_inplace`, `sed_append_after`, `todo_commit_push`)
- Do NOT duplicate `print_*` functions -- source shared-constants.sh instead
- Use `sed_inplace` wrapper instead of `sed -i` (macOS/Linux portability)

## SQLite Usage

- All SQLite databases use WAL mode + `busy_timeout=5000`
- Use parameterized queries where possible
- Supervisor, memory, and mail helpers all follow this pattern

## Security

- Never expose credentials in output or logs
- Use `gopass` (encrypted) or `credentials.sh` (600 permissions) for secrets
- No `eval` -- use bash arrays for dynamic command construction
- Temp files must have `trap` cleanup (RETURN or EXIT)

## Naming

- Scripts: `{domain}-helper.sh` (e.g., `supervisor-helper.sh`, `memory-helper.sh`)
- Functions: `cmd_{command}()` for CLI subcommands, descriptive names for internal functions
- Variables: `UPPER_SNAKE` for constants/env vars, `lower_snake` for locals

## Git Conventions

- Conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `perf:`
- Branch types: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`

## What NOT to Flag

- Flat script directory structure is intentional (scripts are cross-domain)
- Long scripts (supervisor-helper.sh ~5000+ lines) are by design -- monolithic helpers
- `2>/dev/null` is acceptable ONLY when redirecting to log files, not blanket suppression
- Blanket ShellCheck disables are banned -- targeted per-file disables are correct
