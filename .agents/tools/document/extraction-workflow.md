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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Document Extraction Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `scripts/document-extraction-helper.sh`
- **Validation**: `scripts/extraction_pipeline.py` (Pydantic schemas, VAT checks, confidence scoring)
- **Stack**: Docling (parsing) + ExtractThinker (LLM extraction) + Presidio (PII)

## Tool Selection

| Need | Tool | Command |
|------|------|---------|
| Structured extraction (± PII) | Docling+ET (ExtractThinker)+Pipeline | `document-extraction-helper.sh extract file --schema invoice --privacy local` |
| Classify document type | Classification pipeline | `document-extraction-helper.sh classify file.pdf` |
| Validate extracted JSON | Validation pipeline | `document-extraction-helper.sh validate file.json` |
| Quick extraction, good OCR | DocStrange | `docstrange file.pdf --output json` |
| Enterprise ETL | Unstract | `unstract-helper.sh` |
| PDF → MD (layout-aware) | MinerU | `mineru -p file.pdf -o output/` |
| Format conversion | Pandoc | `pandoc-helper.sh convert file.docx` |
| Local OCR only | GLM-OCR | `ollama run glm-ocr "Extract text" --images file.png` |
| Receipt → QuickFile | OCR Receipt Pipeline | `ocr-receipt-helper.sh extract invoice.pdf` |
| Categorise nominal code | Pipeline utility | `python3 extraction_pipeline.py categorise "Amazon" "office supplies"` |
| Layout-aware conversion | Docling | `document-extraction-helper.sh convert report.pdf --output markdown` |

<!-- AI-CONTEXT-END -->

**Privacy modes:** `local` (Ollama) · `edge` (CF Workers AI) · `cloud` (OpenAI/Anthropic) · `none` (auto)

**Batch:** `document-extraction-helper.sh batch ./invoices/ --schema invoice --privacy local`

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
```

## Validation Rules

**VAT arithmetic:** `subtotal + vat_amount = total` (±2p). VAT claimed without supplier VAT number → warning. Line items VAT sum must match total VAT (±5p). Valid UK rates: 0, 5, 20, exempt, oos, servrc, cisrc, postgoods.

**Confidence scoring (0.0-1.0):** Base 0.7 (present+non-empty) + 0.2 (format) + 0.1 (required). <0.5 → manual review.

## Custom Schemas

Define a Pydantic `BaseModel`, then extract:

```python
from pydantic import BaseModel
from extract_thinker import Extractor

class MyDoc(BaseModel):
    field_a: str
    field_b: list[str]

extractor = Extractor()
extractor.load_document_loader("docling")
extractor.load_llm("ollama/llama3.2")
result = extractor.extract("file.pdf", MyDoc)
```

## Tool Comparison

| Feature | Docling+ET+Presidio | DocStrange | Unstract | MinerU | Pandoc |
|---------|---------------------|------------|----------|--------|--------|
| Structured | Pydantic schemas | JSON schema | Visual builder | No | No |
| PII | Built-in (Presidio) | No | Manual | No | No |
| Local | Ollama (CPU/GPU) | GPU (CUDA) | Docker | GPU/CPU | CPU |
| OCR | Tesseract/EasyOCR | 7B model | LLM-based | 109 languages | pdftotext |
| Formats | PDF/DOCX/PPTX/XLSX/HTML/images | PDF/DOCX/PPTX/XLSX/images/URLs | PDF/DOCX/images | PDF only | 20+ formats |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Docling parse failure | `python3 --version` (3.10+); `document-extraction-helper.sh install --core` |
| Ollama not responding | `ollama list`; `brew services restart ollama`; `ollama pull llama3.2` |
| PII scan misses entities | `document-extraction-helper.sh install --pii`; `python3 -m spacy validate` |
| Out of memory | Use smaller model (e.g. `phi-4`); process one at a time; switch to `cloud` privacy |

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
