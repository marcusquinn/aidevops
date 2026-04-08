<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Routines Reference

Recurring operational jobs live in `TODO.md` under `## Routines`. Git-tracked, `r`-prefixed IDs distinguish them from one-off `t`-prefixed tasks. Use `/routine` to design, dry-run, and install scheduler entries.

## Format

```markdown
## Routines

- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [x] r002 Daily health check repeat:daily(@06:00) ~2m run:custom/scripts/health-check.sh
- [ ] r003 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
- [x] r004 Nightly repo triage repeat:cron(15 2 * * *) ~20m agent:Build+
```

## Fields

| Field | Meaning |
|-------|---------|
| `[x]` / `[ ]` | Enabled / disabled (keep disabled entries for auditability) |
| `r001` | Stable ID — never reuse |
| `repeat:` | Recurrence expression (see below) |
| `~30m` | Expected runtime estimate |
| `run:` | Script path relative to `~/.aidevops/agents/` — deterministic, no LLM tokens |
| `agent:` | Agent name dispatched via `headless-runtime-helper.sh` |

## `repeat:` syntax

| Form | Example | When to use |
|------|---------|-------------|
| `daily(@HH:MM)` | `daily(@06:00)` | Every day at a fixed time |
| `weekly(day@HH:MM)` | `weekly(mon@09:00)` | Weekly on a named day |
| `monthly(N@HH:MM)` | `monthly(1@09:00)` | Day N of each month |
| `cron(expr)` | `cron(15 2 * * *)` | Complex schedules only |

## Dispatch rules

1. `run:` present → execute script directly (deterministic-first)
2. `agent:` present → dispatch via `headless-runtime-helper.sh`
3. Both present → prefer `run:`
4. Neither → try `custom/scripts/{routine_id}.sh` (e.g. `r001.sh`), else `agent:Build+`

Use `run:` for scripts, exports, health checks. Use `agent:` when judgment or summarisation is needed.

## Anti-patterns

- Separate routine registry outside `TODO.md`
- One-off task entries for routine execution history
- Running deterministic scripts through an LLM agent
- Schedule semantics outside version control
