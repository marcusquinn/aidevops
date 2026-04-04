---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# GH#15088: Simplify .agents/marketing-sales/cro-chapter-06.md

## Origin

- **Created:** 2026-04-02
- **Session:** opencode:GH#15088
- **Created by:** ai-supervisor
- **Conversation context:** Automated scan flagged .agents/marketing-sales/cro-chapter-06.md for simplification. It's a reference corpus that needs to be split into chapters.

## What

Split `.agents/marketing-sales/cro-chapter-06.md` into multiple files within a new directory `.agents/marketing-sales/cro-chapter-06/`. Replace the original file with a slim index.

## Why

Reference corpora should be split into smaller, more manageable files to improve context efficiency and maintainability.

## How (Approach)

1. Create directory `.agents/marketing-sales/cro-chapter-06/`.
2. Extract each major section from `.agents/marketing-sales/cro-chapter-06.md` into its own file in the new directory.
3. Replace `.agents/marketing-sales/cro-chapter-06.md` with a slim index containing a table of contents with one-line descriptions and file pointers.
4. Ensure zero content loss.

## Acceptance Criteria

- [ ] Directory `.agents/marketing-sales/cro-chapter-06/` exists.
- [ ] All sections from the original file are present in the new chapter files.
- [ ] `.agents/marketing-sales/cro-chapter-06.md` is a slim index.
- [ ] Total line count of chapter files >= original line count minus index overhead.
- [ ] Tests pass (if any).
- [ ] Lint clean.

## Relevant Files

- `.agents/marketing-sales/cro-chapter-06.md` — original file to be split.
- `.agents/marketing-sales/cro-chapter-06/` — new directory for chapter files.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read original file and identify sections |
| Implementation | 30m | Create directory and files, update index |
| Testing | 10m | Verify content preservation and line count |
| **Total** | **45m** | |
