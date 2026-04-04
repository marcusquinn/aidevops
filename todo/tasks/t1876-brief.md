---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1876: Add instruction_to_save Detection to Session Miner

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + ai-interactive
- **Conversation context:** Analysis of imbue-ai/mngr repo revealed their `.reviewer/conversation-issue-categories.md` has an `instruction_to_save` category that detects when users give persistent guidance that should be captured in instruction files. We already have session-miner-pulse.sh and autoagent signal-mining.md, so this enriches existing pipeline rather than creating a new tool.

## What

Add a new signal source (`instruction-to-save`) to the session miner pipeline that detects when users provide corrections, style preferences, or persistent guidance during conversations — and surfaces these as findings for the autoagent pipeline with suggested additions to instruction files (AGENTS.md, build.txt, style guides).

The deliverable is: the session miner summary includes a section "Instruction Candidates" listing user utterances that appear to be persistent rules, with the suggested target file for each.

## Why

User guidance given during interactive sessions gets lost between sessions. Examples: "always use single quotes in shell scripts", "never use that library — builds are too slow", "I prefer approach X over Y". This knowledge should be captured in instruction files so all future sessions (interactive and headless) benefit from it. Currently no automated path exists from "user said something once" to "framework remembers it forever."

The session miner already runs daily and feeds the autoagent loop. This is a small addition to an existing pipeline, not new infrastructure.

## How (Approach)

1. **`session-miner/extract.py`** — Add a new extraction pass over session messages that identifies user correction patterns:
   - User messages following an agent action that contain directive language ("always", "never", "don't", "prefer", "from now on", "going forward")
   - User messages that explicitly reference rules or conventions ("add this to AGENTS.md", "update the style guide")
   - User messages that correct agent behavior with generalizable guidance (not just "undo that" but "when X, always do Y")
   - Filter: only messages from the human role, skip single-word messages, skip task-specific directions (needs heuristic — e.g., references to specific files/PRs are task-specific, references to patterns/conventions are persistent)

2. **`session-miner/compress.py`** — Add `instruction_candidates` key to compressed output:
   ```json
   {
     "instruction_candidates": [
       {
         "text": "always use local var=\"$1\" in shell functions",
         "session_id": "abc123",
         "session_title": "Fix helper scripts",
         "confidence": 0.9,
         "target_file": ".agents/prompts/build.txt",
         "category": "code_style"
       }
     ]
   }
   ```

3. **`session-miner-pulse.sh`** — Add `instruction_candidates` to the summary output in `generate_summary()` and `generate_feedback_actions()`.

4. **`tools/autoagent/autoagent/signal-mining.md`** — Add signal source entry for `instruction-to-save` with the finding format.

Key files:
- `.agents/scripts/session-miner/extract.py` — add extraction pass
- `.agents/scripts/session-miner/compress.py` — add compression/dedup for instruction candidates
- `.agents/scripts/session-miner-pulse.sh:165-255` — update summary generation
- `.agents/tools/autoagent/autoagent/signal-mining.md` — add signal source

Pattern to follow: the existing steerage signal extraction in extract.py. Same structure — scan messages, classify, output structured findings.

## Acceptance Criteria

- [ ] Session miner extract.py has a function that identifies user correction/guidance patterns
  ```yaml
  verify:
    method: codebase
    pattern: "instruction_candidates|instruction_to_save"
    path: ".agents/scripts/session-miner/extract.py"
  ```
- [ ] Compressed output includes `instruction_candidates` key with structured entries
  ```yaml
  verify:
    method: codebase
    pattern: "instruction_candidates"
    path: ".agents/scripts/session-miner/compress.py"
  ```
- [ ] Pulse summary includes "Instruction Candidates" section when candidates found
  ```yaml
  verify:
    method: codebase
    pattern: "Instruction Candidates|instruction_candidates"
    path: ".agents/scripts/session-miner-pulse.sh"
  ```
- [ ] Signal mining doc lists `instruction-to-save` as a source
  ```yaml
  verify:
    method: codebase
    pattern: "instruction-to-save"
    path: ".agents/tools/autoagent/autoagent/signal-mining.md"
  ```
- [ ] False positive rate is acceptable: task-specific directions ("fix that file", "undo the last commit") are NOT flagged as instruction candidates
  ```yaml
  verify:
    method: subagent
    prompt: "Review extract.py instruction detection logic. Does it filter out task-specific directions that reference particular files, PRs, or one-off commands? Does it only flag generalizable patterns?"
    files: ".agents/scripts/session-miner/extract.py"
  ```
- [ ] Lint clean (shellcheck for .sh, python syntax for .py)

## Context & Decisions

- Inspired by imbue-ai/mngr `.reviewer/conversation-issue-categories.md` `instruction_to_save` category
- Decided against creating a new `/verify-conversation` command — enriching existing session miner is lower-cost and uses established pipeline
- False positive management is critical — user warned about not disrupting productivity with noise. The detection should be conservative (high precision over high recall). Better to miss some candidates than to flood with false positives.
- Candidates are surfaced as suggestions, never auto-applied. A human or the autoagent hypothesis loop decides whether to act on them.

## Relevant Files

- `.agents/scripts/session-miner/extract.py` — existing extraction logic to extend
- `.agents/scripts/session-miner/compress.py` — existing compression logic to extend
- `.agents/scripts/session-miner-pulse.sh:165-255` — summary generation functions
- `.agents/tools/autoagent/autoagent/signal-mining.md` — signal source registry
- `.agents/reference/self-improvement.md` — self-improvement workflow (consumes miner output)

## Dependencies

- **Blocked by:** nothing
- **Blocks:** nothing (enrichment to existing pipeline)
- **External:** OpenCode session DB must be present (`~/.local/share/opencode/opencode.db`)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Read existing extract.py, compress.py patterns |
| Implementation | 3h | Extraction logic, compression, summary integration |
| Testing | 30m | Run against real session DB, verify output |
| **Total** | **4h** | |
