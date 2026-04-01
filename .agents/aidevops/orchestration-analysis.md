---
description: Daily orchestration efficiency analysis — reads pre-collected JSON report, produces ranked findings and auto-files issues
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
---

# Orchestration Efficiency Analysis

<!-- AI-CONTEXT-START -->

## Purpose

Analyse the pre-collected orchestration efficiency report and produce:

1. **Top 3 findings** — ranked by impact, with specific recommendations and expected savings
2. **Trend analysis** — compare today vs yesterday vs 7-day average (when historical reports exist)
3. **Meta-assessment** — is the collected data sufficient for diagnosis? What additional instrumentation would improve future analysis?
4. **Auto-filed issues** — findings that cross severity thresholds become GitHub issues

This agent does NOT collect data. It reads the structured JSON from `orchestration-efficiency-collector.sh` (Phase 1) and produces analysis only.

<!-- AI-CONTEXT-END -->

## Input

The report file path is passed as the first argument, or auto-detected from today's date:

```bash
REPORT_FILE="${1:-${HOME}/.aidevops/logs/efficiency-report-$(date -u +%Y-%m-%d).json}"
```

Read the report with:

```bash
cat "$REPORT_FILE"
```

If the file does not exist, exit with: `ERROR: No report file found at $REPORT_FILE. Run orchestration-efficiency-collector.sh first.`

## Analysis Framework

### Metric Thresholds

Use these thresholds to classify findings as `critical`, `high`, `medium`, or `low`:

| Metric | Critical | High | Medium | Low |
|--------|----------|------|--------|-----|
| `token_efficiency.llm_skip_rate_pct` | >80% | 60-80% | 40-60% | <40% |
| `token_efficiency.tokens_wasted_on_stalls` | >500K | 200K-500K | 50K-200K | <50K |
| `errors.launch_failure_rate_pct` | >20% | 10-20% | 5-10% | <5% |
| `errors.watchdog_kills_stalled` | >10 | 5-10 | 2-5 | <2 |
| `errors.provider_error_count` | >50 | 20-50 | 5-20 | <5 |
| `concurrency.fill_rate_pct` | <20% | 20-40% | 40-70% | >70% |
| `concurrency.backoff_duration_total_secs` | >7200 | 3600-7200 | 1800-3600 | <1800 |
| `audit_trails.issues_closed_without_pr_link` | >5 | 3-5 | 1-3 | 0 |
| `audit_trails.prs_without_merge_summary` | >5 | 3-5 | 1-3 | 0 |
| `speed.worker_completion_p90_secs` | >7200 | 3600-7200 | 1800-3600 | <1800 |

### Finding Format

Each finding must include:

```
## Finding N: <title>

**Severity**: critical | high | medium | low
**Metric**: <metric.path> = <value> (threshold: <threshold>)
**Impact**: <quantified impact — tokens saved, time saved, issues unblocked>
**Root cause hypothesis**: <1-2 sentences>
**Recommendation**: <specific, actionable change — script name, config key, or workflow step>
**Expected saving**: <quantified estimate>
```

### Trend Analysis

When `historical_context.has_yesterday_report` or `historical_context.has_week_ago_report` is true:

1. Read the referenced report files
2. Compare key metrics: `token_efficiency.total_cost_usd`, `errors.launch_failure_rate_pct`, `concurrency.fill_rate_pct`, `throughput.prs_merged`
3. Report direction: `↑ improved`, `↓ degraded`, `→ stable` (±5% = stable)
4. Flag regressions (degraded vs yesterday AND vs week-ago snapshot) as additional findings

Note: `historical_context.week_ago_report_path` is a single snapshot from 7 days ago, not a rolling 7-day average. Use it for point-in-time comparison only.

### Meta-Assessment

After producing findings, assess the data quality:

1. **Coverage gaps**: Which metrics are `0` or missing that should have data? List them.
2. **Instrumentation improvements**: What additional data points would enable better diagnosis?
3. **Confidence level**: `high` (all key metrics populated), `medium` (some gaps), `low` (major gaps)

If confidence is `low`, the meta-assessment itself becomes a `medium` finding.

## Auto-Filing Issues

For each `critical` or `high` finding, file a GitHub issue:

```bash
REPO="marcusquinn/aidevops"
SIG_FOOTER=$(~/.aidevops/agents/scripts/gh-signature-helper.sh footer \
  --model "${ANTHROPIC_MODEL:-unknown}" \
  --no-session --session-type worker 2>/dev/null || echo "")

gh issue create \
  --repo "$REPO" \
  --title "fix: <finding title from analysis>" \
  --label "auto-dispatch,priority:high" \
  --body "## Orchestration Efficiency Finding

**Date**: $(date -u +%Y-%m-%d)
**Severity**: <critical|high>
**Metric**: <metric.path> = <value>

### Root Cause
<root cause hypothesis>

### Recommendation
<specific recommendation>

### Expected Impact
<quantified saving>

_Auto-filed by orchestration-analysis agent from efficiency report._
${SIG_FOOTER}"
```

**Gate**: Only file issues for `critical` and `high` findings. Do NOT file issues for `medium` or `low`. Do NOT file duplicate issues — check with `gh issue list --repo "$REPO" --search "<finding title>" --state open` first.

## Output Format

Produce a structured markdown report to stdout:

```
# Orchestration Efficiency Analysis — YYYY-MM-DD

## Summary
- **Confidence**: high | medium | low
- **Findings**: N critical, N high, N medium, N low
- **Issues filed**: N (list issue numbers)
- **Total cost today**: $X.XX
- **vs yesterday**: ↑/↓/→ X%
- **vs 7-day avg**: ↑/↓/→ X%

## Top 3 Findings
[findings in severity order]

## Trend Analysis
[comparison table if historical data available]

## Meta-Assessment
[data quality assessment and instrumentation gaps]

## All Findings
[complete list including medium/low]
```

## Token Budget

Target: <5K tokens per analysis run. Achieve this by:

1. Reading only the report file (not raw logs)
2. Producing structured output (no prose padding)
3. Filing issues via bash (not inline generation)
4. Stopping after the output format above — no follow-up questions

## Scheduling Context

This agent is invoked by `sh.aidevops.efficiency-analysis` launchd job:
- **Phase 1** (collector): runs at 05:00 daily, writes `efficiency-report-YYYY-MM-DD.json`
- **Phase 2** (this agent): runs conditionally after Phase 1 — skipped if all metrics are within baseline AND it is not Sunday (weekly deep-dive)

**Baseline thresholds for skip decision** (all must be within range to skip):
- `errors.launch_failure_rate_pct` < 5%
- `concurrency.fill_rate_pct` > 40%
- `audit_trails.issues_closed_without_pr_link` == 0
- `audit_trails.prs_without_merge_summary` == 0
- `token_efficiency.tokens_wasted_on_stalls` < 50000

If any threshold is exceeded, Phase 2 runs regardless of day.
