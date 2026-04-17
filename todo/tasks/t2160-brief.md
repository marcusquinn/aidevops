---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2160: Fix pulse-routines cron schedule extraction (truncates at first space)

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:t2156-followup
- **Created by:** ai-interactive (marcusquinn directing)
- **Parent task:** none
- **Conversation context:** While verifying pulse health after t2156-t2159 systemic fixes merged, observed `~/.aidevops/logs/pulse-wrapper.log` containing repeated `ERROR: unrecognised schedule expression 'cron(*/10'` style messages. Traced to `pulse-routines.sh:213` where the `repeat:` extraction regex `[^[:space:]]+` truncates cron expressions at the first internal space. Every cron-style routine in `aidevops-routines/TODO.md` (r901, r902, r903, r904, r905, r907, r908, r909, r910, r911 — at least 10 routines) has been silently failing since the routine system was introduced. Daily/weekly/monthly forms use `(NN:NN)` with no internal space and work correctly; only `cron(...)` forms break.

## What

Fix `_collect_routines` (or equivalent extraction logic) in `.agents/scripts/pulse-routines.sh` so that `repeat:cron(...)` expressions are extracted in full, including internal spaces between cron fields. Daily, weekly, and monthly forms must continue to work (they already do).

## Why

**Silent failure for the entire cron-routine class.** Confirmed broken expressions from `~/Git/aidevops-routines/TODO.md`:

- `r901 Supervisor pulse repeat:cron(*/2 * * * *)` — pulse dispatch
- `r902 Auto-update repeat:cron(*/10 * * * *)` — framework update check
- `r903 Process guard repeat:cron(*/1 * * * *)` — runaway-process kill
- `r904 Worker watchdog repeat:cron(*/2 * * * *)` — headless worker monitoring
- `r905 Memory pressure monitor repeat:cron(*/1 * * * *)`
- `r907 Contribution watch repeat:cron(0 * * * *)` — FOSS activity scan
- `r908 Profile README update repeat:cron(0 * * * *)`
- `r909 Screen time snapshot repeat:cron(0 */6 * * *)`
- `r910 Skills sync repeat:cron(*/5 * * * *)`
- `r911 OAuth token refresh repeat:cron(*/30 * * * *)`

Every single one of these silently fails on every pulse cycle. The error is logged but the routine never executes. The `r004 Nightly repo triage repeat:cron(15 2 \* \* \*)` entry in canonical `aidevops/TODO.md` works around the bug by escaping asterisks with backslashes, but that's documentation noise and wouldn't help with `*/N` step expressions.

The bug is a class-defect masked by the daily/weekly/monthly forms working correctly. There is no observable user-facing failure mode (the routines just don't run); the only signal is repeated ERROR lines in the pulse log.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — `.agents/scripts/pulse-routines.sh` only. Test file is additive (new file, doesn't count toward the 2-file gate per convention).
- [x] **Every target file under 500 lines?** `pulse-routines.sh` is 253 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — the fix needs a regex change (single line) but a regression test needs to be designed.
- [x] **No judgment or design decisions?** Minor: the fix could use `[^[:space:]]+` extended to allow spaces inside parens, OR use a different field-extraction strategy. Recommend the regex extension.
- [x] **No error handling or fallback logic to design?** No — the parser already errors gracefully on malformed input.
- [x] **No cross-package or cross-module changes?** Single file + new test.
- [x] **Estimate ≤ 1 hour?** Yes — single regex change + 4-6 test cases.
- [x] **4 or fewer acceptance criteria?** Yes — 4 below.

**Verdict: tier:standard.** Single file fix, but the regex change has subtle implications (must not break daily/weekly/monthly extraction) and needs regression test coverage.

## How

### Files to modify

- **EDIT: `.agents/scripts/pulse-routines.sh:213`** — current line:

  ```bash
  if [[ "$line" =~ repeat:([^[:space:]]+) ]]; then
  ```

  Replace with a regex that handles balanced parentheses. Recommended:

  ```bash
  if [[ "$line" =~ repeat:((daily|weekly|monthly|cron)\([^)]+\)) ]]; then
  ```

  This matches `repeat:` followed by one of the four schedule keywords, an opening paren, any characters except `)`, and a closing paren. The captured group `BASH_REMATCH[1]` returns the full expression including parens.

- **NEW: `.agents/scripts/tests/test-pulse-routines-cron.sh`** — model on `.agents/scripts/tests/test-claim-task-id-todo-collision.sh` for structure (header, helper functions, test cases, summary). Test cases:

  1. `daily(@06:00)` extracted in full
  2. `weekly(mon@09:00)` extracted in full
  3. `monthly(1@09:00)` extracted in full
  4. `cron(*/2 * * * *)` extracted in full (the bug — currently truncated to `cron(*/2`)
  5. `cron(15 2 \* \* \*)` (escaped form) still extracted in full
  6. Trailing tags after the schedule (`~1m run:scripts/foo.sh`) not consumed by the schedule regex

### Reference patterns

- Model on `.agents/scripts/tests/test-claim-task-id-todo-collision.sh` for test harness structure (recently merged via PR #19461).
- The schedule-expression grammar is already defined in `.agents/scripts/routine-schedule-helper.sh:129-175` (function `_parse_expression`). The fixed regex must produce strings that match the grammar there.

### Verification

```bash
# Run the new test
bash .agents/scripts/tests/test-pulse-routines-cron.sh

# Manually verify pulse can extract the cron routines
~/.aidevops/agents/scripts/pulse-routines.sh --dry-run 2>&1 | grep "is due"

# Confirm no more ERROR lines in pulse log
tail -50 ~/.aidevops/logs/pulse-wrapper.log | grep "unrecognised schedule" | wc -l
# Expected: 0 after fix is deployed
```

### Rollout

After merge, the deployed pulse will inherit the fix on the next `aidevops update` cycle (now automatic via t2156's drift detection — landed in PR #19462). No manual intervention needed.

## Acceptance Criteria

1. `.agents/scripts/pulse-routines.sh` correctly extracts `cron(...)` expressions with internal spaces, in addition to the existing daily/weekly/monthly forms.
2. `.agents/scripts/tests/test-pulse-routines-cron.sh` exists and passes locally with the 6 test cases above.
3. After deployment, `~/.aidevops/logs/pulse-wrapper.log` shows zero new `ERROR: unrecognised schedule expression` lines for cron routines on subsequent pulse cycles.
4. Existing routine extraction (daily/weekly/monthly forms in `r004` and similar) continues to work — verified by either running the existing test suite or by including those forms in the new test.

## Dependencies

- None blocking. This is an isolated fix.

## Out of scope

- Audit `aidevops-routines/TODO.md` to verify all 10+ cron routines actually execute correctly after the fix — that's verification work, can be done as a follow-up if any routine still misbehaves.
- Removing the asterisk-escaping in `r004` (`cron(15 2 \* \* \*)` → `cron(15 2 * * *)`) — purely cosmetic, separate task.
- Migrating cron expressions to a YAML/JSON registry instead of inline TODO.md fields — much larger architectural change, not justified by this single bug.

## Context

- **Symptom**: Repeated `ERROR: unrecognised schedule expression 'cron(*/10'` in `~/.aidevops/logs/pulse-wrapper.log`.
- **Root cause**: `pulse-routines.sh:213` regex `repeat:([^[:space:]]+)` is greedy on non-whitespace, so `cron(*/10 * * * *)` becomes `cron(*/10` (truncated at first space inside the parens).
- **Why it went unnoticed**: The pulse keeps running fine because the dispatch path doesn't depend on routines — routines are an additive feature. The error only shows up in logs, never as a user-facing failure. Daily/weekly/monthly forms (`(@HH:MM)`, `(day@HH:MM)`, `(N@HH:MM)`) have no internal spaces, so they extract correctly and gave a false sense of "routines work".
- **Why this is high-value to fix**: Routines like `r907 Contribution watch` are the user-visible mechanism for monitoring FOSS activity. If they silently haven't been running, the user has been missing notifications.
