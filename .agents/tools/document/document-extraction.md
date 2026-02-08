---
description: Privacy-preserving document extraction with Docling, ExtractThinker, and Presidio
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Document Extraction

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract structured data from documents (PDF, DOCX, images) with PII redaction
- **Stack**: Docling (parsing) + ExtractThinker (LLM extraction) + Presidio (PII detection)
- **Privacy**: Fully local processing via Ollama or Cloudflare Workers AI
- **Helper**: `scripts/document-extraction-helper.sh`
- **Workflow**: `tools/document/extraction-workflow.md` (tool selection, pipeline orchestration)
- **PRD**: `todo/tasks/prd-document-extraction.md`

**Quick start**:

```bash
# Install dependencies
document-extraction-helper.sh install --all

# Extract structured data from an invoice
document-extraction-helper.sh extract invoice.pdf --schema invoice --privacy local

# Scan for PII
document-extraction-helper.sh pii-scan document.txt

# Check component status
document-extraction-helper.sh status
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
Document Input (PDF/DOCX/Image/HTML)
         │
    ┌────┴────┐
    │ Docling  │  ← Document parsing (layout, tables, OCR)
    └────┬────┘
         │
    ┌────┴──────────┐
    │ ExtractThinker │  ← LLM-powered structured extraction
    └────┬──────────┘
         │
    ┌────┴────────┐
    │  Presidio    │  ← PII detection and redaction (optional)
    └────┬────────┘
         │
    Structured Output (JSON/CSV/Markdown)
```

## Components

### Docling (Document Parsing)

IBM's document conversion library. Handles complex layouts, tables, and OCR.

```bash
pip install docling

# Python usage
from docling.document_converter import DocumentConverter
converter = DocumentConverter()
result = converter.convert("document.pdf")
print(result.document.export_to_markdown())
```

- **Formats**: PDF, DOCX, PPTX, XLSX, HTML, images, AsciiDoc
- **Features**: Table extraction, OCR (EasyOCR/Tesseract), layout analysis
- **Repo**: https://github.com/DS4SD/docling

### ExtractThinker (LLM Extraction)

Pydantic-based structured extraction using LLMs.

```python
from extract_thinker import Extractor, Contract
from pydantic import BaseModel

class Invoice(BaseModel):
    vendor: str
    date: str
    total: float
    items: list[dict]

extractor = Extractor()
extractor.load_document_loader("docling")
extractor.load_llm("ollama/llama3.2")  # Local model

result = extractor.extract("invoice.pdf", Invoice)
print(result.model_dump_json(indent=2))
```

- **Repo**: https://github.com/enoch3712/ExtractThinker
- **LLM backends**: Ollama (local), OpenAI, Anthropic, Google, Cloudflare Workers AI

### Presidio (PII Redaction)

Microsoft's PII detection and anonymization.

```python
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine

analyzer = AnalyzerEngine()
anonymizer = AnonymizerEngine()

text = "John Smith's SSN is 123-45-6789"
results = analyzer.analyze(text=text, language="en")
anonymized = anonymizer.anonymize(text=text, analyzer_results=results)
print(anonymized.text)  # "<PERSON>'s SSN is <US_SSN>"
```

- **Entities**: PERSON, EMAIL, PHONE, SSN, CREDIT_CARD, IBAN, IP_ADDRESS, etc.
- **Repo**: https://github.com/microsoft/presidio

## Extraction Schemas (Templates)

> These are example/template schemas for common document types. Customize for your project.

### Invoice

```python
class Invoice(BaseModel):
    vendor_name: str
    vendor_address: str | None
    invoice_number: str
    invoice_date: str
    due_date: str | None
    subtotal: float
    tax: float | None
    total: float
    currency: str
    line_items: list[LineItem]
```

### Receipt

```python
class Receipt(BaseModel):
    merchant: str
    date: str
    total: float
    payment_method: str | None
    items: list[ReceiptItem]
```

### Contract

```python
class ContractSummary(BaseModel):
    parties: list[str]
    effective_date: str
    termination_date: str | None
    key_terms: list[str]
    obligations: list[str]
```

## Privacy Modes

| Mode | LLM | PII Handling | Use Case |
|------|-----|-------------|----------|
| **Local** | Ollama (llama3.2) | Presidio redact before LLM | Maximum privacy |
| **Edge** | Cloudflare Workers AI | Presidio redact before API | Good privacy, faster |
| **Cloud** | OpenAI/Anthropic | Presidio redact before API | Best quality |
| **None** | Any | No redaction | Non-sensitive documents |

## Installation

### Via Helper Script (Recommended)

```bash
# Install everything (core + PII + local LLM check)
document-extraction-helper.sh install --all

# Install only core (Docling + ExtractThinker)
document-extraction-helper.sh install --core

# Install PII detection (Presidio + spaCy)
document-extraction-helper.sh install --pii

# Check local LLM setup (Ollama)
document-extraction-helper.sh install --llm

# Verify installation
document-extraction-helper.sh status
```

### Manual Installation

```bash
# Core
pip install docling extract-thinker

# PII (optional)
pip install presidio-analyzer presidio-anonymizer
python -m spacy download en_core_web_lg

# Local LLM (optional)
brew install ollama && ollama pull llama3.2

# OCR backends (optional)
pip install easyocr  # or: brew install tesseract
```

The helper script creates an isolated Python venv at `~/.aidevops/.agent-workspace/python-env/document-extraction/` to avoid dependency conflicts.

## When to Use (vs Alternatives)

| Feature | This Stack (Docling+ExtractThinker) | DocStrange | Unstract MCP |
|---------|-------------------------------------|-----------|-------------|
| **Privacy** | Full local processing via Ollama | Local GPU (CUDA) | Cloud or self-hosted |
| **Schema control** | Pydantic models, custom schemas | JSON schema or field list | Pre-built extractors |
| **PII redaction** | Built-in via Presidio | Not built-in | Manual |
| **Setup** | pip install (3 packages) | `pip install docstrange` | Docker/server required |
| **Best for** | Custom pipelines with PII | Quick extraction, scans | Enterprise workflows |

Use this stack when you need custom Pydantic schemas, PII redaction, or fully local CPU processing. Use DocStrange (`tools/document/docstrange.md`) for simpler setup with schema-based extraction and strong OCR. Use Unstract for enterprise ETL pipelines.

## Related

- `tools/document/extraction-workflow.md` - Workflow orchestration and tool selection guide
- `scripts/document-extraction-helper.sh` - CLI helper script
- `tools/document/docstrange.md` - DocStrange: simpler single-install alternative (NanoNets, 7B model, schema extraction)
- `tools/conversion/pandoc.md` - Document format conversion
- `tools/conversion/mineru.md` - PDF to markdown (layout-aware)
- `tools/ocr/glm-ocr.md` - Local OCR via Ollama
- `services/document-processing/unstract.md` - Self-hosted document processing (alternative)
- `todo/tasks/prd-document-extraction.md` - Full PRD
