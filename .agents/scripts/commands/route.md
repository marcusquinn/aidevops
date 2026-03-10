---
description: Suggest optimal model tier for a task description using rules + pattern history
agent: Build+
mode: subagent
model: haiku
---

Analyze the task description and recommend the optimal model tier.

Task: $ARGUMENTS

<!-- NOTE: $ARGUMENTS is raw free-form text from the user, not necessarily a --task-type
     value. The recommend command (cmd_recommend in model-routing) only filters by
     --task-type. When called with free-form text, recommend shows global model stats
     (not task-type-specific). For task-specific routing, extract a task type (e.g.,
     "code", "triage", "research") from ARGUMENTS before calling recommend. -->

## Instructions

1. First, check pattern history from cross-session memory:

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --type SUCCESS_PATTERN --limit 10
~/.aidevops/agents/scripts/memory-helper.sh recall --type FAILURE_PATTERN --limit 10
```

2. Read `tools/context/model-routing.md` for the routing rules and tier definitions.

3. Analyze the task description against the routing rules:
   - **Complexity**: Simple transform vs reasoning vs novel design
   - **Context size**: Small focused task vs large codebase sweep
   - **Output type**: Classification vs code vs architecture

4. Combine pattern history with routing rules:
   - If pattern data exists and shows a clear winner (>75% success rate with 3+ samples), weight it heavily
   - If pattern data is sparse or inconclusive, rely on routing rules
   - If pattern data contradicts routing rules, note the conflict and explain

5. Output a recommendation in this format:

```text
Recommended: {tier} ({model_name})
Reason: {one-line justification}
Cost: ~{relative}x vs sonnet baseline
Pattern data: {success_rate}% success rate from {N} samples (or "no data")
```

6. If the task is ambiguous, suggest the tier and note what would push it up or down:

```text
Recommended: sonnet (claude-sonnet-4-6)
Reason: Code modification with moderate reasoning
Cost: ~1x baseline
Pattern data: 85% success rate from 12 samples

Could be haiku if: the change is a simple rename/reformat
Could be opus if: the change requires architectural decisions
```
