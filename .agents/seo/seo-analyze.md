---
description: Analyze exported SEO data for ranking opportunities
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Analyze exported SEO data for ranking opportunities, cannibalization, and optimization targets.

Target: `$ARGUMENTS` — parse for domain and optional analysis type, run the helper, return report with concrete recommendations.

## Quick Reference

- Input: TOON exports from `/seo-export` (run `/seo-export all example.com --days 90` if none exist)
- Helper: `~/.aidevops/agents/scripts/seo-analysis-helper.sh $ARGUMENTS`
- Output: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/analysis-{date}.toon`
- Modes: `quick-wins`, `striking-distance`, `low-ctr`, `cannibalization`, `summary` (default: full analysis)
- Docs: `seo/ranking-opportunities.md`

## Analysis Types

| Type | Criteria | Primary action |
|------|----------|----------------|
| Quick Wins | Position 4-20, high impressions | On-page optimization |
| Striking Distance | Position 11-30, high volume | Content expansion, backlinks |
| Low CTR | CTR < 2%, high impressions | Title/meta optimization |
| Cannibalization | Same query, multiple URLs | Consolidate content |
