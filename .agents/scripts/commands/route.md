---
description: Suggest optimal model tier for a task description
agent: Build+
mode: subagent
model: haiku
---

Analyze the task description and recommend the optimal model tier.

Task: $ARGUMENTS

## Instructions

1. Read `tools/context/model-routing.md` for the routing rules and tier definitions.

2. Analyze the task description against the routing rules:
   - **Complexity**: Simple transform vs reasoning vs novel design
   - **Context size**: Small focused task vs large codebase sweep
   - **Output type**: Classification vs code vs architecture

3. Output a recommendation in this format:

```text
Recommended: {tier} ({model_name})
Reason: {one-line justification}
Cost: ~{relative}x vs sonnet baseline
```

4. If the task is ambiguous, suggest the tier and note what would push it up or down:

```text
Recommended: sonnet (claude-sonnet-4)
Reason: Code modification with moderate reasoning
Cost: ~1x baseline

Could be haiku if: the change is a simple rename/reformat
Could be opus if: the change requires architectural decisions
```
