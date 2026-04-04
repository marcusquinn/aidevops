<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Comprehension Benchmark

Tests whether agent files are comprehensible at each model tier (haiku, sonnet,
opus). Produces per-file tier compatibility ratings for dispatch routing.

## Schema

Test scenarios use YAML with this structure:

```yaml
# Required fields
file: .agents/path/to/agent-file.md    # Agent file under test
tier_minimum: haiku                      # Expected minimum tier (haiku|sonnet|opus)

# Scenarios (2-3 per file)
scenarios:
  - name: "short descriptive name"
    prompt: "Task or question to give the model"
    expected:
      contains:                          # Strings that MUST appear in output
        - "keyword"
      not_contains:                      # Strings that MUST NOT appear
        - "forbidden action"
      action:                            # Expected behavioral outcome
        - "skip"                         # e.g., skip, refuse, analyze, list
      min_length: 50                     # Minimum response length (chars)
      max_length: 2000                   # Maximum response length (chars)
    reference_answer: |                  # Opus-validated ground truth (set at authoring)
      Expected output summary from opus tier.
    fast_fail_triggers:                  # Skip adjudication, escalate immediately
      - refusal                          # Model refuses or says "I don't understand"
      - confabulation                    # Hallucinated paths, tools, or task IDs
      - structural_violation             # Core constraint violated (e.g., edits when told analysis-only)
      - disengagement                    # Response <20% expected length with no justification
```

## Scoring Layers (cheapest first)

1. **Deterministic** (free) -- regex/string matching on output
2. **Haiku self-check** (~$0.001) -- haiku compares its output to expected spec
3. **Sonnet adjudication** (~$0.01) -- sonnet judges haiku output vs opus reference

## Fast-Fail Escalation

These signals skip adjudication and escalate to the next tier immediately:

| Trigger | Detection | Cost |
|---------|-----------|------|
| Refusal | `"I don't understand"`, `"I cannot"`, `"not able to"` | Free (regex) |
| Confabulation | Paths/tools/IDs not in input context | Free (set diff) |
| Structural violation | Core constraint violated | Free (action check) |
| Disengagement | Response length < 20% of `min_length` | Free (length check) |

## Slow-Fail Signals (adjudicate before escalating)

- Output plausible but misses 1-2 expected elements
- Right process, wrong conclusion
- Model adds reasonable steps not in expected output

## Directory Layout

```
.agents/tests/comprehension/
  README.md                              # This file (schema docs)
  pilot-results.md                       # Pilot run analysis
  {agent-path-slug}.yaml                 # One test file per agent file
```

Slug convention: replace `/` with `--` and drop `.agents/` prefix and `.md`
suffix. Example: `.agents/reference/task-taxonomy.md` becomes
`reference--task-taxonomy.yaml`.

## Running

```bash
# Test one file
.agents/scripts/comprehension-benchmark-helper.sh test <file.yaml>

# Run all tests
.agents/scripts/comprehension-benchmark-helper.sh sweep

# Generate report
.agents/scripts/comprehension-benchmark-helper.sh report

# Update simplification-state.json with tier_minimum results
.agents/scripts/comprehension-benchmark-helper.sh update-state
```

## Integration Points

- **simplification-state.json**: `tier_minimum` field per file entry
- **Pulse dispatch**: reads `tier_minimum` for cost-aware model routing
- **Code-simplifier**: re-runs comprehension test after simplification to verify
  tier did not regress

## Cost Targets

- Per-file full 3-tier sweep: < $0.02
- Full sweep of 300 files: $1-3
- Deterministic checks handle ~60-70% of pass/fail decisions at zero cost
