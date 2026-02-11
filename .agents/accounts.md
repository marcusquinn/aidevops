---
name: accounts
description: Financial operations and accounting - QuickFile integration, invoicing, expense tracking
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

**Subagents** (`services/accounting/`):
- `quickfile.md` - QuickFile MCP integration

**Typical Tasks**:
- Invoice management
- Expense tracking
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

### Expense Tracking

- Categorize expenses
- Match bank transactions
- Track by project/client
- VAT handling (UK)

### OCR Receipt/Invoice to Purchase

Automated pipeline for scanning receipts and invoices into QuickFile purchases:

```text
Receipt/Invoice (photo, PDF, scan)
    → document-extraction-helper.sh extract --schema invoice|receipt
    → quickfile-purchase-helper.sh prepare <extracted.json>
    → AI agent reviews payload, matches supplier, selects nominal code
    → User confirms → quickfile_purchase_create (MCP)
```

**Quick commands**:

```bash
# Extract structured data from a receipt image
document-extraction-helper.sh extract receipt.jpg --schema receipt --privacy local

# Prepare QuickFile purchase payload from extraction output
quickfile-purchase-helper.sh prepare receipt-extracted.json

# Batch process a folder of invoices
document-extraction-helper.sh batch ./invoices --schema invoice
quickfile-purchase-helper.sh batch ~/.aidevops/.agent-workspace/work/document-extraction/
```

**Agent workflow** (after payload is prepared):

1. Search for supplier: `quickfile_supplier_search`
2. Create supplier if not found: `quickfile_supplier_create`
3. Review nominal codes (default 5000 — Cost of Sales)
4. Confirm line items and totals with user
5. Create purchase: `quickfile_purchase_create`

See `scripts/quickfile-purchase-helper.sh` for payload preparation and
`tools/document/extraction-workflow.md` for the full extraction pipeline.

### Reporting

- Profit and loss
- Balance sheet
- VAT returns
- Cash flow

### Integration Points

- `sales.md` - Quote to invoice
- `services/` - Project-based billing

*See `services/accounting/quickfile.md` for detailed QuickFile operations.*
