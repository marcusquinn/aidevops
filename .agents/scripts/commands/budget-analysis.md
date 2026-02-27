---
description: Analyse budget feasibility and recommend tiered outcomes for a goal or task
agent: Build+
mode: subagent
model: haiku
---

Analyse the budget or goal and provide tiered recommendations.

Input: $ARGUMENTS

## Instructions

This command provides budget analysis for the `/mission` scoping phase and general cost planning. It has four modes depending on what the user provides:

### 1. Budget Analysis (user provides a dollar/time budget)

Run the analysis engine to show what the budget buys at each model tier:

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh analyse --budget <USD> [--hours <H>] --json
```

Present the JSON output as a readable comparison table showing tokens, tasks, and messages achievable at haiku/sonnet/opus tiers.

### 2. Goal Recommendations (user provides a goal description)

Generate tiered outcome recommendations:

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh recommend --goal "<description>" --json
```

Present the three tiers (MVP, Production-Ready, Polished) with costs, time estimates, and what's included/excluded at each level. Help the user choose the right tier for their needs.

### 3. Task Estimation (user provides a specific task)

Estimate cost for a single task:

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh estimate --task "<description>" [--tier <tier>] --json
```

Show the estimate with range (0.5x-2x) and alternative tier costs. If the user hasn't specified a tier, recommend one based on the task complexity.

### 4. Spend Forecast (user wants to project future costs)

Forecast based on historical burn rate:

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh forecast --days <N> --json
```

Present the forecast with confidence interval. Note data quality (warn if <7 days of history).

## Presentation Guidelines

- Always show costs in USD with 2 decimal places
- Show token counts with thousand separators for readability
- When recommending, be direct: "I recommend Tier 2 (Production-Ready) because..."
- If historical data exists, calibrate estimates against actual spend patterns
- For `/mission` integration: run `recommend` first, then `analyse` with the chosen budget
- Flag when estimates have high uncertainty (novel task types, no historical data)
