---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1394: Evaluator presets for ai-judgment-helper.sh

## Origin

- **Created:** 2026-03-05
- **Session:** claude-code:chore/langwatch-agent
- **Created by:** human + ai-interactive
- **Conversation context:** LangWatch's LangEvals library defines a pluggable evaluator interface — each evaluator takes (input, output, expected?) and returns {score, passed, details}. Categories include faithfulness, relevancy, safety, format validity. Our ai-judgment-helper.sh already makes haiku-tier judgment calls but only for memory relevance and response length. Extending it with named evaluator presets gives us LangWatch's eval capability without the infrastructure.

## What

Named evaluator presets in `ai-judgment-helper.sh` that score LLM outputs on standard quality dimensions. Each evaluator is a haiku-tier LLM call with a specific system prompt, returning a structured `{score, passed, details}` result.

Deliverables:
1. `ai-judgment-helper.sh evaluate` subcommand with `--type` flag
2. Built-in evaluator presets: faithfulness, relevancy, safety, format-validity, completeness, conciseness
3. Structured output format (JSON) compatible with pattern tracker
4. `--dataset` flag to run evaluators across a JSONL dataset (batch mode)
5. Custom evaluator support via user-defined prompt files
6. Documentation in a new or updated agent doc

## Why

Currently there's no way to programmatically assess LLM output quality in aidevops. Code review bots (CodeRabbit, Gemini) check code, but nothing checks LLM-generated content for hallucination, relevance, or safety. This matters for:
- CI/CD quality gates on prompt changes (did this prompt edit regress quality?)
- Validating agent outputs before acting on them (guardrail-lite)
- Building evaluation datasets from production traces (annotate failures, re-evaluate)
- Comparing model quality in bench runs (t1393 --judge mode can delegate to these evaluators)

LangWatch charges for this via their platform. We can do it with ~$0.001 per evaluation using haiku.

## How (Approach)

### Evaluator interface

Each evaluator is a function that:
1. Constructs a system prompt specific to the evaluation type
2. Sends (input, output, optional context/expected) to haiku
3. Parses the structured response into `{score: 0-1, passed: bool, details: string}`

### Built-in evaluators

| Evaluator | Judges | System prompt focus |
|-----------|--------|-------------------|
| `faithfulness` | Does the output stay true to provided context? | Given context X, does output Y contain only claims supported by X? |
| `relevancy` | Does the output address the input question? | Given question X, does output Y answer what was asked? |
| `safety` | Is the output free of harmful/inappropriate content? | Check for PII, toxicity, jailbreak compliance, harmful instructions |
| `format-validity` | Does the output match expected format? | Given format spec X, does output Y conform? |
| `completeness` | Does the output cover all aspects of the input? | Given request X, does output Y address all parts? |
| `conciseness` | Is the output appropriately concise? | Is output Y unnecessarily verbose for input X? |

### Key files to modify

- `.agents/scripts/ai-judgment-helper.sh` — add `evaluate` subcommand and evaluator functions
- New or updated doc for evaluator usage guidance

### Patterns to follow

- `ai-judgment-helper.sh:1-40` — existing judgment call pattern (haiku API, deterministic fallback)
- `ai-judgment-helper.sh` caching pattern — cache evaluator results to avoid re-evaluating identical input/output pairs
- LangWatch's `langevals/evaluators/langevals/langevals_langevals/llm_score.py` — LLM-as-judge scoring prompt design

### CLI interface

```bash
# Single evaluation
ai-judgment-helper.sh evaluate --type faithfulness \
  --input "What is the capital of France?" \
  --output "The capital of France is Paris, located on the Seine river." \
  --context "France is a country in Western Europe. Its capital is Paris."

# Output: {"score": 0.95, "passed": true, "details": "All claims supported by context"}

# Batch evaluation from dataset
ai-judgment-helper.sh evaluate --type faithfulness --dataset path/to/dataset.jsonl

# Custom evaluator
ai-judgment-helper.sh evaluate --type custom --prompt-file path/to/evaluator-prompt.txt \
  --input "..." --output "..."

# Multiple evaluators
ai-judgment-helper.sh evaluate --type faithfulness,relevancy,safety \
  --input "..." --output "..."
```

## Acceptance Criteria

- [ ] `ai-judgment-helper.sh evaluate --type faithfulness --input "..." --output "..."` returns JSON with score, passed, details

  ```yaml
  verify:
    method: codebase
    pattern: "evaluate.*--type.*faithfulness"
    path: ".agents/scripts/ai-judgment-helper.sh"
  ```

- [ ] All 6 built-in evaluators implemented (faithfulness, relevancy, safety, format-validity, completeness, conciseness)

  ```yaml
  verify:
    method: codebase
    pattern: "faithfulness|relevancy|safety|format-validity|completeness|conciseness"
    path: ".agents/scripts/ai-judgment-helper.sh"
  ```

- [ ] `--dataset` flag processes JSONL file and outputs per-row results

  ```yaml
  verify:
    method: codebase
    pattern: "--dataset.*jsonl"
    path: ".agents/scripts/ai-judgment-helper.sh"
  ```

- [ ] Custom evaluator via `--prompt-file` works
- [ ] Results cached to avoid duplicate API calls for identical inputs
- [ ] Deterministic fallback when API unavailable (returns `{"score": null, "passed": null, "details": "API unavailable, using fallback"}`). `score` is `null` (not `0`) and `passed` is `null` (not `false`) to distinguish "not evaluated" from "evaluated and failed". Callers must check for `null` before comparing scores or treating `passed` as boolean.
- [ ] ShellCheck clean

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/ai-judgment-helper.sh"
  ```

## Context & Decisions

- Inspired by LangWatch's LangEvals evaluator framework — pluggable scoring functions with a common interface
- Haiku tier chosen for cost (~$0.001/eval) — evaluators should be cheap enough to run in CI
- JSON output format chosen for machine readability and pattern tracker integration
- `passed` field uses a threshold (default 0.7) — configurable via `--threshold`
- Custom evaluators via prompt files allow domain-specific evaluation without modifying the script
- Batch mode (`--dataset`) aligns with t1395 dataset convention
- Caching prevents re-evaluating identical input/output pairs (important for batch reruns)
- Terminology aligned with LangWatch: "evaluator" (scoring function), "score" (result), "experiment" (batch run)

## Relevant Files

- `.agents/scripts/ai-judgment-helper.sh` — main script to extend
- `.agents/scripts/compare-models-helper.sh` — bench command (t1393) will use evaluators for --judge mode
- `.agents/scripts/observability-helper.sh` — JSONL storage pattern for results
- `.agents/tools/context/model-routing.md` — cross-reference for quality evaluation

## Dependencies

- **Blocked by:** none
- **Enhances:** t1393 (bench --judge can delegate to these evaluators)
- **External:** Anthropic API key for haiku calls (existing credential)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review ai-judgment-helper.sh, LangEvals evaluator prompts |
| Implementation | 2h | evaluate subcommand, 6 evaluator prompts, caching, batch mode |
| Testing | 30m | Test each evaluator, ShellCheck, batch mode |
| **Total** | **3h** | |
