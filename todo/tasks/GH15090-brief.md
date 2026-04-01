# Task Brief: GH#15090 - Tighten agent doc Hashline Edit Format

## Context
- **Session Origin**: Headless continuation (GH#15090)
- **Topic**: Simplification of `.agents/reference/hashline-edit-format.md`
- **Current State**: 135 lines, dense technical specification.

## What
Tighten the prose and restructure the agent documentation for Hashline Edit Format to improve readability and token efficiency while preserving all technical details and institutional knowledge.

## Why
The file has been flagged for simplification. Improving the structure and tightening the prose makes it easier for agents to consume and reduces context overhead.

## How
1.  Analyze `.agents/reference/hashline-edit-format.md`.
2.  Reorder sections by importance (most critical first).
3.  Tighten prose without losing technical details (hashes, algorithms, error formats).
4.  Ensure all code blocks and examples are preserved.
5.  Verify that no information is lost.

## Acceptance Criteria
- [ ] Prose is tightened and more concise.
- [ ] Sections are ordered by importance.
- [ ] All technical details (hash algorithm, edit operations, staleness detection) are preserved.
- [ ] All code blocks and examples are present.
- [ ] No broken internal links or references.
- [ ] File size is reduced (if possible without losing knowledge).

## Context
- File: `.agents/reference/hashline-edit-format.md`
- Issue: https://github.com/marcusquinn/aidevops/issues/15090
