---
description: Show success/failure patterns from memory to guide task approach and model routing
agent: Build+
mode: subagent
model: haiku
---

Show cross-session success/failure patterns relevant to the current task.

Arguments: `$ARGUMENTS`

## Instructions

1. Query memory for all pattern types:

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall "success pattern" --type SUCCESS_PATTERN --limit 20
~/.aidevops/agents/scripts/memory-helper.sh recall "failure pattern" --type FAILURE_PATTERN --limit 20
~/.aidevops/agents/scripts/memory-helper.sh recall "working solution" --type WORKING_SOLUTION --limit 10
~/.aidevops/agents/scripts/memory-helper.sh recall "failed approach" --type FAILED_APPROACH --limit 10
```

2. Apply mode from arguments:
   - Contains `recommend` → prioritize model-tier recommendation from observed outcomes.
   - Contains `report` → return full pattern summary.
   - Otherwise → return concise task-focused suggestions.

3. If arguments are provided, filter findings to task-relevant patterns.

4. Present output in this order:
   - **What works:** approaches with repeated success in similar tasks
   - **What fails:** approaches with repeated failure or regressions
   - **Recommended tier:** best model tier with short rationale from pattern evidence

5. If no patterns exist, return:

```text
No patterns recorded yet. Patterns are recorded automatically by the pulse supervisor after observing outcomes, or manually with:

  /remember "SUCCESS: bugfix with sonnet — structured debugging found root cause quickly"
  /remember "FAILURE: architecture with sonnet — needed opus for cross-service trade-offs"

Available commands: /patterns suggest, /patterns recommend, /patterns report
```
