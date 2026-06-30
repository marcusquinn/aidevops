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
- Collapsing SOP, targets, and schedule into a single prompt — keep them independent

## Runtime Health Audit (r-runtime-audit, t3072)

The supervisor LLM cycle triages GitHub state — issues, PRs, labels, scanner findings — but never inspects processes, logs, pulse-stats counters, or deployed-script mtimes. That gap is a structural blind spot: bugs visible to any operator running `ps`, `jq`, `tail` go unraised for hours.

`r-runtime-audit` runs a registry of small detectors against **local files only** — no GitHub API or GraphQL calls (which would amplify the blind spot many of the detectors surface). When a detector fires, the orchestrator either prints the finding (`--dry-run`, default) or files an auto-dispatch issue tagged with `<!-- aidevops:generator=runtime-audit detector=<id> -->`. The pre-dispatch validator re-runs the cited detector before any worker spawns, so transient regressions (the kind that resolve before a worker arrives) are auto-closed instead of consuming worker time.

### Detectors

| ID | Surfaces |
|----|----------|
| `counter-trend-delta` | 3x regression in any pulse-stats counter over the last 4h vs prior 4h |
| `process-count-anomaly` | More than 5 `pulse-wrapper.sh` processes (lifecycle reap leak) |
| `deployed-vs-source-mtime-drift` | Hot deployed script lags source by >24h (stale deploy) |
| `log-pattern-novelty` | New high-frequency log template absent from prior baseline |
| `idle-state-stuck` | `pulse.pid` shows `SETUP:<pid>` with a dead PID (lifecycle wedged) |

Each detector lives in `.agents/scripts/runtime-audit-rules/<id>.sh` as a self-contained file with `runtime_audit_id` + `runtime_audit_check` functions. To add a new detector, copy any existing rule file and add a fixture pair to `.agents/scripts/tests/test-runtime-audit-detectors.sh`.

### Operator workflow

1. **Dry-run first.** The routine ships **disabled** in `TODO.md` so the operator can review baseline noise: `runtime-health-audit-helper.sh --dry-run`.
2. **Tune thresholds.** Each detector has env-overridable inputs (e.g. `REGRESSION_MULT`, `LEAK_THRESHOLD`, `DRIFT_SECONDS`). If the dry-run flags benign conditions, raise the threshold or add the routine entry to `~/.aidevops/cron-overrides.conf` with custom env.
3. **Enable.** Flip the `[ ]` to `[x]` in the `## Routines` block once you're satisfied.
4. **Investigate findings.** Filed issues are real — they cite local files an operator can confirm in seconds. Close with rationale if benign; otherwise the issue body itself contains the worker-ready brief (file paths, verification commands, acceptance criteria) per t1900.

### Anti-patterns specific to this routine

- **Adding a detector that calls `gh`, `curl`, or any network API.** The whole point is local-only inspection — network calls amplify the very blind spot we're closing.
- **Filing a finding without a marker.** The marker is what the pre-dispatch validator uses to re-check before dispatch. Without it, stale findings consume worker time.
- **Lowering thresholds to surface "everything".** Every false positive trains the operator to ignore the routine. Tune for high precision; the supervisor's task triage is the lower-precision layer.

## Pulse Check (r915)

`r915` runs `pulse-check-helper.sh apply` once daily. Unlike
`r-runtime-audit`, it is intentionally allowed to make bounded GitHub reads: its
job is to compare **current worker utilisation** with the **repos.json
auto-dispatch queue** and provider/API budget signals.

The helper is also the backing command for `/pulse-check` in interactive chats:

```bash
pulse-check-helper.sh report
pulse-check-helper.sh json
pulse-check-helper.sh apply --repo owner/repo
```

It gathers evidence from:

- `pulse-current-state-helper.sh --window 15m --json` for live dispatch,
  launch, guardrail, and API-budget state.
- `worker-activity-helper.sh summary --since 1h/24h --json --no-pr-check` for
  canonical recent and historical worker outcomes.
- A privacy-preserving aggregate scan of open `auto-dispatch` issues across
  pulse-enabled `repos.json` entries.

`apply` mode files only deduplicated self-improvement issues with the marker
`<!-- aidevops:generator=pulse-check finding=... -->`; issue bodies must stay
aggregate-only and must not include private repo names, local paths, issue
titles, or raw worker examples.
