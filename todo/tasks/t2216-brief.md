<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2216 Brief — Fix pre-commit validate_positional_parameters false positives on awk and comments

**Issue:** GH#19716 (marcusquinn/aidevops). **Blocked-by:** GH#19712 (t2209) — the hook cannot be edited without `--no-verify` until the t2209 fix lands.

## Session origin

Discovered 2026-04-18 during t2209 fix session (PR #19712). The validator at `.agents/scripts/pre-commit-hook.sh:107-150` greps for `\$[1-9]` without stripping single-quoted awk blocks or comments, producing ERROR-level findings on:

- `awk '$1 >= 3'` — awk's `$1` refers to the first input field, not a shell positional parameter
- `# Arguments: $1=staged_todo, $2=task_id` — comments aren't executed

These false positives fire on the hook's own file (lines 139, 143, 325) and on any test file documenting argument names in comments.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19716 for:
- Exact reproduction against the current hook file
- Two fix options (comment/string stripping heuristic vs mini-parser)
- Recommended approach: Option A (strip comments + single-quoted segments before scanning)

## Acceptance criteria

Listed in issue body. Key test: hook passes against its own file with zero positional-parameter violations, AND real misuse (like `foo() { bar "$1"; }` without `local`) is still flagged.

## Tier

`tier:standard` — stripping comments/strings safely in bash is more than a one-line regex tweak, and the validator needs to preserve correct detection of genuine violations. Sonnet-appropriate.
