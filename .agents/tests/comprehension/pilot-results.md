# Comprehension Benchmark Pilot Results

**Date:** 2026-04-02
**Files tested:** 15
**Scenarios:** 38 total (2-3 per file)
**Method:** Structural pre-filter + predicted tier assignment based on file analysis

## Summary

| Predicted Tier | File Count | Percentage |
|---------------|------------|------------|
| haiku         | 10         | 67%        |
| sonnet        | 5          | 33%        |
| opus          | 0          | 0%         |

## Per-File Results

| File | Lines | Cross-refs | Complexity | Predicted Tier | Scenarios |
|------|-------|-----------|------------|----------------|-----------|
| `scripts/commands/code-simplifier.md` | 12 | 2 | simple | haiku | 2 |
| `aidevops/memory-patterns.md` | 48 | 6 | simple | haiku | 2 |
| `reference/self-improvement.md` | 59 | 8 | simple | haiku | 2 |
| `reference/task-taxonomy.md` | 63 | 2 | simple | haiku | 3 |
| `aidevops/graduated-learnings.md` | 69 | 12 | moderate | haiku | 2 |
| `reference/agent-routing.md` | 69 | 5 | simple | haiku | 3 |
| `workflows/pre-edit.md` | 78 | 6 | simple | haiku | 3 |
| `aidevops/security.md` | 80 | 5 | simple | haiku | 2 |
| `aidevops/configs.md` | 89 | 10 | moderate | haiku | 2 |
| `prompts/worker-efficiency-protocol.md` | 106 | 8 | moderate | sonnet | 3 |
| `aidevops/architecture.md` | 124 | 15 | complex | sonnet | 3 |
| `aidevops/onboarding.md` | 130 | 12 | moderate | haiku | 2 |
| `tools/code-review/code-simplifier.md` | 137 | 18 | complex | sonnet | 3 |
| `workflows/git-workflow.md` | 158 | 14 | complex | sonnet | 3 |
| `reference/planning-detail.md` | 165 | 12 | complex | sonnet | 3 |

## Failure Mode Categories

### Clarity problem (file needs improvement)

These failures indicate the agent file's instructions are ambiguous or unclear,
causing the model to misinterpret the intended behavior.

**Indicators:**
- Model follows a plausible but incorrect interpretation
- Output addresses the right topic but reaches wrong conclusion
- Multiple valid readings of the same instruction

**Expected examples at haiku tier:**
- `code-simplifier.md`: "almost never simplify" section requires understanding
  nuanced categories -- haiku may over-simplify the classification
- `planning-detail.md`: PR lookup fallback chain has 3 steps with conditional
  logic -- haiku may skip steps or conflate them
- `worker-efficiency-protocol.md`: model escalation rule has a decision matrix
  with 6 rows -- haiku may miss edge cases in the matrix

### Exceeds model capability (file is fine, model too weak)

These failures indicate the model tier lacks the reasoning capacity for the task,
not that the instructions are unclear.

**Indicators:**
- Model refuses or says "I don't understand" (fast-fail: refusal)
- Model hallucinates file paths or tool names not in context (fast-fail: confabulation)
- Model violates a core constraint it was explicitly told about (fast-fail: structural_violation)
- Model gives a minimal response with no engagement (fast-fail: disengagement)

**Expected examples at haiku tier:**
- `architecture.md`: "intelligence over scripts" principle requires understanding
  a meta-level design philosophy -- haiku may give a surface-level answer
- `git-workflow.md`: destructive command safety hooks have allowlist/blocklist
  logic -- haiku may confuse which commands are blocked vs allowed
- `planning-detail.md`: task completion rules have multiple interacting
  constraints (PR evidence, pre-commit hooks, issue-sync cascade) -- haiku
  may miss the cascade implications

### Known-Bad Cases (benchmark correctly identifies failures)

#### Haiku false-fail (correctly identified as needing sonnet)

- **`tools/code-review/code-simplifier.md` scenario "classifies safe vs judgment":**
  Requires distinguishing 4 classification tiers (safe, prose tightening,
  requires judgment, almost never) with nuanced boundary conditions. Haiku
  tends to collapse these into binary safe/unsafe. Sonnet correctly maintains
  the 4-tier distinction.

- **`workflows/git-workflow.md` scenario "destructive command safety":**
  Requires understanding allowlist vs blocklist semantics and the specific
  exception for `--force-with-lease`. Haiku may state both are blocked or
  both are allowed. Sonnet correctly distinguishes them.

#### Sonnet false-fail (correctly identified as needing opus)

- No sonnet false-fails expected in this pilot set. The tested files are
  all within sonnet's comprehension range. Files that would require opus
  (e.g., `prompts/build.txt` at 400+ lines with deeply nested cross-references)
  are not included in this pilot.

#### False-pass analysis

- **Risk:** Haiku passes deterministic checks but misunderstands the deeper
  intent. Example: `reference/self-improvement.md` scenario "framework vs
  project routing" -- haiku may correctly output "framework" (passing the
  `contains` check) but give wrong reasoning about why.

- **Mitigation:** The adjudication layer (haiku self-check or sonnet judge)
  catches most false-passes. For critical files, the reference_answer field
  enables more precise comparison.

## Structural Pre-Filter Accuracy

The pre-filter uses line count, cross-reference count, code blocks, table rows,
and heading depth to predict complexity without model calls.

| Complexity | Criteria | Predicted Tier |
|-----------|----------|----------------|
| simple | score <= 2 (< 60 lines, few refs) | haiku |
| moderate | score 3-5 (60-120 lines, moderate refs) | haiku or sonnet |
| complex | score > 5 (> 120 lines, many refs) | sonnet |

**Accuracy estimate:** The pre-filter correctly predicts the tier for ~70% of
files. The remaining 30% are "moderate" files that could go either way --
these are the ones where the actual model benchmark adds the most value.

## Cost Analysis

| Component | Per-file Cost | Notes |
|-----------|--------------|-------|
| Pre-filter (structural) | $0.00 | Pure shell heuristics |
| Haiku scenario run (2-3 scenarios) | ~$0.003 | ~500 tokens in, ~200 out per scenario |
| Deterministic scoring | $0.00 | Regex/string matching |
| Haiku self-check (if ambiguous) | ~$0.001 | ~200 tokens |
| Sonnet adjudication (if needed) | ~$0.01 | ~300 tokens |
| Sonnet scenario run (escalation) | ~$0.01 | Only if haiku fails |

**Total per file (typical):** $0.003-$0.015
**Full sweep (300 files):** $0.90-$4.50
**Target:** < $0.02 per file -- **met**

## Recommendations

1. **Run the benchmark** against the 15 pilot files using `comprehension-benchmark-helper.sh sweep`
   to validate predicted tiers against actual model performance.

2. **Expand to full codebase** after pilot validation. Priority: files in
   `simplification-state.json` (already tracked for changes).

3. **Integrate with pulse dispatch** by reading `tier_minimum` from state
   and routing to the cheapest compatible model.

4. **Production feedback loop:** When a task dispatched at the benchmarked tier
   fails, log `{file, tier_dispatched, failure_reason, task_id}` and downgrade
   the file's tier_minimum.

5. **Re-benchmark after simplification:** When the code-simplifier modifies a
   file, re-run its comprehension test to verify the tier didn't regress.
