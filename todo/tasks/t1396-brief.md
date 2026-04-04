---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1396: Prompt version tracking in observability traces

## Origin

- **Created:** 2026-03-05
- **Session:** claude-code:chore/langwatch-agent
- **Created by:** human + ai-interactive
- **Conversation context:** LangWatch links prompt versions to traces — you can see "version 3 of this prompt regressed on faithfulness vs version 2". Our prompts are in git (version controlled) but there's no linkage between a specific prompt version and the traces it produced. This is a lightweight addition to observability-helper.sh.

## What

Add a `prompt_version` field to observability traces recorded by `observability-helper.sh`, enabling correlation between prompt changes and output quality over time.

Deliverables:
1. `prompt_version` field in JSONL trace records (git short hash of prompt file, or manual version tag)
2. `observability-helper.sh` updated to accept and record prompt version metadata
3. Query support: filter bench/eval results by prompt version
4. Documentation update in observability and model-routing docs

## Why

When you change a prompt and quality regresses, you need to know which version caused it. Currently:
- Prompts are in git (versioned) but traces don't record which version produced them
- The pattern tracker records model + outcome but not prompt version
- There's no way to answer "did my last prompt edit make things better or worse?"

This is the cheapest possible regression detection: just tag each trace with the prompt version that produced it. Combined with t1393 (bench) and t1394 (evaluators), you can run the same dataset against two prompt versions and compare scores.

LangWatch builds a full prompt management UI for this. We just need a field in the JSONL.

## How (Approach)

### Trace format change

Add `prompt_version` and `prompt_file` to existing JSONL trace records in `observability-helper.sh`. Existing fields remain unchanged — these are additive:

```jsonl
{"provider":"anthropic","model":"claude-sonnet-4-6","session_id":"...","request_id":"...","project":"...","input_tokens":150,"output_tokens":320,"cache_read_tokens":0,"cache_write_tokens":0,"cost_input":0.0,"cost_output":0.0,"cost_cache_read":0.0,"cost_cache_write":0.0,"cost_total":0.0062,"stop_reason":"","service_tier":"","git_branch":"...","log_source":"...","recorded_at":"...","error_message":"","prompt_version":"a1b2c3d","prompt_file":"prompts/build.txt"}
```

### Version resolution

Three strategies (in priority order):

1. **Explicit tag**: `--prompt-version v2.1` passed by caller
2. **Git hash**: If `--prompt-file path/to/prompt.txt` is provided, compute `git log -1 --format='%h' -- path/to/prompt.txt`
3. **None**: Field omitted if no prompt metadata available (backward compatible)

### Key files to modify

- `.agents/scripts/observability-helper.sh` — add `prompt_version` and `prompt_file` fields to `record` subcommand (via `--prompt-version` and `--prompt-file` flags)
- `.agents/scripts/compare-models-helper.sh` — bench results include prompt version when available
- `.agents/tools/ai-assistants/compare-models.md` — document prompt version filtering
- `.agents/tools/context/model-routing.md` — cross-reference in "Model Comparison" section

### CLI changes

```bash
# Record a trace with prompt version
observability-helper.sh record \
  --model claude-sonnet-4-6 \
  --input-tokens 150 --output-tokens 320 \
  --prompt-file prompts/build.txt

# Bench with prompt version tracking
compare-models-helper.sh bench "prompt text" model1 model2 \
  --prompt-file prompts/build.txt

# Filter bench history by prompt version
compare-models-helper.sh bench --history --prompt-version a1b2c3d
```

### Patterns to follow

- `observability-helper.sh` existing field handling — add fields without breaking existing consumers
- Git short hash pattern: `git log -1 --format='%h' -- "$file"` (fast, deterministic)

## Acceptance Criteria

- [ ] `observability-helper.sh record --prompt-file path/to/file` includes `prompt_version` (git short hash) in JSONL output

  ```yaml
  verify:
    method: codebase
    pattern: "prompt_version|prompt_file"
    path: ".agents/scripts/observability-helper.sh"
  ```

- [ ] Explicit `--prompt-version` flag overrides git hash detection

  ```yaml
  verify:
    method: codebase
    pattern: "--prompt-version"
    path: ".agents/scripts/observability-helper.sh"
  ```

- [ ] Existing traces without prompt_version continue to work (backward compatible)
- [ ] `compare-models-helper.sh bench` passes prompt version through to results when available
- [ ] Documentation updated in compare-models.md and model-routing.md
- [ ] ShellCheck clean

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/observability-helper.sh"
  ```

## Context & Decisions

- Inspired by LangWatch's prompt versioning with trace linkage — they build a full UI, we just need a JSONL field
- Git short hash chosen as default version identifier because prompts are already in git — no new versioning system needed
- `prompt_file` field included alongside `prompt_version` for human readability (hash alone is opaque)
- Backward compatible: field is optional, existing traces without it continue to parse
- This is intentionally minimal — a full prompt management system (versioning UI, A/B testing, rollback) is out of scope. The field enables future tooling without requiring it now.
- Combined with t1393 (bench) and t1394 (evaluators), this enables: "run dataset against prompt v1 and v2, compare scores" — the core regression detection workflow

## Relevant Files

- `.agents/scripts/observability-helper.sh` — main script to modify (add fields to record subcommand)
- `.agents/scripts/compare-models-helper.sh` — bench command (t1393) to pass through prompt version
- `.agents/tools/ai-assistants/compare-models.md` — docs to update
- `.agents/tools/context/model-routing.md:202-218` — cross-reference section

## Dependencies

- **Blocked by:** none
- **Blocks:** none (enhances t1393 and t1394 but not required by them)
- **External:** none (git is already available)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review observability-helper.sh record format |
| Implementation | 30m | Add fields, git hash resolution, CLI flags |
| Documentation | 15m | Update compare-models.md, model-routing.md |
| **Total** | **1h** | |
