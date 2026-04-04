<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1491: fix: Bash 3.2 bad substitution in config_get indirect expansion

## Session Origin

Pulse cycle 2026-03-15. Issue GH#4929 filed by prior pulse detecting startup errors.

## What

Replace Bash 4.0+ indirect expansion syntax `${!env_var:-}` with Bash 3.2-safe equivalent in `config-helper.sh` at lines 333, 527, and 732.

## Why

On macOS `/bin/bash` 3.2.57, `${!var:-default}` throws "bad substitution". This causes `config_get` to fail silently during pulse-wrapper.sh startup, making `MAX_WORKERS_CAP` and `QUALITY_DEBT_CAP_PCT` fall back to hardcoded defaults instead of reading from `settings.json`. The pulse then operates with potentially wrong worker caps.

## How

1. In `config-helper.sh`, replace all 3 instances of `${!env_var:-}` with:
   ```bash
   env_val=""
   if [[ -n "$env_var" ]]; then
       eval "env_val=\${$env_var:-}"
   fi
   ```
   Or simpler: `env_val="${!env_var}"` (without `:-` suffix, which is the part that breaks on 3.2 — bare `${!var}` works on 3.2).
2. Run ShellCheck on the modified file.
3. Test that `config_get "orchestration.max_workers_cap" "8"` returns the correct value.

## Acceptance Criteria

- [ ] No "bad substitution" errors when sourcing config-helper.sh under `/bin/bash` 3.2 compatibility
- [ ] `config_get` correctly reads env var overrides when set
- [ ] `config_get` correctly falls through to JSONC config when env var is unset
- [ ] ShellCheck clean
- [ ] All 3 occurrences (lines 333, 527, 732) fixed

## Context

- File: `.agents/scripts/config-helper.sh`
- Issue: GH#4929
- Bash 3.2 compat rules: see `prompts/build.txt` "Bash 3.2 Compatibility"
