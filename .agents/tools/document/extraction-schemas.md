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

**Schema selection guide**:

| Document Type | Schema | QuickFile Target |
|---------------|--------|-----------------|
| Supplier invoice (formal, with invoice number) | `purchase-invoice` | `quickfile_purchase_create` |
| Till/shop receipt (informal, no invoice number) | `expense-receipt` | `quickfile_purchase_create` |
| Sales invoice (you issued it) | `invoice` | `quickfile_invoice_create` |
| Credit note from supplier | `credit-note` | `quickfile_purchase_create` (negative) |
| Generic receipt (non-accounting) | `receipt` | N/A |

<!-- AI-CONTEXT-END -->

## Schema Design Principles

1. **Field names match document terminology** - `vendor_name` not `SupplierID`
2. **Optional fields have defaults** - extraction works even with partial data
3. **Dates use ISO 8601** - `YYYY-MM-DD` for unambiguous parsing
4. **Amounts are floats** - not strings, enabling arithmetic validation
5. **VAT is explicit** - rate and amount separated for UK compliance
6. **Currency is ISO 4217** - 3-letter codes (GBP, USD, EUR)
7. **Line items are structured** - not free text, enabling per-line VAT
8. **Confidence scores** - optional per-field confidence for QA workflows

## Core Schemas

### Purchase Invoice (Supplier Invoice)

Use for formal invoices received from suppliers with an invoice number.

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
    """A single line item on a purchase invoice."""
    description: str = Field(
        ..., description="Item or service description", max_length=5000
    )
    quantity: float = Field(
        default=1.0, description="Number of units", ge=0
    )
    unit_price: float = Field(
        ..., description="Price per unit excluding VAT"
    )
    amount: float = Field(
        ..., description="Line total excluding VAT (quantity * unit_price)"
    )
    vat_rate: str = Field(
        default="20", description="VAT rate percentage or special code"
    )
    vat_amount: Optional[float] = Field(
        default=None, description="VAT amount for this line (calculated if omitted)"
    )
    nominal_code: Optional[str] = Field(
        default=None,
        description="Accounting nominal code (e.g., 5000=General Purchases, "
        "7501=Postage, 7502=Telephone). Auto-categorised if omitted.",
        min_length=2, max_length=5
    )


class PurchaseInvoice(BaseModel):
    """
    Schema for supplier invoices received for goods/services purchased.

    Maps to: quickfile_purchase_create
    """
    # Vendor identification
    vendor_name: str = Field(
        ..., description="Supplier/vendor company name"
    )
    vendor_address: Optional[str] = Field(
        default=None, description="Supplier address (full or partial)"
    )
    vendor_vat_number: Optional[str] = Field(
        default=None, description="Supplier VAT registration number"
    )
    vendor_company_number: Optional[str] = Field(
        default=None, description="Supplier company registration number"
    )

    # Invoice identification
    invoice_number: str = Field(
        ..., description="Supplier's invoice reference number"
    )
    invoice_date: str = Field(
        ..., description="Date invoice was issued (YYYY-MM-DD)"
    )
    due_date: Optional[str] = Field(
        default=None, description="Payment due date (YYYY-MM-DD)"
    )
    purchase_order: Optional[str] = Field(
        default=None, description="Purchase order number if referenced"
    )

    # Financial totals
    subtotal: float = Field(
        ..., description="Total before VAT"
    )
    vat_amount: float = Field(
        default=0.0, description="Total VAT amount"
    )
    total: float = Field(
        ..., description="Total including VAT"
    )
    currency: str = Field(
        default="GBP", description="ISO 4217 currency code",
        min_length=3, max_length=3
    )

    # Line items
    line_items: list[PurchaseLineItem] = Field(
        default_factory=list,
        description="Individual line items (up to 500)"
    )

    # Payment info
    payment_terms: Optional[str] = Field(
        default=None, description="Payment terms (e.g., 'Net 30', '14 days')"
    )
    bank_details: Optional[str] = Field(
        default=None, description="Supplier bank details for payment"
    )

    # Metadata
    document_type: str = Field(
        default="purchase_invoice",
        description="Document classification"
    )
```

### Expense Receipt (Till/Shop Receipt)

Use for informal receipts from shops, restaurants, fuel stations, etc.

```python
class ExpenseCategory(str, Enum):
    """Common expense categories with QuickFile nominal codes."""
    OFFICE_SUPPLIES = "7504"       # Stationery & Office Supplies
    TRAVEL = "7400"                # Travel & Subsistence
    FUEL = "7401"                  # Motor Expenses - Fuel
    MEALS = "7402"                 # Subsistence
    ACCOMMODATION = "7403"         # Hotel & Accommodation
    TELEPHONE = "7502"             # Telephone & Internet
    POSTAGE = "7501"               # Postage & Shipping
    SOFTWARE = "7404"              # Computer Software
    EQUIPMENT = "0030"             # Office Equipment (asset)
    GENERAL = "5000"               # General Purchases
    ADVERTISING = "6201"           # Advertising & Marketing
    PROFESSIONAL = "7600"          # Professional Fees
    REPAIRS = "7300"               # Repairs & Maintenance
    SUBSCRIPTIONS = "7900"         # Subscriptions


class ReceiptItem(BaseModel):
    """A single item on a receipt."""
    name: str = Field(
        ..., description="Item name or description"
    )
    quantity: float = Field(
        default=1.0, description="Number of units"
    )
    unit_price: Optional[float] = Field(
        default=None, description="Price per unit"
    )
    price: float = Field(
        ..., description="Total price for this item"
    )
    vat_rate: Optional[str] = Field(
        default=None,
        description="VAT rate if shown (e.g., '20', '0', 'A'=standard, 'B'=zero)"
    )


class ExpenseReceipt(BaseModel):
    """
    Schema for informal receipts (shops, restaurants, fuel stations).

    Maps to: quickfile_purchase_create (with auto-categorisation)
    """
    # Merchant identification
    merchant_name: str = Field(
        ..., description="Shop/restaurant/vendor name"
    )
    merchant_address: Optional[str] = Field(
        default=None, description="Merchant address"
    )
    merchant_vat_number: Optional[str] = Field(
        default=None, description="Merchant VAT number (if shown)"
    )

    # Receipt identification
    receipt_number: Optional[str] = Field(
        default=None, description="Receipt/transaction number"
    )
    date: str = Field(
        ..., description="Transaction date (YYYY-MM-DD)"
    )
    time: Optional[str] = Field(
        default=None, description="Transaction time (HH:MM)"
    )

    # Financial totals
    subtotal: Optional[float] = Field(
        default=None, description="Total before VAT (if shown separately)"
    )
    vat_amount: Optional[float] = Field(
        default=None, description="VAT amount (if shown)"
    )
    total: float = Field(
        ..., description="Total amount paid"
    )
    currency: str = Field(
        default="GBP", description="ISO 4217 currency code",
        min_length=3, max_length=3
    )

    # Items
    items: list[ReceiptItem] = Field(
        default_factory=list,
        description="Individual items purchased"
    )

    # Payment
    payment_method: Optional[str] = Field(
        default=None,
        description="Payment method (cash, card, contactless, etc.)"
    )
    card_last_four: Optional[str] = Field(
        default=None, description="Last 4 digits of card used"
    )

    # Categorisation
    expense_category: Optional[str] = Field(
        default=None,
        description="Expense category nominal code (auto-categorised if omitted)"
    )

    # Metadata
    document_type: str = Field(
        default="expense_receipt",
        description="Document classification"
    )
```

### Credit Note

Use for credit notes received from suppliers (refunds, adjustments).

```python
class CreditNote(BaseModel):
    """
    Schema for credit notes received from suppliers.

    Maps to: quickfile_purchase_create (with negative amounts)
    """
    vendor_name: str = Field(
        ..., description="Supplier/vendor company name"
    )
    credit_note_number: str = Field(
        ..., description="Credit note reference number"
    )
    date: str = Field(
        ..., description="Credit note date (YYYY-MM-DD)"
    )
    original_invoice: Optional[str] = Field(
        default=None, description="Original invoice number being credited"
    )

    subtotal: float = Field(
        ..., description="Credit amount before VAT (positive number)"
    )
    vat_amount: float = Field(
        default=0.0, description="VAT credit amount"
    )
    total: float = Field(
        ..., description="Total credit including VAT"
    )
    currency: str = Field(
        default="GBP", description="ISO 4217 currency code",
        min_length=3, max_length=3
    )

    reason: Optional[str] = Field(
        default=None, description="Reason for credit"
    )
    line_items: list[PurchaseLineItem] = Field(
        default_factory=list,
        description="Credited line items"
    )

    document_type: str = Field(
        default="credit_note",
        description="Document classification"
    )
```

### Sales Invoice (Issued by You)

Use for invoices you have issued to clients (existing schema, enhanced).

```python
class SalesLineItem(BaseModel):
    """A single line item on a sales invoice."""
    description: str = Field(
        ..., description="Service or product description", max_length=5000
    )
    quantity: float = Field(
        default=1.0, description="Number of units or hours"
    )
    unit_price: float = Field(
        ..., description="Price per unit excluding VAT"
    )
    amount: float = Field(
        ..., description="Line total excluding VAT"
    )
    vat_rate: str = Field(
        default="20", description="VAT rate percentage"
    )
    vat_amount: Optional[float] = Field(
        default=None, description="VAT amount for this line"
    )


class Invoice(BaseModel):
    """
    Schema for sales invoices (issued by you to clients).

    Maps to: quickfile_invoice_create
    """
    # Client identification
    client_name: str = Field(
        ..., description="Client/customer company or individual name"
    )
    client_address: Optional[str] = Field(
        default=None, description="Client billing address"
    )

    # Invoice identification
    invoice_number: str = Field(
        ..., description="Your invoice number"
    )
    invoice_date: str = Field(
        ..., description="Date invoice was issued (YYYY-MM-DD)"
    )
    due_date: Optional[str] = Field(
        default=None, description="Payment due date (YYYY-MM-DD)"
    )

    # Financial totals
    subtotal: float = Field(
        ..., description="Total before VAT"
    )
    vat_amount: float = Field(
        default=0.0, description="Total VAT amount"
    )
    total: float = Field(
        ..., description="Total including VAT"
    )
    currency: str = Field(
        default="GBP", description="ISO 4217 currency code",
        min_length=3, max_length=3
    )

    # Line items
    line_items: list[SalesLineItem] = Field(
        default_factory=list,
        description="Individual line items"
    )

    # Payment
    payment_terms: Optional[str] = Field(
        default=None, description="Payment terms"
    )

    document_type: str = Field(
        default="invoice",
        description="Document classification"
    )
```

### Generic Receipt (Non-Accounting)

Use for general-purpose receipt extraction without accounting integration.

```python
class Receipt(BaseModel):
    """
    Schema for generic receipts (no accounting integration).

    Use expense-receipt for accounting workflows instead.
    """
    merchant: str = Field(
        ..., description="Merchant/vendor name"
    )
    date: str = Field(
        ..., description="Transaction date (YYYY-MM-DD)"
    )
    total: float = Field(
        ..., description="Total amount"
    )
    currency: str = Field(
        default="GBP", description="ISO 4217 currency code"
    )
    payment_method: Optional[str] = Field(
        default=None, description="Payment method"
    )
    items: list[ReceiptItem] = Field(
        default_factory=list,
        description="Items purchased"
    )

    document_type: str = Field(
        default="receipt",
        description="Document classification"
    )
```

## QuickFile Field Mapping

### Purchase Invoice -> `quickfile_purchase_create`

| Extracted Field | QuickFile Parameter | Notes |
|----------------|--------------------|----|
| `vendor_name` | Lookup via `quickfile_supplier_search` -> `supplierId` | Create supplier if not found |
| `invoice_number` | `supplierRef` | Supplier's reference number |
| `invoice_date` | `issueDate` | YYYY-MM-DD format |
| `due_date` | `dueDate` | Or calculate from `payment_terms` |
| `currency` | `currency` | Default: GBP |
| `line_items[].description` | `lines[].description` | Max 5000 chars |
| `line_items[].quantity` | `lines[].quantity` | |
| `line_items[].unit_price` | `lines[].unitCost` | |
| `line_items[].vat_rate` | `lines[].vatPercentage` | Default: 20 |
| `line_items[].nominal_code` | `lines[].nominalCode` | Auto-categorise if missing |

### Expense Receipt -> `quickfile_purchase_create`

Expense receipts require additional processing before QuickFile submission:

1. **Supplier resolution**: Search by `merchant_name`, create if not found
2. **Date handling**: Use `date` as `issueDate`
3. **Line item consolidation**: If no line items, create single line from `total`
4. **VAT inference**: If `vat_amount` present but no per-item rates, calculate from total
5. **Category mapping**: Use `expense_category` or auto-categorise from merchant/items

| Extracted Field | QuickFile Parameter | Notes |
|----------------|--------------------|----|
| `merchant_name` | Lookup -> `supplierId` | Create supplier if not found |
| `receipt_number` | `supplierRef` | Optional |
| `date` | `issueDate` | |
| `total` | Derived from lines | |
| `items[].name` | `lines[].description` | |
| `items[].price` | `lines[].unitCost` (qty=1) | |
| `expense_category` | `lines[].nominalCode` | All lines same category |

## VAT Handling

### UK VAT Rate Detection

The extraction pipeline should detect VAT from these common patterns:

| Receipt Pattern | Meaning | Rate |
|----------------|---------|------|
| `VAT @ 20%` | Standard rate | 20 |
| `VAT @ 5%` | Reduced rate | 5 |
| `VAT: 0.00` or `Zero rated` | Zero-rated | 0 |
| `*` or `A` next to item | Standard rate (supermarket convention) | 20 |
| `B` or no marker | Zero-rated (supermarket convention) | 0 |
| `VAT Exempt` | Exempt | exempt |
| `No VAT` or no VAT line | Out of scope or not VAT registered | oos |
| `Reverse Charge` | Reverse charge (B2B services) | servrc |

### VAT Validation Rules

```text
1. If subtotal + vat_amount != total (within 0.02 tolerance):
   -> Flag for manual review

2. If vat_amount > 0 but no vendor_vat_number:
   -> Warning: VAT claimed without supplier VAT number

3. If line_items VAT sum != total vat_amount (within 0.05 tolerance):
   -> Recalculate from line items (line items take precedence)

4. If vat_rate not in [0, 5, 20, exempt, oos, servrc, cisrc, postgoods]:
   -> Flag as unusual rate for review
```

## Nominal Code Auto-Categorisation

When `nominal_code` is not extracted from the document, infer from context:

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

## Document Classification

Before extraction, classify the document to select the correct schema:

```text
Classification signals:
  "Invoice" / "Tax Invoice"     -> purchase-invoice (if from supplier)
                                -> invoice (if issued by you)
  "Receipt" / "Till Receipt"    -> expense-receipt
  "Credit Note" / "CN-"        -> credit-note
  "Estimate" / "Quote"         -> Not an extraction target (skip)
  "Statement"                  -> Not an extraction target (skip)

Disambiguation:
  - Your company name in "From" field -> invoice (you issued it)
  - Your company name in "To" field   -> purchase-invoice (supplier issued it)
  - No invoice number + till format   -> expense-receipt
```

## Extraction Pipeline Integration

### Single Document

```bash
# Extract with specific schema
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# Auto-classify and extract
document-extraction-helper.sh extract document.pdf --schema auto --privacy local
```

### Batch Processing

```bash
# Process folder of mixed documents
document-extraction-helper.sh batch ./receipts/ --schema auto --privacy local

# Process only invoices
document-extraction-helper.sh batch ./invoices/ --schema purchase-invoice
```

### Full Pipeline (Extract -> Validate -> Record)

```bash
# 1. Extract
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# 2. Review extracted JSON (human or AI validation)
cat ~/.aidevops/.agent-workspace/work/document-extraction/invoice-extracted.json

# 3. Record in QuickFile (future: t012.4)
# quickfile-helper.sh record-purchase invoice-extracted.json
```

## Confidence and Validation

Each extraction should include a validation summary:

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
- `../../accounts.md` - Accounting agent
- `../../../todo/tasks/prd-document-extraction.md` - Full PRD
