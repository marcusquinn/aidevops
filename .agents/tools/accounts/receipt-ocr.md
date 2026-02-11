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

- **Purpose**: Extract structured data from receipts and invoices via OCR, with optional QuickFile purchase invoice creation
- **Helper**: `scripts/ocr-receipt-helper.sh`
- **OCR Engine**: GLM-OCR via Ollama (local, no API keys)
- **Extraction**: llama3.2 via Ollama (structured parsing) or Docling + ExtractThinker (PDF/documents)
- **Accounting**: QuickFile MCP (`quickfile_purchase_create`, `quickfile_supplier_search`)

**Quick start**:

```bash
# Install dependencies
ocr-receipt-helper.sh install

# Scan a receipt (raw OCR text)
ocr-receipt-helper.sh scan receipt.jpg

# Extract structured data (auto-detects invoice vs receipt)
ocr-receipt-helper.sh extract invoice.pdf

# Preview QuickFile purchase invoice (dry run)
ocr-receipt-helper.sh preview receipt.png --supplier "Amazon UK"

# Generate QuickFile-ready JSON
ocr-receipt-helper.sh quickfile invoice.pdf --nominal 7502
```

**Decision tree** - pick the right command:

| Need | Command |
|------|---------|
| Quick text dump from image | `ocr-receipt-helper.sh scan photo.jpg` |
| Structured JSON from receipt/invoice | `ocr-receipt-helper.sh extract file` |
| Process a folder of receipts | `ocr-receipt-helper.sh batch ~/receipts/` |
| Create QuickFile purchase invoice | `ocr-receipt-helper.sh quickfile file` |
| Check what would be sent to QuickFile | `ocr-receipt-helper.sh preview file` |
| Complex PDF with tables/forms | `document-extraction-helper.sh extract file --schema invoice` |

<!-- AI-CONTEXT-END -->

## Pipeline Architecture

```text
Input (photo/scan/PDF)
         |
    [1. OCR]  ── GLM-OCR via Ollama (~2GB, local)
         |        Prompt: "Extract all text from this receipt/invoice"
         |
    [2. Type Detection]  ── Heuristic scoring
         |                   Invoice: invoice number, due date, PO, bill-to
         |                   Receipt: receipt, cash/card, change, thank you
         |
    [3. Structured Extraction]  ── llama3.2 via Ollama (local)
         |                          or Docling + ExtractThinker (for PDFs)
         |                          Schema: Invoice or Receipt (Pydantic)
         |
    [4. Output]  ── JSON with vendor, date, items, totals, VAT
         |
    [5. QuickFile]  ── (optional) Supplier lookup/create + purchase invoice
                       Tools: quickfile_supplier_search, quickfile_purchase_create
```

## Supported Input Formats

| Format | Method | Notes |
|--------|--------|-------|
| **Images** (PNG, JPG, TIFF, BMP, WebP, HEIC) | GLM-OCR direct | Best for phone photos of receipts |
| **PDF** | ImageMagick → GLM-OCR per page | Requires `brew install imagemagick` |
| **Documents** (DOCX, XLSX, HTML) | Delegates to `document-extraction-helper.sh` | Uses Docling + ExtractThinker |

## Extraction Schemas

### Invoice Schema

```json
{
  "vendor_name": "Acme Ltd",
  "vendor_address": "123 Business St, London",
  "invoice_number": "INV-2024-001",
  "invoice_date": "2024-03-15",
  "due_date": "2024-04-14",
  "currency": "GBP",
  "subtotal": 100.00,
  "tax_amount": 20.00,
  "tax_rate": 20,
  "total": 120.00,
  "line_items": [
    {
      "description": "Consulting services",
      "quantity": 8,
      "unit_price": 12.50,
      "amount": 100.00
    }
  ],
  "payment_method": null
}
```

### Receipt Schema

```json
{
  "merchant": "Tesco Express",
  "merchant_address": "45 High Street",
  "date": "2024-03-15",
  "currency": "GBP",
  "subtotal": 8.50,
  "tax_amount": 0,
  "total": 8.50,
  "payment_method": "contactless",
  "items": [
    {"name": "Milk 2L", "quantity": 1, "price": 1.50},
    {"name": "Bread", "quantity": 2, "price": 1.20},
    {"name": "Coffee", "quantity": 1, "price": 4.60}
  ]
}
```

## QuickFile Integration

The `quickfile` command generates a JSON file ready for the QuickFile MCP tools:

```text
ocr-receipt-helper.sh quickfile invoice.pdf
  → Extracts structured data
  → Generates ~/.aidevops/.agent-workspace/work/ocr-receipts/{name}-quickfile.json
  → Provides AI prompt to create the purchase invoice via MCP tools
```

### QuickFile Workflow (AI-Assisted)

After running `quickfile`, prompt the AI assistant:

1. **Supplier lookup**: `quickfile_supplier_search` with the extracted vendor name
2. **Supplier creation** (if new): `quickfile_supplier_create` with vendor details
3. **Purchase invoice**: `quickfile_purchase_create` with extracted line items, amounts, VAT
4. **Nominal codes**: Use `quickfile_report_chart_of_accounts` to find the right code

### Common Nominal Codes (UK)

| Code | Category |
|------|----------|
| 7901 | General Purchases |
| 7502 | Office Supplies |
| 7501 | Postage & Delivery |
| 7400 | Travel & Subsistence |
| 7304 | Software & IT |
| 7200 | Advertising & Marketing |
| 7100 | Rent |
| 7003 | Subcontractors |

## Privacy Modes

| Mode | OCR | Extraction LLM | Data Leaves Machine? |
|------|-----|----------------|---------------------|
| **local** (default) | GLM-OCR (Ollama) | llama3.2 (Ollama) | No |
| **edge** | GLM-OCR (Ollama) | Cloudflare Workers AI | Extraction only |
| **cloud** | GLM-OCR (Ollama) | OpenAI/Anthropic | Extraction only |
| **none** | GLM-OCR (Ollama) | Auto-select best | Depends |

OCR always runs locally via GLM-OCR. Only the structured extraction step can optionally use cloud LLMs for better accuracy.

## Installation

```bash
# Install OCR pipeline (Ollama + GLM-OCR + llama3.2 + ImageMagick)
ocr-receipt-helper.sh install

# For structured extraction with Pydantic schemas (optional, for PDFs)
document-extraction-helper.sh install --core

# Check everything is working
ocr-receipt-helper.sh status
```

### Requirements

| Component | Purpose | Install |
|-----------|---------|---------|
| Ollama | LLM runtime | `brew install ollama` |
| GLM-OCR | OCR model (~2GB) | `ollama pull glm-ocr` |
| llama3.2 | Structured extraction | `ollama pull llama3.2` |
| ImageMagick | PDF to image conversion | `brew install imagemagick` |
| Python 3.10+ | Docling/ExtractThinker (optional) | System or `brew install python` |

## Troubleshooting

### OCR returns garbled text

- Ensure image resolution is at least 150 DPI (300 DPI for scans)
- Crop to the receipt/invoice area (remove background)
- Try a different angle or lighting for phone photos
- For very small text, upscale the image first

### Structured extraction returns wrong fields

- Specify `--type invoice` or `--type receipt` explicitly instead of auto-detect
- Check the raw OCR output first: `ocr-receipt-helper.sh scan file.jpg`
- For complex invoices with tables, use `document-extraction-helper.sh extract file --schema invoice`

### PDF OCR fails

- Ensure ImageMagick is installed: `brew install imagemagick`
- Check Ghostscript is available (needed by ImageMagick for PDF): `brew install ghostscript`
- For text-based PDFs (not scanned), use `document-extraction-helper.sh` directly

### QuickFile data looks wrong

- Use `preview` command first to check: `ocr-receipt-helper.sh preview file`
- Override supplier name: `--supplier "Correct Name"`
- Override nominal code: `--nominal 7502`
- Check currency: `--currency GBP`

## Related

- `scripts/ocr-receipt-helper.sh` - CLI helper script
- `tools/ocr/glm-ocr.md` - GLM-OCR model reference
- `tools/document/extraction-workflow.md` - General document extraction workflow
- `tools/document/document-extraction.md` - Docling + ExtractThinker + Presidio
- `services/accounting/quickfile.md` - QuickFile MCP integration
- `tools/accounts/subscription-audit.md` - Subscription tracking from receipts
