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

Reads JSON from `orchestration-efficiency-collector.sh` (Phase 1). Does NOT collect data. Produces top 3 findings, trend analysis, meta-assessment, and auto-files `critical`/`high` findings as GitHub issues.

**Input:** `REPORT_FILE="${1:-${HOME}/.aidevops/logs/efficiency-report-$(date -u +%Y-%m-%d).json}"`

Missing file → exit: `ERROR: No report file found at $REPORT_FILE. Run orchestration-efficiency-collector.sh first.`

**Token budget:** <5K tokens. Read only the report file; produce structured output; file issues via bash; stop.

## Metric Thresholds

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

## Finding Format

```
## Finding N: <title>
**Severity**: critical | high | medium | low
**Metric**: <metric.path> = <value> (threshold: <threshold>)
**Impact**: <quantified — tokens saved, time saved, issues unblocked>
**Root cause hypothesis**: <1-2 sentences>
**Recommendation**: <specific, actionable — script name, config key, or workflow step>
**Expected saving**: <quantified estimate>
```

## Trend Analysis

When `historical_context.has_yesterday_report` or `has_week_ago_report` is true:

1. Read referenced report files
2. Compare: `token_efficiency.total_cost_usd`, `errors.launch_failure_rate_pct`, `concurrency.fill_rate_pct`, `throughput.prs_merged`
3. Direction: `↑ improved`, `↓ degraded`, `→ stable` (±5% = stable)
4. Flag regressions (degraded vs yesterday AND vs week-ago) as additional findings

Note: `historical_context.week_ago_report_path` is a point-in-time snapshot, not a rolling average.

## Meta-Assessment

1. **Coverage gaps**: Which metrics are `0` or missing that should have data?
2. **Instrumentation improvements**: What additional data points would enable better diagnosis?
3. **Confidence**: `high` (all key metrics populated), `medium` (some gaps), `low` (major gaps)

Low confidence → meta-assessment becomes a `medium` finding.

## Auto-Filing Issues

Gate: `critical` and `high` only. Check duplicates first: `gh issue list --repo "$REPO" --search "<finding title>" --state open`.

```bash
REPO="marcusquinn/aidevops"
SIG_FOOTER=$(~/.aidevops/agents/scripts/gh-signature-helper.sh footer \
  --model "${ANTHROPIC_MODEL:-unknown}" --no-session --session-type worker 2>/dev/null || echo "")
gh issue create --repo "$REPO" \
  --title "fix: <finding title from analysis>" \
  --label "auto-dispatch,priority:high" \
  --body "## Orchestration Efficiency Finding
**Date**: $(date -u +%Y-%m-%d) | **Severity**: <critical|high> | **Metric**: <metric.path> = <value>
### Root Cause
<root cause hypothesis>
### Recommendation
<specific recommendation>
### Expected Impact
<quantified saving>
_Auto-filed by orchestration-analysis agent._
${SIG_FOOTER}"
```

## Output Format

```
# Orchestration Efficiency Analysis — YYYY-MM-DD
## Summary
- **Confidence**: high | medium | low  **Findings**: N critical, N high, N medium, N low
- **Issues filed**: N (list numbers)  **Total cost today**: $X.XX
- **vs yesterday**: ↑/↓/→ X%  **vs 7-day avg**: ↑/↓/→ X%
## Top 3 Findings
[findings in severity order]
## Trend Analysis
[comparison table if historical data available]
## Meta-Assessment
[data quality assessment and instrumentation gaps]
## All Findings
[complete list including medium/low]
```

## Scheduling Context

Invoked by `sh.aidevops.efficiency-analysis` launchd job:
- **Phase 1** (collector): 05:00 daily → `efficiency-report-YYYY-MM-DD.json`
- **Phase 2** (this agent): conditional — skipped if ALL skip thresholds pass AND not Sunday

**Skip thresholds** (all must pass to skip): `errors.launch_failure_rate_pct` < 5%, `concurrency.fill_rate_pct` > 40%, `audit_trails.issues_closed_without_pr_link` == 0, `audit_trails.prs_without_merge_summary` == 0, `token_efficiency.tokens_wasted_on_stalls` < 50000. Any threshold exceeded → Phase 2 runs regardless of day.
