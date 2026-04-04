---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1859: simplification: reduce function complexity in normalise-markdown.py

## Origin

- **Created:** 2026-04-03
- **Session:** opencode:qlty-maintainability-recovery
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability grade dropped from A to C. `normalise-markdown.py` contains `detect_email_sections()` with complexity 63 — the highest complexity Python function in the codebase. Total file complexity is 142.

## What

Reduce function complexity in `.agents/scripts/normalise-markdown.py` (358 lines) from 142 total (worst function: `detect_email_sections` at 63) to under 40 total, with no individual function exceeding complexity 12.

## Why

- `detect_email_sections()` at complexity 63 is the worst Python function in the codebase
- Total 142 complexity from a 358-line file indicates extreme density — nearly every line is branching
- Python files are scored alongside JS/MJS in the maintainability grade
- Quick win: small file, clear function boundaries, straightforward decomposition

## How (Approach)

1. **Read `detect_email_sections()`** to understand what it does — likely a state machine or regex-heavy classifier that identifies email parts (greeting, body, signature, quoted text, etc.)
2. **Extract section detectors** into individual functions: `detect_greeting()`, `detect_signature()`, `detect_quoted_text()`, `detect_disclaimer()`, etc.
3. **Replace nested if/elif chains** with a detector registry pattern:
   ```python
   SECTION_DETECTORS = [
       ("greeting", detect_greeting),
       ("signature", detect_signature),
       ("quoted", detect_quoted_text),
   ]
   ```
4. **Simplify the main function** to iterate detectors and compose results
5. **Extract regex patterns** into module-level constants with descriptive names
6. **Replace complex boolean expressions** with named helper functions

## Acceptance Criteria

- [ ] `detect_email_sections()` complexity drops below 12 (from 63)
  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && ~/.qlty/bin/qlty smells .agents/scripts/normalise-markdown.py --sarif 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); results=d.get('runs',[])[0].get('results',[]); high=[r for r in results if 'high complexity' in r.get('message',{}).get('text','').lower()]; sys.exit(0 if not high else 1)\""
  ```
- [ ] Total file complexity below 40 (from 142)
- [ ] No function exceeds complexity 12
- [ ] Script still produces identical output for the same input
  ```yaml
  verify:
    method: bash
    run: "echo 'Hello,\n\nTest body.\n\nBest regards,\nName\n\n> Quoted text' | python3 .agents/scripts/normalise-markdown.py 2>/dev/null; echo $?"
  ```
- [ ] No new Python linting warnings (ruff/flake8)

## Context & Decisions

- The file is only 358 lines so the refactoring scope is manageable
- The detector registry pattern works well for section classification — it's the standard approach for this kind of text processing
- Regex patterns should be compiled at module level (`re.compile()`) for clarity and performance
- If the function uses a state machine, extract the state transition table

## Relevant Files

- `.agents/scripts/normalise-markdown.py:1` — target file (358 lines, complexity 142)
- `.agents/scripts/email-summary.py` — may call this script; check for API compatibility
- `.agents/scripts/email_jmap_adapter.py` — may call this script

## Dependencies

- **Blocked by:** nothing
- **Blocks:** overall qlty A-grade recovery
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Read function, understand section detection logic |
| Implementation | 1.5h | Extract 6-8 detector functions, add registry |
| Testing | 20m | Qlty before/after, test with sample email content |
| **Total** | **~2h** | |
