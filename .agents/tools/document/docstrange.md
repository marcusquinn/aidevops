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

# DocStrange - Document Conversion & Extraction

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Convert documents to Markdown/JSON/CSV/HTML with structured data extraction
- **Install**: `pip install docstrange` (web UI: `pip install "docstrange[web]"`)
- **Formats**: PDF, DOCX, PPTX, XLSX, images (PNG/JPG/TIFF/BMP), HTML, URLs
- **Modes**: Cloud (free, 10k docs/month) or local GPU (100% private, CUDA required)
- **MCP**: Built-in server for Claude Desktop (clone repo, not in PyPI)
- **License**: MIT
- **GitHub**: https://github.com/NanoNets/docstrange (1.3k stars)
- **Docs**: https://docstrange.nanonets.com/

**On-demand loading**: This MCP is disabled globally and enabled per-agent when document extraction is needed.

**Key differentiator**: Single `pip install` replaces the multi-tool Docling+ExtractThinker+Presidio stack. Uses an upgraded 7B model for OCR and layout detection, producing LLM-optimized Markdown and structured JSON.

<!-- AI-CONTEXT-END -->

## Processing Modes

| Mode | Privacy | Speed | Setup | Limit |
|------|---------|-------|-------|-------|
| **Cloud (anonymous)** | Low | Fast | None | Rate-limited |
| **Cloud (authenticated)** | Low | Fast | `docstrange login` | 10k docs/month |
| **Cloud (API key)** | Low | Fast | API key | 10k docs/month |
| **Local GPU** | Full | Medium | CUDA required | Unlimited |

## Python API

```python
from docstrange import DocumentExtractor
extractor = DocumentExtractor()          # cloud mode (or gpu=True for local)
result = extractor.extract("document.pdf")

result.extract_markdown()    # clean Markdown (LLM/RAG pipelines)
result.extract_data()        # structured JSON
result.extract_html()        # formatted HTML
result.extract_csv()         # CSV (table/spreadsheet data)
result.extract_text()        # plain text

# Targeted fields
result.extract_data(specified_fields=["invoice_number", "total_amount", "vendor_name"])
# Schema-conforming
result.extract_data(json_schema={"contract_number": "string", "parties": ["string"],
    "total_value": "number", "start_date": "string", "terms": ["string"]})
```

## CLI

```bash
docstrange document.pdf                                              # Markdown output
docstrange invoice.pdf --output json --extract-fields invoice_number total_amount
docstrange contract.pdf --output json --json-schema schema.json      # schema extraction
docstrange document.pdf --gpu-mode                                   # local GPU
docstrange *.pdf --output markdown                                   # batch
docstrange document.pdf --output-file result.md                      # save to file

# Authentication (10k docs/month)
docstrange login                          # Google login
docstrange document.pdf --api-key YOUR_API_KEY
docstrange --logout

# Local web UI (drag-and-drop at localhost:8000)
docstrange web                            # default port
docstrange web --port 8080                # custom port
```

## MCP Server (Claude Desktop)

Not in PyPI — clone repo to use:

```bash
git clone https://github.com/nanonets/docstrange.git
cd docstrange && pip install -e ".[dev]"
```

Config (`~/Library/Application Support/Claude/claude_desktop_config.json`): add `mcpServers.docstrange` with `command: "python3"`, `args: ["/path/to/docstrange/mcp_server_module/server.py"]`.

Features: smart token counting, hierarchical navigation, intelligent chunking, document search.

## When to Use (vs Alternatives)

| Feature | DocStrange | Docling+ExtractThinker | Unstract |
|---------|-----------|----------------------|----------|
| **Setup** | `pip install docstrange` | 3 separate installs | Docker/server |
| **Schema extraction** | JSON schema or field list | Pydantic models | Pre-built extractors |
| **PII redaction** | Not built-in | Via Presidio | Manual |
| **Local processing** | GPU mode (CUDA) | Ollama (CPU/GPU) | Self-hosted Docker |
| **MCP server** | Built-in (repo only) | None | Docker-based |
| **Cloud API** | Free 10k/month | N/A (bring your LLM) | Cloud or self-hosted |
| **OCR quality** | 7B model, strong on scans | EasyOCR/Tesseract | Depends on LLM |
| **Best for** | Quick extraction, scans | Custom pipelines, PII | Enterprise workflows |

## Limitations

- CUDA required for local GPU (no Apple Silicon/MLX)
- No built-in PII redaction (use Presidio separately)
- Cloud mode sends documents to NanoNets servers
- MCP server not in PyPI (must clone repo)
- 7B model downloads on first local run (~4GB)

## Related

- `tools/document/document-extraction.md` - Docling+ExtractThinker+Presidio stack (alternative)
- `tools/ocr/glm-ocr.md` - Local OCR via Ollama
- `services/document-processing/unstract.md` - Enterprise document processing
- `tools/conversion/pandoc.md` - Document format conversion
- `todo/tasks/prd-document-extraction.md` - Full document extraction PRD
