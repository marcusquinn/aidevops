<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#14990: Tighten `.agents/marketing-sales/direct-response-copy-checklists-pre-publish.md`

## Session Origin

Interactive `/full-loop` run for GitHub issue #14990 under the headless continuation contract.

## What

Restructure `.agents/marketing-sales/direct-response-copy-checklists-pre-publish.md` into a tighter pre-publish checklist that surfaces the highest-value pass/fail gate first, keeps the same copy-review guidance, and stays single-file.

## Why

The checklist is already concise, but its highest-priority publishing gate sits at the bottom and several sections repeat the same idea in separate buckets. Reordering by decision importance improves scan speed and reduces prompt cost without changing the checklist's intent.

## How

1. Classify the file as an instruction doc, not a reference corpus.
2. Move the six-point publish gate to the top so it acts as the primary stop/go screen.
3. Merge adjacent sections into clearer buckets: strategy, message, conversion mechanics, and delivery QA.
4. Preserve every substantive requirement from the original checklist while tightening phrasing.
5. Run markdown lint on the edited doc.

## Acceptance Criteria

- [ ] The six-point gate appears before the detailed checklist sections.
- [ ] All original substantive checks remain represented after the rewrite.
- [ ] The file remains a single markdown document and is shorter than the original 98-line version.
- [ ] Markdown lint passes for `.agents/marketing-sales/direct-response-copy-checklists-pre-publish.md`.
- [ ] PR created with `Closes #14990`.

## Context

Issue #14990 is an automated simplification-debt task. The target is an instruction checklist, so the right simplification is tighter prose and stronger ordering, not chapter extraction.
