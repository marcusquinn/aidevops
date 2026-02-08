---
description: Document structured data extraction with DocStrange (NanoNets)
mode: subagent
tools:
  read: true
  bash: true
---

# DocStrange

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract structured data from documents (PDF, DOCX, PPTX, XLSX, images, URLs)
- **Install**: `pip install docstrange` (Python 3.8+, MIT license)
- **Repo**: <https://github.com/NanoNets/docstrange> (1.3k stars)
- **Output**: Markdown, JSON, CSV, HTML
- **Modes**: Cloud API (free 10k docs/month) or local GPU (100% private, CUDA required)

<!-- AI-CONTEXT-END -->

## Supported Formats

| Category | Types |
|----------|-------|
| **Documents** | PDF, DOCX, DOC, PPTX, PPT |
| **Spreadsheets** | XLSX, XLS, CSV |
| **Images** | PNG, JPG, JPEG, TIFF, BMP |
| **Web** | HTML, HTM, URLs |
| **Text** | TXT |

## Schema-Based Extraction

```python
from docstrange import DocumentExtractor

extractor = DocumentExtractor()  # cloud mode (default)
result = extractor.extract("invoice.pdf")

# Method 1: Specify fields to extract
fields = result.extract_data(specified_fields=[
    "invoice_number", "total_amount", "vendor_name", "due_date"
])

# Method 2: Enforce a JSON schema
schema = {
    "invoice_number": "string",
    "total_amount": "number",
    "vendor_name": "string",
    "line_items": [{"description": "string", "amount": "number"}]
}
structured = result.extract_data(json_schema=schema)
```

## Processing Modes

| Mode | Init | Privacy | Requires |
|------|------|---------|----------|
| **Cloud (default)** | `DocumentExtractor()` | Data sent to NanoNets API | Internet |
| **Cloud (auth)** | `DocumentExtractor(api_key="...")` | Same, 10k docs/month | API key |
| **Local GPU** | `DocumentExtractor(gpu=True)` | 100% private, on-device | CUDA GPU |

```bash
# CLI usage
docstrange document.pdf --output json --extract-fields invoice_number total_amount
docstrange document.pdf --gpu-mode  # local processing
docstrange document.pdf --output json --json-schema schema.json
```

## MCP Server (Claude Desktop)

The MCP server is in the repo but **not** in the PyPI package. Clone to use it.

```bash
git clone https://github.com/nanonets/docstrange.git
pip install -e ".[dev]"
```

Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

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

Features: token-aware navigation, hierarchical chunking, document search.

## Common Patterns

- **Invoice**: `specified_fields=["invoice_number", "vendor_name", "total_amount", "due_date", "line_items"]`
- **Contract**: `json_schema={"parties": ["string"], "contract_value": "number", "start_date": "string", "end_date": "string", "key_terms": ["string"]}`
- **Receipt**: `specified_fields=["merchant_name", "total_amount", "date", "payment_method"]`
- **Batch CLI**: `docstrange *.pdf --output json --extract-fields title author date summary`

## Comparison with Docling + ExtractThinker + Presidio (t073)

| Aspect | DocStrange | Docling + ExtractThinker + Presidio |
|--------|------------|-------------------------------------|
| **Install** | `pip install docstrange` (single pkg) | 3-4 packages + spaCy model + Ollama |
| **Schema** | JSON dict with type hints | Pydantic models (stronger typing) |
| **PII redaction** | None built-in | Presidio (50+ entity types) |
| **Local LLM** | Built-in 7B model (GPU mode) | BYO via Ollama (any model) |
| **OCR quality** | Upgraded 7B model, multi-engine | Docling (EasyOCR/Tesseract) |
| **MCP server** | Included (clone repo) | Not included |
| **Cloud tier** | Free 10k docs/month | No cloud option |
| **Best for** | Quick extraction, cloud+local hybrid | Custom pipelines, PII compliance |

**Recommendation**: Use DocStrange for straightforward document-to-JSON extraction where PII redaction is not required. Use the Docling+ExtractThinker+Presidio stack (t073) when you need Pydantic-typed contracts, PII anonymization, or full control over the LLM backend. The two can complement each other -- DocStrange for rapid prototyping, t073 stack for production pipelines with privacy requirements.

## Related

- `tools/document/document-extraction.md` - Docling + ExtractThinker + Presidio stack
- `tools/document/pandoc-helper.sh` - Format conversion
- `tools/document/mineru.md` - Alternative PDF extraction (MinerU)
