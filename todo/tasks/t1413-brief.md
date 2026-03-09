---
mode: subagent
---
# t1413: Add memory consolidation phase (cross-memory insight generation)

## Origin

- **Created:** 2026-03-07
- **Session:** claude-code:interactive
- **Created by:** human + ai-interactive
- **Conversation context:** Reviewed Google's [always-on-memory-agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent) for ideas to adopt. Identified that aidevops memory system has strong maintenance (dedup, prune, graduate) but lacks active cross-memory connection discovery — finding that memory A about a CORS fix relates to memory B about nginx config and generating synthesized insights.

## What

Add a **memory consolidation phase** to `memory-audit-pulse.sh` that uses a cheap LLM call (haiku-tier, ~$0.001/call) to scan unconsolidated memories, discover cross-cutting connections, and store synthesized insights as new `derives` relations in the existing `learning_relations` table.

Deliverables:
1. New `phase_consolidate()` function in `memory-audit-pulse.sh` (Phase 4; opportunity scan renumbered to Phase 5, report to Phase 6).
2. New `insights` subcommand in `memory-helper.sh` for manual invocation (delegates to audit pulse with `--force`).
3. New `memory_consolidations` table for storing consolidation insights with source memory IDs
4. Documentation updates in `memory/README.md`

## Why

The existing memory system is maintenance-oriented: dedup removes noise, prune removes staleness, graduate promotes value. But no phase actively **connects** memories to discover patterns. A user who stores "CORS fix: add nginx headers" and later stores "nginx proxy_pass config for API" has two related memories that are never linked. The consolidation phase bridges this gap — like the brain's sleep-cycle replay that connects and compresses information.

Cost is negligible (~$0.001-0.01 per audit pulse run on 10-50 memories). Value is high: surfaces patterns that individual `/recall` queries miss.

## How (Approach)

1. **New table** `memory_consolidations` in `memory.db`:
   - `id TEXT PRIMARY KEY` — consolidation ID
   - `source_ids TEXT NOT NULL` — JSON array of memory IDs that were consolidated
   - `insight TEXT NOT NULL` — the synthesized insight
   - `connections TEXT NOT NULL DEFAULT '[]'` — JSON array of `{from_id, to_id, relationship}`
   - `created_at TEXT`

2. **Consolidation logic** in `memory-audit-pulse.sh`:
   - Query unconsolidated memories (those not in any `memory_consolidations.source_ids`)
   - If fewer than 3, skip (not enough to find patterns)
   - Send batch to `ai-research-helper.sh` (haiku tier) with a structured prompt
   - Parse response: extract connections and insight
   - Store in `memory_consolidations` table
   - Create `derives` relations in `learning_relations` for discovered connections

3. **Integration**:
   - `memory-audit-pulse.sh`: new Phase 4 between graduate and opportunity scan
   - `memory-helper.sh insights`: manual trigger subcommand
   - Report phase includes consolidation count
   - `/memory-audit` slash command already covers it (runs all phases)

4. **Key files to modify**:
   - `.agents/scripts/memory-audit-pulse.sh` — add `phase_consolidate()`
   - `.agents/scripts/memory/_common.sh` — add `memory_consolidations` table to `init_db()` and `migrate_db()`
   - `.agents/scripts/memory-helper.sh` — add `insights` command dispatch
   - `.agents/memory/README.md` — document consolidation phase

## Acceptance Criteria

- [x] `memory-audit-pulse.sh run --force` includes consolidation phase in output

  ```yaml
  verify:
    method: bash
    run: "grep -q 'phase_consolidate\\|Phase.*[Cc]onsolidat' .agents/scripts/memory-audit-pulse.sh"
  ```

- [x] `memory-helper.sh insights` triggers consolidation manually

  ```yaml
  verify:
    method: bash
    run: "grep -q 'insights)' .agents/scripts/memory-helper.sh"
  ```

- [x] `memory_consolidations` table created in init_db migration

  ```yaml
  verify:
    method: bash
    run: "grep -q 'memory_consolidations' .agents/scripts/memory/_common.sh"
  ```

- [x] Consolidation uses ai-research-helper.sh with haiku model tier

  ```yaml
  verify:
    method: bash
    run: "grep -q 'ai-research-helper\\|ai_research' .agents/scripts/memory-audit-pulse.sh"
  ```

- [x] Consolidation results stored as `derives` relations in `learning_relations`

  ```yaml
  verify:
    method: bash
    run: "grep -q 'derives' .agents/scripts/memory-audit-pulse.sh"
  ```

- [x] Documentation updated in memory/README.md

  ```yaml
  verify:
    method: bash
    run: "grep -qi 'consolidat' .agents/memory/README.md"
  ```

- [x] ShellCheck clean on modified scripts

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/memory-audit-pulse.sh .agents/scripts/memory-helper.sh .agents/scripts/memory/_common.sh"
  ```

- [x] Dry-run mode skips LLM call and reports what would be consolidated
- [x] Graceful degradation: if ai-research-helper.sh is unavailable, skip phase with warning

## Context & Decisions

- **Inspired by** Google's always-on-memory-agent consolidation loop, but adapted to aidevops's existing architecture (SQLite + bash + existing `learning_relations` table)
- **No new dependencies**: uses existing `ai-research-helper.sh` for LLM calls, existing `learning_relations` for connections
- **Haiku tier chosen** because consolidation is background processing — speed and cost matter more than raw intelligence
- **Threshold of 3 memories** before consolidation runs — fewer than 3 doesn't have enough signal for cross-cutting patterns
- **Not a separate daemon**: runs as part of the existing audit pulse cycle (every 24h), not as a persistent background process. This matches aidevops's batch-oriented architecture.
- **Rejected**: separate consolidation database (Google's approach uses a separate `consolidations` table with its own schema). We use the existing `learning_relations` table with `derives` type for connections, plus a lightweight `memory_consolidations` table for the insight text and source tracking.

## Relevant Files

- `.agents/scripts/memory-audit-pulse.sh` — main integration point, add Phase 4
- `.agents/scripts/memory/_common.sh` — schema migration for `memory_consolidations` table
- `.agents/scripts/memory-helper.sh` — add `insights` command dispatch
- `.agents/scripts/memory/store.sh` — reference for how `learning_relations` are created
- `.agents/scripts/ai-research-helper.sh` — LLM call interface
- `.agents/memory/README.md` — documentation

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** Anthropic API key (for haiku calls via ai-research-helper.sh) — already configured in most installations

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review existing memory system (done in this session) |
| Implementation | 2h | Schema + consolidation logic + integration |
| Testing | 30m | ShellCheck + manual verification |
| **Total** | **3h** | |
