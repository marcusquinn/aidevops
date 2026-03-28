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

- **Helper**: `scripts/document-extraction-helper.sh`
- **Validation**: `scripts/extraction_pipeline.py` (Pydantic schemas, VAT checks, confidence scoring)
- **Stack**: Docling (parsing) + ExtractThinker (LLM extraction) + Presidio (PII)

## Tool Selection

| Need | Tool | Command |
|------|------|---------|
| Structured extraction + validation | Docling+ExtractThinker+Pipeline | `document-extraction-helper.sh extract file --schema purchase-invoice --privacy local` |
| Classify document type | Classification pipeline | `document-extraction-helper.sh classify file.pdf` |
| Validate extracted JSON | Validation pipeline | `document-extraction-helper.sh validate file.json` |
| Structured extraction + PII redaction | Docling+ExtractThinker+Presidio | `document-extraction-helper.sh extract file --schema invoice --privacy local` |
| Quick extraction, good OCR, no PII | DocStrange | `docstrange file.pdf --output json` |
| Enterprise ETL, visual schema builder | Unstract | `unstract-helper.sh` |
| PDF to markdown (layout-aware) | MinerU | `mineru -p file.pdf -o output/` |
| Simple format conversion | Pandoc | `pandoc-helper.sh convert file.docx` |
| Local OCR only | GLM-OCR | `ollama run glm-ocr "Extract text" --images file.png` |
| Receipt/invoice OCR → QuickFile | OCR Receipt Pipeline | `ocr-receipt-helper.sh extract invoice.pdf` |
| Auto-categorise nominal code | Pipeline utility | `python3 extraction_pipeline.py categorise "Amazon" "office supplies"` |

<!-- AI-CONTEXT-END -->

## Structured Extraction

```bash
# Check available tools and schemas
document-extraction-helper.sh status
document-extraction-helper.sh schemas

# Single document
document-extraction-helper.sh extract invoice.pdf --schema invoice --privacy local

# Batch (output: ~/.aidevops/.agent-workspace/work/document-extraction/)
document-extraction-helper.sh batch ./invoices/ --schema invoice --privacy local

# Auto-detect (markdown, no schema)
document-extraction-helper.sh extract document.pdf

# PII scan/redact (optional)
document-extraction-helper.sh pii-scan extracted-text.txt
document-extraction-helper.sh pii-redact extracted-text.txt --output redacted.txt
```

**Privacy modes:**

| Mode | When |
|------|------|
| `local` | Sensitive (PII, financial, medical) — requires Ollama |
| `edge` | Moderate sensitivity — Cloudflare Workers AI |
| `cloud` | Non-sensitive — best quality via OpenAI/Anthropic |
| `none` | Auto-select best available backend |

## Simple Conversion

```bash
document-extraction-helper.sh convert report.pdf --output markdown  # Docling, layout-aware
pandoc-helper.sh convert report.docx                                 # Pandoc, broader formats
mineru -p paper.pdf -o ./output                                      # MinerU, complex PDF layouts
```

## Pipeline Architecture

```text
Input (PDF/DOCX/Image/HTML)
  → [1. Parse]      Docling | DocStrange | MinerU | Pandoc
  → [2. Classify]   extraction_pipeline.py — weighted keyword scoring
                    types: purchase_invoice | expense_receipt | credit_note | invoice
  → [3. PII Scan]   Presidio — PERSON, EMAIL, PHONE, SSN, CREDIT_CARD, etc. (optional)
  → [4. Anonymize]  Presidio — redact | replace | hash | encrypt (optional)
  → [5. Extract]    ExtractThinker + LLM (Pydantic schema)
                    backends: Gemini Flash → Ollama → OpenAI
  → [6. Validate]   VAT arithmetic, date format, confidence scoring, nominal codes
                    Review flagging: confidence < 0.7 or VAT mismatch
  → [7. Output]     JSON with data + validation summary
  → [8. De-anon]    Presidio decrypt (if step 4 used encryption)
  → [9. Record]     quickfile-helper.sh — supplier resolution + purchase recording (optional)
                    Tools: quickfile_supplier_search, quickfile_purchase_create
```

## Validation Rules

**VAT arithmetic:**
- `subtotal + vat_amount = total` (±2p tolerance)
- VAT claimed without supplier VAT number → warning
- Line items VAT sum must match total VAT (±5p)
- Valid UK rates: 0, 5, 20, exempt, oos, servrc, cisrc, postgoods

**Confidence scoring (per field, 0.0–1.0):**
- Base 0.7: field present and non-empty
- +0.2: matches expected format (valid date, positive amount)
- +0.1: required field present
- <0.5: flagged for manual review

```bash
# Nominal code auto-categorisation
python3 extraction_pipeline.py categorise "Shell" "diesel fuel"
# → {"nominal_code": "7401", "category": "Motor Expenses - Fuel"}

# Standalone validation
document-extraction-helper.sh validate extracted.json --type purchase_invoice
python3 extraction_pipeline.py validate extracted.json --type expense_receipt
```

## Custom Schemas

```python
from pydantic import BaseModel
from extract_thinker import Extractor

class MedicalRecord(BaseModel):
    patient_id: str
    diagnosis: str
    medications: list[str]
    provider: str
    date: str

extractor = Extractor()
extractor.load_document_loader("docling")
extractor.load_llm("ollama/llama3.2")
result = extractor.extract("record.pdf", MedicalRecord)
```

## Tool Comparison

| Feature | Docling+ET+Presidio | DocStrange | Unstract | MinerU | Pandoc |
|---------|-------------------|-----------|---------|--------|--------|
| Structured extraction | Pydantic schemas | JSON schema | Visual builder | No | No |
| PII redaction | Built-in (Presidio) | No | Manual | No | No |
| Local processing | Ollama (CPU/GPU) | GPU (CUDA only) | Docker | GPU/CPU | CPU |
| OCR | Tesseract/EasyOCR | 7B model | LLM-based | 109 languages | pdftotext |
| Formats | PDF/DOCX/PPTX/XLSX/HTML/images | PDF/DOCX/PPTX/XLSX/images/URLs | PDF/DOCX/images | PDF only | 20+ formats |
| Setup | 3 pip installs | 1 pip install | Docker | 1 pip install | brew install |
| Best for | Custom pipelines, PII | Quick extraction | Enterprise ETL | PDF→markdown | Format conversion |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Docling parse failure | `python3 --version` (3.10+ required); `document-extraction-helper.sh install --core` |
| Ollama not responding | `ollama list`; `brew services restart ollama`; `ollama pull llama3.2` |
| PII scan misses entities | `document-extraction-helper.sh install --pii`; `python3 -m spacy validate` |
| Out of memory | Use smaller model (e.g. `phi-4`); process one at a time; use `cloud` privacy mode |

## Related

- `document-extraction.md` — component reference (Docling, ExtractThinker, Presidio)
- `docstrange.md` — DocStrange alternative
- `tools/ocr/glm-ocr.md` — local OCR via Ollama
- `tools/conversion/pandoc.md` — format conversion
- `tools/conversion/mineru.md` — PDF to markdown
- `services/document-processing/unstract.md` — enterprise document processing
- `tools/pdf/overview.md` — PDF manipulation (form filling, signing)
- `business/accounts-receipt-ocr.md` — receipt/invoice OCR with QuickFile
- `todo/tasks/prd-document-extraction.md` — full PRD
