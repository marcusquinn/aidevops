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

- **Purpose**: Pydantic schema contracts for structured document extraction
- **Pipeline**: Docling (parse) -> ExtractThinker (extract) -> QuickFile (record)
- **Schemas**: `invoice`, `receipt`, `expense-receipt`, `purchase-invoice`, `credit-note`
- **Helper**: `document-extraction-helper.sh extract file.pdf --schema <name>`
- **QuickFile mapping**: Each schema maps extracted fields to QuickFile API parameters

**Schema selection:**

| Document Type | Schema | QuickFile Target |
|---------------|--------|-----------------|
| Supplier invoice (formal, with invoice number) | `purchase-invoice` | `quickfile_purchase_create` |
| Till/shop receipt (informal, no invoice number) | `expense-receipt` | `quickfile_purchase_create` |
| Sales invoice (you issued it) | `invoice` | `quickfile_invoice_create` |
| Credit note from supplier | `credit-note` | `quickfile_purchase_create` (negative) |
| Generic receipt (non-accounting) | `receipt` | N/A |

**Document classification signals:**

```text
"Invoice" / "Tax Invoice"  -> purchase-invoice (supplier) or invoice (you issued it)
"Receipt" / "Till Receipt" -> expense-receipt
"Credit Note" / "CN-"      -> credit-note
"Estimate" / "Quote"       -> skip (not an extraction target)
"Statement"                -> skip (not an extraction target)

Disambiguation:
  Your company name in "From" field -> invoice (you issued it)
  Your company name in "To" field   -> purchase-invoice (supplier issued it)
  No invoice number + till format   -> expense-receipt
```

<!-- AI-CONTEXT-END -->

## Core Schemas

### Purchase Invoice (Supplier Invoice)

```python
from pydantic import BaseModel, Field
from typing import Optional
from enum import Enum


class VatRate(str, Enum):
    """UK VAT rates and special codes."""
    STANDARD = "20"
    REDUCED = "5"
    ZERO = "0"
    EXEMPT = "exempt"
    OUT_OF_SCOPE = "oos"
    REVERSE_CHARGE = "servrc"
    CIS_REVERSE = "cisrc"
    PVA_GOODS = "postgoods"


class PurchaseLineItem(BaseModel):
    description: str = Field(..., description="Item or service description", max_length=5000)
    quantity: float = Field(default=1.0, description="Number of units", ge=0)
    unit_price: float = Field(..., description="Price per unit excluding VAT")
    amount: float = Field(..., description="Line total excluding VAT (quantity * unit_price)")
    vat_rate: str = Field(default="20", description="VAT rate percentage or special code")
    vat_amount: Optional[float] = Field(default=None, description="VAT amount for this line")
    nominal_code: Optional[str] = Field(
        default=None,
        description="Accounting nominal code (e.g., 5000=General Purchases, 7501=Postage). Auto-categorised if omitted.",
        min_length=2, max_length=5
    )


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
    vat_amount: float = Field(default=0.0, description="Total VAT amount")
    total: float = Field(..., description="Total including VAT")
    currency: str = Field(default="GBP", description="ISO 4217 currency code", min_length=3, max_length=3)
    line_items: list[PurchaseLineItem] = Field(default_factory=list, description="Individual line items (up to 500)")
    payment_terms: Optional[str] = Field(default=None)
    bank_details: Optional[str] = Field(default=None)
    document_type: str = Field(default="purchase_invoice")
```

### Expense Receipt (Till/Shop Receipt)

```python
class ExpenseCategory(str, Enum):
    """Common expense categories with QuickFile nominal codes."""
    OFFICE_SUPPLIES = "7504"
    TRAVEL = "7400"
    FUEL = "7401"
    MEALS = "7402"
    ACCOMMODATION = "7403"
    TELEPHONE = "7502"
    POSTAGE = "7501"
    SOFTWARE = "7404"
    EQUIPMENT = "0030"
    GENERAL = "5000"
    ADVERTISING = "6201"
    PROFESSIONAL = "7600"
    REPAIRS = "7300"
    SUBSCRIPTIONS = "7900"


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
    time: Optional[str] = Field(default=None, description="Transaction time (HH:MM)")
    subtotal: Optional[float] = Field(default=None)
    vat_amount: Optional[float] = Field(default=None)
    total: float = Field(..., description="Total amount paid")
    currency: str = Field(default="GBP", min_length=3, max_length=3)
    items: list[ReceiptItem] = Field(default_factory=list)
    payment_method: Optional[str] = Field(default=None)
    card_last_four: Optional[str] = Field(default=None)
    expense_category: Optional[str] = Field(default=None, description="Nominal code (auto-categorised if omitted)")
    document_type: str = Field(default="expense_receipt")
```

### Credit Note

```python
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
```

### Sales Invoice (Issued by You)

```python
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

### Generic Receipt (Non-Accounting)

```python
class Receipt(BaseModel):
    """Generic receipts — no accounting integration. Use expense-receipt for accounting workflows."""
    merchant: str = Field(..., description="Merchant/vendor name")
    date: str = Field(..., description="Transaction date (YYYY-MM-DD)")
    total: float = Field(..., description="Total amount")
    currency: str = Field(default="GBP")
    payment_method: Optional[str] = Field(default=None)
    items: list[ReceiptItem] = Field(default_factory=list)
    document_type: str = Field(default="receipt")
```

## QuickFile Field Mapping

### Purchase Invoice -> `quickfile_purchase_create`

| Extracted Field | QuickFile Parameter | Notes |
|----------------|--------------------|----|
| `vendor_name` | Lookup via `quickfile_supplier_search` -> `supplierId` | Create supplier if not found |
| `invoice_number` | `supplierRef` | |
| `invoice_date` | `issueDate` | YYYY-MM-DD |
| `due_date` | `dueDate` | Or calculate from `payment_terms` |
| `currency` | `currency` | Default: GBP |
| `line_items[].description` | `lines[].description` | Max 5000 chars |
| `line_items[].quantity` | `lines[].quantity` | |
| `line_items[].unit_price` | `lines[].unitCost` | |
| `line_items[].vat_rate` | `lines[].vatPercentage` | Default: 20 |
| `line_items[].nominal_code` | `lines[].nominalCode` | Auto-categorise if missing |

### Expense Receipt -> `quickfile_purchase_create`

Pre-processing required: (1) resolve supplier by `merchant_name`, (2) if no line items, create single line from `total`, (3) infer VAT from `vat_amount` if no per-item rates, (4) map `expense_category` or auto-categorise.

| Extracted Field | QuickFile Parameter | Notes |
|----------------|--------------------|----|
| `merchant_name` | Lookup -> `supplierId` | Create if not found |
| `receipt_number` | `supplierRef` | Optional |
| `date` | `issueDate` | |
| `items[].name` | `lines[].description` | |
| `items[].price` | `lines[].unitCost` (qty=1) | |
| `expense_category` | `lines[].nominalCode` | All lines same category |

## VAT Handling

### UK VAT Rate Detection

| Receipt Pattern | Meaning | Rate |
|----------------|---------|------|
| `VAT @ 20%` | Standard rate | 20 |
| `VAT @ 5%` | Reduced rate | 5 |
| `VAT: 0.00` or `Zero rated` | Zero-rated | 0 |
| `*` or `A` next to item | Standard rate (supermarket) | 20 |
| `B` or no marker | Zero-rated (supermarket) | 0 |
| `VAT Exempt` | Exempt | exempt |
| `No VAT` or no VAT line | Out of scope | oos |
| `Reverse Charge` | Reverse charge (B2B) | servrc |

### VAT Validation Rules

```text
1. subtotal + vat_amount != total (>0.02 tolerance) -> flag for manual review
2. vat_amount > 0 but no vendor_vat_number -> warning: VAT claimed without supplier VAT number
3. line_items VAT sum != total vat_amount (>0.05 tolerance) -> recalculate from line items
4. vat_rate not in [0, 5, 20, exempt, oos, servrc, cisrc, postgoods] -> flag as unusual
```

## Nominal Code Auto-Categorisation

| Merchant/Item Pattern | Nominal Code | Category |
|----------------------|-------------|----------|
| Amazon, Staples, office supplies | 7504 | Stationery & Office Supplies |
| Shell, BP, Esso, fuel, petrol, diesel | 7401 | Motor Expenses - Fuel |
| Hotel, Airbnb, accommodation | 7403 | Hotel & Accommodation |
| Restaurant, cafe, food, lunch | 7402 | Subsistence |
| Train, bus, taxi, Uber, parking | 7400 | Travel & Subsistence |
| Royal Mail, DHL, FedEx, postage | 7501 | Postage & Shipping |
| BT, Vodafone, phone, broadband | 7502 | Telephone & Internet |
| Adobe, Microsoft, SaaS, subscription | 7404 | Computer Software |
| Google Ads, Facebook Ads, marketing | 6201 | Advertising & Marketing |
| Accountant, solicitor, legal | 7600 | Professional Fees |
| Plumber, electrician, repair | 7300 | Repairs & Maintenance |
| *Default (no match)* | 5000 | General Purchases |

## Extraction Pipeline

```bash
# Single document — specific schema
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# Single document — auto-classify
document-extraction-helper.sh extract document.pdf --schema auto --privacy local

# Batch processing
document-extraction-helper.sh batch ./receipts/ --schema auto --privacy local

# Full pipeline: extract -> review -> record
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local
cat ~/.aidevops/.agent-workspace/work/document-extraction/invoice-extracted.json
quickfile-helper.sh record-purchase invoice-extracted.json --auto-supplier
quickfile-helper.sh batch-record ~/.aidevops/.agent-workspace/work/ocr-receipts/
```

## Confidence and Validation

Each extraction includes a validation summary:

```json
{
  "extraction": { "...schema fields..." },
  "validation": {
    "vat_check": "pass",
    "total_check": "pass",
    "date_valid": true,
    "currency_detected": "GBP",
    "confidence": {
      "vendor_name": 0.95,
      "total": 0.99,
      "vat_amount": 0.85,
      "line_items": 0.80
    },
    "warnings": [],
    "requires_review": false
  }
}
```

Fields with confidence below 0.7 should be flagged for manual review.

## Related

- `document-extraction.md` - Component reference (Docling, ExtractThinker, Presidio)
- `extraction-workflow.md` - Pipeline orchestration and tool selection
- `../../services/accounting/quickfile.md` - QuickFile MCP integration
- `../../business.md` - Accounting agent
- `../../scripts/quickfile-helper.sh` - QuickFile recording bridge (t012.4)
- `../../scripts/ocr-receipt-helper.sh` - OCR extraction pipeline
- `../../../todo/tasks/prd-document-extraction.md` - Full PRD
