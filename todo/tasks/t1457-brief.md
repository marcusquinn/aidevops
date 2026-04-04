---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1457: Model-agnostic session-miner feedback loop

## Origin

- **Created:** 2026-03-12
- **Session:** OpenCode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** User asked for a full feedback loop so lessons from all models and sessions improve aidevops globally, including rare outliers and traceable self-improvement actions.

## What

Implement a model-agnostic signal-to-action pipeline in session-miner that converts mined error patterns into actionable common/outlier feedback candidates, emits machine-readable artifacts, tracks pulse-over-pulse pattern deltas, and optionally files deduplicated GitHub issues with rate caps.

## Why

Session mining currently surfaces useful signals, but without a structured and traceable actuation path, many learnings never become tasks or harness improvements. The loop must improve all models/users by fixing shared process weaknesses, including low-frequency high-impact failures.

## How (Approach)

Augment extraction with model metadata, enrich compression output with cross-model severity fields, and extend pulse orchestration to generate ranked feedback actions plus optional issue creation behind explicit flags.

- `/.agents/scripts/session-miner/extract.py:255` — include model ID for tool-error records
- `/.agents/scripts/session-miner/compress.py:124` — compute model spread and severity metadata per pattern
- `/.agents/scripts/session-miner-pulse.sh:257` — generate action/report/metrics artifacts and optional issue actuation
- `/.agents/scripts/commands/pulse.md:1159` — document optional auto-issue invocation

## Acceptance Criteria

- [ ] Session-miner error records include model metadata
  ```yaml
  verify:
    method: codebase
    pattern: "json_extract\(m\.data, '\$\.modelID'\) as model_id"
    path: ".agents/scripts/session-miner/extract.py"
  ```
- [ ] Compressed error patterns include model_count/severity/cross_model fields
  ```yaml
  verify:
    method: codebase
    pattern: "\"model_count\"|\"severity\"|\"cross_model\""
    path: ".agents/scripts/session-miner/compress.py"
  ```
- [ ] Pulse generates feedback action and delta artifacts
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/session-miner-pulse.sh --force --dry-run"
  ```
- [ ] Optional issue filing path is deduplicated and cap-limited behind explicit opt-in flags
  ```yaml
  verify:
    method: codebase
    pattern: "SESSION_MINER_AUTO_ISSUES|SESSION_MINER_MAX_ISSUES|--search"
    path: ".agents/scripts/session-miner-pulse.sh"
  ```
- [ ] Tests/lint for touched files pass

## Context & Decisions

- Use two lanes (common + outlier) to avoid missing rare high-impact failures.
- Keep defaults non-destructive; issue filing requires explicit opt-in.
- Prioritize model-agnostic improvements by grouping on failure patterns, not model name.

## Relevant Files

- `.agents/scripts/session-miner/extract.py:255` — error extraction query/data shape
- `.agents/scripts/session-miner/compress.py:124` — compressed pattern schema
- `.agents/scripts/session-miner-pulse.sh:257` — pulse feedback action generation and issue actuation
- `.agents/scripts/commands/pulse.md:1159` — operator guidance for optional auto-issue mode

## Dependencies

- **Blocked by:** none
- **Blocks:** closed-loop self-improvement automation from mined sessions
- **External:** `gh` CLI auth for optional auto-issue filing

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | inspect extraction/compression/pulse flow |
| Implementation | 1.5h | extraction + compression + pulse automation |
| Testing | 1h | dry-runs, lint, syntax validation |
| **Total** | **3h** | |
