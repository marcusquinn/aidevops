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

- **Purpose**: Hierarchical tree-index RAG — uses LLM reasoning to navigate document structure instead of vector similarity search
- **Install**: `pip3 install --upgrade -r requirements.txt` (clone repo first)
- **Key commands**: `python3 run_pageindex.py --pdf_path <file>` | `--md_path <file>`
- **LLM support**: Multi-provider via LiteLLM (OpenAI, Anthropic, etc.) — set `OPENAI_API_KEY` in `.env`
- **Repo**: <https://github.com/VectifyAI/PageIndex> (MIT, Python)
- **Docs**: <https://docs.pageindex.ai>
- **MCP/API**: <https://pageindex.ai/developer>

**Use when**: Documents exceed LLM context limits — financial reports, regulatory filings, academic textbooks, legal/technical manuals. Need explainable retrieval with page/section references. Want human-like document navigation without vector DB infrastructure.

**Do NOT use**: Short documents that fit in context window. Keyword/exact-match search (use rg/grep). Codebase semantic search (use [Augment Context Engine](augment-context-engine.md)). Real-time streaming ingestion. Already have a vector pipeline that works (see [vector-search](../database/vector-search.md)).

<!-- AI-CONTEXT-END -->

## How It Works

Inspired by AlphaGo's tree search. PageIndex builds a hierarchical tree from document structure (headings, sections, ToC), then uses LLM reasoning to navigate the tree top-down — selecting relevant branches at each level until reaching the target content.

```text
Document
├── Chapter 1: Financial Stability
│   ├── Section 1.1: Monitoring Vulnerabilities (pages 22-28)
│   └── Section 1.2: Policy Actions (pages 29-35)
├── Chapter 2: Monetary Policy
│   └── ...
```

**Key differences from vector RAG**:

| Aspect | Vector RAG | PageIndex |
|--------|-----------|-----------|
| Retrieval | Embedding similarity | LLM reasoning over tree |
| Chunking | Fixed-size or sliding window | Natural document sections |
| Explainability | Cosine score | Reasoning trace with page refs |
| Infrastructure | Vector DB required | No DB — JSON tree + LLM |

## Gotchas

1. **LLM cost per query** — every retrieval invokes LLM reasoning (multiple calls to navigate the tree). Cost scales with tree depth. Budget accordingly.
2. **Index build time** — tree generation requires LLM calls per section. Large documents (500+ pages) take minutes, not seconds.
3. **PDF quality matters** — scanned PDFs without OCR produce poor trees. Pre-process with OCR if needed.
4. **Model dependency** — retrieval quality depends heavily on the LLM used. GPT-4o recommended; smaller models may miss nuanced navigation decisions.
5. **No incremental updates** — changing the document requires full re-indexing. Not suited for frequently updated content.
6. **Single-document focus** — designed for deep retrieval within one document, not cross-corpus search.

## Installation

```bash
git clone https://github.com/VectifyAI/PageIndex.git
cd PageIndex
pip3 install --upgrade -r requirements.txt
```

Set API key in `.env`:

```bash
OPENAI_API_KEY=your_key_here
```

## Usage

### Generate Tree Index

```bash
# From PDF
python3 run_pageindex.py --pdf_path /path/to/document.pdf

# From Markdown
python3 run_pageindex.py --md_path /path/to/document.md
```

### Optional Parameters

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
  "start_index": 21,
  "end_index": 22,
  "summary": "The Federal Reserve ...",
  "nodes": [
    {
      "title": "Monitoring Financial Vulnerabilities",
      "node_id": "0007",
      "start_index": 22,
      "end_index": 28,
      "summary": "The Federal Reserve's monitoring ..."
    }
  ]
}
```

### Agentic RAG (OpenAI Agents SDK)

```bash
pip3 install openai-agents
python3 examples/agentic_vectorless_rag_demo.py
```

## Deployment Options

| Option | Description |
|--------|-------------|
| **Self-hosted** | Clone repo, run locally (open source, MIT) |
| **Cloud chat** | <https://chat.pageindex.ai> — hosted document QA |
| **MCP server** | Integrate with AI coding tools via MCP protocol |
| **REST API** | Programmatic access via <https://pageindex.ai/developer> |

## Benchmark

98.7% accuracy on FinanceBench (state-of-the-art for financial document QA).

## Related

- [Augment Context Engine](augment-context-engine.md) — Semantic codebase retrieval (code, not documents)
- [Context Builder](context-builder.md) — Token-efficient codebase packing
- [Per-Tenant RAG Patterns](../database/vector-search.md) — Vector-based RAG with tenant isolation
- [llm-tldr](llm-tldr.md) — Semantic code analysis with token savings
