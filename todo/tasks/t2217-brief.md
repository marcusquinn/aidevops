<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2217 Brief — Fix pre-commit validate_string_literals over-counting empty strings and numeric literals

**Issue:** GH#19717 (marcusquinn/aidevops). **Blocked-by:** GH#19712 (t2209) — the hook cannot be edited without `--no-verify` until the t2209 fix lands.

## Session origin

Discovered 2026-04-18 during t2209 fix session (PR #19712). The validator's regex `"[^"]*"` at `pre-commit-hook.sh:139,143` (approximately) matches the empty string `""` and numeric strings like `"0"`/`"1"`, producing warnings like "28x: \"\"" on every run. These aren't genuine "extract a constant" opportunities — they're just empty strings, return codes, and trivial values.

The warnings don't block commits (they're WARNING level, not ERROR), but they pollute every hook invocation with noise that buries legitimate repeated-literal warnings.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19717 for:
- Exact reproduction
- Fix direction: add minimum-length threshold (`{4,}`) and exclude purely-numeric strings via `grep -vE '^"[0-9]+\.?[0-9]*"$'`
- Line references

## Acceptance criteria

Listed in issue body. Core assertion: `""`, `"0"`, `"1"` no longer flagged; meaningful constants like `"shared-constants.sh"` still flagged when 3+ occurrences exist.

## Tier

`tier:simple` — two-line regex tightening at known line numbers, no new logic paths.
