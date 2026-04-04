---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t15450: Simplification: tighten agent doc Bitwarden CLI Integration

## Origin

- **Created:** 2026-04-02
- **Session:** opencode:gemini-3-flash
- **Created by:** ai-interactive
- **Parent task:** GH#15450
- **Conversation context:** Automated scan flagged `.agents/tools/credentials/bitwarden.md` for simplification. The goal is to tighten prose and reorder by importance while preserving institutional knowledge.

## What

A simplified and tightened version of `.agents/tools/credentials/bitwarden.md`. The new version should be more concise, prioritize security and core workflows, and maintain all functional command examples and URLs.

## Why

The current document is 68 lines long and contains verbose prose that can be compressed for better LLM context efficiency. Tightening agent docs reduces token usage and improves agent focus.

## How (Approach)

1.  Read `.agents/tools/credentials/bitwarden.md`.
2.  Reorder sections: Security Notes should come earlier as they are critical.
3.  Tighten prose in all sections.
4.  Ensure all `bw` command examples are preserved.
5.  Ensure all URLs are preserved.
6.  Verify the new file length is significantly reduced without losing knowledge.

## Acceptance Criteria

- [ ] Security Notes moved up (after Quick Reference).
- [ ] Prose tightened throughout the document.
- [ ] All command examples (`bw login`, `bw unlock`, `bw get item`, etc.) preserved.
- [ ] All URLs preserved.
- [ ] File length reduced (target < 50 lines).
- [ ] Markdown lint clean.

## Context & Decisions

- Institutional knowledge (task IDs, incident refs) must be preserved if present (none found in current version).
- Progressive disclosure: keep pointers to related tools.

## Relevant Files

- `.agents/tools/credentials/bitwarden.md` — file to be simplified.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read current doc and issue |
| Implementation | 15m | Rewrite doc |
| Testing | 5m | Lint and verify content |
| **Total** | **25m** | |
