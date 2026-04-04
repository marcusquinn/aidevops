<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t15078: recheck: simplification: tighten agent doc Hexagonal Architecture

## Session Origin
- User request: "/full-loop Implement issue #15078 (https://github.com/marcusquinn/aidevops/issues/15078)"
- Repository: `marcusquinn/aidevops`

## What
Simplify and tighten the agent doc `.agents/tools/architecture/clean-ddd-hexagonal-skill/hexagonal.md`.

## Why
The file was previously simplified but has since been modified, causing the content hash to mismatch. It needs to be re-evaluated and restructured as a reference corpus with a slim index and chapter files.

## How
1.  Classify the file as a **Reference corpus**.
2.  Reconcile the content of `hexagonal.md` with the existing chapter files in `.agents/tools/architecture/clean-ddd-hexagonal-skill/hexagonal/`.
3.  Ensure zero content loss during reconciliation.
4.  Replace the content of `hexagonal.md` with a slim index (~50-100 lines) containing a table of contents, one-line descriptions, and file pointers to the chapter files.
5.  Verify content preservation and link integrity.

## Acceptance Criteria
- `hexagonal.md` is a slim index pointing to chapter files in `hexagonal/`.
- All original content from `hexagonal.md` is preserved in the chapter files.
- No broken links or references.
- `wc -l` total of chapter files >= original line count minus index overhead.
- Content hash in `simplification-state.json` (if applicable) is updated or the file is marked as simplified.

## Context
- Issue: GH#15078
- File: `.agents/tools/architecture/clean-ddd-hexagonal-skill/hexagonal.md`
- Chapters: `.agents/tools/architecture/clean-ddd-hexagonal-skill/hexagonal/*.md`
