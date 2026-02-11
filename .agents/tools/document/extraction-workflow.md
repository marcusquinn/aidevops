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

- **Purpose**: Orchestrate document extraction - select tools, run pipelines, validate output
- **Helper**: `scripts/document-extraction-helper.sh`
- **Validation**: `scripts/extraction_pipeline.py` (Pydantic schemas, VAT checks, confidence scoring)
- **Stack**: Docling (parsing) + ExtractThinker (LLM extraction) + Presidio (PII)
- **Alternatives**: DocStrange (simpler), Unstract (enterprise), MinerU (PDF-only), Pandoc (basic)

**Decision tree** - pick the right tool:

| Need | Tool | Command |
|------|------|---------|
| Structured extraction with validation | Docling+ExtractThinker+Pipeline | `document-extraction-helper.sh extract file --schema purchase-invoice --privacy local` |
| Classify document type | Classification pipeline | `document-extraction-helper.sh classify file.pdf` |
| Validate extracted JSON | Validation pipeline | `document-extraction-helper.sh validate file.json` |
| Structured extraction with PII redaction | Docling+ExtractThinker+Presidio | `document-extraction-helper.sh extract file --schema invoice --privacy local` |
| Quick extraction, good OCR, no PII needs | DocStrange | `docstrange file.pdf --output json` |
| Enterprise ETL, visual schema builder | Unstract | `unstract-helper.sh` |
| PDF to markdown (layout-aware) | MinerU | `mineru -p file.pdf -o output/` |
| Simple format conversion | Pandoc | `pandoc-helper.sh convert file.docx` |
| Local OCR only | GLM-OCR | `ollama run glm-ocr "Extract text" --images file.png` |
| Receipt/invoice OCR → QuickFile | OCR Receipt Pipeline | `ocr-receipt-helper.sh extract invoice.pdf` |
| Auto-categorise nominal code | Pipeline utility | `python3 extraction_pipeline.py categorise "Amazon" "office supplies"` |

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
    [2. Classify]  ── extraction_pipeline.py classify
         |              Weighted keyword scoring
         |              purchase_invoice | expense_receipt | credit_note | invoice
         |
    [3. PII Scan]  ── Presidio (optional)
         |              Detect: PERSON, EMAIL, PHONE, SSN, CREDIT_CARD, etc.
         |
    [4. Anonymize]  ── Presidio (optional)
         |              Operators: redact, replace, hash, encrypt
         |
    [5. Extract]  ── ExtractThinker + LLM
         |             Schema: Pydantic model (PurchaseInvoice, ExpenseReceipt, etc.)
         |             Backend: Gemini Flash (cloud) -> Ollama (local) -> OpenAI (fallback)
         |
    [6. Validate]  ── extraction_pipeline.py validate
         |              VAT arithmetic (subtotal + VAT = total within 2p tolerance)
         |              Date format validation (YYYY-MM-DD)
         |              Per-field confidence scoring (0.0-1.0)
         |              Nominal code auto-categorisation
         |              Review flagging (confidence < 0.7 or VAT mismatch)
         |
     [7. Output]  ── JSON with data + validation summary
         |
     [8. De-anonymize]  ── Presidio decrypt (if encrypted in step 4)
         |
     [9. Record]  ── (optional) quickfile-helper.sh
                     Supplier resolution + purchase/expense recording
                     Tools: quickfile_supplier_search, quickfile_purchase_create
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

## Validation Pipeline

The extraction pipeline includes automatic validation via `extraction_pipeline.py`:

### VAT Arithmetic Checks

```text
Rule 1: subtotal + vat_amount must equal total (within 2p tolerance)
Rule 2: VAT claimed without supplier VAT number triggers warning
Rule 3: Line items VAT sum must match total VAT (within 5p tolerance)
Rule 4: VAT rates must be valid UK rates (0, 5, 20, exempt, oos, servrc, cisrc, postgoods)
```

### Confidence Scoring

Each extracted field gets a confidence score (0.0-1.0):

- **0.7+**: Field present and non-empty (base score)
- **+0.2**: Field matches expected format (valid date, positive amount)
- **+0.1**: Required field is present
- **< 0.5**: Flagged for manual review

### Nominal Code Auto-Categorisation

When no nominal code is extracted, the pipeline infers from vendor/item patterns:

```bash
# Example: auto-categorise from vendor name
python3 extraction_pipeline.py categorise "Shell" "diesel fuel"
# Output: {"nominal_code": "7401", "category": "Motor Expenses - Fuel"}
```

### Standalone Validation

```bash
# Validate an already-extracted JSON file
document-extraction-helper.sh validate extracted.json --type purchase_invoice

# Or directly via Python
python3 extraction_pipeline.py validate extracted.json --type expense_receipt
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
- `tools/accounts/receipt-ocr.md` - Receipt/invoice OCR with QuickFile integration
- `todo/tasks/prd-document-extraction.md` - Full PRD
