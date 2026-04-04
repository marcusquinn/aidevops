---
description: Analyse budget feasibility and recommend tiered outcomes
agent: Build+
mode: subagent
model: haiku
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Input: $ARGUMENTS

## Modes

### Budget Analysis (USD/time)

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh analyse --budget <USD> [--hours <H>] --json
```

Present comparison table: tokens, tasks, and messages at haiku/sonnet/opus tiers.

### Goal Recommendations

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh recommend --goal "<description>" --json
```

Present three tiers (MVP, Production-Ready, Polished) with costs, time, and inclusions.

### Task Estimation

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh estimate --task "<description>" [--tier <tier>] --json
```

Show estimate range (0.5x-2x) and alternative tier costs. Recommend tier if unspecified.

### Spend Forecast

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh forecast --days <N> --json
```

Present forecast with confidence interval. Warn if <7 days history.

## Presentation Guidelines

- Costs in USD (2 decimal places); tokens with thousand separators.
- Be direct: "I recommend Tier 2 (Production-Ready) because...".
- Calibrate against historical spend patterns; flag high uncertainty.
- `/mission` integration: run `recommend` first, then `analyse` with chosen budget.
