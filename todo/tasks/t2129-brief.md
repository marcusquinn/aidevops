---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2129: refactor(email-pipeline) — decompose email python cluster

## Origin

- **Created:** 2026-04-16
- **Session:** Claude:interactive
- **Created by:** ai-interactive (maintainer directed)
- **Parent task:** t2126 (#19222)
- **Conversation context:** Child of the qlty A-grade campaign. 5 email-pipeline Python scripts have `qlty:file-complexity` smells that account for 5 of the remaining 20 repo-wide smells.

## What

Clear the 5 remaining `qlty:file-complexity` smells in the email pipeline cluster:

| File | Lines | Complexity | Purpose |
|------|-------|-----------|---------|
| `email_jmap_adapter.py` | 1705 | **169** | JMAP mailbox operations (RFC 8620/8621) |
| `email-voice-miner.py` | 1045 | **140** | Sent-folder style extraction |
| `extraction_pipeline.py` | 947 | **105** | OCR/invoice extraction pipeline |
| `email-summary.py` | 614 | **98** | Auto-summary for email markdown |
| `email_normaliser.py` | 488 | **78** | Section normalisation/frontmatter |

**Total current complexity: 590.** Each file must be split so `qlty smells --all` reports zero file-complexity on them.

Deliverable:

1. Decomposed Python modules, each under the file_complexity threshold.
2. All existing CLI entry points (`python3 script.py <command>`) unchanged.
3. All existing `import` statements from other scripts still resolve.
4. Python `--check` (syntax check) passes on every new module.

## Why

These 5 files are 5 of the 20 remaining smells (25% of budget). `email_jmap_adapter.py` is the second-highest complexity in the repo (169, behind only higgsfield-commands.mjs at 334). Clearing this cluster drops the total from 20 toward ~10-12, which gives `QLTY_SMELL_THRESHOLD` room to ratchet by 8+.

The email pipeline also has established internal module boundaries (`email_normaliser.py` is already extracted from `email_to_markdown.py`, and `email_frontmatter_utils.py` was extracted in PR #19013), so the split pattern has prior art in the same file family.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? **NO — 5 files + new modules**
- [ ] Every target file under 500 lines? **NO — 3 files over 500 lines**
- [ ] Exact `oldString`/`newString` for every edit? **NO — module boundary decisions**
- [ ] No judgment or design decisions? **NO — concern group identification needed**
- [ ] No error handling or fallback logic to design? **YES — preserve as-is**
- [ ] No cross-package changes? **Single scripts/ directory**
- [ ] Estimate 1h or less? **NO — 3h**
- [ ] 4 or fewer acceptance criteria? **NO — 6**

**Selected tier:** `tier:thinking`

**Tier rationale:** 5 files totalling 4800 lines. Largest file (email_jmap_adapter.py, 1705 lines) contains JMAP session, mailbox, message, search, flag, and push-notification concerns — needs architectural reading to split without breaking the JMAP method/call chaining. Plus extraction_pipeline.py has a multi-model fallback pipeline that needs careful concern separation.

## PR Conventions

PR body: `For #19222` (parent) and `Resolves #19225` (this task's issue).

## How (Approach)

### Worker Quick-Start

```bash
# 1. Baseline smell counts:
qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("email|extraction")) | "\(.locations[0].physicalLocation.artifactLocation.uri)\t\(.message.text)"'

# 2. See the prior extraction pattern (email_frontmatter_utils.py was extracted in PR #19013):
ls .agents/scripts/email_frontmatter_utils.py .agents/scripts/email_normaliser.py
# These show the split pattern already used in this file family

# 3. Check which other scripts import from these files:
rg "from email_|import email_" .agents/scripts/ --no-heading -l

# 4. Line counts:
wc -l .agents/scripts/email_jmap_adapter.py .agents/scripts/email-voice-miner.py .agents/scripts/extraction_pipeline.py .agents/scripts/email-summary.py .agents/scripts/email_normaliser.py
```

### Files to Modify

- `EDIT: .agents/scripts/email_jmap_adapter.py` (1705 lines, complexity 169) — split by JMAP concern:
  - `NEW: .agents/scripts/email_jmap_session.py` — JMAP session/connection management
  - `NEW: .agents/scripts/email_jmap_mailbox.py` — mailbox listing/navigation
  - `NEW: .agents/scripts/email_jmap_message.py` — message fetch/headers/body
  - `NEW: .agents/scripts/email_jmap_search.py` — search, flag, move operations
  - Keep `email_jmap_adapter.py` as entry with CLI dispatch + re-exports
- `EDIT: .agents/scripts/email-voice-miner.py` (1045 lines, complexity 140) — split by analysis stage:
  - `NEW: .agents/scripts/email_voice_patterns.py` — pattern extraction (greetings, closings, sentence structure)
  - `NEW: .agents/scripts/email_voice_analyzer.py` — tone distribution, vocabulary analysis
  - Keep `email-voice-miner.py` as CLI entry point
- `EDIT: .agents/scripts/extraction_pipeline.py` (947 lines, complexity 105) — split by pipeline stage:
  - `NEW: .agents/scripts/extraction_classify.py` — document classification
  - `NEW: .agents/scripts/extraction_validate.py` — Pydantic validation, VAT checks, confidence scoring
  - Keep `extraction_pipeline.py` as the orchestrator
- `EDIT: .agents/scripts/email-summary.py` (614 lines, complexity 98) — extract LLM interface:
  - `NEW: .agents/scripts/email_summary_heuristic.py` — extractive heuristic summariser
  - Keep `email-summary.py` as CLI entry + Ollama/LLM orchestration (if still too complex, further split)
- `EDIT: .agents/scripts/email_normaliser.py` (488 lines, complexity 78) — extract thread reconstruction:
  - `NEW: .agents/scripts/email_normaliser_threads.py` — thread reconstruction + section normalisation
  - Keep `email_normaliser.py` as the entry/frontmatter builder

### Implementation Steps

1. **Read all 5 files. Map concern groups per file.** The JMAP adapter is the highest priority — 1705 lines with 6 distinct JMAP method groups (connect, headers, body, search, flag/move, push).
2. **Check existing import consumers.** `rg "from email_|import email_" .agents/scripts/` reveals which other scripts depend on these modules' public surface. All those imports must continue to resolve after the split.
3. **Split email_jmap_adapter.py first** (biggest, most smells). Use the existing `email_frontmatter_utils.py` extraction as the local pattern: entry file re-imports from new modules and re-exports the public surface.
4. **Split each remaining file in descending complexity order.** email-voice-miner (140), extraction_pipeline (105), email-summary (98), email_normaliser (78).
5. **Run `python3 -m py_compile <file>` on every new module** after each split.
6. **Run `qlty smells --all` after all 5 splits** to confirm zero file-complexity on the cluster.
7. **Verify CLI entry points** still work (`python3 email_jmap_adapter.py --help`, etc.).

### Verification

```bash
# 1. Syntax check on all new and modified Python files:
for f in .agents/scripts/email_jmap*.py .agents/scripts/email-voice*.py .agents/scripts/email_voice*.py .agents/scripts/extraction*.py .agents/scripts/email-summary.py .agents/scripts/email_summary*.py .agents/scripts/email_normaliser*.py; do
  [ -f "$f" ] && python3 -m py_compile "$f" && echo "OK: $f" || echo "FAIL: $f"
done

# 2. Zero qlty file-complexity smells on email/extraction files:
qlty smells --all --sarif 2>/dev/null | \
  jq -r '.runs[0].results[] | select(.ruleId == "qlty:file-complexity") | .locations[0].physicalLocation.artifactLocation.uri' | \
  grep -cE '(email_jmap|email-voice|email_voice|extraction_|email-summary|email_summary|email_normaliser)' 
# Expected: 0

# 3. CLI entry points still respond:
python3 .agents/scripts/email_jmap_adapter.py --help 2>&1 | head -3
python3 .agents/scripts/email-voice-miner.py --help 2>&1 | head -3
python3 .agents/scripts/extraction_pipeline.py --help 2>&1 | head -3
```

## Acceptance Criteria

- [ ] Zero `qlty:file-complexity` smells on any email/extraction pipeline file
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.ruleId == \"qlty:file-complexity\") | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE '(email_jmap|email-voice|email_voice|extraction_|email-summary|email_summary|email_normaliser)') -eq 0"
  ```
- [ ] `python3 -m py_compile` passes for all new and modified .py files
  ```yaml
  verify:
    method: bash
    run: "for f in .agents/scripts/email_jmap*.py .agents/scripts/email-voice*.py .agents/scripts/email_voice*.py .agents/scripts/extraction*.py .agents/scripts/email-summary.py .agents/scripts/email_summary*.py .agents/scripts/email_normaliser*.py; do [ -f \"$f\" ] && python3 -m py_compile \"$f\" || exit 1; done"
  ```
- [ ] All existing `import` statements from other scripts in `.agents/scripts/` still resolve
  ```yaml
  verify:
    method: bash
    run: "rg 'from email_jmap_adapter|from email_normaliser|from extraction_pipeline' .agents/scripts/ -l | while read f; do python3 -m py_compile \"$f\" || exit 1; done"
  ```
- [ ] CLI entry points respond to `--help` without error
- [ ] No new smells introduced on any of the new sibling modules
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE '(email_jmap|email_voice|extraction_|email_summary|email_normaliser)') -eq 0"
  ```
- [ ] Total repo smell count decreased by at least 5 vs merge-base

## Context & Decisions

- **Prior art in this family:** `email_frontmatter_utils.py` was extracted from `email_to_markdown.py` in PR #19013 as part of the 39→20 sweep. Same pattern: entry file re-imports + re-exports, new module gets the extracted concern.
- **Python import compatibility:** all 5 files are CLI entry points invoked via `python3 script.py <command>`. They also import each other (e.g., `email_to_markdown.py` imports `email_normaliser`). The re-export barrel pattern preserves both use cases.
- **Non-goal:** refactoring the JMAP adapter's method/call chaining or the extraction pipeline's model fallback logic. Mechanical extraction only.
- **email_normaliser.py is the smallest target (78).** If splitting it cleanly is hard (488 lines, already extracted once), the worker may leave it and document why. The campaign still succeeds if 4/5 clear.

## Relevant Files

- `.agents/scripts/email_jmap_adapter.py:1` — 1705 lines, complexity 169 (biggest)
- `.agents/scripts/email-voice-miner.py:1` — 1045 lines, complexity 140
- `.agents/scripts/extraction_pipeline.py:1` — 947 lines, complexity 105
- `.agents/scripts/email-summary.py:1` — 614 lines, complexity 98
- `.agents/scripts/email_normaliser.py:1` — 488 lines, complexity 78
- `.agents/scripts/email_frontmatter_utils.py` — prior art for this family's split pattern
- `.agents/scripts/email_to_markdown.py` — imports from normaliser (consumer reference)

## Dependencies

- **Blocked by:** none
- **Blocks:** parent t2126 (#19222) closure
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read all 5 files + import graph | 40m | ~4800 lines total |
| Split email_jmap_adapter.py | 50m | biggest, 4 new modules |
| Split email-voice-miner.py | 25m | 2 new modules |
| Split extraction_pipeline.py | 25m | 2 new modules |
| Split email-summary.py | 15m | 1 new module |
| Split email_normaliser.py | 15m | 1 new module, may skip |
| Verification + iteration | 20m | — |
| **Total** | **~3h** | |
