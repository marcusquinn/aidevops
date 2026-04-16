---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2131: refactor(misc-scripts) — decompose voice-bridge/normalise-markdown/tabby-profile-sync

## Origin

- **Created:** 2026-04-16
- **Session:** Claude:interactive
- **Created by:** ai-interactive (maintainer directed)
- **Parent task:** t2126 (#19222)
- **Conversation context:** Child of the qlty A-grade campaign. 3 miscellaneous Python scripts have `qlty:file-complexity` smells — the last 3 of the remaining 20 repo-wide smells.

## What

Clear the 3 remaining `qlty:file-complexity` smells in miscellaneous Python scripts:

| File | Lines | Complexity | Purpose |
|------|-------|-----------|---------|
| `voice-bridge.py` | 828 | **95** | VAD → STT → OpenCode → TTS speech bridge |
| `normalise-markdown.py` | 445 | **80** | Heading hierarchy fixer for document creation |
| `tabby-profile-sync.py` | 654 | **76** | Tabby terminal profile generator from repos.json |

**Total current complexity: 251.** These are the lowest-complexity files in the campaign — closest to the threshold and therefore the most likely to be clearable with modest splits.

Deliverable:

1. Decomposed Python modules, each under the file_complexity threshold.
2. All existing CLI entry points unchanged.
3. `python3 -m py_compile` passes on every new module.

## Why

These 3 files are the final 3 of the 20 remaining smells. Clearing them (combined with t2127-t2130) drops the total to 0 file-complexity smells, letting `QLTY_SMELL_THRESHOLD` ratchet from 22 down to whatever non-file-complexity smells remain (currently 0, so threshold → 2).

Even if one or two of these prove hard to split cleanly (they're already modestly over threshold), the campaign still achieves grade A with headroom as long as t2127-t2130 land.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? **NO — 3 files + new modules**
- [x] Every target file under 500 lines? **YES for normalise-markdown (445), NO for others**
- [ ] Exact `oldString`/`newString` for every edit? **NO**
- [ ] No judgment or design decisions? **YES — concern groups are relatively clear**
- [x] No error handling or fallback logic to design? **YES**
- [x] No cross-package changes? **YES**
- [ ] Estimate 1h or less? **NO — 1.5h**
- [x] 4 or fewer acceptance criteria? **YES — 4**

**Selected tier:** `tier:standard`

**Tier rationale:** All 3 files have straightforward internal structure (voice-bridge: VAD/STT/TTS pipeline stages; normalise-markdown: rule sets + heading walker; tabby-profile-sync: config reader + profile generator + colour mapper). The concern boundaries are visible from function names — no architectural judgment needed. Standard tier is sufficient for these mechanical extractions.

## PR Conventions

PR body: `For #19222` (parent) and `Resolves #19227` (this task's issue).

## How (Approach)

### Worker Quick-Start

```bash
# 1. Baseline smell counts:
qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("(voice-bridge|normalise-markdown|tabby-profile)")) | "\(.locations[0].physicalLocation.artifactLocation.uri)\t\(.message.text)"'

# 2. Function structure of each file (concern groups visible from names):
grep 'def ' .agents/scripts/voice-bridge.py
grep 'def ' .agents/scripts/normalise-markdown.py
grep 'def ' .agents/scripts/tabby-profile-sync.py
```

### Files to Modify

- `EDIT: .agents/scripts/voice-bridge.py` (828 lines, complexity 95) — split by pipeline stage:
  - `NEW: .agents/scripts/voice_bridge_audio.py` — VAD + STT + audio I/O (microphone, speaker)
  - `NEW: .agents/scripts/voice_bridge_tts.py` — TTS engine interface (swappable providers)
  - Keep `voice-bridge.py` as CLI entry + pipeline orchestration
- `EDIT: .agents/scripts/normalise-markdown.py` (445 lines, complexity 80) — split by rule type:
  - `NEW: .agents/scripts/normalise_markdown_rules.py` — heading hierarchy rules, list normalisation, whitespace cleanup
  - Keep `normalise-markdown.py` as CLI entry + file walker
- `EDIT: .agents/scripts/tabby-profile-sync.py` (654 lines, complexity 76) — split by concern:
  - `NEW: .agents/scripts/tabby_colour_mapper.py` — colour assignment, scheme matching, tab colour generation
  - Keep `tabby-profile-sync.py` as CLI entry + profile YAML generation

### Implementation Steps

1. **Read all 3 files.** These are the simplest in the campaign — visible concern groups in each.
2. **Split voice-bridge.py first** (highest complexity, clearest pipeline stages: audio in → STT → agent → TTS → audio out).
3. **Split tabby-profile-sync.py** (colour mapper is a self-contained concern — ~200 lines of colour logic).
4. **Split normalise-markdown.py** (rule extraction — the heading walker stays, the rules move).
5. **Run `python3 -m py_compile` on all files** + `qlty smells --all` to verify.

### Verification

```bash
# 1. Syntax check:
for f in .agents/scripts/voice-bridge.py .agents/scripts/voice_bridge*.py \
         .agents/scripts/normalise-markdown.py .agents/scripts/normalise_markdown*.py \
         .agents/scripts/tabby-profile-sync.py .agents/scripts/tabby_colour*.py; do
  [ -f "$f" ] && python3 -m py_compile "$f" && echo "OK: $f" || echo "FAIL: $f"
done

# 2. Zero qlty file-complexity smells:
qlty smells --all --sarif 2>/dev/null | \
  jq -r '.runs[0].results[] | select(.ruleId == "qlty:file-complexity") | .locations[0].physicalLocation.artifactLocation.uri' | \
  grep -cE '(voice-bridge|normalise-markdown|tabby-profile)'
# Expected: 0

# 3. CLI entry points still work:
python3 .agents/scripts/normalise-markdown.py --help 2>&1 | head -3
python3 .agents/scripts/tabby-profile-sync.py --help 2>&1 | head -3
```

## Acceptance Criteria

- [ ] Zero `qlty:file-complexity` smells on the 3 target files
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.ruleId == \"qlty:file-complexity\") | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE '(voice-bridge|normalise-markdown|tabby-profile)') -eq 0"
  ```
- [ ] `python3 -m py_compile` passes for all new and modified .py files
  ```yaml
  verify:
    method: bash
    run: "for f in .agents/scripts/voice-bridge.py .agents/scripts/voice_bridge*.py .agents/scripts/normalise-markdown.py .agents/scripts/normalise_markdown*.py .agents/scripts/tabby-profile-sync.py .agents/scripts/tabby_colour*.py; do [ -f \"$f\" ] && python3 -m py_compile \"$f\" || exit 1; done"
  ```
- [ ] No new smells introduced on any of the new sibling modules
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE '(voice_bridge|normalise_markdown|tabby_colour)') -eq 0"
  ```
- [ ] CLI entry points still respond without error

## Context & Decisions

- **Tier: standard, not thinking.** These 3 files have the clearest internal structure in the campaign. Voice-bridge is a linear pipeline (VAD→STT→agent→TTS), normalise-markdown is rules + walker, tabby-profile-sync is config + colour mapper. A standard-tier worker can handle these.
- **Smallest files in the campaign.** If one proves impossible to split below threshold without awkward single-function modules, the worker should document which file and why in the PR. The campaign succeeds regardless — the other 4 clusters clear 17 smells by themselves.
- **Non-goal:** changing voice-bridge's STT/TTS provider logic or normalise-markdown's email_mode handling.

## Relevant Files

- `.agents/scripts/voice-bridge.py:1` — 828 lines, complexity 95
- `.agents/scripts/normalise-markdown.py:1` — 445 lines, complexity 80
- `.agents/scripts/tabby-profile-sync.py:1` — 654 lines, complexity 76

## Dependencies

- **Blocked by:** none
- **Blocks:** parent t2126 (#19222) closure
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read all 3 files | 15m | ~1930 lines total |
| Split voice-bridge.py | 25m | 2 new modules |
| Split tabby-profile-sync.py | 20m | 1 new module |
| Split normalise-markdown.py | 15m | 1 new module |
| Verification + iteration | 15m | — |
| **Total** | **~1.5h** | |
