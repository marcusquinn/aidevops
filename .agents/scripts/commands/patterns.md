---
description: Show success/failure patterns from memory to guide task approach
agent: Build+
mode: subagent
model: haiku
---

Analyze and display success/failure patterns relevant to the current context.

Arguments: $ARGUMENTS

## Instructions

1. If arguments are provided, use them as a task description to find relevant patterns:

```bash
~/.aidevops/agents/scripts/pattern-tracker-helper.sh suggest "$ARGUMENTS"
```

2. If no arguments, show overall pattern statistics and recent patterns:

```bash
~/.aidevops/agents/scripts/pattern-tracker-helper.sh stats
~/.aidevops/agents/scripts/pattern-tracker-helper.sh analyze --limit 5
```

3. Present the results with actionable guidance:
   - Highlight what approaches have worked for similar tasks
   - Warn about approaches that have failed
   - Suggest the optimal model tier based on pattern data

4. If no patterns exist yet, explain how to start recording:

```text
No patterns recorded yet. Patterns are recorded automatically during
development loops, or manually with:

  pattern-tracker-helper.sh record --outcome success \
      --task-type bugfix --model sonnet \
      --description "Structured debugging approach found root cause quickly"
```
