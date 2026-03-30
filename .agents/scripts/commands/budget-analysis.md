---
description: Analyse budget feasibility and recommend tiered outcomes for a goal or task
agent: Build+
mode: subagent
model: haiku
---

Input: $ARGUMENTS

## Modes

### Budget Analysis (user provides dollar/time budget)

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh analyse --budget <USD> [--hours <H>] --json
```

Present as comparison table: tokens, tasks, and messages at haiku/sonnet/opus tiers.

### Goal Recommendations (user provides goal description)

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh recommend --goal "<description>" --json
```

Present three tiers (MVP, Production-Ready, Polished) with costs, time estimates, inclusions/exclusions. Help user choose.

### Task Estimation (user provides specific task)

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh estimate --task "<description>" [--tier <tier>] --json
```

Show estimate with range (0.5x-2x) and alternative tier costs. Recommend tier based on complexity if unspecified.

### Spend Forecast (user wants to project future costs)

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh forecast --days <N> --json
```

Present forecast with confidence interval. Warn if <7 days of history.

## Presentation Guidelines

- Costs in USD, 2 decimal places; token counts with thousand separators
- Be direct: "I recommend Tier 2 (Production-Ready) because..."
- Calibrate estimates against actual spend patterns when historical data exists
- Flag high uncertainty (novel task types, no historical data)
- `/mission` integration: run `recommend` first, then `analyse` with chosen budget
