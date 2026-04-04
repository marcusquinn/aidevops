<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1737: simplification: tighten agent doc CRO Fundamentals and Core Concepts

## Session Origin
- User request: "/full-loop Implement issue #15077 (https://github.com/marcusquinn/aidevops/issues/15077)"
- Issue: GH#15077

## What
- Simplify `.agents/marketing-sales/cro-chapter-02.md` by replacing it with a slim index.
- Ensure all content is preserved in the already existing `cro-chapter-02/` directory.

## Why
- The file is a reference corpus and should be split into chapters for better context management.
- Large files consume too many tokens and can lead to context loss.

## How
- Verify all sections from `cro-chapter-02.md` are present in `.agents/marketing-sales/cro-chapter-02/*.md`.
- Replace `cro-chapter-02.md` with a table of contents pointing to the chapter files.
- Add one-line descriptions for each chapter.

## Acceptance Criteria
- `cro-chapter-02.md` is a slim index (~100-200 lines).
- All original content is preserved in `cro-chapter-02/` directory.
- No broken links or references.
- `wc -l` total of chapter files >= original line count minus index overhead.

## Context
- The file is a reference corpus for CRO fundamentals.
- Partial split already exists in `cro-chapter-02/`.
