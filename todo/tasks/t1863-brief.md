---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1863: simplification: deduplicate shared code in email-summary.py and entity-extraction.py

## Origin

- **Created:** 2026-04-03
- **Session:** opencode:qlty-maintainability-recovery
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability grade dropped from A to C. Qlty detected 15 similar lines shared between `email-summary.py` (681 lines) and `entity-extraction.py` (590 lines). Code duplication is a distinct smell type from complexity but still contributes to the maintainability grade.

## What

Extract the 15+ duplicated lines between `.agents/scripts/email-summary.py` and `.agents/scripts/entity-extraction.py` into a shared utility module (`.agents/scripts/email_shared.py`), and update both files to import from it. Also reduce any high-complexity functions in both files (email-summary.py has total complexity 156 with 34 functions, 3 high-complexity).

## Why

- Code duplication is flagged by qlty and drags down the maintainability grade
- Duplicated code means bugs must be fixed in two places — maintenance risk
- Both files are part of the email intelligence system and share natural common ground
- The 3 high-complexity functions in email-summary.py add ~156 complexity points
- Quick win: small scope, clear dedup target, low regression risk

## How (Approach)

### Phase 1: Identify duplicated code
1. Run `qlty smells .agents/scripts/email-summary.py .agents/scripts/entity-extraction.py --sarif` to get exact line ranges of duplication
2. Read both files at the flagged ranges to understand what's duplicated (likely: email parsing setup, LLM API call patterns, output formatting)

### Phase 2: Extract shared module
1. Create `.agents/scripts/email_shared.py` with the shared functions
2. Common candidates: email header parsing, markdown conversion calls, LLM prompt templates, output formatting, config loading
3. Update imports in both files to use the shared module
4. Verify identical behaviour

### Phase 3: Reduce complexity in email-summary.py
1. Identify the 3 high-complexity functions via qlty output
2. Apply standard decomposition: extract sub-functions, flatten nesting, use early returns
3. Target: no function over complexity 12

### Phase 4: Review entity-extraction.py
1. Check for any high-complexity functions (total complexity not flagged as severely but worth a pass)
2. Apply same patterns if needed

## Acceptance Criteria

- [ ] Zero code duplication smells between the two files
  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && ~/.qlty/bin/qlty smells .agents/scripts/email-summary.py .agents/scripts/entity-extraction.py --sarif 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); dupes=[r for r in d.get('runs',[])[0].get('results',[]) if 'similar' in r.get('message',{}).get('text','').lower() or 'duplicate' in r.get('message',{}).get('text','').lower()]; sys.exit(0 if not dupes else 1)\""
  ```
- [ ] Shared utility module exists at `.agents/scripts/email_shared.py`
  ```yaml
  verify:
    method: codebase
    pattern: "import.*email_shared|from email_shared"
    path: ".agents/scripts/"
  ```
- [ ] No function in either file exceeds complexity 12
- [ ] Both scripts still produce correct output
  ```yaml
  verify:
    method: bash
    run: "python3 .agents/scripts/email-summary.py --help 2>&1; python3 .agents/scripts/entity-extraction.py --help 2>&1; echo $?"
  ```
- [ ] No new Python linting warnings

## Context & Decisions

- The shared module name `email_shared.py` follows the existing `email_` prefix convention in the scripts directory
- If the duplication is only in boilerplate (imports, argparse setup), the dedup may be minimal — but still worth extracting to eliminate the qlty smell
- The 3 high-complexity functions in email-summary.py are a secondary target but still contribute to the grade

## Relevant Files

- `.agents/scripts/email-summary.py:1` — 681 lines, complexity 156, 3 high-complexity functions
- `.agents/scripts/entity-extraction.py:1` — 590 lines, duplication target
- `.agents/scripts/email_shared.py` — new file to create for shared utilities
- `.agents/scripts/email_jmap_adapter.py` — related email module (refactored in t1861)

## Dependencies

- **Blocked by:** nothing (independent of other tasks)
- **Blocks:** overall qlty A-grade recovery
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Identify exact duplicated lines and hot functions |
| Implementation | 1.5h | Extract shared module, dedup, decompose 3 functions |
| Testing | 20m | Qlty before/after, run both scripts with --help |
| **Total** | **~2h** | |
