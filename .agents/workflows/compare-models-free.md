---
description: Compare AI model capabilities using offline embedded data only (no web fetches)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Compare AI models using only the local model registry. No web fetches, no API calls.

Target: $ARGUMENTS

## Instructions

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh list                        # all models
~/.aidevops/agents/scripts/compare-models-helper.sh list --provider <name>      # filter by provider
```

Present results as a structured comparison table: pricing per 1M tokens
(input and output), context window sizes, and each model's canonical aidevops
workload tier (`simple`, `standard`, or `thinking`).

For "how good is a new model at our actual work?", this catalog is not the
right tool — read `tools/ai-assistants/compare-models.md` and use
model-replay, model-ab, or frontier-harness-eval instead.

## Examples

```bash
/compare-models-free                    # full registry
/compare-models-free --provider OpenAI  # OpenAI models only
```
