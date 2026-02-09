---
description: Show success/failure patterns from memory to guide task approach and model routing
agent: Build+
mode: subagent
model: haiku
---

Analyze and display success/failure patterns relevant to the current context.

Arguments: $ARGUMENTS

## Instructions

1. If arguments contain "report", show the comprehensive report:

```bash
~/.aidevops/agents/scripts/pattern-tracker-helper.sh report
```

2. If arguments contain "recommend", show model recommendation:

```bash
~/.aidevops/agents/scripts/pattern-tracker-helper.sh recommend "$ARGUMENTS"
```

3. If other arguments are provided, use them as a task description to find relevant patterns:

```bash
~/.aidevops/agents/scripts/pattern-tracker-helper.sh suggest "$ARGUMENTS"
```

4. If no arguments, show overall pattern statistics and recent patterns:

```bash
~/.aidevops/agents/scripts/pattern-tracker-helper.sh stats
~/.aidevops/agents/scripts/pattern-tracker-helper.sh analyze --limit 5
```

5. Present the results with actionable guidance:
   - Highlight what approaches have worked for similar tasks
   - Warn about approaches that have failed
   - Suggest the optimal model tier based on pattern data

6. If no patterns exist yet, explain how to start recording:

```text
No patterns recorded yet. Patterns are recorded automatically by the
supervisor after task completion, or manually with:

  pattern-tracker-helper.sh record --outcome success \
      --task-type bugfix --model sonnet \
      --description "Structured debugging approach found root cause quickly"

Available commands: suggest, recommend, analyze, stats, report, export
```
