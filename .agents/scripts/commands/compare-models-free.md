---
description: Compare AI model capabilities using offline embedded data only (no web fetches)
agent: Build+
mode: subagent
---

Compare AI models using only embedded reference data. No web fetches, no API calls.
Useful when working offline or to avoid token spend on web fetches.

Target: $ARGUMENTS

## Instructions

1. Run the helper script to get structured model data:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh list
   ```

2. If specific models were requested, compare them:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh compare <model1> <model2> ...
   ```

3. If a `--task` was specified, get recommendations:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh recommend "<task>"
   ```

4. For pricing overview:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh pricing
   ```

5. For capability matrix:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh capabilities
   ```

6. **Do NOT fetch any web pages.** All data comes from the helper script's embedded database.
   Note the "Last updated" date in the output so the user knows data freshness.

7. Present results in a structured comparison table with:
   - Pricing per 1M tokens (input and output)
   - Context window sizes
   - Capability matrix
   - Task suitability recommendations
   - aidevops tier mapping (haiku/flash/sonnet/pro/opus)

## Examples

```bash
# Compare specific models (offline)
/compare-models-free claude-sonnet-4 gpt-4o

# Get recommendation for a task (offline)
/compare-models-free --task "summarization"

# Show all pricing (offline)
/compare-models-free --pricing

# Show capabilities matrix (offline)
/compare-models-free --capabilities
```
