---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1487: Split email-to-markdown.py into focused modules (Qlty file-complexity 223)

## Origin

- **Created:** 2026-03-15
- **Session:** claude-code:interactive (quality sweep session)
- **Created by:** AI DevOps (agent) + marcusquinn (human)
- **Conversation context:** Systematic Qlty smell reduction session. This file had 13 smells reduced to 2 (file-complexity 223, function-parameters 9) via extract-function refactoring. The file-complexity requires module splitting.

## What

Split `.agents/scripts/email-to-markdown.py` (1332 lines, complexity 223) into focused modules while preserving the CLI interface and the `email_to_markdown()` public API.

**Proposed module structure:**

1. **`email_parser.py`** — MIME parsing, header extraction, body extraction
   - `get_email_body`, `_extract_mime_parts`, `_html_to_markdown`
   - `extract_attachments`, `_process_one_attachment`, `_iter_msg_attachments`, `_iter_eml_attachments`
   - `_parse_email_file`, `_extract_headers`, `_parse_received_date`
   - ~350 lines, complexity ~60

2. **`email_normaliser.py`** — Section normalisation, thread reconstruction, frontmatter
   - `normalise_email_sections`, `_SectionState`, `_handle_forwarded_header`, `_handle_forwarded_body`, `_handle_signature`, `_start_quote_block`, `_handle_quote_exit`, `_handle_quoted_line`, `_process_section_line`
   - `reconstruct_thread`, `_walk_ancestor_chain`, `_count_descendants`
   - `build_frontmatter`, `_format_attachment_yaml`, `_format_attachments_yaml`, `_format_entities_yaml`
   - ~400 lines, complexity ~80

3. **`email_summary.py`** (note: different from the existing `email-summary.py` — use `email_md_summary.py` to avoid collision)
   - `generate_summary`, `_try_llm_summary`
   - Summary-related constants
   - ~100 lines, complexity ~25

4. **`email_to_markdown.py`** — Pipeline orchestrator and CLI entry point
   - `email_to_markdown()` function (public API, 9 params preserved)
   - `ConvertOptions`, `_PipelineData`, `_build_metadata`
   - `main`, `_build_arg_parser`, `_run_batch`, `_run_single`
   - Imports from the 3 modules above
   - ~300 lines, complexity ~50

## Why

At complexity 223, this file is 4.5x the Qlty threshold. It contains a clear pipeline: parse → normalise → summarise → assemble markdown. Each stage is independent and can be tested in isolation. The file also has cross-file duplication with `email-summary.py` (shared `extract_frontmatter` function) — splitting creates a natural place for shared utilities.

## How (Approach)

1. Map all function definitions and their call graph
2. Identify shared utilities between `email-to-markdown.py` and `email-summary.py` — extract to a shared `email_utils.py` if needed
3. Create each module, preserving all type hints and docstrings
4. Update imports in `email_to_markdown.py` to use the new modules
5. Verify with `python3 -c "import ast; ast.parse(open('path').read())"` for each file
6. Run `qlty smells` to confirm each module is below threshold
7. Test CLI: `python3 email_to_markdown.py --help`

**Key constraint:** The `email_to_markdown()` function signature (9 params) is a public API used by other scripts. It must not change. The function can internally use `ConvertOptions` for cleaner code, but the external signature stays the same.

## Acceptance Criteria

- [ ] Each new module has file-complexity below 100
- [ ] `email_to_markdown.py` file-complexity drops from 223 to <60
- [ ] All files pass `python3 -c "import ast; ast.parse(...)"`
- [ ] CLI entry point (`python3 email_to_markdown.py --help`) still works
- [ ] `email_to_markdown()` function signature unchanged (9 params)
- [ ] No behavioral changes
- [ ] Cross-file duplication with `email-summary.py` addressed via shared utility

## Context

- **Model tier:** opus (complex pipeline, public API preservation, cross-file dedup)
- **Estimated effort:** ~2.5h
- **Tags:** #refactor #quality #qlty #auto-dispatch
- **Branch pattern:** `refactor/split-email-to-markdown`
