<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Schema Design Principles

1. **Field names match document terminology** - `vendor_name` not `SupplierID`
2. **Optional fields have defaults** - extraction works even with partial data
3. **Dates use ISO 8601** - `YYYY-MM-DD` for unambiguous parsing
4. **Amounts are floats** - not strings, enabling arithmetic validation
5. **VAT is explicit** - rate and amount separated for UK compliance
6. **Currency is ISO 4217** - 3-letter codes (GBP, USD, EUR)
7. **Line items are structured** - not free text, enabling per-line VAT
8. **Confidence scores** - optional per-field confidence for QA workflows
