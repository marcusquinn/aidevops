<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Document Classification

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
