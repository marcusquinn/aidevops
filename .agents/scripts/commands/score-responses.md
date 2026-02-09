---
description: Score and compare AI model responses side-by-side with structured criteria
agent: Build+
mode: subagent
---

Evaluate AI model responses against structured scoring criteria (correctness, completeness, code quality, clarity).

Target: $ARGUMENTS

## Instructions

1. Read `tools/ai-assistants/response-scoring.md` for the full scoring workflow.

2. If the user wants to create a new evaluation:

   ```bash
   # Create a prompt
   ~/.aidevops/agents/scripts/response-scoring-helper.sh prompt add --title "Title" --text "Prompt text"

   # Record model responses
   ~/.aidevops/agents/scripts/response-scoring-helper.sh record --prompt <id> --model <model_id> --text "response"

   # Score each response
   ~/.aidevops/agents/scripts/response-scoring-helper.sh score --response <id> --correctness <1-5> --completeness <1-5> --code-quality <1-5> --clarity <1-5>
   ```

3. If the user wants to compare existing results:

   ```bash
   # Compare responses for a prompt
   ~/.aidevops/agents/scripts/response-scoring-helper.sh compare --prompt <id>

   # View leaderboard
   ~/.aidevops/agents/scripts/response-scoring-helper.sh leaderboard
   ```

4. If the user wants to run a live comparison:
   - Send the same prompt to multiple models using their respective APIs
   - Record each response with timing and token count
   - Score each response on all four criteria
   - Present the side-by-side comparison

5. Present results with:
   - Side-by-side scoring table
   - Winner declaration with rationale
   - Per-criterion breakdown
   - Cost-effectiveness analysis (score per dollar)

## Scoring Criteria

| Criterion | Weight | Description |
|-----------|--------|-------------|
| Correctness | 30% | Factual accuracy and technical correctness |
| Completeness | 25% | Coverage of all requirements and edge cases |
| Code Quality | 25% | Clean code, best practices, maintainability |
| Clarity | 20% | Clear explanation, good formatting, readability |

## Examples

```bash
# Full evaluation workflow
/score-responses --prompt "Write a Python function to merge two sorted lists" --models "claude-sonnet-4,gpt-4o,gemini-2.5-pro"

# View existing comparisons
/score-responses --leaderboard

# Export results
/score-responses --export --csv
```
