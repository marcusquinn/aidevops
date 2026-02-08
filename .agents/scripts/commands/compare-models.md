---
description: Compare AI model capabilities, pricing, and context windows (with optional live data)
agent: Build+
mode: subagent
---

Compare AI models by capability, pricing, context window, and task suitability.

Target: $ARGUMENTS

## Instructions

1. Read `tools/ai-assistants/compare-models.md` for the full comparison workflow.

2. Run the helper script to get structured model data:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh list
   ```

3. If specific models were requested, compare them:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh compare <model1> <model2> ...
   ```

4. If a `--task` was specified, get recommendations:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh recommend "<task>"
   ```

5. **Live data enrichment** (this is the full `/compare-models` command):
   - Fetch latest pricing from provider documentation pages
   - Cross-reference against embedded data
   - Note any pricing changes since last update

6. Present results in a structured comparison table with:
   - Pricing per 1M tokens (input and output)
   - Context window sizes
   - Capability matrix
   - Task suitability recommendations
   - aidevops tier mapping (haiku/flash/sonnet/pro/opus)

## Examples

```bash
# Compare specific models
/compare-models claude-sonnet-4 gpt-4o gemini-2.5-pro

# Get recommendation for a task
/compare-models --task "code review"

# Show all pricing
/compare-models --pricing

# Compare by tier
/compare-models --tier medium
```
