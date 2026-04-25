---
mode: subagent
---

# t2850: PageIndex tree generation across corpus

## Pre-flight

- [x] Memory recall: `pageindex tree rag retrieval` → existing `pageindex-generator.py` and `pageindex_helpers.py` plus skill `tools/context/pageindex.md`
- [x] Discovery: PageIndex skill is production-quality for single-document trees
- [x] File refs verified: `.agents/tools/context/pageindex.md`, `.agents/scripts/pageindex-generator.py`, `.agents/scripts/pageindex_helpers.py`
- [x] Tier: `tier:standard` — wraps existing PageIndex skill, generalises from per-doc to corpus-wide tree

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P1 (kind-aware enrichment)

## What

Generate a PageIndex tree over the entire `_knowledge/sources/` corpus per repo (and per personal plane). The tree gives the AI comms agent (P6a) a vectorless RAG over all promoted knowledge — query intent → tree-walk → relevant excerpts. Tree regenerates on corpus change via a routine; the v1 implementation is a thin wrapper over the existing per-document PageIndex generator.

**Concrete deliverables:**

1. `scripts/knowledge-index-helper.sh build` — reads all `_knowledge/sources/*/extracted.json` and `_knowledge/sources/*/text.txt`, writes a corpus-wide tree to `_knowledge/index/tree.json`
2. `scripts/knowledge-index-helper.sh query <intent>` — given a natural-language intent, walks the tree and returns ranked source IDs + excerpt anchors
3. Per-source PageIndex tree: each source gets `_knowledge/sources/<id>/tree.json` (per-doc); corpus tree at `_knowledge/index/tree.json` aggregates the top levels
4. Incremental rebuild: only rebuild when source list changes (sha-based change detection — pattern from `pulse-simplification.sh`)
5. Routine `r042` on pulse loop, runs every hour, idempotent
6. CLI integration: `aidevops knowledge search <query>` (from t2843) upgrades from substring grep to tree-walk when tree exists
7. Personal plane: separate tree at `~/.aidevops/.agent-workspace/knowledge/index/tree.json`

## Why

Without a corpus-wide index, querying knowledge is grep — fine for v1 in t2843, useless at scale. PageIndex is vectorless (no FAISS, no embeddings infrastructure) which fits the framework's "lightweight tools first" principle. The tree-walk approach means an LLM can navigate the corpus the way a human would — by topic, then sub-topic, then document.

Building corpus-wide tree on top of per-doc trees lets an LLM agent (P6a) ask "where in the corpus is X" without scanning every document — a meaningful efficiency gain at 1000+ sources.

## How (Approach)

1. **Per-source tree generation** — `knowledge-index-helper.sh build-source <id>`:
   - Read `_knowledge/sources/<id>/text.txt` (extracted text from `document-extraction-helper.sh`)
   - Call `pageindex-generator.py` with appropriate model (route via `llm-routing-helper.sh` with source's sensitivity tier)
   - Write `_knowledge/sources/<id>/tree.json`
2. **Corpus-wide aggregation** — `build` subcommand:
   - List all sources with `tree.json`; for each, take the top 2-3 levels
   - Build a meta-tree where root is "corpus" and children are sources, grouped by document kind (invoices, contracts, …) when explicit, else flat
   - Write `_knowledge/index/tree.json`
3. **Incremental rebuild** — `_should_rebuild()`:
   - Hash all source IDs + their `tree.json` mtimes; if hash matches `_knowledge/index/.tree-hash`, skip
   - Otherwise rebuild changed-only (delegating to `build-source` per changed source) and re-aggregate
4. **Query subcommand** — `knowledge-index-helper.sh query <intent>`:
   - Use `pageindex_helpers.py` tree-walk routine; the helper already returns ranked nodes with anchors
   - Output JSON: `{matches: [{source_id, score, anchor, excerpt}, …]}`
5. **Routine `r042`** — `repeat: cron(*/60 * * * *)` (hourly), `run: scripts/knowledge-index-helper.sh build`, idempotent
6. **CLI upgrade** — extend `knowledge-helper.sh search` to detect tree existence; if present, route to `knowledge-index-helper.sh query`; otherwise fall back to grep
7. **Tests** — covers per-source build, corpus build, incremental rebuild skip path, query result shape, sensitivity routing, fallback to grep when tree absent

### Files Scope

- NEW: `.agents/scripts/knowledge-index-helper.sh`
- EDIT: `.agents/scripts/knowledge-helper.sh` (search subcommand routes to tree-walk when available)
- EDIT: `TODO.md` (add `r042` routine entry — done in this task's PR)
- NEW: `.agents/tests/test-knowledge-index.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (indexing section)
- EDIT: `.agents/tools/context/pageindex.md` (cross-reference corpus-wide usage)

## Acceptance Criteria

- [ ] `aidevops knowledge index build` writes `_knowledge/index/tree.json` covering all promoted sources
- [ ] Each source has its own `tree.json` after build
- [ ] `aidevops knowledge index query "all invoices over £5k"` returns ranked source IDs with anchors and excerpt
- [ ] `aidevops knowledge search <query>` (CLI from t2843) auto-routes to tree-walk when tree exists, falls back to grep otherwise
- [ ] Re-running `build` on unchanged corpus skips work (sha-cache hit)
- [ ] Adding a new source and re-running `build`: only the new source's tree is generated; meta-tree updated
- [ ] Routine `r042` runs hourly, idempotent under concurrent invocation (lock-protected)
- [ ] Personal plane tree at `~/.aidevops/.agent-workspace/knowledge/index/tree.json` works equivalently
- [ ] LLM calls during build route through `llm-routing-helper.sh` with each source's sensitivity tier (auditable)
- [ ] ShellCheck zero violations on new + modified helpers
- [ ] Tests pass: `bash .agents/tests/test-knowledge-index.sh`

## Dependencies

- **Blocked by:** t2844 (P0a directory contract), t2849 (P1a enrichment writes `text.txt` extractor invokes)
- **Soft-blocked by:** t2847 (P0.5b LLM routing — PageIndex generator uses LLM)
- **Blocks:** P6a (case draft RAG depends on tree)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Kind-aware enrichment + index"
- Existing skill: `.agents/tools/context/pageindex.md`
- Existing scripts: `.agents/scripts/pageindex-generator.py`, `.agents/scripts/pageindex_helpers.py`
- Pattern for incremental rebuild: `.agents/scripts/pulse-simplification.sh` (sha-based change detection)
