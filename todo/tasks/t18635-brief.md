# t18635: fix(pulse): silence missing routines registry noise for repos without routines

## Origin

- Created: 2026-10-09, interactive session, found during a background-worker readiness check of registered repos.
- Issue: GH#34169. Delivered by PR #34170.

## What

Pulse `evaluate_routines` logs `TODO.md has a missing, duplicate, or malformed routines registry — skipping` on every cycle for every pulse-enabled repo whose `TODO.md` simply has no `## Routines` section. Treat an absent registry with no routine-shaped lines as "no routines": skip silently. Keep the fail-closed diagnostic for duplicate headings, malformed dedicated layouts, unclosed fences/comments, and routine-shaped lines (`- [x] rNNN ... repeat:`) outside any registry.

## Why

Observed in `~/.aidevops/logs/pulse.log`: 40 registered repos each log the warning 48 times in the retained window. The standard `aidevops init` TODO template has no `## Routines` section, so every freshly initialised repo looks broken. This made healthy repos look misconfigured during a background-worker readiness check. Dispatch behaviour was correct (nothing to run); only the diagnostic was wrong.

## How

- `.agents/scripts/pulse-routines.sh` `_routine_extract_section` (around line 579): when `section_count == 0`, there is no structural error, and no routine-shaped active line was seen, return 2 (no registry) instead of 1. Track routine-shaped lines with a regex on `_RML_TRIMMED_LINE`.
- `evaluate_routines` (around line 884): on rc 2 `continue` silently; rc 1 keeps the existing log line.
- `.agents/reference/routines.md` lines 33-38: document that an absent registry means no routines, while misplaced routine lines still fail closed with a diagnostic.
- `.agents/scripts/tests/test-pulse-routines-selector.sh` Case 8: keep the `r-missing` fixture failing closed, and add an assertion that a TODO with no registry and no routine lines returns 2.

## Acceptance

- A TODO.md with no `## Routines` heading and no routine lines produces no pulse log line and dispatches nothing.
- A missing heading with a routine-shaped line still logs the malformed diagnostic.
- Duplicate/malformed cases still fail closed.
- `test-pulse-routines-selector.sh` and ShellCheck pass.

## Files Scope

- `.agents/scripts/pulse-routines.sh`
- `.agents/reference/routines.md`
- `.agents/scripts/tests/test-pulse-routines-selector.sh`
