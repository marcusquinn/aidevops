---
description: Score and compare AI model responses side-by-side with structured criteria
agent: Build+
mode: subagent
---

Score AI model responses against structured criteria (correctness, completeness, code quality, clarity).

Target: $ARGUMENTS

## Instructions

Read `tools/ai-assistants/response-scoring.md` for full scoring workflow, criteria weights, and CLI reference.

**Workflow:** `prompt add` → `record` → `score` → `compare`/`leaderboard`. For live comparisons, send the same prompt to multiple models, record with timing/tokens, score all four criteria, present side-by-side.

Scores auto-sync to the pattern tracker (t1099), feeding `/route` and `/patterns`. Disable: `SCORING_NO_PATTERN_SYNC=1`. Bulk sync: `response-scoring-helper.sh sync`.

## Examples

```bash
/score-responses --prompt "Write a Python function to merge two sorted lists" --models "claude-sonnet-4-6,gpt-4o,gemini-2.5-pro"
/score-responses --leaderboard
/score-responses --export --csv
```
