<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Generic Receipt Schema (Non-Accounting)

Use for general-purpose receipt extraction without accounting integration.

Reuses `ReceiptItem` from [03-expense-receipt.md](03-expense-receipt.md).

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
