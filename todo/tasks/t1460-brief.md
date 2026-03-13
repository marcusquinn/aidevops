---
mode: subagent
---
# t1460: Normalize model identifiers to canonical latest IDs

## Origin

- **Created:** 2026-03-13
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** User requested removing old hard-coded model identifiers and standardizing defaults to clean current model IDs without version-pinned fallbacks.

## What

Update active runtime routing defaults, verification fallback chains, generated agent tier mappings, and shipped config templates to use canonical model identifiers (for example, `claude-haiku-4-5`, `gemini-2.5-flash`, `gemini-2.5-pro`) instead of date-pinned preview variants.

## Why

Date/version-pinned model strings in defaults create drift and unnecessary maintenance overhead. Canonical IDs keep routing stable and model-agnostic while retaining compatibility handling only where historical parsing requires it.

## How (Approach)

Replace dated IDs in active scripts/config defaults, keep legacy alias support only in dedicated normalization logic, then verify with syntax and config validation checks.

- `.agents/scripts/shared-constants.sh:1243` — tier-to-model static fallback map
- `.agents/scripts/model-availability-helper.sh:112` — runtime tier primary/fallback model chain
- `.agents/scripts/verify-operation-helper.sh:56` — high-stakes verifier fallback provider chain
- `.agents/scripts/generate-opencode-agents.sh:221` — generated OpenCode model tier table
- `configs/crewai-config.json.txt:30` — template provider defaults

## Acceptance Criteria

- [ ] Active runtime tier defaults use canonical non-preview model IDs
  ```yaml
  verify:
    method: bash
    run: "rg -n 'preview-05-20|preview-06-05|20251001' .agents/scripts --glob '!**/archived/**' --glob '!**/supervisor-archived/**' --glob '!**/tests/**'"
  ```
- [ ] Config templates no longer use deprecated `claude-3-*` / `gpt-3.5` defaults
  ```yaml
  verify:
    method: bash
    run: "rg -n 'claude-3-5|claude-3-opus|claude-3-sonnet|claude-3-haiku|gpt-3\\.5-turbo|gpt-4-turbo-preview' configs"
  ```
- [ ] Modified shell scripts remain syntactically valid
  ```yaml
  verify:
    method: bash
    run: "bash -n .agents/scripts/shared-constants.sh .agents/scripts/model-availability-helper.sh .agents/scripts/verify-operation-helper.sh .agents/scripts/generate-opencode-agents.sh .agents/scripts/stagehand-python-setup.sh .agents/scripts/stagehand-python-helper.sh .agents/scripts/contest-helper.sh .agents/scripts/model-registry-helper.sh"
  ```
- [ ] Modified JSON templates/config files remain valid
  ```yaml
  verify:
    method: bash
    run: "jq -e . configs/crewai-config.json.txt >/dev/null && jq -e . configs/langflow-config.json.txt >/dev/null && jq -e . configs/dspy-config.json.txt >/dev/null && jq -e .agents/configs/fallback-chain-config.json.txt >/dev/null"
  ```

## Context & Decisions

- Keep backward-compatible alias parsing in normalization helpers to avoid breaking historical logs/tools.
- Remove version-pinned IDs from active defaults and generated mappings.
- Do not assume unreleased model families (for example, no `haiku-4-6` until present in registry).

## Relevant Files

- `.agents/scripts/shared-constants.sh:1255` — canonicalized flash/pro mappings
- `.agents/scripts/model-availability-helper.sh:118` — canonicalized tier model chain
- `.agents/scripts/verify-operation-helper.sh:59` — canonicalized verifier fallback chain
- `.agents/scripts/generate-opencode-agents.sh:222` — canonicalized generated tier map
- `configs/dspy-config.json.txt:17` — refreshed legacy template defaults

## Dependencies

- **Blocked by:** none
- **Blocks:** cleaner model-routing consistency across runtime and templates
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | locate active vs legacy references |
| Implementation | 1h | update runtime + templates |
| Testing | 30m | syntax + config + search validation |
| **Total** | **2h** | |
