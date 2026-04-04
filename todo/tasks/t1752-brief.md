---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1752: recheck: simplification: tighten agent doc Gotchas & Best Practices (.agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md)

## Origin

- **Created:** 2026-04-02
- **Session:** opencode:gemini-3-flash
- **Created by:** ai-supervisor
- **Parent task:** GH#15053
- **Conversation context:** Automated scan flagged `.agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md` for re-simplification as it has been modified since the last simplification (PR #14658).

## What

Tighten and restructure the agent instruction doc `.agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md`. The goal is to reduce token usage while preserving all institutional knowledge, ordering by importance, and following `tools/build-agent/build-agent.md` guidance.

## Why

Instruction docs should be as lean as possible to minimize context window usage for agents. This file has grown to 114 lines and needs tightening to ensure agents focus on the most critical rules first.

## How (Approach)

1.  **Classify:** Already classified as an **Instruction doc**.
2.  **Tighten prose:** Compress verbose rules without losing knowledge (task IDs, incident references, rationale).
3.  **Order by importance:** Ensure Security rules are first, followed by core workflows, then edge cases.
4.  **Remove stale references:** Replace any `file:line_number` references with search patterns or section headings.
5.  **Verify:** Ensure all code blocks, URLs, and task ID references are preserved.

## Acceptance Criteria

- [ ] Content preservation: all code blocks, URLs, task ID references (`tNNN`, `GH#NNN`), and command examples are present.
  ```yaml
  verify:
    method: subagent
    prompt: "Compare the original and simplified versions of .agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md. Ensure no institutional knowledge, code blocks, URLs, or task ID references were lost."
    files: ".agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md"
  ```
- [ ] No broken internal links or references.
- [ ] Security rules remain at the top of the file.
  ```yaml
  verify:
    method: bash
    run: "head -n 20 .agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md | grep -i 'Security'"
  ```
- [ ] Total line count is reduced (target < 100 lines).
  ```yaml
  verify:
    method: bash
    run: "[ $(wc -l < .agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md) -lt 114 ]"
  ```

## Relevant Files

- `.agents/services/hosting/cloudflare-platform-skill/agents-sdk-gotchas.md` — target for simplification.
- `tools/build-agent/build-agent.md` — guidance for agent doc simplification.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read target file and guidance |
| Implementation | 15m | Tighten prose and restructure |
| Testing | 5m | Verify content preservation |
| **Total** | **25m** | |
