---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1488: Split seo-content-analyzer.py into focused modules (Qlty file-complexity 177)

## Origin

- **Created:** 2026-03-15
- **Session:** claude-code:interactive (quality sweep session)
- **Created by:** AI DevOps (agent) + marcusquinn (human)
- **Conversation context:** Systematic Qlty smell reduction session. This file had its function-level smells fixed (rate complexity 36 → below threshold, main complexity 21 → below threshold) but file-complexity 177 remains, requiring module splitting.

## What

Split `.agents/scripts/seo-content-analyzer.py` (745 lines, complexity 177) into focused modules while preserving the CLI interface.

**Proposed module structure:**

1. **`seo_scoring.py`** — Content scoring engine
   - `rate` (the main scoring function)
   - `_score_content`, `_score_structure`, `_score_keywords`, `_score_meta`, `_score_links`
   - Scoring constants and thresholds
   - ~300 lines, complexity ~80

2. **`seo_extraction.py`** — HTML/content extraction and parsing
   - Functions that extract headings, meta tags, links, word counts from HTML/markdown
   - Content normalisation utilities
   - ~200 lines, complexity ~40

3. **`seo_content_analyzer.py`** — CLI entry point and report formatting
   - `main`, `_run_file_command`
   - Argument parsing, output formatting, report generation
   - Imports from scoring and extraction modules
   - ~200 lines, complexity ~50

## Why

At complexity 177, this file is 3.5x the Qlty threshold. It contains three distinct concerns: extraction (parsing HTML/markdown), scoring (applying SEO rules), and reporting (CLI, output formatting). These are independently useful — the scoring engine could be reused by the SEO audit workflow without the CLI wrapper.

## How (Approach)

1. Map all function definitions and identify the extraction → scoring → reporting pipeline
2. Create `seo_scoring.py` with the scoring engine and its helper functions
3. Create `seo_extraction.py` with content parsing utilities
4. Update `seo_content_analyzer.py` to import from the new modules
5. Verify with `python3 -c "import ast; ast.parse(...)"`
6. Run `qlty smells` to confirm each module is below threshold
7. Test CLI: `python3 seo_content_analyzer.py --help`

## Acceptance Criteria

- [ ] Each new module has file-complexity below 100
- [ ] `seo_content_analyzer.py` file-complexity drops from 177 to <60
- [ ] All files pass `python3 -c "import ast; ast.parse(...)"`
- [ ] CLI entry point still works
- [ ] No behavioral changes

## Context

- **Model tier:** opus (moderate complexity, clean pipeline structure)
- **Estimated effort:** ~1.5h
- **Tags:** #refactor #quality #qlty #auto-dispatch
- **Branch pattern:** `refactor/split-seo-content-analyzer`
