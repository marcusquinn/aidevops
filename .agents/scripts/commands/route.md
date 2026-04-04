---
description: Suggest optimal model tier for a task description using rules + pattern history
agent: Build+
mode: subagent
model: haiku
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Recommend the optimal model tier for the task.

Task: $ARGUMENTS

<!-- NOTE: $ARGUMENTS is raw free-form text, not guaranteed to match --task-type.
     compare-models-helper.sh recommend only filters by --task-type. For task-specific
     routing, first extract a task type such as "code", "triage", or "research". -->

## Instructions

1. Recall cross-session pattern history:

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --type SUCCESS_PATTERN --limit 10
~/.aidevops/agents/scripts/memory-helper.sh recall --type FAILURE_PATTERN --limit 10
```

2. Read `tools/context/model-routing.md` for tier definitions and routing rules.
3. Assess the task on three axes: complexity, context size, and output type.
4. Combine rules with pattern data:
   - >75% success with 3+ samples: weight pattern history heavily
   - sparse or inconclusive data: use routing rules
   - conflict between data and rules: recommend a tier and explain the conflict
5. Output:

```text
Recommended: {tier} ({model_name})
Reason: {one-line justification}
Cost: ~{relative}x vs sonnet baseline
Pattern data: {success_rate}% success rate from {N} samples (or "no data")
```

6. If ambiguous, keep the recommendation and add:

```text
Could be haiku if: the change is a simple rename/reformat
Could be opus if: the change requires architectural decisions
```
