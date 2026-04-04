<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Sales Invoice Schema (Issued by You)

Use for invoices you have issued to clients (existing schema, enhanced).

## SalesLineItem Model

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
```

## Invoice Model

```python
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
