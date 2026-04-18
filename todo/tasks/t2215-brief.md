<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2215 Brief — Fix pre-commit validate_return_statements arithmetic syntax error

**Issue:** GH#19714 (marcusquinn/aidevops). **Blocked-by:** GH#19712 (t2209) — the hook cannot be edited without `--no-verify` until the t2209 fix lands.

## Session origin

Discovered 2026-04-18 during t2209 fix session (PR #19712) while running the full pre-commit hook against its own file. The `|| echo "0"` fallback on `grep -c` in `pre-commit-hook.sh:93-95` produces `"0\n0"` when grep finds zero matches (grep outputs "0" AND exits 1), and the subsequent `[[ $functions -gt 0 ]]` on line 97 can't parse the two-line value as an integer. Non-fatal stderr pollution on every hook run, dormant until PR #19683 / t2191 installed the dispatcher.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19714 for:
- Exact reproduction command
- Root cause analysis with the `grep -c || echo "0"` anti-pattern explained
- Two fix options (parameter-default or arithmetic coercion)
- File references with line numbers

## Acceptance criteria

Listed in issue body. Key assertion: zero "arithmetic syntax error" messages in hook stderr.

## Tier

`tier:simple` — single-line fix (or two if applied to both `functions` and `returns` vars), no new code paths, verification is a `grep -c`.
