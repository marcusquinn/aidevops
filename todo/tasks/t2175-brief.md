<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2175: pulse-routines: silence `unrecognised schedule expression` noise (t-prefix false-match + unsupported `persistent` type)

## Origin

- **Created:** 2026-04-18
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** While investigating why PR #19621 (GH#19620) wasn't being picked up by the pulse, the pulse-wrapper.log showed a continuous stream of `ERROR: unrecognised schedule expression 'persistent'` and `ERROR: unrecognised schedule expression '([^[:space:]]+)\`'` on every pulse cycle. User flagged as a secondary bug to brief out.

## What

Stop the `pulse-routines.sh` routine scanner from emitting two categories of spurious `unrecognised schedule expression` errors on every pulse cycle:

1. **False-match on `t`-prefix task descriptions.** Task entries whose *description text* happens to contain the literal string `repeat:` (e.g. `t2160` in `aidevops/TODO.md` references `pulse-routines.sh:213` regex `` `repeat:([^[:space:]]+)` ``) are matched by the routine-scanner grep and their description is parsed as a schedule. Observed exact error: `ERROR: unrecognised schedule expression '([^[:space:]]+)\`'`.
2. **`repeat:persistent` unsupported.** `aidevops-routines/TODO.md:28` declares `r912 Dashboard server repeat:persistent ~0s run:server/index.ts`. This is a legitimate concept (long-running launchd-supervised process, not a scheduled invocation) but `routine-schedule-helper.sh::parse_schedule` rejects it. Observed exact error: `ERROR: unrecognised schedule expression 'persistent'`.

After this task: pulse-wrapper.log contains zero `unrecognised schedule expression` lines during steady-state operation, AND `r912` continues to not be dispatched by the routine evaluator (the dashboard is launchd-managed, not pulse-managed).

## Why

Two independent harms:

- **Log noise.** The routine evaluator runs every pulse cycle (~120s). Every cycle produces 2+ of these errors. The pulse-wrapper.log fills with thousands of lines of spurious errors, which masks real problems and makes log triage harder.
- **Semantic ambiguity.** The t-prefix false-match reveals a real selector bug: any completed t-task whose description mentions `repeat:` (common when documenting routine bugs) gets parsed as a routine. Today it's noise; tomorrow someone documents a routine with `repeat:cron(0 * * * *)` inside a task description and the pulse silently dispatches phantom work.

Root cause context: `t2160` (PR #19468, merged 2026-04-17) fixed a related regex bug (schedule truncation at first space). That fix changed the regex but did not tighten the grep selector to require the `r`-prefix, so t-prefix task descriptions still match.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (pulse-routines.sh + test file)
- [x] **Every target file under 500 lines?** — `pulse-routines.sh` is ~260 lines
- [ ] **Exact `oldString`/`newString` for every edit?** — the approach below has a sketch but the exact surrounding context needs a re-read of the current file. Worker must confirm the selector and the persistent-handling block.
- [x] **No judgment or design decisions?** — policy is clear: ignore t-prefix entries; treat `persistent` as "skip scheduling, launchd owns it".
- [x] **No error handling or fallback logic to design?**
- [x] **No cross-package or cross-module changes?** — one helper, one test.
- [x] **Estimate 1h or less?**
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:standard`

**Tier rationale:** Two-change bugfix in one helper plus a regression test. Selector is clear and parse-helper is clear. Default to standard because the worker must re-read the current grep/regex wording in `pulse-routines.sh` to write exact oldString blocks (the snippet below is the 2026-04-17 post-t2160 version).

## PR Conventions

Leaf task — use `Resolves #NNN` when the GitHub issue is created.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-routines.sh:196-250` — tighten the routine-scan selector so only `r`-prefixed IDs match, and short-circuit `persistent` before calling the schedule parser.
- `EDIT: .agents/scripts/routine-schedule-helper.sh:120-175` — recognise `persistent` as a valid schedule keyword that always reports "not due" (the job is launchd-supervised; the pulse should never try to start it).
- `NEW: .agents/scripts/tests/test-pulse-routines-selector.sh` — regression test covering both false-match cases.

### Implementation Steps

1. **Tighten the scan selector.** In `pulse-routines.sh`, the grep at line ~250 currently reads:

   ```bash
   grep -E '^\s*-\s*\[x\].*repeat:' "$todo_file"
   ```

   This matches any completed task with `repeat:` anywhere. Change to require an `r`-prefixed task ID immediately after the checkbox:

   ```bash
   grep -E '^\s*-\s*\[x\][[:space:]]+r[0-9]+[[:space:]].*repeat:' "$todo_file"
   ```

   Verify by running against `~/Git/aidevops/TODO.md` — the t2160 line must NOT match; the dozen r-prefix entries in `~/Git/aidevops-routines/TODO.md` must still match.

2. **Add `persistent` handling in `pulse-routines.sh` evaluator.** Before calling `routine-schedule-helper.sh is-due`, short-circuit:

   ```bash
   if [[ "$repeat_expr" == "persistent" ]]; then
       # r912-style: job is managed by launchd/equivalent supervisor,
       # not the pulse scheduler. Skip silently.
       continue
   fi
   ```

   Place this right after the repeat: expression is extracted and before any helper call that would parse it.

3. **Recognise `persistent` in the schedule parser (defensive).** In `routine-schedule-helper.sh::parse_schedule` (line ~120-175), add a case before the final "unrecognised" error:

   ```bash
   if [[ "$expr" == "persistent" ]]; then
       printf 'persistent'
       return 0
   fi
   ```

   And in `is-due` (line ~570-580), make `persistent` always return 1 (not due):

   ```bash
   case "$parsed" in
       "persistent")
           return 1  # launchd-supervised; never due from the pulse
           ;;
       ...
   esac
   ```

   This makes `persistent` a supported keyword at both layers, in case callers bypass the pulse-routines.sh short-circuit.

4. **Regression test.** Create `.agents/scripts/tests/test-pulse-routines-selector.sh` with the following cases:
   - TODO.md containing ONLY `- [x] t2160 ... \`repeat:([^[:space:]]+)\` ...` — routine scanner finds 0 routines.
   - TODO.md containing `- [x] r912 Dashboard server repeat:persistent ~0s run:server/index.ts` — routine scanner finds 1 routine, but `is-due` returns 1 (not due), no error output.
   - TODO.md containing `- [x] r901 Supervisor pulse repeat:cron(*/2 * * * *) ...` — routine scanner finds 1 routine, `is-due` behaves normally.
   - Mixed TODO.md containing both t-prefix with `repeat:` in description AND r-prefix routines — only r-prefix matches.

   Model the test structure on `.agents/scripts/tests/test-compute-counter-seed-octal.sh` (setup_sandbox pattern, inline TODO.md fixtures via `_make_todo`, explicit pass/fail counts, exit 0/1).

### Verification

```bash
# 1. Unit regression
bash .agents/scripts/tests/test-pulse-routines-selector.sh
# Expect: Results: 4 passed, 0 failed

# 2. Tail pulse-wrapper.log after the fix deploys:
tail -f ~/.aidevops/logs/pulse-wrapper.log | grep -E "unrecognised schedule expression"
# Expect: no output during steady-state pulses (wait ~5m for 2-3 cycles).

# 3. r912 (dashboard) still running under launchd, NOT dispatched by pulse:
launchctl list | grep -i dashboard
# Expect: dashboard job present (0 PID expected unless actively running).
grep "routine r912" ~/.aidevops/logs/pulse.log | tail -5
# Expect: no "routine r912 is due" lines after the fix (or at most one tail
# entry before the fix landed).

# 4. Shellcheck clean on both edited files
shellcheck .agents/scripts/pulse-routines.sh .agents/scripts/routine-schedule-helper.sh
```

## Acceptance Criteria

- [ ] `pulse-routines.sh` routine-scan grep requires `r[0-9]+` prefix after the checkbox; t-prefix entries with `repeat:` in their description no longer match.

  ```yaml
  verify:
    method: codebase
    pattern: 'grep -E .\^\\s\*-\\s\*\\\[x\\\]\[\[:space:\]\]\+r\[0-9\]\+'
    path: .agents/scripts/pulse-routines.sh
  ```

- [ ] `repeat:persistent` recognised at both the pulse-routines.sh scanner (short-circuit) and the `routine-schedule-helper.sh parse_schedule` (returns `persistent` keyword). `is-due` on a `persistent` expression returns non-zero (not due).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/routine-schedule-helper.sh is-due persistent 0; test $? -ne 0"
  ```

- [ ] Zero `unrecognised schedule expression` lines in a fresh pulse cycle after deploy.

  ```yaml
  verify:
    method: manual
    prompt: "After deploy, tail ~/.aidevops/logs/pulse-wrapper.log for 5 minutes and confirm no 'unrecognised schedule expression' lines appear."
  ```

- [ ] `.agents/scripts/tests/test-pulse-routines-selector.sh` exists and passes 4/4.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-routines-selector.sh"
  ```

- [ ] Shellcheck clean on all modified files.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-routines.sh .agents/scripts/routine-schedule-helper.sh .agents/scripts/tests/test-pulse-routines-selector.sh"
  ```

## Context & Decisions

- **Why tighten the selector instead of tightening the regex alone?** The regex fixed in t2160 only determines what gets captured as the schedule *after* a line matches. The selector fix (require `r`-prefix) is the semantic gate — it says "routines are a different namespace from tasks, enforce it at the grep level". This matches how the TODO.md format already treats `r001-r899` as a reserved namespace.
- **Why not remove `repeat:persistent` from `aidevops-routines/TODO.md:28` instead?** The dashboard IS conceptually a persistent routine, managed by launchd. The TODO.md entry serves as documentation that it exists and is enabled. Making the scheduler aware of the keyword (rather than forcing users to omit/hide persistent jobs) is the cleaner long-term model — future persistent routines (other daemons) will want the same treatment.
- **Why no log-suppression (throttle duplicate errors) approach?** Suppression hides real bugs. The root cause is two mis-classifications; fix them directly.
- **Non-goals:** this task does NOT add schedule types beyond `persistent`. No `systemd.socket` or `on-demand` or similar. If those are wanted later, they are separate tasks.

## Relevant Files

- `.agents/scripts/pulse-routines.sh:196-250` — the routine scanner loop (grep selector, regex extraction, description parsing).
- `.agents/scripts/routine-schedule-helper.sh:120-175` — `parse_schedule` function with the 4 existing branches (daily/weekly/monthly/cron) and the catch-all error.
- `.agents/scripts/routine-schedule-helper.sh:570-600` — `is-due` subcommand dispatcher that calls `parse_schedule`.
- `~/Git/aidevops-routines/TODO.md:28` — the `r912 persistent` entry that triggered error-path #2.
- `~/Git/aidevops/TODO.md` — contains the `t2160` completed entry that triggered error-path #1 (description has `` `repeat:([^[:space:]]+)` ``).
- `.agents/scripts/tests/test-compute-counter-seed-octal.sh` — pattern to model the new regression test after (setup_sandbox, _make_todo, pass/fail counts, main() runner).

## Dependencies

- **Blocked by:** none.
- **Blocks:** cleaner pulse-wrapper.log for all future investigation (t2176 investigation of the bash re-exec guard will be easier without this noise).
- **External:** none.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Re-read pulse-routines.sh selector + regex (~50 lines), routine-schedule-helper.sh parse+is-due (~80 lines). |
| Implementation | 25m | Selector tighten, persistent short-circuit, parser extension, is-due case. |
| Testing | 20m | New regression test (~120 lines), local run, pulse log verification after deploy. |
| **Total** | **~55m** | Fits tier:standard. |
