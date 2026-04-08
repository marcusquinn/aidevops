<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Routines Reference

Recurring operational jobs live in `TODO.md` under a dedicated `## Routines` section. They are git-tracked, human-readable, and use `r`-prefixed IDs to distinguish them from one-off `t`-prefixed tasks.

## Format

```markdown
## Routines

- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [x] r002 Daily health check repeat:daily(@06:00) ~2m run:custom/scripts/health-check.sh
- [ ] r003 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
- [x] r004 Nightly repo triage repeat:cron(15 2 * * *) ~20m agent:Build+
```

## Fields

- `[x]` — enabled routine; schedulers and pulse-style dispatchers may run it
- `[ ]` — disabled or paused routine; skip it without deleting the definition
- `r001` — stable routine ID; never reuse IDs
- Description — human-readable name of the routine
- `repeat:` — recurrence expression
- `~30m` — expected runtime estimate
- `run:` — path relative to `~/.aidevops/agents/` for deterministic script execution
- `agent:` — agent name for LLM-backed execution through `headless-runtime-helper.sh`

## `repeat:` syntax

- `daily(@06:00)` — every day at 06:00 local time
- `weekly(mon@09:00)` — every Monday at 09:00 local time
- `monthly(1@09:00)` — on day 1 of each month at 09:00 local time
- `cron(15 2 * * *)` — raw cron expression for schedules that do not fit the shorthand forms

Use the shorthand forms when possible. Use `cron(...)` only when the schedule needs cron-level flexibility.

## Dispatch rules

1. `run:` present → execute the script directly with no LLM tokens
2. `agent:` present → dispatch via `headless-runtime-helper.sh` to the named agent
3. Both present → prefer `run:`; the routine is deterministic-first
4. Neither present → default to `run:custom/scripts/{routine-name}.sh` if that script exists, otherwise `agent:Build+`

## Execution model

- Keep SOP, targets, and schedule independent; do not collapse them into one giant prompt
- Use `run:` for deterministic scripts, exports, health checks, and monitor-style jobs
- Use `agent:` when the routine needs judgment, summarisation, triage, or outbound drafting
- Disabled routines stay in `TODO.md` for auditability; do not delete them just to pause execution

## Relationship to `/routine`

Use `/routine` to design, dry-run, and install scheduler entries for the routines defined in `TODO.md`. The command doc is the operator workflow; `TODO.md` is the canonical routine registry.

## Anti-patterns

- Creating a separate routine registry when `TODO.md` can hold the definition
- Repeating one-off task entries for routine execution history
- Running deterministic script routines through an LLM agent unnecessarily
- Hiding schedule semantics outside version control
