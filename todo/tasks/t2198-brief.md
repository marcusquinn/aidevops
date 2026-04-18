<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2198 Brief — Pre-push complexity regression hook to shift-left CI checks

**Issue:** GH#19685 (marcusquinn/aidevops) — issue body is the canonical spec.

## Session origin

Filed 2026-04-18 from the t2189 interactive session (PR #19682). During t2189 I committed a `setup_test_env` at 126 lines that tripped the function-complexity gate — only caught when I manually re-ran `complexity-regression-helper.sh check` post-commit, forcing an additional refactor commit (afa76b00d). CI would catch it eventually but only after a wasted push + wait cycle. This hook shifts the check left by ~5 seconds at push time.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19685 for:
- Hook location `.agents/hooks/complexity-regression-pre-push.sh`
- Installation extended from `install-privacy-guard.sh` → renamed `install-pre-push-guards.sh`
- Three metrics to check: function-complexity, nesting-depth, file-size
- `COMPLEXITY_GUARD_DISABLE=1` bypass pattern
- Fail-open behaviour offline

## Acceptance criteria

Listed in the issue body. Key gates: blocks push with new function >100 lines; passes on clean diff; bypass env var works; documented in AGENTS.md.

## Tier

`tier:standard` — new hook + installer refactor + setup.sh integration + docs, 4 files touched, reuses the privacy-guard install pattern.

## Relation to t2189

Would have caught the setup_test_env regression I introduced. Logging this task IS the self-improvement loop the framework encourages.
