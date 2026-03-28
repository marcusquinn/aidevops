---
description: Extraction schema contracts for OCR invoice/receipt pipeline - Pydantic models with QuickFile mapping
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Extraction Schemas

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Pipeline**: Docling (parse) -> ExtractThinker (extract) -> QuickFile (record)
- **Helper**: `document-extraction-helper.sh extract file.pdf --schema <name>`

| Document Type | Schema | QuickFile Target |
|---------------|--------|-----------------|
| Supplier invoice (formal, with invoice number) | `purchase-invoice` | `quickfile_purchase_create` |
| Till/shop receipt (informal, no invoice number) | `expense-receipt` | `quickfile_purchase_create` |
| Sales invoice (you issued it) | `invoice` | `quickfile_invoice_create` |
| Credit note from supplier | `credit-note` | `quickfile_purchase_create` (negative) |
| Generic receipt (non-accounting) | `receipt` | N/A |

<!-- AI-CONTEXT-END -->

## Chapter Index

Full schema definitions, field mappings, and reference data in focused chapters:

| # | Chapter | Description |
|---|---------|-------------|
| 01 | [Design Principles](extraction-schemas/01-design-principles.md) | 8 schema design rules (field naming, types, VAT, confidence) |
| 02 | [Purchase Invoice](extraction-schemas/02-purchase-invoice.md) | `PurchaseInvoice` + `VatRate` enum + `PurchaseLineItem` — full Pydantic models |
| 03 | [Expense Receipt](extraction-schemas/03-expense-receipt.md) | `ExpenseReceipt` + `ExpenseCategory` enum + `ReceiptItem` — full Pydantic models |
| 04 | [Credit Note](extraction-schemas/04-credit-note.md) | `CreditNote` model (reuses `PurchaseLineItem`) |
| 05 | [Sales Invoice](extraction-schemas/05-sales-invoice.md) | `Invoice` + `SalesLineItem` — full Pydantic models |
| 06 | [Generic Receipt](extraction-schemas/06-generic-receipt.md) | `Receipt` model (non-accounting, reuses `ReceiptItem`) |
| 07 | [QuickFile Mapping](extraction-schemas/07-quickfile-mapping.md) | Field-to-parameter mapping tables for purchase and expense flows |
| 08 | [VAT Handling](extraction-schemas/08-vat-handling.md) | UK VAT rate detection patterns + validation rules |
| 09 | [Nominal Codes](extraction-schemas/09-nominal-codes.md) | Auto-categorisation table (merchant pattern -> nominal code) |
| 10 | [Classification](extraction-schemas/10-classification.md) | Document type classification signals and disambiguation |
| 11 | [Pipeline Integration](extraction-schemas/11-pipeline-integration.md) | CLI commands: single extract, batch, full pipeline (t012.4) |
| 12 | [Validation](extraction-schemas/12-validation.md) | Confidence scoring and validation summary JSON format |

## Compact Schema Reference

All models in one block for quick inline reference. Full annotated versions in chapters 02-06.

```python
from pydantic import BaseModel, Field
from typing import Optional

class PurchaseLineItem(BaseModel):
    description: str = Field(..., description="Item or service description", max_length=5000)
    quantity: float = Field(default=1.0, ge=0)
    unit_price: float = Field(..., description="Price per unit excluding VAT")
    amount: float = Field(..., description="Line total excluding VAT (quantity * unit_price)")
    vat_rate: str = Field(default="20", description="VAT rate percentage or special code")
    vat_amount: Optional[float] = Field(default=None)
    nominal_code: Optional[str] = Field(default=None, description="Accounting nominal code (e.g., 5000=General Purchases, 7501=Postage). Auto-categorised if omitted.", min_length=2, max_length=5)

class PurchaseInvoice(BaseModel):
    """Supplier invoices received. Maps to: quickfile_purchase_create"""
    vendor_name: str = Field(..., description="Supplier/vendor company name")
    vendor_address: Optional[str] = Field(default=None)
    vendor_vat_number: Optional[str] = Field(default=None)
    vendor_company_number: Optional[str] = Field(default=None)
    invoice_number: str = Field(..., description="Supplier's invoice reference number")
    invoice_date: str = Field(..., description="Date invoice was issued (YYYY-MM-DD)")
    due_date: Optional[str] = Field(default=None, description="Payment due date (YYYY-MM-DD)")
    purchase_order: Optional[str] = Field(default=None)
    subtotal: float = Field(..., description="Total before VAT")
    vat_amount: float = Field(default=0.0)
    total: float = Field(..., description="Total including VAT")
    currency: str = Field(default="GBP", min_length=3, max_length=3)
    line_items: list[PurchaseLineItem] = Field(default_factory=list, description="Individual line items (up to 500)")
    payment_terms: Optional[str] = Field(default=None)
    bank_details: Optional[str] = Field(default=None)
    document_type: str = Field(default="purchase_invoice")

class CreditNote(BaseModel):
    """Credit notes from suppliers. Maps to: quickfile_purchase_create (negative amounts)"""
    vendor_name: str = Field(..., description="Supplier/vendor company name")
    credit_note_number: str = Field(..., description="Credit note reference number")
    date: str = Field(..., description="Credit note date (YYYY-MM-DD)")
    original_invoice: Optional[str] = Field(default=None, description="Original invoice number being credited")
    subtotal: float = Field(..., description="Credit amount before VAT (positive number)")
    vat_amount: float = Field(default=0.0)
    total: float = Field(..., description="Total credit including VAT")
    currency: str = Field(default="GBP", min_length=3, max_length=3)
    reason: Optional[str] = Field(default=None)
    line_items: list[PurchaseLineItem] = Field(default_factory=list)
    document_type: str = Field(default="credit_note")

class ReceiptItem(BaseModel):
    name: str = Field(..., description="Item name or description")
    quantity: float = Field(default=1.0)
    unit_price: Optional[float] = Field(default=None)
    price: float = Field(..., description="Total price for this item")
    vat_rate: Optional[str] = Field(default=None, description="VAT rate if shown (e.g., '20', '0', 'A'=standard, 'B'=zero)")

class ExpenseReceipt(BaseModel):
    """Informal receipts (shops, restaurants, fuel). Maps to: quickfile_purchase_create"""
    merchant_name: str = Field(..., description="Shop/restaurant/vendor name")
    merchant_address: Optional[str] = Field(default=None)
    merchant_vat_number: Optional[str] = Field(default=None)
    receipt_number: Optional[str] = Field(default=None)
    date: str = Field(..., description="Transaction date (YYYY-MM-DD)")
    time: Optional[str] = Field(default=None)
    subtotal: Optional[float] = Field(default=None)
    vat_amount: Optional[float] = Field(default=None)
    total: float = Field(..., description="Total amount paid")
    currency: str = Field(default="GBP", min_length=3, max_length=3)
    items: list[ReceiptItem] = Field(default_factory=list)
    payment_method: Optional[str] = Field(default=None)
    card_last_four: Optional[str] = Field(default=None)
    expense_category: Optional[str] = Field(default=None, description="Nominal code (auto-categorised if omitted)")
    document_type: str = Field(default="expense_receipt")

class Receipt(BaseModel):
    """Generic receipts — no accounting integration. Use expense-receipt for accounting workflows."""
    merchant: str = Field(..., description="Merchant/vendor name")
    date: str = Field(..., description="Transaction date (YYYY-MM-DD)")
    total: float = Field(..., description="Total amount")
    currency: str = Field(default="GBP")
    payment_method: Optional[str] = Field(default=None)
    items: list[ReceiptItem] = Field(default_factory=list)
    document_type: str = Field(default="receipt")

class SalesLineItem(BaseModel):
    description: str = Field(..., max_length=5000)
    quantity: float = Field(default=1.0)
    unit_price: float = Field(..., description="Price per unit excluding VAT")
    amount: float = Field(..., description="Line total excluding VAT")
    vat_rate: str = Field(default="20")
    vat_amount: Optional[float] = Field(default=None)

class Invoice(BaseModel):
    """Sales invoices issued by you. Maps to: quickfile_invoice_create"""
    client_name: str = Field(..., description="Client/customer company or individual name")
    client_address: Optional[str] = Field(default=None)
    invoice_number: str = Field(..., description="Your invoice number")
    invoice_date: str = Field(..., description="Date invoice was issued (YYYY-MM-DD)")
    due_date: Optional[str] = Field(default=None)
    subtotal: float = Field(..., description="Total before VAT")
    vat_amount: float = Field(default=0.0)
    total: float = Field(..., description="Total including VAT")
    currency: str = Field(default="GBP", min_length=3, max_length=3)
    line_items: list[SalesLineItem] = Field(default_factory=list)
    payment_terms: Optional[str] = Field(default=None)
    document_type: str = Field(default="invoice")
```

## Related

- `document-extraction.md` - Component reference (Docling, ExtractThinker, Presidio)
- `extraction-workflow.md` - Pipeline orchestration and tool selection
- `../../services/accounting/quickfile.md` - QuickFile MCP integration
- `../../business.md` - Accounting agent
- `../../scripts/quickfile-helper.sh` - QuickFile recording bridge (t012.4)
- `../../scripts/ocr-receipt-helper.sh` - OCR extraction pipeline
- `../../../todo/tasks/prd-document-extraction.md` - Full PRD
