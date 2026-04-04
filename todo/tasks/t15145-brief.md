---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t15145: simplification: tighten agent doc Tunnel Gotchas

## Origin

- **Created:** 2026-04-02
- **Session:** opencode:current-session
- **Created by:** ai-interactive
- **Conversation context:** The user requested to implement issue #15145, which involves simplifying the Cloudflare Tunnel Gotchas agent doc.

## What

A tightened and restructured version of `.agents/services/hosting/cloudflare-platform-skill/tunnel-gotchas.md` that preserves all knowledge but reduces prose and improves readability for LLMs.

## Why

The file was flagged for simplification to improve agent performance and reduce context token usage.

## How (Approach)

Follow instruction doc simplification strategy from `tools/build-agent/build-agent.md`.
1. Classify as "Instruction doc".
2. Reorder by importance: Security rules first, then core operations, then troubleshooting.
3. Compress prose, not knowledge.
4. Preserve all code blocks, URLs, task ID references, and command examples.
5. Use search patterns instead of line numbers for references.

## Acceptance Criteria

- [ ] Content preservation: all code blocks, URLs, task ID references, and command examples are present.
  ```yaml
  verify:
    method: subagent
    prompt: "Compare the original and new versions of .agents/services/hosting/cloudflare-platform-skill/tunnel-gotchas.md. Ensure all code blocks, URLs, and command examples are preserved."
  ```
- [ ] Reordered by importance: Security rules first.
  ```yaml
  verify:
    method: codebase
    pattern: "^# Tunnel Gotchas\n\n## Security"
    path: ".agents/services/hosting/cloudflare-platform-skill/tunnel-gotchas.md"
  ```
- [ ] Prose tightened: redundant words removed.
- [ ] No broken internal links or references.
- [ ] Lint clean (markdownlint if available).

## Relevant Files

- `.agents/services/hosting/cloudflare-platform-skill/tunnel-gotchas.md` — file to simplify
- `tools/build-agent/build-agent.md` — simplification guidance

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read original file and guidance |
| Implementation | 15m | Tighten and restructure |
| Testing | 5m | Verify content preservation |
| **Total** | **25m** | |
