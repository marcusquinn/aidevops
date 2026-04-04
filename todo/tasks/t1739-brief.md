<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1739: simplification: tighten agent doc Services & Integrations

## Summary
Simplify `.agents/reference/services.md` by splitting it into chapter files and replacing the original with a slim index.

## Acceptance Criteria
- [ ] `services.md` is reduced to a slim index (~100-200 lines).
- [ ] Each major section is extracted into its own file in `.agents/reference/`.
- [ ] Zero content loss — all information from the original `services.md` is preserved in the new files.
- [ ] No broken internal links or references.
- [ ] `wc -l` total of chapter files >= original line count minus index overhead.

## Context
- Issue: GH#15094
- File: `.agents/reference/services.md`
- Classification: Reference corpus

## How
1. Create `reference/contribution-watch.md`, `reference/auto-update.md`, and `reference/repo-sync.md`.
2. Verify existing files (`memory.md`, `mailbox.md`, `skills.md`, `settings.md`, `foss-contributions.md`) contain the content from `services.md`.
3. Update `services.md` to be a slim index with one-line descriptions and file pointers.
4. Run verification checks.
