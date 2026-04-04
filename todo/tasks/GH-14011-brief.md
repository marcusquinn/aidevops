<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#14011: Restructure Mobile CRO reference chapter

## Session Origin

Interactive `/full-loop` invocation targeting GitHub issue #14011.

## What

Restructure `.agents/marketing-sales/cro-chapter-11.md` as a reference corpus index that points to section files for the Mobile CRO chapter, preserving all chapter knowledge without compressing or deleting it.

## Why

Issue #14011 flagged the file as a simplification target. The file is a textbook-style reference chapter, so the correct fix is restructuring into a slim index plus section files per the reference-corpus rule in `.agents/tools/code-review/code-simplifier.md`.

## How

1. Classify the file as a reference corpus, not an instruction doc.
2. Move each major section into a dedicated file under `.agents/marketing-sales/cro-chapter-11/`.
3. Replace `.agents/marketing-sales/cro-chapter-11.md` with a slim index linking each section file and preserving reading order.
4. Verify that code blocks and all substantive guidance still exist after the split.

## Acceptance Criteria

- [ ] `.agents/marketing-sales/cro-chapter-11.md` becomes an index for the chapter section files.
- [ ] Every major section from the original chapter exists in a dedicated file under `.agents/marketing-sales/cro-chapter-11/`.
- [ ] The chapter's code blocks and practical examples remain present after restructuring.
- [ ] Markdown linting passes for the touched Markdown files.
- [ ] Total lines across the section files are at least the original chapter size minus index overhead.
- [ ] PR created with `Closes #14011`.

## Context

The issue explicitly distinguishes instruction-doc tightening from reference-corpus restructuring. Chapter 11 is already a self-contained knowledge chapter, so the safe change is progressive disclosure via a slim index plus section files.

## Relevant Files

- `.agents/marketing-sales/cro-chapter-11.md` — replace dense chapter body with section index.
- `.agents/marketing-sales/cro-chapter-11/` — new section files holding the moved reference content.
- `.agents/tools/code-review/code-simplifier.md` — classification rule for reference corpora.
- `.agents/tools/build-agent/build-agent.md` — progressive disclosure and subdivision guidance.
