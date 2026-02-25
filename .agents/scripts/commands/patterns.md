---
description: Show success/failure patterns from memory to guide task approach and model routing
agent: Build+
mode: subagent
model: haiku
---

Analyze and display success/failure patterns relevant to the current context.

Arguments: $ARGUMENTS

## Instructions

1. Query cross-session memory for pattern data:

```bash
# Get success patterns
~/.aidevops/agents/scripts/memory-helper.sh recall --type SUCCESS_PATTERN --limit 20

# Get failure patterns
~/.aidevops/agents/scripts/memory-helper.sh recall --type FAILURE_PATTERN --limit 20

# Get working solutions
~/.aidevops/agents/scripts/memory-helper.sh recall --type WORKING_SOLUTION --limit 10

# Get failed approaches
~/.aidevops/agents/scripts/memory-helper.sh recall --type FAILED_APPROACH --limit 10
```

2. If arguments are provided, filter results relevant to the task description.

3. If arguments contain "recommend", focus on model tier recommendations based on success/failure rates per tier.

4. If arguments contain "report", provide a comprehensive summary of all patterns.

5. Present the results with actionable guidance:
   - Highlight what approaches have worked for similar tasks
   - Warn about approaches that have failed
   - Suggest the optimal model tier based on pattern data

6. If no patterns exist yet, explain how to start recording:

```text
No patterns recorded yet. Patterns are recorded automatically by the
pulse supervisor after observing outcomes, or manually with:

  /remember "SUCCESS: bugfix with sonnet — structured debugging found root cause quickly"
  /remember "FAILURE: architecture with sonnet — needed opus for cross-service trade-offs"

Available commands: /patterns suggest, /patterns recommend, /patterns report
```
