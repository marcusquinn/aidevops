---
description: Legal corpus research - contracts, case law, statutes, depositions via agentic RAG over multi-collection schemas
mode: subagent
model: sonnet
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Legal Research - Corpus RAG for Contracts, Case Law, Depositions

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Retrieve and reason over legal document corpora — contracts, case law, statutes, regulations, depositions, discovery — with citation fidelity suitable for filings.
- **Default substrate (file-based, chat-first)**: [PageIndex](../context/pageindex.md) for single-document deep-dive; SQLite FTS5 + `rg` for keyword-exhaustive review; [zvec or pgvector](../database/vector-search.md) for local vector corpus. No GUI required — all operations through CLI/chat.
- **Scale up when**: corpus >10M chunks, per-tenant isolation required, or agentic cross-collection routing is the main feature. See "When to Scale" below.
- **Never skip**: source citations with page/section/line refs. Hallucinated citations are malpractice-grade failures (see `legal.md`).
- **Parent agents**: [Legal](../../legal.md), [Research](../../research.md).

**Use when**: contract-clause discovery, case-law precedent search, deposition cross-referencing, regulatory compliance lookup, opposing-counsel profile building, privilege log review.

**Do NOT use**: short/single-document Q&A that fits in context (just read it), statutory text in active memory (cite directly), live case-status lookup (use court docket APIs — this is retrieval, not monitoring).

<!-- AI-CONTEXT-END -->

## Naive Search vs Agentic Search

Linear "embed-query → cosine-topK → return" collapses on legal questions because they carry implicit filters (jurisdiction, date, agreement type, privilege status) and require reasoning about which collection to consult. A reasoning layer that decomposes the query, routes to the right collection(s), applies filters, and reranks produces both better recall and transparent traces suitable for privilege logs and court exhibits. This is the pattern; the retrieval engine is an implementation choice.

## Decision Flowchart

```text
What is the research task?
├── Deep Q&A over ONE long document (>50 pages, structured ToC)?
│     → PageIndex (vectorless, reasoning-over-tree, 98.7% on FinanceBench)
│     → ../context/pageindex.md
│
├── Keyword-exhaustive review (term sheet search, named-entity scan)?
│     → rg/grep over extracted text + SQLite FTS5 for ranked recall
│     → Pair with OCR for scanned PDFs: tools/ocr/overview.md
│
├── Cross-document corpus with semantic queries, single tenant, <10M chunks?
│     → zvec (embedded, INT8 quantization) OR pgvector (if on Postgres)
│     → tools/database/vector-search.md decision matrix
│
├── Per-tenant SaaS (client matters, separate contract libraries)?
│     → Collection-per-tenant: tools/database/vector-search/per-tenant-rag.md
│
├── Agentic cross-collection routing (agreement-type + jurisdiction + date)?
│     → Multi-collection schema below + reasoning layer (Query Agent pattern)
│     → Implement on zvec+LLM first; Weaviate Query Agent only if managed service
│       justifies cost; see "When to Scale"
│
└── Live citation verification (case still good law, statute still in force)?
      → Retrieval ≠ verification. Use LexisNexis/Westlaw shepardising APIs or
        CourtListener (free) via curl subagent. NEVER trust corpus for currency.
```

## Multi-Collection Corpus Taxonomy

Splitting a legal corpus into collections narrows the search space and gives the reasoning layer explicit routing targets. Collections are physical for zvec/pgvector, namespaces for Vectorize, tenants for hosted. Proposed default schema (adapt per matter):

| Collection | Contents | Routing signals |
|------------|----------|-----------------|
| `contracts_commercial` | Licensing, distribution, reseller, marketing, sponsorship, franchise | "vendor", "license grant", "territory", "royalty" |
| `contracts_corporate_ip` | Strategic alliance, JV, affiliate, M&A, IP assignment, development | "equity", "IP ownership", "change of control" |
| `contracts_operational` | MSA, SOW, services, maintenance, hosting, outsourcing, consulting | "SLA", "deliverables", "service credits" |
| `caselaw_{jurisdiction}` | Opinions, orders — one collection per circuit/state/tribunal | "jurisdiction", "court", "precedent" |
| `statutes_regulations` | Codified law, agency regulations, administrative guidance | "statute", "reg", "CFR/USC citation" |
| `depositions_{case}` | Transcripts, exhibits, errata — one collection per active matter | "witness name", "exhibit #", "date of testimony" |
| `discovery_{case}` | Produced documents, privilege logs, interrogatory responses | "Bates range", "production set", "privileged" |

**Per-object metadata (every chunk)**: `doc_id`, `page`, `section`, `line_start`, `line_end`, `doc_type` (contract/opinion/statute/deposition), `jurisdiction`, `effective_date`, `parties`, `privilege_status` (privileged/work-product/non-privileged/uncertain), `source_bates`, `matter_id`. Without these, citations are unverifiable and privilege leaks become possible.

## Query Modes

Adopt the Weaviate Query Agent dual-mode pattern — useful regardless of backend:

| Mode | When to use | Return shape |
|------|-------------|--------------|
| **Search** | Discovery, manual review — "find all notice-period clauses in 2024 MSAs" | Ranked chunks with highlights + metadata; user skims |
| **Ask** | Synthesis — "what are the typical cure periods across our operational agreements?" | Grounded answer + inline citations `[doc_id, p.N]` + full chunks appended; user verifies |
| **Cross-reference** | Contradiction detection across depositions, version diff across contract revisions | Side-by-side chunks with diff highlights + citation chain |

In ask-mode, the LLM answer MUST be constrained to retrieved context. Surface zero-result cases explicitly ("no matching clause found in the searched collections") rather than hallucinating.

## Citation Fidelity (Malpractice-Grade)

Legal citations are load-bearing. Apply these rules in every ask-mode response:

1. **Every assertion traces to a retrieved chunk**. No chunk → no claim. Say "not found" instead of speculating.
2. **Page/line citations come from chunk metadata, never from the LLM**. The LLM formats, the metadata supplies. Verify post-generation: every `[p.N]` in output must appear in retrieved `page` fields.
3. **Jurisdiction banners**. Opinions without a `jurisdiction` field are untagged; never rank them as authoritative. Warn the user.
4. **Currency caveat**. Corpus retrieval returns what was ingested, not what is currently in force. Any "binding" / "precedent" claim requires a live Shepardizing / KeyCite / CanLII-Connects check — surface this as a follow-up step, not as implicit trust.
5. **Pincite discipline**. "See Smith v. Jones, 123 F.3d 456" without the pincite is a drafting smell. The retriever should return the paragraph-level citation; carry it through.

## When to Scale Beyond File-Based

Default to local/embedded. Escalate only when a specific constraint forces it:

| Trigger | Upgrade path |
|---------|--------------|
| Corpus >10M chunks per matter | pgvector with partitioning (already on Postgres) OR Qdrant self-hosted |
| Multi-tenant SaaS with >100 client firms | Pinecone (namespace isolation) OR Qdrant Cloud |
| Need agentic Query Agent out-of-box (schema inspection, sub-query planning, rerank sub-agent) | Weaviate (managed Query Agent) — the article's primary value-add |
| Edge latency <10ms, Cloudflare stack | Vectorize (5M vectors/index limit, no hybrid search) |
| Regulated data residency, on-prem only | zvec (Apache 2.0, no network) OR Qdrant self-hosted |

See [`tools/database/vector-search.md`](../database/vector-search.md) for the full cost matrix and per-engine gotchas. The Weaviate article's `npx skills add weaviate/agent-skills` plugin approach is registerable as an optional skill if a project commits to that stack — not a framework default.

## Chat-First Workflow

Every operation is CLI/chat-driven; no GUI is required at any step.

1. **Ingest**: [`mineru`](../conversion/mineru.md) / [`pandoc`](../conversion/pandoc.md) for PDFs → chunked text. OCR first for scanned filings ([`tools/ocr/overview.md`](../ocr/overview.md)).
2. **Index**: `zvec.create_and_open(path=f"~/.aidevops/.agent-workspace/work/{matter_id}/{collection}")` per collection (framework-standard persistent path); attach metadata on every chunk.
3. **Query**: agent receives natural-language question → decomposes into (collection route, filters, sub-queries) → executes parallel searches → reranks → cites.
4. **Deliver**: inline answer in chat with `[doc_id, p.N]` citations; full retrieved chunks available on request; export to `todo/research/{matter_id}/{question-slug}.md` for persistent matter notes.

Version-control the ingestion manifest (document list, chunk strategy, embedding model ID) in the matter's repo so re-indexing is reproducible.

## Gotchas

1. **Amended contracts** — the corpus must track document version. Query "current termination clause" without version filtering returns superseded text. Store `effective_date` + `supersedes: [doc_id]` on every chunk.
2. **Privilege leakage** — mixed privileged/non-privileged in one collection is one application bug away from disclosure. Physically separate privileged collections; require explicit flag to query them; audit-log every privileged retrieval.
3. **Visual content loss** — legal PDFs contain tables, signatures, stamps, redactions. Text-only extraction loses these. For signature blocks and redaction boxes, store page images alongside extracted text (multivector / late-interaction models handle this; plain text embeddings do not).
4. **Opposing counsel's exhibits** — ingesting produced documents means the corpus contains their framing. Tag `source: produced-by-opposing` on every chunk; filter or weight accordingly.
5. **Jurisdictional confusion** — a "reasonable notice" case from NY is not persuasive in CA. Reject cross-jurisdictional mixing unless the user opts in with explicit scope.
6. **Deposition errata** — witnesses change testimony via errata sheets. Index the errata as versioned updates to the transcript, not as separate documents; otherwise contradiction detection finds the same witness "contradicting themselves" via their own correction.
7. **Embedding model lock-in** — changing models requires re-embedding the entire corpus. For active matters, this can mean days of re-indexing. Record the model ID with every vector (per `per-tenant-rag.md` Stage 4).
8. **Citation hallucination** — cross-check output `[p.N]` tokens against chunk metadata pages before surfacing answers; treat any mismatch as a hard fail, not a warning.

## Related

- [Legal main agent](../../legal.md) — strategy, pre-flight questions, case building, opposing counsel profiling
- [Research main agent](../../research.md) — general research patterns
- [Vector Search Decision Guide](../database/vector-search.md) — backend comparison, cost matrix
- [Per-Tenant RAG](../database/vector-search/per-tenant-rag.md) — multi-tenant isolation patterns
- [PageIndex](../context/pageindex.md) — vectorless tree RAG for single long documents
- [OCR overview](../ocr/overview.md) — required for scanned filings
- [Document extraction](../document/document-extraction.md) — PDF-to-text pipelines
- Source inspiration: <https://weaviate.io/blog/legal-rag-app> (agentic-search pattern, multi-collection schema, search/ask modes)
