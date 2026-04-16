---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2130: refactor(doc-indexing) — decompose doc/agent indexing python cluster

## Origin

- **Created:** 2026-04-16
- **Session:** Claude:interactive
- **Created by:** ai-interactive (maintainer directed)
- **Parent task:** t2126 (#19222)
- **Conversation context:** Child of the qlty A-grade campaign. 5 doc/agent indexing Python scripts have `qlty:file-complexity` smells — 5 of the remaining 20 repo-wide smells.

## What

Clear the 5 remaining `qlty:file-complexity` smells in the doc/agent indexing cluster:

| File | Lines | Complexity | Purpose |
|------|-------|-----------|---------|
| `cross-document-linking.py` | 524 | **126** | Cross-document related_docs frontmatter |
| `opencode-agent-discovery.py` | 693 | **116** | OpenCode agent/MCP registration generator |
| `entity-extraction.py` | 524 | **96** | spaCy/LLM NER from markdown emails |
| `add-related-docs.py` | 365 | **89** | Related docs links + navigation |
| `agent-discovery.py` | 540 | **87** | Claude Code agent registration generator |

**Total current complexity: 514.** Each file must be split so `qlty smells --all` reports zero file-complexity on them.

Deliverable:

1. Decomposed Python modules, each under the file_complexity threshold.
2. All existing CLI entry points (`python3 script.py <args>`) unchanged.
3. `python3 -m py_compile` passes on every new module.
4. `opencode-agent-discovery.py` and `agent-discovery.py` produce identical JSON output before and after split (characterisation test).

## Why

These 5 files are 5 of the 20 remaining smells (25%). The agent-discovery files (`opencode-agent-discovery.py` and `agent-discovery.py`) share substantial overlap — they scan the same agent tree for different runtimes. Part of this decomposition may involve extracting shared scanning logic into a common module used by both, which would be a natural concern boundary.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? **NO — 5 files + new modules**
- [ ] Every target file under 500 lines? **YES for add-related-docs (365), NO for others**
- [ ] Exact `oldString`/`newString` for every edit? **NO — module boundary decisions**
- [ ] No judgment or design decisions? **NO — shared scanning logic may warrant unification**
- [ ] No error handling or fallback logic to design? **YES — preserve as-is**
- [ ] No cross-package changes? **Single scripts/ directory**
- [ ] Estimate 1h or less? **NO — 2.5h**
- [ ] 4 or fewer acceptance criteria? **NO — 6**

**Selected tier:** `tier:thinking`

**Tier rationale:** The two agent-discovery files have structural overlap that a skilled decomposition could unify into shared scanning logic — this is a design decision beyond mechanical extraction. Also, `cross-document-linking.py` (126) has entity matching heuristics that must be split along algorithm boundaries, not arbitrary line cuts.

## PR Conventions

PR body: `For #19222` (parent) and `Resolves #19226` (this task's issue).

## How (Approach)

### Worker Quick-Start

```bash
# 1. Baseline smell counts:
qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("(cross-document|agent-discovery|opencode-agent|entity-extraction|add-related)")) | "\(.locations[0].physicalLocation.artifactLocation.uri)\t\(.message.text)"'

# 2. See lib/discovery_utils.py — shared utilities already extracted:
cat .agents/scripts/lib/discovery_utils.py | head -30

# 3. Check overlap between the two agent-discovery files:
diff <(grep 'def ' .agents/scripts/agent-discovery.py) <(grep 'def ' .agents/scripts/opencode-agent-discovery.py)

# 4. Check consumers:
rg "from cross_document|from entity_extraction|from add_related|import agent.discovery" .agents/scripts/ -l
```

### Files to Modify

- `EDIT: .agents/scripts/cross-document-linking.py` (524 lines, complexity 126) — split by concern:
  - `NEW: .agents/scripts/cross_document_matchers.py` — entity/thread/attachment matching logic
  - Keep `cross-document-linking.py` as CLI entry + orchestration
- `EDIT: .agents/scripts/opencode-agent-discovery.py` (693 lines, complexity 116) — extract shared scanning:
  - `NEW: .agents/scripts/lib/agent_scanner.py` — shared agent tree scanning logic used by both discovery scripts
  - Thin down `opencode-agent-discovery.py` to OpenCode-specific formatting + import from shared scanner
- `EDIT: .agents/scripts/agent-discovery.py` (540 lines, complexity 87) — refactor to use shared scanner:
  - Import from `lib/agent_scanner.py` instead of duplicating scanning logic
  - Thin down to Claude Code-specific formatting
- `EDIT: .agents/scripts/entity-extraction.py` (524 lines, complexity 96) — split by extraction method:
  - `NEW: .agents/scripts/entity_spacy_extractor.py` — spaCy NER extraction
  - `NEW: .agents/scripts/entity_llm_extractor.py` — Ollama/LLM fallback extraction
  - Keep `entity-extraction.py` as CLI entry + method selection
- `EDIT: .agents/scripts/add-related-docs.py` (365 lines, complexity 89) — extract scanning/matching:
  - `NEW: .agents/scripts/related_docs_scanner.py` — directory scanning + frontmatter matching
  - Keep `add-related-docs.py` as CLI entry

### Implementation Steps

1. **Read all 5 files.** Pay special attention to the structural overlap between `agent-discovery.py` and `opencode-agent-discovery.py`. Both import `lib/discovery_utils.py` — the shared scanner extraction extends this pattern.
2. **Characterisation test: capture current agent-discovery output.** Before any changes:
   ```bash
   python3 .agents/scripts/agent-discovery.py ~/.aidevops/agents claude > /tmp/agent-discovery-before.json
   python3 .agents/scripts/opencode-agent-discovery.py ~/.aidevops/agents opencode > /tmp/opencode-agent-discovery-before.json
   ```
3. **Extract `lib/agent_scanner.py` first.** This is the shared foundation that both discovery scripts use. Model on the existing `lib/discovery_utils.py` pattern.
4. **Refactor both agent-discovery files to use the shared scanner.** Each should be thin — just runtime-specific formatting.
5. **Split the remaining 3 files** (cross-document-linking, entity-extraction, add-related-docs) in descending complexity order.
6. **Run the characterisation test again** — diff the output against the before snapshots. Zero diff = no regression.
7. **Run `qlty smells --all`** to confirm zero file-complexity on the cluster.

### Verification

```bash
# 1. Syntax check on all new and modified Python files:
for f in .agents/scripts/cross-document-linking.py .agents/scripts/cross_document*.py \
         .agents/scripts/opencode-agent-discovery.py .agents/scripts/agent-discovery.py \
         .agents/scripts/lib/agent_scanner.py \
         .agents/scripts/entity-extraction.py .agents/scripts/entity_*.py \
         .agents/scripts/add-related-docs.py .agents/scripts/related_docs*.py; do
  [ -f "$f" ] && python3 -m py_compile "$f" && echo "OK: $f" || echo "FAIL: $f"
done

# 2. Zero qlty file-complexity smells on target files:
qlty smells --all --sarif 2>/dev/null | \
  jq -r '.runs[0].results[] | select(.ruleId == "qlty:file-complexity") | .locations[0].physicalLocation.artifactLocation.uri' | \
  grep -cE '(cross-document|agent-discovery|opencode-agent|entity-extraction|add-related)'
# Expected: 0

# 3. Agent-discovery characterisation (output must be identical):
python3 .agents/scripts/agent-discovery.py ~/.aidevops/agents claude > /tmp/agent-discovery-after.json 2>/dev/null
diff /tmp/agent-discovery-before.json /tmp/agent-discovery-after.json
# Expected: no diff
```

## Acceptance Criteria

- [ ] Zero `qlty:file-complexity` smells on any doc-indexing cluster file
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.ruleId == \"qlty:file-complexity\") | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE '(cross-document|agent-discovery|opencode-agent|entity-extraction|add-related)') -eq 0"
  ```
- [ ] `python3 -m py_compile` passes for all new and modified .py files
  ```yaml
  verify:
    method: bash
    run: "for f in .agents/scripts/cross-document-linking.py .agents/scripts/cross_document*.py .agents/scripts/opencode-agent-discovery.py .agents/scripts/agent-discovery.py .agents/scripts/lib/agent_scanner.py .agents/scripts/entity-extraction.py .agents/scripts/entity_*.py .agents/scripts/add-related-docs.py .agents/scripts/related_docs*.py; do [ -f \"$f\" ] && python3 -m py_compile \"$f\" || exit 1; done"
  ```
- [ ] Agent-discovery JSON output is identical before and after refactor (characterisation test)
- [ ] Shared scanning logic extracted into `lib/agent_scanner.py` (used by both discovery scripts)
  ```yaml
  verify:
    method: codebase
    pattern: "from.*agent_scanner"
    path: ".agents/scripts/"
  ```
- [ ] No new smells introduced on any of the new sibling modules
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE '(cross_document|agent_scanner|entity_spacy|entity_llm|related_docs)') -eq 0"
  ```
- [ ] Total repo smell count decreased by at least 5 vs merge-base

## Context & Decisions

- **Shared scanner extraction:** `agent-discovery.py` and `opencode-agent-discovery.py` both walk the agent tree, parse frontmatter, and enumerate MCP tools — with runtime-specific formatting on top. Extracting the shared scanning to `lib/agent_scanner.py` is the cleanest split point and reduces BOTH files significantly. Prior art: `lib/discovery_utils.py` already exists for exactly this purpose.
- **Non-goal:** merging the two agent-discovery scripts into one. They serve different runtimes with different output schemas. The shared scanner handles the overlap; the entry scripts remain separate.
- **Non-goal:** changing entity-extraction's spaCy vs Ollama fallback logic or cross-document-linking's matching algorithm. Mechanical extraction only.
- **add-related-docs.py is the smallest (89).** If it proves hard to split below threshold from 365 lines, the worker may leave it and document why.

## Relevant Files

- `.agents/scripts/cross-document-linking.py:1` — 524 lines, complexity 126
- `.agents/scripts/opencode-agent-discovery.py:1` — 693 lines, complexity 116
- `.agents/scripts/entity-extraction.py:1` — 524 lines, complexity 96
- `.agents/scripts/add-related-docs.py:1` — 365 lines, complexity 89
- `.agents/scripts/agent-discovery.py:1` — 540 lines, complexity 87
- `.agents/scripts/lib/discovery_utils.py` — existing shared utility (pattern to follow)

## Dependencies

- **Blocked by:** none
- **Blocks:** parent t2126 (#19222) closure
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read all 5 files + overlap analysis | 35m | ~2650 lines total |
| Characterisation test capture | 5m | — |
| Extract lib/agent_scanner.py | 30m | shared scanning logic |
| Refactor both agent-discovery files | 25m | thin to formatting only |
| Split cross-document-linking.py | 20m | 1 new module |
| Split entity-extraction.py | 20m | 2 new modules |
| Split add-related-docs.py | 15m | 1 new module |
| Verification + characterisation diff | 15m | — |
| **Total** | **~2.5h** | |
