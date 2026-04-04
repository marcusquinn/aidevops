---
description: Score and compare AI model responses side-by-side with structured criteria
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Evaluate real AI responses against correctness, completeness, code quality, and clarity.

Target: $ARGUMENTS

## Instructions

Read `tools/ai-assistants/response-scoring.md` for criteria weights, storage details, and helper syntax.

## Workflow

1. `prompt add` — save the shared evaluation prompt.
2. `record` — capture one response per model with timing/tokens.
3. `score` — rate all four criteria for each response.
4. `compare` or `leaderboard` — rank the responses side-by-side.
5. `export` — optional CSV output for reuse.

Scores auto-sync to the pattern tracker (t1099), feeding `/route` and `/patterns`. Disable: `SCORING_NO_PATTERN_SYNC=1`. Bulk sync: `response-scoring-helper.sh sync`.

## Examples

```bash
/score-responses --prompt "Write a Python function to merge two sorted lists" --models "claude-sonnet-4-6,gpt-4o,gemini-2.5-pro"
/score-responses --leaderboard
/score-responses --export --csv
```
