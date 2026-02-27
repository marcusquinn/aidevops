---
mode: subagent
---
# t1350: fix: setup.sh exits early in non-interactive terminals

## Origin

- **Created:** 2026-02-27
- **Session:** interactive:pulse
- **Created by:** ai-interactive
- **Conversation context:** setup.sh has no auto-detection of non-interactive terminals. When run from CI/CD or agent shells (no stdin tty), `read` commands fail with `set -Eeuo pipefail`, killing the function before agent deploy runs. Also, `grep -c` ERR trap noise in shell-env.sh.

## What

Auto-detect non-interactive terminals in setup.sh and fix `grep -c` ERR trap noise in `setup-modules/shell-env.sh`.

**Deliverable:** setup.sh correctly auto-sets `NON_INTERACTIVE=true` when stdin is not a tty, and `grep -c` calls in shell-env.sh handle no-match exit code inside the subshell.

## Why

Agents running `setup.sh` without `--non-interactive` flag get stuck or fail silently because `read` fails on non-tty stdin. This means agent deployment never runs in headless environments.

## How

1. **setup.sh**: After `parse_args`, add:
   ```bash
   if [[ "$INTERACTIVE_MODE" != "true" && ! -t 0 ]]; then
     NON_INTERACTIVE=true
   fi
   ```
2. **setup-modules/shell-env.sh**: Change `$(grep -cE ... 2>/dev/null) || true` to `$(grep -cE ... 2>/dev/null || echo "0")` to handle no-match inside the subshell, avoiding ERR trap noise with `inherit_errexit`.

## Acceptance Criteria

- [ ] `echo "" | bash setup.sh` runs without hanging or exiting early (auto-detects non-interactive)
- [ ] `bash setup.sh --interactive` still works (explicit flag takes precedence)
- [ ] ShellCheck passes on both modified files
- [ ] `grep -c` calls in shell-env.sh use `|| echo "0"` inside subshell

## Context & Decisions

- Auto-detection runs after `parse_args` so `--interactive` flag takes precedence
- Uses `[[ ! -t 0 ]]` (stdin not a tty) as the detection signal — standard POSIX approach
- `AIDEVOPS_NON_INTERACTIVE` env var already supported (line 30 of setup.sh)
- Codacy/SonarCloud: documentation-only changes in other PRs may flag advisory issues; these are not blocking
