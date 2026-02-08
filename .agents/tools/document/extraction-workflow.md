---
description: Document extraction workflow orchestration - tool selection and pipeline guidance
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Document Extraction Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Orchestrate document extraction - select tools, run pipelines, handle PII
- **Helper**: `scripts/document-extraction-helper.sh`
- **Stack**: Docling (parsing) + ExtractThinker (LLM extraction) + Presidio (PII)
- **Alternatives**: DocStrange (simpler), Unstract (enterprise), MinerU (PDF-only), Pandoc (basic)

**Decision tree** - pick the right tool:

| Need | Tool | Command |
|------|------|---------|
| Structured extraction with PII redaction | Docling+ExtractThinker+Presidio | `document-extraction-helper.sh extract file --schema invoice --privacy local` |
| Quick extraction, good OCR, no PII needs | DocStrange | `docstrange file.pdf --output json` |
| Enterprise ETL, visual schema builder | Unstract | `unstract-helper.sh` |
| PDF to markdown (layout-aware) | MinerU | `mineru -p file.pdf -o output/` |
| Simple format conversion | Pandoc | `pandoc-helper.sh convert file.docx` |
| Local OCR only | GLM-OCR | `ollama run glm-ocr "Extract text" --images file.png` |

<!-- AI-CONTEXT-END -->

## Workflow: Structured Extraction

Use this workflow when you need typed, schema-validated output from documents.

### Step 1: Assess the Document

```bash
# Check what tools are available
document-extraction-helper.sh status

# Determine document type and choose schema
document-extraction-helper.sh schemas
```

### Step 2: Choose Privacy Mode

| Mode | When to Use |
|------|-------------|
| `local` | Sensitive documents (PII, financial, medical). Requires Ollama. |
| `edge` | Moderate sensitivity. Uses Cloudflare Workers AI. |
| `cloud` | Non-sensitive. Best extraction quality via OpenAI/Anthropic. |
| `none` | Auto-select best available backend. |

### Step 3: Extract

```bash
# Single document with schema
document-extraction-helper.sh extract invoice.pdf --schema invoice --privacy local

# Batch processing
document-extraction-helper.sh batch ./invoices/ --schema invoice --privacy local

# Auto-detect (converts to markdown, no schema)
document-extraction-helper.sh extract document.pdf
```

### Step 4: PII Handling (Optional)

```bash
# Scan for PII before sharing
document-extraction-helper.sh pii-scan extracted-text.txt

# Redact PII
document-extraction-helper.sh pii-redact extracted-text.txt --output redacted.txt
```

## Workflow: Simple Conversion

Use this when you just need readable text/markdown from a document, no structured extraction.

```bash
# Convert to markdown (Docling - layout-aware)
document-extraction-helper.sh convert report.pdf --output markdown

# Convert to markdown (Pandoc - simpler, broader format support)
pandoc-helper.sh convert report.docx

# Convert PDF with complex layout (MinerU - best for academic papers)
mineru -p paper.pdf -o ./output
```

## Workflow: Batch Processing

```bash
# Extract all invoices in a directory
document-extraction-helper.sh batch ./documents --schema invoice --privacy local

# Convert all documents to markdown
document-extraction-helper.sh batch ./documents --pattern "*.pdf"

# Output goes to: ~/.aidevops/.agent-workspace/work/document-extraction/
```

## Pipeline Architecture

```text
Document Input (PDF/DOCX/Image/HTML)
         |
    [1. Parse]  ── Docling (layout, tables, OCR)
         |            or DocStrange (simpler)
         |            or MinerU (PDF-only, layout-aware)
         |            or Pandoc (basic conversion)
         |
    [2. PII Scan]  ── Presidio (optional)
         |              Detect: PERSON, EMAIL, PHONE, SSN, CREDIT_CARD, etc.
         |
    [3. Anonymize]  ── Presidio (optional)
         |              Operators: redact, replace, hash, encrypt
         |
    [4. Extract]  ── ExtractThinker + LLM
         |             Schema: Pydantic model (invoice, receipt, contract, etc.)
         |             Backend: Ollama (local), Cloudflare (edge), OpenAI (cloud)
         |
    [5. Output]  ── JSON, Markdown, CSV
         |
    [6. De-anonymize]  ── Presidio decrypt (if encrypted in step 3)
```

## Custom Schemas

Define Pydantic models for domain-specific extraction:

```python
from pydantic import BaseModel

class MedicalRecord(BaseModel):
    patient_id: str
    diagnosis: str
    medications: list[str]
    provider: str
    date: str

# Use with ExtractThinker
from extract_thinker import Extractor

extractor = Extractor()
extractor.load_document_loader("docling")
extractor.load_llm("ollama/llama3.2")

result = extractor.extract("record.pdf", MedicalRecord)
print(result.model_dump_json(indent=2))
```

## Tool Comparison Matrix

| Feature | Docling+ET+Presidio | DocStrange | Unstract | MinerU | Pandoc |
|---------|-------------------|-----------|---------|--------|--------|
| **Structured extraction** | Pydantic schemas | JSON schema/fields | Visual builder | No | No |
| **PII redaction** | Built-in (Presidio) | No | Manual | No | No |
| **Local processing** | Ollama (CPU/GPU) | GPU (CUDA only) | Docker | GPU/CPU | CPU |
| **OCR** | Tesseract/EasyOCR | 7B model | LLM-based | 109 languages | pdftotext |
| **Formats** | PDF/DOCX/PPTX/XLSX/HTML/images | PDF/DOCX/PPTX/XLSX/images/URLs | PDF/DOCX/images | PDF only | 20+ formats |
| **Setup complexity** | 3 pip installs | 1 pip install | Docker | 1 pip install | brew install |
| **Best for** | Custom pipelines, PII | Quick extraction | Enterprise ETL | PDF to markdown | Format conversion |

## Troubleshooting

### Docling fails to parse

```bash
# Check Python version (3.10+ required)
python3 --version

# Reinstall core
document-extraction-helper.sh install --core
```

### Ollama model not responding

```bash
# Check Ollama is running
ollama list

# Restart Ollama
brew services restart ollama

# Pull model if missing
ollama pull llama3.2
```

### PII scan misses entities

```bash
# Ensure spaCy model is installed
document-extraction-helper.sh install --pii

# Check model
python3 -m spacy validate
```

### Out of memory during extraction

- Use smaller Ollama models (e.g., `phi-4` instead of `llama3.2:70b`)
- Process documents one at a time instead of batch
- Use `cloud` privacy mode to offload to API

## Related

- `document-extraction.md` - Component reference (Docling, ExtractThinker, Presidio)
- `docstrange.md` - DocStrange alternative (simpler, single install)
- `tools/ocr/glm-ocr.md` - Local OCR via Ollama
- `tools/conversion/pandoc.md` - Document format conversion
- `tools/conversion/mineru.md` - PDF to markdown (layout-aware)
- `services/document-processing/unstract.md` - Enterprise document processing
- `tools/pdf/overview.md` - PDF manipulation (form filling, signing)
- `todo/tasks/prd-document-extraction.md` - Full PRD
