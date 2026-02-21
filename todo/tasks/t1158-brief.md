---
mode: subagent
---
# t1158: Fix audit script PR linkage detection for auto-reaped tasks

## Origin

- **Created:** 2026-02-18
- **Session:** supervisor:pid:11088 (headless Claude CLI)
- **Created by:** ai-supervisor

- **Commit:** ddee246c0356a2c8e94f6b394ff6b8c295e9432b — "chore: AI supervisor created improvement task t1158"

## What

Fix audit script PR linkage detection for auto-reaped tasks

## Specification

```markdown
- [ ] t1158 Fix audit script PR linkage detection for auto-reaped tasks #bugfix #auto-dispatch #self-improvement ~1h model:opus category:reliability — The issue audit reports no_pr_linkage for tasks t1141, t1129, t1126, t1128 which are all verified in the supervisor DB with PRs. The common pattern: these were 'Auto-reaped: stuck in evaluating >10m'. The audit script likely checks for PR linkage via GitHub issue cross-references but misses PRs that were merged after the evaluation was reaped. Fix: have the audit script also check the supervisor DB for verified status + PR URL before flagging no_pr_linkage. This would eliminate ~4 of the 6 high-severity findings as false positives. ref:GH#1744 assignee:marcusquinn started:2026-02-21T03:18:11Z
  - Notes: BLOCKED by supervisor: Stale state recovery (Phase 0.7/t1132): was evaluating with no live worker, retries exhausted (3/3, cause: eval_delayed_pickup_lag_97019s)
```



## Supervisor Context

```
t1158|Fix audit script PR linkage detection for auto-reaped tasks #bugfix #auto-dispatch #self-improvement ~1h model:opus category:reliability — The issue audit reports no_pr_linkage for tasks t1141, t1129, t1126, t1128 which are all verified in the supervisor DB with PRs. The common pattern: these were 'Auto-reaped: stuck in evaluating >10m'. The audit script likely checks for PR linkage via GitHub issue cross-references but misses PRs that were merged after the evaluation was reaped. Fix: have the audit script also check the supervisor DB for verified status + PR URL before flagging no_pr_linkage. This would eliminate ~4 of the 6 high-severity findings as false positives. ref:GH#1744|pid:11088|2026-02-21T03:16:02Z|2026-02-21T03:50:08Z
```

## Acceptance Criteria

- [ ] Implementation matches the specification above
- [ ] Tests pass
- [ ] Lint clean

## Relevant Files

<!-- TODO: Add relevant file paths after codebase analysis -->
