<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Credit Note Schema

Use for credit notes received from suppliers (refunds, adjustments).

Reuses `PurchaseLineItem` from [02-purchase-invoice.md](02-purchase-invoice.md).

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
