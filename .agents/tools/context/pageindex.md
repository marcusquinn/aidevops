---
description: PageIndex - Vectorless reasoning-based RAG for long document retrieval
mode: subagent
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

# PageIndex - Vectorless Reasoning-Based RAG

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Hierarchical tree-index RAG — LLM reasoning navigates document structure instead of vector similarity
- **Install**: `git clone https://github.com/VectifyAI/PageIndex.git && cd PageIndex && pip3 install --upgrade -r requirements.txt`
- **Run**: `python3 run_pageindex.py --pdf_path <file>` | `--md_path <file>`
- **LLM support**: Multi-provider via LiteLLM — set `OPENAI_API_KEY` in `.env`
- **Benchmark**: 98.7% accuracy on FinanceBench (SOTA for financial document QA)
- **Repo**: <https://github.com/VectifyAI/PageIndex> (MIT, Python)
- **Docs**: <https://docs.pageindex.ai> | **MCP/API**: <https://pageindex.ai/developer>

**Use when**: Documents exceed context limits — financial reports, regulatory filings, academic textbooks, legal/technical manuals. Need explainable retrieval with page/section references. No vector DB infrastructure wanted.

**Do NOT use**: Short documents fitting in context. Keyword search (use rg/grep). Codebase search (use [Augment Context Engine](augment-context-engine.md)). Real-time streaming. Existing vector pipeline (see [vector-search](../database/vector-search.md)).

<!-- AI-CONTEXT-END -->

## How It Works

Builds a hierarchical tree from document structure (headings, sections, ToC), then uses LLM reasoning to navigate top-down — selecting relevant branches at each level until reaching target content. Inspired by AlphaGo's tree search.

```text
Document
├── Chapter 1: Financial Stability
│   ├── Section 1.1: Monitoring Vulnerabilities (pages 22-28)
│   └── Section 1.2: Policy Actions (pages 29-35)
├── Chapter 2: Monetary Policy
│   └── ...
```

**vs Vector RAG**: Vector uses embedding similarity + fixed-size chunks + cosine scores + requires vector DB. PageIndex uses LLM reasoning over natural sections + reasoning traces with page refs + no DB (JSON tree + LLM).

## Gotchas

1. **LLM cost per query** — multiple LLM calls to navigate tree. Cost scales with depth.
2. **Index build time** — LLM calls per section. 500+ page docs take minutes.
3. **PDF quality** — scanned PDFs without OCR produce poor trees. Pre-process with OCR.
4. **Model dependency** — GPT-4o recommended; smaller models miss nuanced navigation.
5. **No incremental updates** — document changes require full re-index.
6. **Single-document focus** — deep retrieval within one document, not cross-corpus.

## Usage

### Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `--model` | `gpt-4o-2024-11-20` | LLM model (any LiteLLM provider) |
| `--toc-check-pages` | `20` | Pages to scan for table of contents |
| `--max-pages-per-node` | `10` | Max pages per tree leaf node |
| `--max-tokens-per-node` | `20000` | Max tokens per tree leaf node |
| `--if-add-node-id` | `yes` | Add unique IDs to tree nodes |
| `--if-add-node-summary` | `yes` | Generate summaries per node |
| `--if-add-doc-description` | `yes` | Add top-level document description |

### Tree Output (JSON)

```jsonc
{
  "title": "Financial Stability",
  "node_id": "0006",
  "start_index": 21, "end_index": 22,
  "summary": "The Federal Reserve ...",
  "nodes": [{ "title": "Monitoring Financial Vulnerabilities", "node_id": "0007", "start_index": 22, "end_index": 28 }]
}
```

### Agentic RAG (OpenAI Agents SDK)

```bash
pip3 install openai-agents
python3 examples/agentic_vectorless_rag_demo.py
```

## Deployment Options

- **Self-hosted**: Clone repo, run locally (MIT)
- **Cloud chat**: <https://chat.pageindex.ai> — hosted document QA
- **MCP server**: Integrate with AI coding tools via MCP protocol
- **REST API**: <https://pageindex.ai/developer>

## Related

- [Augment Context Engine](augment-context-engine.md) — Semantic codebase retrieval (code, not documents)
- [Context Builder](context-builder.md) — Token-efficient codebase packing
- [Per-Tenant RAG Patterns](../database/vector-search.md) — Vector-based RAG with tenant isolation
- [llm-tldr](llm-tldr.md) — Semantic code analysis with token savings
