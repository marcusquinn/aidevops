<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t2155: tighten agent doc API Integration Guide

## Context
- **Origin**: Headless continuation for issue #15042 (https://github.com/marcusquinn/aidevops/issues/15042)
- **File**: `.agents/aidevops/api-integrations.md`
- **Goal**: Tighten and restructure the agent doc according to `code-simplifier.md` and `build-agent.md` guidance.

## What
- Tighten prose in `.agents/aidevops/api-integrations.md`.
- Reorder sections by importance (Setup and Security first).
- Ensure all institutional knowledge is preserved.
- Verify no broken links or references.

## Why
- Token optimization: every token costs on every load.
- Improved agent performance: LLMs weight earlier context more heavily (primacy effect).

## How
- Move "Setup" section to the top (after Quick Reference).
- Move "Security & Code Quality" and "Git Platforms" to the top of the Service Catalog.
- Compress verbose table entries and prose.
- Use `markdownlint-cli2` to verify formatting.

## Acceptance Criteria
- [x] Content preservation: all code blocks, URLs, and command examples present.
- [x] Reordered by importance: Setup and Security/Git sections moved up.
- [x] Prose tightened: redundant words removed, tables compressed where possible.
- [x] No broken internal links or references.
- [x] `markdownlint-cli2` passes.

## Acceptance Evidence
- [x] `git diff` showing reordering and tightening.
- [x] `markdownlint-cli2` output.
- [x] Verification of key content (URLs, code blocks).
- [x] PR created: https://github.com/marcusquinn/aidevops/pull/15580

## Context
- Issue: GH#15042
- Reference: `.agents/tools/code-review/code-simplifier.md`, `.agents/tools/build-agent/build-agent.md`
