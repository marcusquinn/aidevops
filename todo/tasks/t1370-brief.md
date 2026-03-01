---
mode: subagent
---
# t1370: Add vector-search agent with zvec as per-tenant RAG option

## Origin

- **Created:** 2026-03-01
- **Session:** Claude Code (interactive)
- **Created by:** marcusquinn (human)
- **Conversation context:** Evaluated alibaba/zvec (8.4k stars, Apache-2.0, in-process C++ vector DB) for aidevops. Initially assessed as "good library, wrong fit for framework internals" but reconsidered for SaaS app development guidance — specifically per-user/org segregated RAG where each tenant's files and data need isolated vector search. Agreed to create a vector-search decision agent covering zvec alongside existing options (pgvector, Cloudflare Vectorize, PGlite+pgvector, hosted services).

## What

A comprehensive vector search subagent doc at `.agents/tools/database/vector-search.md` (with optional zvec-specific reference at `.agents/tools/database/vector-search/zvec.md`) that serves as the go-to decision guide when building SaaS applications requiring per-tenant RAG. The agent must:

1. **Decision matrix** — help developers choose between zvec, pgvector, Cloudflare Vectorize, PGlite+pgvector, and hosted options (Pinecone, Qdrant, Weaviate) based on constraints (deployment model, scale, ops budget, tenant count, isolation requirements)
2. **zvec deep-dive** — comprehensive reference for zvec's features since it's the newest and least-known option: installation, schema design, index types (HNSW, IVF, Flat), dense+sparse vectors, hybrid search, built-in embedding functions (local Sentence Transformers, OpenAI, Jina, BM25/SPLADE), rerankers (RRF, weighted, cross-encoder), quantization, Node.js and Python APIs
3. **Per-tenant RAG architecture** — end-to-end pipeline from file upload to LLM context assembly with tenant isolation at every step, integrating with our existing multi-org-isolation.md schema patterns
4. **Cross-references** — link to/from existing database agents (multi-org-isolation.md, pglite-local-first.md, postgres-drizzle-skill.md, Cloudflare Vectorize)

## Why

- **Gap in framework**: We have database agents (Postgres/Drizzle, PGlite, multi-org isolation) and a Cloudflare Vectorize reference, but no unified vector search decision guide. When building a SaaS app with per-tenant RAG, a developer currently has to read 4+ separate docs and piece together the architecture themselves.
- **zvec is a strong new option**: In-process, native C++, Node.js+Python bindings, dense+sparse, built-in embeddings and rerankers, billion-scale performance, Apache-2.0. The collection-per-tenant model gives physical isolation without running N server instances — a significant architectural advantage for multi-tenant SaaS.
- **Per-tenant RAG is a common SaaS pattern**: Users upload documents, the system chunks/embeds/stores them, and RAG queries are scoped to that tenant's data. This is the #1 use case for vector search in SaaS apps we build.

## How (Approach)

**Pattern to follow**: `.agents/tools/database/pglite-local-first.md` — decision guide format with "when to use" flowchart, comparison table, implementation patterns, and platform compatibility matrix.

**Key files to reference/cross-link**:
- `.agents/services/database/multi-org-isolation.md` — existing tenant isolation schema (row-level with `org_id`)
- `.agents/services/database/schemas/multi-org.ts` — TypeScript schema patterns
- `.agents/tools/database/pglite-local-first.md` — PGlite+pgvector for local-first
- `.agents/services/hosting/cloudflare-platform/references/vectorize/README.md` — Cloudflare Vectorize
- `.agents/services/database/postgres-drizzle-skill.md` — Postgres patterns

**zvec source material**:
- GitHub: https://github.com/alibaba/zvec (8.4k stars, Apache-2.0)
- Docs: https://zvec.org/en/docs/
- Built on Alibaba's Proxima vector search engine
- Python: `pip install zvec` (3.10-3.12)
- Node.js: `npm install @zvec/zvec`
- Platforms: Linux (x86_64, ARM64), macOS (ARM64)

**zvec key features for the reference**:
- **Index types**: HNSW (default, best recall/speed), IVF (memory-efficient), Flat (exact, small datasets)
- **Vector types**: Dense (FP32, FP16, INT8) + Sparse (for lexical matching)
- **Metrics**: Euclidean, Cosine, Dot-product, Inner-product
- **Quantization**: INT8 for reduced memory with minimal recall loss
- **Built-in embeddings**: DefaultLocalDense (all-MiniLM-L6-v2, 384d), OpenAI, Jina (v5, Matryoshka), Qwen, BM25, SPLADE
- **Rerankers**: RRF (rank fusion), Weighted, DefaultLocal (cross-encoder/ms-marco-MiniLM-L6-v2), Qwen
- **Hybrid search**: Multi-vector queries (dense+sparse) in single call with reranker fusion
- **Schema**: Collections with typed fields (vectors, scalars), DDL operations (add/alter/drop columns)
- **Operations**: Insert, Update, Upsert, Delete, DeleteByFilter, Fetch, Query, GroupByQuery
- **Performance**: Sub-millisecond search on billions of vectors (VectorDBBench: Cohere 10M benchmark)

**Per-tenant isolation patterns to document**:

| Approach | How | Isolation level | Ops complexity |
|----------|-----|----------------|---------------|
| Collection-per-tenant (zvec) | Separate collection per org, own DB path | Physical | Low — create/destroy collection |
| Namespace-per-tenant (Vectorize) | Namespace parameter on insert/query | Logical | Low — 50k namespace limit |
| RLS + org_id (pgvector) | Row-level security on vector table | Logical | Medium — RLS policy management |
| Metadata filter (any) | Filter by tenant_id metadata | Logical | Low — but slower, no hard isolation |
| Index-per-tenant (Vectorize) | Separate Vectorize index per org | Physical | High — 50k index limit |

## Acceptance Criteria

- [ ] `.agents/tools/database/vector-search.md` exists with decision matrix covering 5+ vector DB options
  ```yaml
  verify:
    method: codebase
    pattern: "zvec|pgvector|Vectorize|Pinecone|Qdrant"
    path: ".agents/tools/database/vector-search.md"
  ```
- [ ] zvec features documented: index types, dense+sparse, embeddings, rerankers, hybrid search
  ```yaml
  verify:
    method: codebase
    pattern: "HNSW|IVF|Flat|RrfReRanker|WeightedReRanker|DenseEmbeddingFunction"
    path: ".agents/tools/database/"
  ```
- [ ] Per-tenant RAG architecture section with end-to-end pipeline
  ```yaml
  verify:
    method: codebase
    pattern: "collection-per-tenant|tenant.*isolation|org_id.*vector"
    path: ".agents/tools/database/vector-search.md"
  ```
- [ ] Cross-references added to multi-org-isolation.md, pglite-local-first.md
  ```yaml
  verify:
    method: codebase
    pattern: "vector-search"
    path: ".agents/services/database/multi-org-isolation.md"
  ```
- [ ] AGENTS.md domain index updated with Vector Search entry
  ```yaml
  verify:
    method: codebase
    pattern: "vector-search"
    path: ".agents/AGENTS.md"
  ```
- [ ] zvec installs and basic operations work on macOS ARM64
  ```yaml
  verify:
    method: bash
    run: "pip install zvec && python -c 'import zvec; print(zvec.__all__)'"
  ```
- [ ] Lint clean (markdown-formatter)

## Context & Decisions

- **Why a unified agent, not separate per-tool**: Developers need to compare options at decision time. Separate docs for each vector DB would require reading 5 files to make one decision. The decision matrix + per-tool reference sections pattern (like pglite-local-first.md's "PGlite vs SQLite" section) keeps everything in one place.
- **Why zvec gets the deepest coverage**: It's the newest option (launched 2025), least known, and has the richest feature set (built-in embeddings, rerankers, hybrid search) that developers won't discover from a README skim. pgvector and Vectorize are well-documented elsewhere; our agent adds the comparison context.
- **Why collection-per-tenant over namespace/metadata**: For SaaS with strict data isolation requirements, physical separation (separate collection/DB file per tenant) is the strongest guarantee. zvec makes this cheap — creating a collection is a single function call, no server restart, no schema migration. This is zvec's architectural advantage over server-based vector DBs.
- **Non-goals**: This agent does NOT cover aidevops internal memory (stays on SQLite FTS5), does NOT replace osgrep for code search, does NOT include a helper script (zvec is a library, not a CLI tool).

## Relevant Files

- `.agents/tools/database/vector-search.md` — NEW: main decision guide (to create)
- `.agents/tools/database/vector-search/zvec.md` — NEW: optional zvec deep-dive (to create)
- `.agents/services/database/multi-org-isolation.md` — existing tenant isolation (cross-reference)
- `.agents/tools/database/pglite-local-first.md` — existing PGlite guide (cross-reference)
- `.agents/services/hosting/cloudflare-platform/references/vectorize/README.md` — existing Vectorize (cross-reference)
- `.agents/services/database/postgres-drizzle-skill.md` — existing Postgres (cross-reference)
- `.agents/AGENTS.md` — domain index to update

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing currently, but future SaaS app tasks with RAG requirements will reference this
- **External:** zvec package (pip/npm) for verification testing

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | zvec docs (done in this session), existing agent patterns |
| Implementation | 5h | Decision guide (2h), zvec reference (2h), tenant RAG architecture (1.5h) — some overlap |
| Cross-references | 30m | Update 4-5 existing files |
| Testing | 1h | Install zvec, verify basic ops, markdown lint |
| **Total** | **~7h** | |
