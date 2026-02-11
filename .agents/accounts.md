---
name: accounts
description: Financial operations and accounting - QuickFile integration, OCR extraction, invoicing, expense tracking
mode: subagent
subagents:
  - quickfile
  - general
  - explore
---

# Accounts - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Financial operations and accounting
- **Primary Tool**: QuickFile (UK accounting)
- **OCR Extraction**: `document-extraction-helper.sh` (invoice/receipt scanning)

**Subagents** (`services/accounting/`):

- `quickfile.md` - QuickFile MCP integration

**Scripts**:

- `document-extraction-helper.sh` - OCR extraction pipeline (invoices, receipts)

**Typical Tasks**:

- Invoice management
- Expense tracking from receipts/invoices (OCR)
- Financial reporting
- Client/supplier management
- Bank reconciliation

<!-- AI-CONTEXT-END -->

## Pre-flight Questions

Before generating financial or accounting output, work through:

1. How would this look to a tax inspector, investor, or lender reviewing the books?
2. What is the tax treatment — and in which jurisdiction(s)?
3. Are we recording substance or just form — does this reflect economic reality?
4. What audit trail exists to support every figure?
5. What would change if the business were investigated, sold, or seeking funding tomorrow?

## Accounting Workflows

### OCR Invoice/Receipt Extraction

Extract structured data from scanned invoices, photographed receipts, and PDF documents. Output is QuickFile-ready JSON with field mapping hints.

**Quick start:**

```bash
# Auto-classify and extract (recommended)
document-extraction-helper.sh accounting-extract invoice.pdf

# Extract with explicit schema
document-extraction-helper.sh extract receipt.jpg --schema receipt --privacy local

# Classify a document first
document-extraction-helper.sh classify unknown-doc.pdf

# Watch a folder for new receipts (e.g. phone camera uploads)
document-extraction-helper.sh watch ~/Downloads/receipts --interval 30

# Batch process a folder of invoices
document-extraction-helper.sh batch ./invoices --schema invoice
```

**Supported formats**: PDF, DOCX, PPTX, XLSX, HTML, PNG, JPG, JPEG, TIFF, BMP

**Privacy modes**:

| Mode | Backend | Data leaves machine? |
|------|---------|---------------------|
| `local` | Ollama (llama3.2) | No |
| `edge` | Cloudflare Workers AI | Encrypted transit |
| `cloud` | OpenAI (gpt-4o) | Yes |
| `none` | Auto-select (prefers local) | Depends |

**Invoice schema** extracts: vendor/customer details, VAT numbers, company numbers, line items with VAT rates, tax breakdowns by rate, payment terms, PO numbers, multi-currency (GBP default).

**Receipt schema** extracts: merchant details, items with quantities and VAT codes, payment method, card last four, store/cashier info.

**Workflow: Receipt to QuickFile expense**:

1. Photograph/scan receipt
2. `document-extraction-helper.sh accounting-extract receipt.jpg --privacy local`
3. Review extracted JSON (includes `quickfile_mapping` with field hints)
4. Use QuickFile MCP to create expense: `quickfile.md` POST /expense/create

**Workflow: Watch folder for automated processing**:

1. `document-extraction-helper.sh watch ~/Downloads/receipts`
2. Drop files into the folder (e.g. AirDrop from phone)
3. Pipeline auto-classifies, extracts, and saves QuickFile-ready JSON
4. Review outputs in `~/.aidevops/.agent-workspace/work/document-extraction/`

**Setup**: `document-extraction-helper.sh install --core` (Docling + ExtractThinker), then `install --llm` for local Ollama.

See `tools/document/document-extraction.md` for component details and `tools/document/extraction-workflow.md` for pipeline architecture.

### QuickFile Integration

Use `services/accounting/quickfile.md` for:

- Creating and sending invoices
- Recording expenses
- Managing clients and suppliers
- Bank transaction matching
- Financial reports

### Invoice Management

- Create invoices from quotes
- Track payment status
- Send reminders
- Record payments
- **OCR extraction** from scanned/photographed invoices

### Expense Tracking

- Categorize expenses
- Match bank transactions
- Track by project/client
- VAT handling (UK)
- **OCR extraction** from receipts (auto-classify, extract, QuickFile-ready)

### Reporting

- Profit and loss
- Balance sheet
- VAT returns
- Cash flow

### Integration Points

- `sales.md` - Quote to invoice
- `services/` - Project-based billing
- `document-extraction-helper.sh` - OCR invoice/receipt extraction
- `tools/document/document-extraction.md` - Extraction pipeline reference

*See `services/accounting/quickfile.md` for detailed QuickFile operations.*
