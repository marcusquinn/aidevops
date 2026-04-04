<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Expense Receipt Schema (Till/Shop Receipt)

Use for informal receipts from shops, restaurants, fuel stations, etc.

## ExpenseCategory Enum

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
```

## ReceiptItem Model

```python
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
```

## ExpenseReceipt Model

```python
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
