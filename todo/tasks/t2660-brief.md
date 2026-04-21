# t2660: route operational narration to stderr — fix ANSI pollution of command substitution callers

## Origin

- **Created:** 2026-04-21
- **Session:** surfaced during t2451 session monitoring pulse logs post-deploy
- **Created by:** interactive session (agent-driven)

## Canonical Brief

**The authoritative brief for this task is the GitHub issue body:**

https://github.com/marcusquinn/aidevops/issues/20212

The issue body contains all required sections (Task/What, Why, How, Acceptance, Files to modify, Session Origin, Notes) and is the single source of truth. This stub exists only to satisfy the brief-file-exists gate.

## Task ID reconciliation note

This task carries ID `t2660` from the `CAS_EXHAUSTION_FATAL=0` `+100` offset fallback because the bug itself blocked normal online CAS claim during filing. Real counter was around `t2460` at the time of filing (GH#20212). On successful fix + next online claim, reconciliation should align this entry with its actual sequence position.

## Session-Specific Context

Two concrete reproducers captured in the pulse log and interactive shell during the filing session:

1. `pulse-canonical-maintenance.sh:334 (deployed)` — `sweep_count=$((sweep_count + removed))` with `removed` = ANSI-coloured worktree-helper.sh output.
2. `claim-task-id.sh:792` — `local check_id=$((first_id + i))` with `first_id` = ANSI-coloured pre-commit-hook.sh banner.

Both crashes printed the literal colour-coded string as the "error token" in the arithmetic syntax error, making the stream source visually identifiable.
