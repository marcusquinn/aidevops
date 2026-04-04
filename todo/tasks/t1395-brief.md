---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1395: Dataset convention for repeatable LLM evaluations

## Origin

- **Created:** 2026-03-05
- **Session:** claude-code:chore/langwatch-agent
- **Created by:** human + ai-interactive
- **Conversation context:** LangWatch treats datasets as first-class objects — collections of test cases with inputs and optional expected outputs. You can build datasets from production traces (annotate failures, add to dataset, re-evaluate). aidevops has no dataset concept. The pattern tracker stores outcomes but not reusable test cases. This convention enables repeatable evaluations across t1393 (bench) and t1394 (evaluators).

## What

A standardised JSONL dataset format and directory convention for storing LLM evaluation test cases, plus tooling to create, validate, and manage datasets.

Deliverables:
1. Dataset format specification (JSONL schema)
2. Directory convention (`~/.aidevops/.agent-workspace/datasets/` for global, `datasets/` in project repos)
3. `dataset-helper.sh` script with subcommands: create, validate, add, list, stats, promote
4. "Promote from trace" workflow — convert observability traces into dataset entries
5. Documentation in a new agent doc

## Why

Without a dataset concept, every evaluation is ad-hoc. You can't:
- Re-run the same test cases after a prompt change to detect regressions
- Build a golden set of edge cases discovered in production
- Share test cases between bench runs (t1393) and evaluator runs (t1394)
- Track dataset coverage (which scenarios are tested, which aren't)

LangWatch's dataset management is one of their stickiest features — once you have a curated dataset, you keep coming back to run evals against it. We can get 80% of the value with a JSONL convention and a simple helper script.

## How (Approach)

### Dataset format (JSONL)

Each line is a JSON object with standardised fields:

```jsonl
{"id":"001","input":"What is the capital of France?","expected":"Paris","context":"France is in Western Europe.","tags":["geography","factual"],"source":"manual"}
{"id":"002","input":"Summarize this PR","expected":null,"context":"PR #123 adds auth middleware...","tags":["code-review","summarization"],"source":"trace:abc123"}
```

Required fields: `id`, `input`
Optional fields: `expected`, `context`, `tags`, `source`, `metadata`

### Directory convention

```text
~/.aidevops/.agent-workspace/datasets/    # Global datasets (cross-project)
  golden-prompts.jsonl                     # Curated test prompts
  regression-auth.jsonl                    # Auth-related regression cases
~/Git/myproject/datasets/                  # Project-specific datasets
  api-responses.jsonl                      # Expected API response quality
```

### Helper script subcommands

```bash
dataset-helper.sh create <name> [--project]     # Create empty dataset (valid JSONL file)
dataset-helper.sh validate <file>                # Validate JSONL schema
dataset-helper.sh add <file> --input "..." [--expected "..."] [--tags "a,b"]  # Append entry
dataset-helper.sh list [--project <path>]        # List available datasets
dataset-helper.sh stats <file>                   # Row count, tag distribution, source breakdown
dataset-helper.sh promote --trace-id <id>        # Convert observability trace to dataset entry
dataset-helper.sh merge <file1> <file2> -o <out> # Merge datasets, dedup by id
```

### Key files to create/modify

- `.agents/scripts/dataset-helper.sh` — new helper script
- `.agents/tools/ai-assistants/datasets.md` — new agent doc (or section in compare-models.md)
- `.agents/scripts/observability-helper.sh` — add `promote` integration point
- `.agents/scripts/compare-models-helper.sh` — ensure bench reads dataset format
- `.agents/scripts/ai-judgment-helper.sh` — ensure evaluate reads dataset format

### Patterns to follow

- `compare-models-helper.sh` — helper script structure (subcommands, help, shared-constants)
- `observability-helper.sh:11-12` — JSONL storage conventions
- LangWatch dataset model — id, input, expected, context, tags, source tracking

## Acceptance Criteria

- [ ] `dataset-helper.sh create golden-prompts` creates a valid empty JSONL file (pure JSONL, no inline comments)
- [ ] Dataset schema is documented in the task doc (or a companion schema file)

  ```yaml
  verify:
    method: bash
    run: "test -f .agents/scripts/dataset-helper.sh && grep -q 'create' .agents/scripts/dataset-helper.sh"
  ```

- [ ] `dataset-helper.sh validate <file>` checks JSONL schema (required fields, valid JSON per line)

  ```yaml
  verify:
    method: codebase
    pattern: "validate.*jsonl|required.*input"
    path: ".agents/scripts/dataset-helper.sh"
  ```

- [ ] `dataset-helper.sh add` appends entries with auto-generated IDs
- [ ] `dataset-helper.sh promote --trace-id` converts an observability trace to a dataset entry
- [ ] `dataset-helper.sh stats` shows row count, tag distribution, source breakdown
- [ ] `compare-models-helper.sh bench --dataset` reads the standard format (cross-reference with t1393)
- [ ] `ai-judgment-helper.sh evaluate --dataset` reads the standard format (cross-reference with t1394)
- [ ] Documentation covers format spec, directory convention, and workflows
- [ ] ShellCheck clean

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/dataset-helper.sh"
  ```

## Context & Decisions

- JSONL chosen over CSV/JSON-array because: streamable (append without rewriting), one entry per line (easy grep/wc), standard in ML/eval tooling, consistent with observability-helper.sh
- `id` field is required for deduplication and trace-back; auto-generated if not provided (UUID or sequential)
- `source` field tracks provenance: "manual" (hand-written), "trace:ID" (promoted from observability), "generated:model" (synthetic)
- `expected` is optional because many evaluations don't have a single correct answer (e.g., summarization quality)
- `context` is optional but critical for faithfulness evaluation — it's what the model should ground its answer in
- `tags` enable filtering datasets by scenario type (regression, edge-case, domain)
- Global datasets live in agent-workspace (cross-project); project datasets live in the repo (version-controlled with the code)
- Terminology from LangWatch: "dataset" (collection of test cases), "entry" (single test case), "promote" (trace → dataset)

## Relevant Files

- `.agents/scripts/compare-models-helper.sh` — bench command (t1393) is primary dataset consumer
- `.agents/scripts/ai-judgment-helper.sh` — evaluator presets (t1394) is secondary consumer
- `.agents/scripts/observability-helper.sh` — trace storage, promote source
- `.agents/scripts/shared-constants.sh` — shared paths and conventions

## Dependencies

- **Blocked by:** none (format spec is independent)
- **Blocks:** none (t1393 and t1394 can implement dataset reading independently, but this standardises the format)
- **External:** none (pure shell script, no external dependencies)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review JSONL conventions, observability-helper patterns |
| Implementation | 1.5h | dataset-helper.sh (create, validate, add, list, stats, promote, merge) |
| Documentation | 15m | datasets.md agent doc |
| **Total** | **2h** | |
