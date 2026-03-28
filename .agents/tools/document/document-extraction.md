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
- **Schemas**: `tools/document/extraction-schemas.md` — accounting (`purchase-invoice`, `expense-receipt`, `credit-note`) and general (`invoice`, `receipt`, `contract`, `id-document`, `auto`)
- **Workflow**: `tools/document/extraction-workflow.md`
- **PRD**: `todo/tasks/prd-document-extraction.md`

```bash
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local
document-extraction-helper.sh extract receipt.jpg --schema expense-receipt --privacy local
document-extraction-helper.sh pii-scan document.txt
document-extraction-helper.sh schemas          # List all schemas
document-extraction-helper.sh install --all    # Install dependencies
```

<!-- AI-CONTEXT-END -->

## Architecture

Pipeline: **Document Input** (PDF/DOCX/Image/HTML) → **Docling** (parsing, layout, tables, OCR) → **ExtractThinker** (LLM-powered structured extraction) → **Presidio** (PII detection/redaction, optional) → **Structured Output** (JSON/CSV/Markdown).

## Components

### Docling (Document Parsing)

IBM's document conversion library. Handles complex layouts, tables, and OCR.

- **Formats**: PDF, DOCX, PPTX, XLSX, HTML, images, AsciiDoc
- **Features**: Table extraction, OCR (EasyOCR/Tesseract), layout analysis
- **Repo**: https://github.com/DS4SD/docling

```python
from docling.document_converter import DocumentConverter
result = DocumentConverter().convert("document.pdf")
print(result.document.export_to_markdown())
```

### ExtractThinker (LLM Extraction)

Pydantic-based structured extraction using LLMs. Backends: Ollama (local), OpenAI, Anthropic, Google, Cloudflare Workers AI.

- **Repo**: https://github.com/enoch3712/ExtractThinker

```python
from extract_thinker import Extractor
from pydantic import BaseModel

class Invoice(BaseModel):
    vendor: str; date: str; total: float; items: list[dict]

extractor = Extractor()
extractor.load_document_loader("docling")
extractor.load_llm("ollama/llama3.2")  # Local model
result = extractor.extract("invoice.pdf", Invoice)
```

### Presidio (PII Redaction)

Microsoft's PII detection and anonymization. Entities: PERSON, EMAIL, PHONE, SSN, CREDIT_CARD, IBAN, IP_ADDRESS, etc.

- **Repo**: https://github.com/microsoft/presidio

```python
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine

results = AnalyzerEngine().analyze(text="John Smith's SSN is 123-45-6789", language="en")
print(AnonymizerEngine().anonymize(text="John Smith's SSN is 123-45-6789", analyzer_results=results).text)
# "<PERSON>'s SSN is <US_SSN>"
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
document-extraction-helper.sh install --all     # Core + PII + local LLM check
document-extraction-helper.sh install --core    # Docling + ExtractThinker only
document-extraction-helper.sh install --pii     # Presidio + spaCy
document-extraction-helper.sh install --llm     # Check Ollama setup
document-extraction-helper.sh status            # Verify installation
```

Creates an isolated venv at `~/.aidevops/.agent-workspace/python-env/document-extraction/`.

### Manual Installation

```bash
pip install docling extract-thinker                          # Core
pip install presidio-analyzer presidio-anonymizer             # PII (optional)
python -m spacy download en_core_web_lg                      # PII model
brew install ollama && ollama pull llama3.2                   # Local LLM (optional)
pip install easyocr  # or: brew install tesseract             # OCR backends (optional)
```

## When to Use (vs Alternatives)

| Feature | This Stack | DocStrange | Unstract MCP |
|---------|-----------|-----------|-------------|
| **Privacy** | Full local via Ollama | Local GPU (CUDA) | Cloud or self-hosted |
| **Schema control** | Pydantic models, custom | JSON schema or field list | Pre-built extractors |
| **PII redaction** | Built-in (Presidio) | Not built-in | Manual |
| **Setup** | `pip install` (3 packages) | `pip install docstrange` | Docker/server required |
| **Best for** | Custom pipelines + PII | Quick extraction, scans | Enterprise workflows |

## Related

- `services/accounting/quickfile.md` — QuickFile MCP (target for extracted data)
- `tools/document/docstrange.md` — Simpler single-install alternative (NanoNets, 7B model)
- `tools/conversion/pandoc.md` — Document format conversion
- `tools/conversion/mineru.md` — PDF to markdown (layout-aware)
- `tools/ocr/overview.md` — OCR tool selection guide
- `tools/ocr/paddleocr.md` — PaddleOCR (screenshots, photos, scanned PDFs)
- `tools/ocr/glm-ocr.md` — Local OCR via Ollama
- `services/document-processing/unstract.md` — Self-hosted document processing
