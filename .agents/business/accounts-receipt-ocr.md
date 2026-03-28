---
description: OCR receipt and invoice extraction pipeline with QuickFile integration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
  quickfile_*: true
---

# Receipt/Invoice OCR Pipeline

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract structured data from receipts/invoices via OCR, validate, optionally record in QuickFile
- **Helper**: `scripts/ocr-receipt-helper.sh`
- **Validation**: `scripts/extraction_pipeline.py` (Pydantic schemas, VAT checks, confidence scoring)
- **OCR**: GLM-OCR via Ollama (local, no API keys)
- **Extraction**: llama3.2 via Ollama (structured parsing) or Docling + ExtractThinker (PDFs)
- **Accounting**: QuickFile MCP (`quickfile_purchase_create`, `quickfile_supplier_search`)

| Need | Command |
|------|---------|
| Raw text from image | `ocr-receipt-helper.sh scan photo.jpg` |
| Structured JSON | `ocr-receipt-helper.sh extract file` |
| Validate extracted JSON | `ocr-receipt-helper.sh validate file.json` |
| Batch process folder | `ocr-receipt-helper.sh batch ~/receipts/` |
| Create QuickFile purchase | `ocr-receipt-helper.sh quickfile file` |
| Preview QuickFile payload | `ocr-receipt-helper.sh preview file` |
| Classify document type | `document-extraction-helper.sh classify file` |
| Complex PDF with tables | `document-extraction-helper.sh extract file --schema purchase-invoice` |

<!-- AI-CONTEXT-END -->

## Pipeline

```text
Input (photo/scan/PDF)
     → [1. OCR] GLM-OCR via Ollama (~2GB, local)
     → [2. Classify] Weighted keyword scoring (extraction_pipeline.py)
         purchase_invoice | expense_receipt | credit_note
     → [3. Extract] llama3.2 (Ollama) or Docling+ExtractThinker (PDFs)
         Schema: PurchaseInvoice or ExpenseReceipt (Pydantic)
     → [4. Validate] extraction_pipeline.py
         VAT arithmetic, date format, per-field confidence (0.0-1.0), nominal codes
     → [5. Output] JSON + validation summary
         Flags requires_review if confidence < 0.7 or VAT mismatch
     → [6. QuickFile] quickfile-helper.sh (t012.4)
         Supplier resolution + purchase invoice creation
```

## Supported Formats

| Format | Method | Notes |
|--------|--------|-------|
| Images (PNG, JPG, TIFF, BMP, WebP, HEIC) | GLM-OCR direct | Best for phone photos |
| PDF | ImageMagick → GLM-OCR per page | Requires `brew install imagemagick` |
| Documents (DOCX, XLSX, HTML) | `document-extraction-helper.sh` | Docling + ExtractThinker |

## Extraction Schemas

### Invoice

```json
{
  "vendor_name": "string", "vendor_address": "string",
  "invoice_number": "string", "invoice_date": "YYYY-MM-DD", "due_date": "YYYY-MM-DD",
  "currency": "GBP", "subtotal": 0.00, "tax_amount": 0.00, "tax_rate": 20, "total": 0.00,
  "line_items": [{"description": "string", "quantity": 0, "unit_price": 0.00, "amount": 0.00}],
  "payment_method": null
}
```

### Receipt

```json
{
  "merchant": "string", "merchant_address": "string",
  "date": "YYYY-MM-DD", "currency": "GBP",
  "subtotal": 0.00, "tax_amount": 0.00, "total": 0.00,
  "payment_method": "contactless",
  "items": [{"name": "string", "quantity": 0, "price": 0.00}]
}
```

## QuickFile Integration

The `quickfile` command extracts data and generates MCP recording instructions via `quickfile-helper.sh` (t012.4):

```bash
# Full pipeline (extract + prepare + record):
ocr-receipt-helper.sh quickfile invoice.pdf

# Direct recording with pre-extracted JSON:
quickfile-helper.sh record-purchase invoice-quickfile.json
quickfile-helper.sh record-expense receipt-quickfile.json --auto-supplier

# Batch + preview:
quickfile-helper.sh batch-record ~/.aidevops/.agent-workspace/work/ocr-receipts/
quickfile-helper.sh preview invoice-quickfile.json
```

**MCP tool flow**: `quickfile_supplier_search` → `quickfile_supplier_create` (if new) → `quickfile_purchase_create` with mapped line items, VAT, nominal codes. `record-expense` infers nominal codes from merchant/item patterns.

### Common Nominal Codes (UK)

| Code | Category | Code | Category |
|------|----------|------|----------|
| 5000 | General Purchases | 7404 | Computer Software |
| 7400 | Travel & Subsistence | 7501 | Postage & Shipping |
| 7401 | Motor Expenses - Fuel | 7502 | Telephone & Internet |
| 7402 | Subsistence (meals) | 7504 | Stationery & Office Supplies |
| 7403 | Hotel & Accommodation | 6201 | Advertising & Marketing |
| 7600 | Professional Fees | | |

## Privacy Modes

| Mode | OCR | Extraction LLM | Data Leaves Machine? |
|------|-----|----------------|---------------------|
| **local** (default) | GLM-OCR (Ollama) | llama3.2 (Ollama) | No |
| **edge** | GLM-OCR (Ollama) | Cloudflare Workers AI | Extraction only |
| **cloud** | GLM-OCR (Ollama) | OpenAI/Anthropic | Extraction only |
| **none** | GLM-OCR (Ollama) | Auto-select best | Depends |

OCR always runs locally. Only structured extraction can optionally use cloud LLMs.

## Installation

```bash
ocr-receipt-helper.sh install          # Ollama + GLM-OCR + llama3.2 + ImageMagick
document-extraction-helper.sh install --core  # Optional: Pydantic schemas for PDFs
ocr-receipt-helper.sh status           # Verify
```

| Component | Purpose | Install |
|-----------|---------|---------|
| Ollama | LLM runtime | `brew install ollama` |
| GLM-OCR | OCR model (~2GB) | `ollama pull glm-ocr` |
| llama3.2 | Structured extraction | `ollama pull llama3.2` |
| ImageMagick | PDF→image conversion | `brew install imagemagick` |
| Python 3.10+ | Docling/ExtractThinker (optional) | System or `brew install python` |

## Troubleshooting

- **Garbled OCR**: Ensure ≥150 DPI (300 for scans). Crop to receipt area. Upscale small text.
- **Wrong fields**: Specify `--type invoice` or `--type receipt` explicitly. Check raw OCR first with `scan`. For complex tables, use `document-extraction-helper.sh extract file --schema invoice`.
- **PDF fails**: Install ImageMagick + Ghostscript (`brew install imagemagick ghostscript`). Text-based PDFs: use `document-extraction-helper.sh` directly.
- **QuickFile data wrong**: Use `preview` first. Override with `--supplier`, `--nominal`, `--currency`.

## Related

- `scripts/ocr-receipt-helper.sh` — CLI helper
- `tools/ocr/glm-ocr.md` — GLM-OCR model reference
- `tools/document/extraction-workflow.md` — General document extraction
- `tools/document/document-extraction.md` — Docling + ExtractThinker + Presidio
- `services/accounting/quickfile.md` — QuickFile MCP integration
- `business/accounts-subscription-audit.md` — Subscription tracking from receipts
