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
- **Install**: `pip install docstrange`
- **Formats**: PDF, DOCX, PPTX, XLSX, images (PNG/JPG/TIFF/BMP), HTML, URLs
- **Modes**: Cloud (free, 10k docs/month) or local GPU (100% private, CUDA required)
- **MCP**: Built-in server for Claude Desktop (clone repo, not in PyPI)
- **License**: MIT
- **GitHub**: https://github.com/NanoNets/docstrange (1.3k stars)
- **Docs**: https://docstrange.nanonets.com/

**On-demand loading**: This MCP is disabled globally and enabled per-agent when document extraction is needed.

<!-- AI-CONTEXT-END -->

## What is DocStrange?

NanoNets DocStrange is a Python library for converting documents into clean, structured output. It uses an upgraded 7B model for OCR and layout detection, producing LLM-optimized Markdown and structured JSON. Key differentiator: single `pip install` replaces the multi-tool Docling+ExtractThinker+Presidio stack for most extraction tasks.

## Processing Modes

| Mode | Privacy | Speed | Setup | Limit |
|------|---------|-------|-------|-------|
| **Cloud (anonymous)** | Low | Fast | None | Rate-limited |
| **Cloud (authenticated)** | Low | Fast | `docstrange login` | 10k docs/month |
| **Cloud (API key)** | Low | Fast | API key | 10k docs/month |
| **Local GPU** | Full | Medium | CUDA required | Unlimited |

## Installation

```bash
# Core library
pip install docstrange

# With web UI (local drag-and-drop interface)
pip install "docstrange[web]"

# Local GPU mode requires CUDA
# Models download automatically on first run
```

## Usage

### Convert to Markdown

```python
from docstrange import DocumentExtractor

extractor = DocumentExtractor()
result = extractor.extract("document.pdf")
print(result.extract_markdown())
```

### Extract Structured JSON

```python
result = extractor.extract("invoice.pdf")
json_data = result.extract_data()
print(json_data)
```

### Extract Specific Fields

```python
result = extractor.extract("invoice.pdf")
fields = result.extract_data(specified_fields=[
    "invoice_number", "total_amount", "vendor_name", "due_date"
])
```

### Extract with JSON Schema

```python
schema = {
    "contract_number": "string",
    "parties": ["string"],
    "total_value": "number",
    "start_date": "string",
    "terms": ["string"]
}
structured = result.extract_data(json_schema=schema)
```

### Local GPU Processing

```python
extractor = DocumentExtractor(gpu=True)
result = extractor.extract("sensitive-document.pdf")
```

### CLI

```bash
# Basic conversion
docstrange document.pdf

# JSON output with specific fields
docstrange invoice.pdf --output json --extract-fields invoice_number total_amount

# JSON schema extraction
docstrange contract.pdf --output json --json-schema schema.json

# Local GPU mode
docstrange document.pdf --gpu-mode

# Multiple files
docstrange *.pdf --output markdown

# Save to file
docstrange document.pdf --output-file result.md
```

### Authentication

```bash
# Google login (10k docs/month)
docstrange login

# Or use API key
docstrange document.pdf --api-key YOUR_API_KEY

# Logout
docstrange --logout
```

## Output Formats

| Method | Output | Use Case |
|--------|--------|----------|
| `extract_markdown()` | Clean Markdown | LLM/RAG pipelines |
| `extract_data()` | Structured JSON | Data extraction |
| `extract_data(specified_fields=[...])` | Targeted JSON | Specific field extraction |
| `extract_data(json_schema={...})` | Schema-conforming JSON | Structured pipelines |
| `extract_html()` | Formatted HTML | Web display |
| `extract_csv()` | CSV | Table/spreadsheet data |
| `extract_text()` | Plain text | Simple text extraction |

## Local Web UI

```bash
# Start local web interface
docstrange web

# Custom port
docstrange web --port 8080
```

Provides drag-and-drop document conversion at `http://localhost:8000`. Supports cloud and local GPU modes.

## MCP Server (Claude Desktop)

The MCP server is in the repo but not in the PyPI package. Clone to use:

```bash
git clone https://github.com/nanonets/docstrange.git
cd docstrange
pip install -e ".[dev]"
```

Add to Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

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

MCP features: smart token counting, hierarchical document navigation, intelligent chunking, document search.

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

**Choose DocStrange when**: You need fast setup, good OCR on scans/photos, schema-based extraction, or a free cloud API. Single tool, no orchestration needed.

**Choose Docling+ExtractThinker when**: You need PII redaction (Presidio), custom Pydantic schemas, fully local CPU processing (no CUDA), or fine-grained pipeline control.

**Choose Unstract when**: You need a visual schema builder, enterprise ETL pipelines, or pre-built extractors without code.

## Limitations

- Local GPU mode requires CUDA (no Apple Silicon/MLX support)
- No built-in PII detection/redaction (use Presidio separately if needed)
- Cloud mode sends documents to NanoNets servers
- MCP server not included in PyPI package (must clone repo)
- 7B model downloads on first local run (~4GB)

## Related

- `tools/document/document-extraction.md` - Docling+ExtractThinker+Presidio stack (alternative)
- `tools/ocr/glm-ocr.md` - Local OCR via Ollama
- `services/document-processing/unstract.md` - Enterprise document processing
- `tools/conversion/pandoc.md` - Document format conversion
- `todo/tasks/prd-document-extraction.md` - Full document extraction PRD
