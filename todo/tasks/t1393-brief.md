---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1393: Live model benchmarking — compare-models-helper.sh bench command

## Origin

- **Created:** 2026-03-05
- **Session:** claude-code:chore/langwatch-agent
- **Created by:** human + ai-interactive
- **Conversation context:** While evaluating LangWatch for aidevops integration, identified that our compare-models tooling only compares models by static specs (pricing, context window). LangWatch's ComparisonCharts/ComparisonTable run the same prompt through N models and compare actual outputs with cost/latency/quality metrics. This is the highest-value gap to fill.

## What

A `compare-models-helper.sh bench` subcommand that sends the same prompt (or dataset of prompts) to multiple models and produces a structured comparison of actual outputs, latency, token usage, cost, and optionally an LLM-as-judge quality score.

Deliverables:
1. `compare-models-helper.sh bench` command accepting prompt(s) and model list
2. CLI Markdown table output showing side-by-side results
3. JSONL result storage for historical trending
4. Optional LLM-as-judge scoring (via `ai-judgment-helper.sh` or direct haiku call)
5. Integration with pattern tracker for historical data
6. Support for dataset files (JSONL format from t1395) as input

## Why

Static spec comparison (pricing tables, context windows) helps with planning but not with decisions. When choosing between models for a specific use case, you need to see actual outputs on your actual prompts. Currently this requires manual copy-paste between provider playgrounds. LangWatch solves this with a full UI stack — we can solve it with a CLI command that fits our existing tooling.

The pattern tracker already records historical success rates per model, but there's no way to run a controlled experiment: same input, multiple models, measured comparison. This is the missing link between "which model is cheapest" and "which model is best for this task".

## How (Approach)

### API calls

Use `ai-research` MCP tool or direct provider API calls (via `curl` with keys from `$ANTHROPIC_API_KEY`/`$OPENAI_API_KEY` env vars). Store API keys in a secure secrets store (`aidevops secret set <NAME>` via gopass) — never hardcode credentials in scripts or briefs. The `compare-models-helper.sh discover` command already detects available providers — reuse that for model availability.

### Key files to modify

- `.agents/scripts/compare-models-helper.sh` — add `bench` subcommand
- `.agents/tools/ai-assistants/compare-models.md` — document bench workflow
- `.agents/tools/context/model-routing.md` — add cross-reference to bench command

### Patterns to follow

- `compare-models-helper.sh:159-175` — existing `discover` command pattern for provider detection
- `ai-judgment-helper.sh:1-40` — haiku-tier API call pattern for LLM-as-judge scoring
- `observability-helper.sh:11-12` — JSONL storage pattern for metrics

### Output format (CLI)

```text
| Model                  | Latency | Tokens (in/out) | Cost    | Judge Score |
|------------------------|---------|-----------------|---------|-------------|
| claude-sonnet-4-6      | 1.2s    | 150/320         | $0.0062 | 0.92        |
| gpt-4o                 | 0.9s    | 150/290         | $0.0048 | 0.88        |
| gemini-2.5-pro         | 1.8s    | 150/350         | $0.0071 | 0.90        |
```

### Result storage (JSONL)

```jsonl
{"ts":"2026-03-05T10:00:00Z","prompt_hash":"abc123","model":"claude-sonnet-4-6","latency_ms":1200,"tokens_in":150,"tokens_out":320,"cost":0.0062,"judge_score":0.92,"output_hash":"def456"}
```

Store at `~/.aidevops/.agent-workspace/observability/bench-results.jsonl`.

### LLM-as-judge (optional, --judge flag)

Send all outputs to a haiku-tier model with a scoring prompt:
- Rate output quality 0-1 on: accuracy, completeness, clarity, relevance
- Return structured score + brief rationale
- Cost: ~$0.001 per judgment call

## Acceptance Criteria

- [ ] `compare-models-helper.sh bench "prompt text" model1 model2 model3` produces a comparison table

  ```yaml
  verify:
    method: bash
    run: "compare-models-helper.sh bench 'What is 2+2?' claude-sonnet-4-6 --dry-run 2>&1 | tee /tmp/bench.out >/dev/null && grep -q 'Model' /tmp/bench.out && grep -q 'Latency' /tmp/bench.out"
  ```

- [ ] `compare-models-helper.sh bench --dataset path/to/dataset.jsonl model1 model2` reads prompts from JSONL file

  ```yaml
  verify:
    method: codebase
    pattern: "dataset.*jsonl|--dataset"
    path: ".agents/scripts/compare-models-helper.sh"
  ```

- [ ] `--judge` flag triggers LLM-as-judge scoring for each output

  ```yaml
  verify:
    method: codebase
    pattern: "judge.*score|--judge"
    path: ".agents/scripts/compare-models-helper.sh"
  ```

- [ ] Results stored in JSONL at `~/.aidevops/.agent-workspace/observability/bench-results.jsonl`

  ```yaml
  verify:
    method: codebase
    pattern: "bench-results\\.jsonl"
    path: ".agents/scripts/compare-models-helper.sh"
  ```

- [ ] `compare-models-helper.sh bench --history` shows historical bench results
- [ ] compare-models.md updated with bench workflow documentation
- [ ] ShellCheck clean

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/compare-models-helper.sh"
  ```

## Context & Decisions

- Inspired by LangWatch's `ComparisonCharts.tsx` and `ComparisonTable.tsx` which run batch evaluations across models with per-target metrics (cost, latency, score, pass rate)
- CLI-first approach chosen over UI — fits aidevops's terminal-native workflow
- LLM-as-judge is optional (--judge) because it adds cost and latency; basic comparison (latency, tokens, cost) is free beyond the model calls themselves
- JSONL storage chosen for consistency with `observability-helper.sh` metrics pattern
- Dataset input format (JSONL) aligns with t1395 dataset convention
- Provider discovery reuses existing `compare-models-helper.sh discover` — no new credential management needed

## Relevant Files

- `.agents/scripts/compare-models-helper.sh` — main script to extend with `bench` subcommand
- `.agents/scripts/ai-judgment-helper.sh` — pattern for haiku-tier API calls, potential judge implementation
- `.agents/scripts/observability-helper.sh:11-12` — JSONL storage pattern
- `.agents/tools/ai-assistants/compare-models.md` — docs to update
- `.agents/tools/context/model-routing.md:202-218` — existing comparison section to cross-reference

## Dependencies

- **Blocked by:** none
- **Depends on:** t1395 (dataset convention — bench is the primary consumer)
- **External:** At least one LLM provider API key configured (detected via `discover`)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review existing compare-models-helper.sh, ai-judgment-helper.sh patterns |
| Implementation | 3h | bench subcommand, API calls, output formatting, JSONL storage, judge mode |
| Testing | 30m | Dry-run mode, ShellCheck, manual bench with 2-3 models |
| **Total** | **4h** | |
