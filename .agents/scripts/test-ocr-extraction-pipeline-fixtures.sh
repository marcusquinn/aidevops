#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-ocr-extraction-pipeline-fixtures.sh -- Test Fixture Generators
# =============================================================================
# Provides all create_* fixture functions used by the OCR pipeline test suite.
# Each function writes a synthetic invoice/receipt/credit-note JSON or text
# file to the supplied output path for use in test assertions.
#
# Usage: source "${SCRIPT_DIR}/test-ocr-extraction-pipeline-fixtures.sh"
#
# Dependencies:
#   - No external dependencies; pure bash heredoc generators
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_OCR_PIPELINE_FIXTURES_LIB_LOADED:-}" ]] && return 0
_TEST_OCR_PIPELINE_FIXTURES_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (derived from BASH_SOURCE, matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ---------------------------------------------------------------------------
# Test fixture generators
# ---------------------------------------------------------------------------

create_valid_purchase_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Acme Supplies Ltd",
  "vendor_address": "123 Business Park, London, EC1A 1BB",
  "vendor_vat_number": "GB123456789",
  "vendor_company_number": "12345678",
  "invoice_number": "INV-2025-0042",
  "invoice_date": "2025-12-15",
  "due_date": "2026-01-14",
  "purchase_order": "PO-2025-100",
  "subtotal": 500.00,
  "vat_amount": 100.00,
  "total": 600.00,
  "currency": "GBP",
  "line_items": [
    {
      "description": "Widget A - Premium Grade",
      "quantity": 10,
      "unit_price": 30.00,
      "amount": 300.00,
      "vat_rate": "20",
      "vat_amount": 60.00,
      "nominal_code": "5000"
    },
    {
      "description": "Widget B - Standard",
      "quantity": 20,
      "unit_price": 10.00,
      "amount": 200.00,
      "vat_rate": "20",
      "vat_amount": 40.00,
      "nominal_code": "5000"
    }
  ],
  "payment_terms": "Net 30",
  "bank_details": "Sort: 12-34-56, Acc: 12345678",
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_valid_expense_receipt() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "merchant_name": "Costa Coffee",
  "merchant_address": "45 High Street, Manchester, M1 1AA",
  "merchant_vat_number": "GB987654321",
  "receipt_number": "TXN-88421",
  "date": "2025-12-20",
  "time": "14:35",
  "subtotal": 8.33,
  "vat_amount": 1.67,
  "total": 10.00,
  "currency": "GBP",
  "items": [
    {
      "name": "Flat White Large",
      "quantity": 2,
      "unit_price": 3.75,
      "price": 7.50,
      "vat_rate": "20"
    },
    {
      "name": "Chocolate Brownie",
      "quantity": 1,
      "unit_price": 2.50,
      "price": 2.50,
      "vat_rate": "20"
    }
  ],
  "payment_method": "contactless",
  "card_last_four": "4242",
  "expense_category": "7402",
  "document_type": "expense_receipt"
}
FIXTURE
	return 0
}

create_valid_credit_note() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Acme Supplies Ltd",
  "credit_note_number": "CN-2025-0010",
  "date": "2025-12-22",
  "original_invoice": "INV-2025-0042",
  "subtotal": 100.00,
  "vat_amount": 20.00,
  "total": 120.00,
  "currency": "GBP",
  "reason": "Defective Widget A units returned",
  "line_items": [
    {
      "description": "Widget A - Premium Grade (returned)",
      "quantity": 2,
      "unit_price": 30.00,
      "amount": 60.00,
      "vat_rate": "20",
      "vat_amount": 12.00
    },
    {
      "description": "Restocking credit",
      "quantity": 1,
      "unit_price": 40.00,
      "amount": 40.00,
      "vat_rate": "20",
      "vat_amount": 8.00
    }
  ],
  "document_type": "credit_note"
}
FIXTURE
	return 0
}

create_vat_mismatch_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Bad Maths Ltd",
  "invoice_number": "INV-BAD-001",
  "invoice_date": "2025-12-15",
  "subtotal": 100.00,
  "vat_amount": 25.00,
  "total": 130.00,
  "currency": "GBP",
  "line_items": [],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_missing_fields_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "",
  "invoice_number": "",
  "invoice_date": "",
  "subtotal": 0,
  "vat_amount": 0,
  "total": 0,
  "currency": "GBP",
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_vat_no_supplier_number() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "No VAT Number Ltd",
  "invoice_number": "INV-NOVAT-001",
  "invoice_date": "2025-12-15",
  "subtotal": 100.00,
  "vat_amount": 20.00,
  "total": 120.00,
  "currency": "GBP",
  "line_items": [
    {
      "description": "Service fee",
      "quantity": 1,
      "unit_price": 100.00,
      "amount": 100.00,
      "vat_rate": "20",
      "vat_amount": 20.00
    }
  ],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_unusual_vat_rate_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Weird VAT Ltd",
  "vendor_vat_number": "GB111222333",
  "invoice_number": "INV-WEIRD-001",
  "invoice_date": "2025-12-15",
  "subtotal": 100.00,
  "vat_amount": 15.00,
  "total": 115.00,
  "currency": "GBP",
  "line_items": [
    {
      "description": "Mystery item",
      "quantity": 1,
      "unit_price": 100.00,
      "amount": 100.00,
      "vat_rate": "15",
      "vat_amount": 15.00
    }
  ],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_zero_rated_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Zero Rate Books Ltd",
  "vendor_vat_number": "GB444555666",
  "invoice_number": "INV-ZERO-001",
  "invoice_date": "2025-12-15",
  "subtotal": 50.00,
  "vat_amount": 0.00,
  "total": 50.00,
  "currency": "GBP",
  "line_items": [
    {
      "description": "Children's book",
      "quantity": 5,
      "unit_price": 10.00,
      "amount": 50.00,
      "vat_rate": "0",
      "vat_amount": 0.00
    }
  ],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_multi_currency_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Euro Supplies GmbH",
  "vendor_vat_number": "DE123456789",
  "invoice_number": "RE-2025-0099",
  "invoice_date": "2025-12-15",
  "subtotal": 1000.00,
  "vat_amount": 190.00,
  "total": 1190.00,
  "currency": "EUR",
  "line_items": [
    {
      "description": "Consulting services",
      "quantity": 10,
      "unit_price": 100.00,
      "amount": 1000.00,
      "vat_rate": "19"
    }
  ],
  "payment_terms": "Net 14",
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_usd_receipt() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "merchant_name": "Walmart",
  "date": "2025-12-20",
  "subtotal": 45.99,
  "vat_amount": 3.68,
  "total": 49.67,
  "currency": "USD",
  "items": [
    {
      "name": "Groceries",
      "quantity": 1,
      "price": 45.99
    }
  ],
  "payment_method": "card",
  "document_type": "expense_receipt"
}
FIXTURE
	return 0
}

create_wrapped_extraction_output() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "source_file": "test-invoice.pdf",
  "document_type": "purchase_invoice",
  "extraction_status": "complete",
  "data": {
    "vendor_name": "Wrapped Format Ltd",
    "vendor_vat_number": "GB999888777",
    "invoice_number": "INV-WRAP-001",
    "invoice_date": "2025-12-15",
    "subtotal": 200.00,
    "vat_amount": 40.00,
    "total": 240.00,
    "currency": "GBP",
    "line_items": [
      {
        "description": "Service",
        "quantity": 1,
        "unit_price": 200.00,
        "amount": 200.00,
        "vat_rate": "20",
        "vat_amount": 40.00
      }
    ],
    "document_type": "purchase_invoice"
  }
}
FIXTURE
	return 0
}

create_malformed_json() {
	local output_file="$1"
	echo '{"vendor_name": "Broken JSON", "total": 100.00, invalid}' >"$output_file"
	return 0
}

create_invoice_text() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
INVOICE

Invoice No: INV-2025-0042
Date: 15 December 2025
Due Date: 14 January 2026

From:
Acme Supplies Ltd
123 Business Park
London EC1A 1BB
VAT No: GB123456789

Bill To:
Customer Corp
456 Client Street
Manchester M1 2AB

Purchase Order: PO-2025-100

Description                  Qty    Unit Price    Amount
Widget A - Premium Grade      10       30.00     300.00
Widget B - Standard           20       10.00     200.00

                              Subtotal:          500.00
                              VAT @ 20%:         100.00
                              Total:             600.00

Payment Terms: Net 30
Bank: Sort 12-34-56, Account 12345678
FIXTURE
	return 0
}

create_receipt_text() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
COSTA COFFEE
45 High Street
Manchester M1 1AA
VAT No: GB987654321

Receipt #TXN-88421
Date: 20/12/2025  Time: 14:35

Flat White Large    x2    7.50
Chocolate Brownie   x1    2.50

Subtotal:                 8.33
VAT @ 20%:                1.67
Total:                   10.00

Paid by: Contactless
Card: ****4242

Thank you for visiting!
FIXTURE
	return 0
}

create_credit_note_text() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
CREDIT NOTE

Credit Note No: CN-2025-0010
Date: 22 December 2025

From:
Acme Supplies Ltd

Original Invoice: INV-2025-0042

Reason: Defective Widget A units returned

Description                  Qty    Unit Price    Amount
Widget A - Premium (returned)  2       30.00      60.00
Restocking credit              1       40.00      40.00

                              Subtotal:          100.00
                              VAT @ 20%:          20.00
                              Total Credit:      120.00

This credit note has been applied to your account.
FIXTURE
	return 0
}

create_ambiguous_text() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
Document Reference: DOC-2025-001
Date: 15 December 2025

Items:
  - Widget A: 100.00
  - Widget B: 200.00

Total: 300.00
FIXTURE
	return 0
}

create_mixed_date_formats_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Date Format Test Ltd",
  "vendor_vat_number": "GB111111111",
  "invoice_number": "INV-DATE-001",
  "invoice_date": "15/12/2025",
  "due_date": "14 Jan 2026",
  "subtotal": 100.00,
  "vat_amount": 20.00,
  "total": 120.00,
  "currency": "GBP",
  "line_items": [],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_us_date_format_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "US Date Format Inc",
  "vendor_vat_number": null,
  "invoice_number": "INV-USDATE-001",
  "invoice_date": "12/15/2025",
  "subtotal": 100.00,
  "vat_amount": 0.00,
  "total": 100.00,
  "currency": "USD",
  "line_items": [],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_invalid_currency_invoice() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Bad Currency Ltd",
  "invoice_number": "INV-CUR-001",
  "invoice_date": "2025-12-15",
  "subtotal": 100.00,
  "vat_amount": 20.00,
  "total": 120.00,
  "currency": "GBPX",
  "line_items": [],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_line_item_vat_mismatch() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "vendor_name": "Line VAT Mismatch Ltd",
  "vendor_vat_number": "GB222333444",
  "invoice_number": "INV-LINEVAT-001",
  "invoice_date": "2025-12-15",
  "subtotal": 200.00,
  "vat_amount": 40.00,
  "total": 240.00,
  "currency": "GBP",
  "line_items": [
    {
      "description": "Item A",
      "quantity": 1,
      "unit_price": 100.00,
      "amount": 100.00,
      "vat_rate": "20",
      "vat_amount": 20.00
    },
    {
      "description": "Item B",
      "quantity": 1,
      "unit_price": 100.00,
      "amount": 100.00,
      "vat_rate": "20",
      "vat_amount": 15.00
    }
  ],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}

create_receipt_no_vat() {
	local output_file="$1"
	cat >"$output_file" <<'FIXTURE'
{
  "merchant_name": "Market Stall",
  "date": "2025-12-20",
  "total": 15.00,
  "currency": "GBP",
  "items": [
    {
      "name": "Fresh vegetables",
      "quantity": 1,
      "price": 15.00
    }
  ],
  "payment_method": "cash",
  "document_type": "expense_receipt"
}
FIXTURE
	return 0
}

create_large_invoice() {
	local output_file="$1"
	local items=""
	local subtotal=0
	for i in $(seq 1 50); do
		local amount=$((i * 10))
		subtotal=$((subtotal + amount))
		local vat_amt
		vat_amt=$(bc <<<"$amount * 0.2" || echo "$((amount / 5))")
		if [[ -n "$items" ]]; then
			items="${items},"
		fi
		items="${items}
    {
      \"description\": \"Item ${i}\",
      \"quantity\": 1,
      \"unit_price\": ${amount}.00,
      \"amount\": ${amount}.00,
      \"vat_rate\": \"20\",
      \"vat_amount\": ${vat_amt}
    }"
	done
	local vat_total
	vat_total=$(bc <<<"$subtotal * 0.2" || echo "$((subtotal / 5))")
	local total
	total=$(bc <<<"$subtotal + $vat_total" || echo "$((subtotal + subtotal / 5))")

	cat >"$output_file" <<FIXTURE
{
  "vendor_name": "Bulk Supplier Ltd",
  "vendor_vat_number": "GB555666777",
  "invoice_number": "INV-BULK-001",
  "invoice_date": "2025-12-15",
  "subtotal": ${subtotal}.00,
  "vat_amount": ${vat_total},
  "total": ${total},
  "currency": "GBP",
  "line_items": [${items}
  ],
  "document_type": "purchase_invoice"
}
FIXTURE
	return 0
}
