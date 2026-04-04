---
description: DocStrange - document conversion and structured data extraction
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
mcp:
  docstrange: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# DocStrange - Document Conversion & Extraction

<!-- AI-CONTEXT-START -->

## Quick Reference

| | |
|---|---|
| **Install** | `pip install docstrange` |
| **Formats** | PDF, DOCX, PPTX, XLSX, PNG/JPG/TIFF/BMP, HTML, URLs |
| **Cloud** | Free 10k/month (anonymous or authenticated); sends docs to NanoNets |
| **Local GPU** | CUDA required, 100% private, unlimited; ~4GB model download on first run |
| **MCP** | Clone repo (not in PyPI): `git clone https://github.com/nanonets/docstrange.git` |
| **GitHub** | https://github.com/NanoNets/docstrange |
| **Docs** | https://docstrange.nanonets.com/ |

**Purpose**: Single `pip install` replaces Docling+ExtractThinker+Presidio for most extraction tasks. 7B model for OCR and layout detection; produces LLM-optimized Markdown and structured JSON.

**On-demand loading**: MCP disabled globally; enabled per-agent when document extraction is needed.

<!-- AI-CONTEXT-END -->

## Installation

```bash
pip install docstrange                 # core
pip install "docstrange[web]"          # + local web UI
# Local GPU: CUDA required; models download on first run (~4GB)
```

## Python API

```python
from docstrange import DocumentExtractor
extractor = DocumentExtractor()

result = extractor.extract("document.pdf")
result.extract_markdown()                                          # Markdown
result.extract_data()                                             # JSON
result.extract_data(specified_fields=["invoice_number", "total_amount"])  # targeted
result.extract_data(json_schema={"contract_number": "string"})   # schema
result.extract_html() / extract_csv() / extract_text()           # other formats

DocumentExtractor(gpu=True).extract("document.pdf")              # local GPU (private)
```

## CLI

```bash
docstrange document.pdf                                                    # Markdown
docstrange invoice.pdf --output json --extract-fields invoice_number total_amount
docstrange contract.pdf --output json --json-schema schema.json
docstrange document.pdf --gpu-mode                                         # local GPU
docstrange *.pdf --output markdown                                         # batch
docstrange document.pdf --output-file result.md
docstrange login                                                           # auth (10k/month)
docstrange document.pdf --api-key YOUR_API_KEY
docstrange --logout
docstrange web [--port 8080]                                               # UI at :8000
```

## MCP Server (Claude Desktop)

```bash
git clone https://github.com/nanonets/docstrange.git
cd docstrange && pip install -e ".[dev]"
```

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "docstrange": {
      "command": "python3",
      "args": ["/path/to/docstrange/mcp_server_module/server.py"]
    }
  }
}
```

MCP features: smart token counting, hierarchical navigation, intelligent chunking, document search.

## When to Use

| | DocStrange | Docling+ExtractThinker | Unstract |
|---|---|---|---|
| **Setup** | `pip install` | 3 installs | Docker/server |
| **Schema extraction** | JSON schema / field list | Pydantic models | Pre-built extractors |
| **PII redaction** | Not built-in | Via Presidio | Manual |
| **Local processing** | GPU (CUDA only) | Ollama (CPU/GPU) | Self-hosted Docker |
| **MCP server** | Repo only | None | Docker-based |
| **Cloud API** | Free 10k/month | N/A | Cloud or self-hosted |
| **OCR quality** | 7B model, strong on scans | EasyOCR/Tesseract | LLM-dependent |
| **Best for** | Fast setup, scans, free API | PII, custom pipelines | Enterprise ETL |

**Decision rules:**
- **DocStrange**: fast setup, scan/photo OCR, schema extraction, free cloud API — single tool, no orchestration
- **Docling+ExtractThinker**: PII redaction (Presidio), Pydantic schemas, CPU-only local, fine-grained control
- **Unstract**: visual schema builder, enterprise ETL, pre-built extractors without code

## Limitations

- Local GPU requires CUDA — no Apple Silicon/MLX support
- No built-in PII detection/redaction (use Presidio separately)
- Cloud mode sends documents to NanoNets servers
- MCP server not in PyPI — must clone repo

## Related

- `tools/document/document-extraction.md` — Docling+ExtractThinker+Presidio stack
- `tools/ocr/glm-ocr.md` — local OCR via Ollama
- `services/document-processing/unstract.md` — enterprise document processing
- `tools/conversion/pandoc.md` — document format conversion
- `todo/tasks/prd-document-extraction.md` — full document extraction PRD
