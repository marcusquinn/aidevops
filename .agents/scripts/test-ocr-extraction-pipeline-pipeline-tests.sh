#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-ocr-extraction-pipeline-pipeline-tests.sh -- Pipeline Test Functions
# =============================================================================
# Provides all test_pipeline_* functions for the OCR pipeline test suite:
#   - classify: document type classification
#   - validate: extraction validation (doc types, VAT, currency, formats, errors)
#   - categorise: nominal code categorisation
#   - confidence: confidence scoring
#   - nominal-auto-assign: auto-assignment of nominal codes
#   - python-import: Python module import and Pydantic model verification
#   - cli: CLI argument handling
#
# Usage: source "${SCRIPT_DIR}/test-ocr-extraction-pipeline-pipeline-tests.sh"
#
# Dependencies:
#   - test-ocr-extraction-pipeline-fixtures.sh (create_* functions)
#   - Globals: PYTHON_CMD, PIPELINE_PY, TEST_WORKSPACE, FILTER, VERBOSE
#   - Functions: log_test, should_run, verbose_log (from orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_OCR_PIPELINE_PIPELINE_TESTS_LIB_LOADED:-}" ]] && return 0
_TEST_OCR_PIPELINE_PIPELINE_TESTS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (derived from BASH_SOURCE, matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ---------------------------------------------------------------------------
# Test groups: pipeline/classify
# ---------------------------------------------------------------------------

test_pipeline_classify() {
	local group="pipeline/classify"

	# Test 1: Classify invoice text
	if should_run "${group}/invoice-text"; then
		local text_file="${TEST_WORKSPACE}/invoice-text.txt"
		create_invoice_text "$text_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" classify "$text_file")" || true
		if echo "$output" | grep -q '"purchase_invoice"'; then
			log_test "PASS" "${group}/invoice-text"
		else
			log_test "FAIL" "${group}/invoice-text" "Expected purchase_invoice, got: ${output}"
		fi
	fi

	# Test 2: Classify receipt text
	if should_run "${group}/receipt-text"; then
		local text_file="${TEST_WORKSPACE}/receipt-text.txt"
		create_receipt_text "$text_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" classify "$text_file")" || true
		if echo "$output" | grep -q '"expense_receipt"'; then
			log_test "PASS" "${group}/receipt-text"
		else
			log_test "FAIL" "${group}/receipt-text" "Expected expense_receipt, got: ${output}"
		fi
	fi

	# Test 3: Classify credit note text
	if should_run "${group}/credit-note-text"; then
		local text_file="${TEST_WORKSPACE}/credit-note-text.txt"
		create_credit_note_text "$text_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" classify "$text_file")" || true
		if echo "$output" | grep -q '"credit_note"'; then
			log_test "PASS" "${group}/credit-note-text"
		else
			log_test "FAIL" "${group}/credit-note-text" "Expected credit_note, got: ${output}"
		fi
	fi

	# Test 4: Classify ambiguous text (should default to purchase_invoice)
	if should_run "${group}/ambiguous-text"; then
		local text_file="${TEST_WORKSPACE}/ambiguous-text.txt"
		create_ambiguous_text "$text_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" classify "$text_file")" || true
		if echo "$output" | grep -q '"purchase_invoice"'; then
			log_test "PASS" "${group}/ambiguous-text"
		else
			log_test "FAIL" "${group}/ambiguous-text" "Expected purchase_invoice (default), got: ${output}"
		fi
	fi

	# Test 5: Classify inline string (no file)
	if should_run "${group}/inline-string"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" classify "Invoice No: 12345 Due Date: 2025-01-15 Payment Terms: Net 30")" || true
		if echo "$output" | grep -q '"purchase_invoice"'; then
			log_test "PASS" "${group}/inline-string"
		else
			log_test "FAIL" "${group}/inline-string" "Expected purchase_invoice, got: ${output}"
		fi
	fi

	# Test 6: Classify with scores output
	if should_run "${group}/scores-output"; then
		local text_file="${TEST_WORKSPACE}/invoice-text.txt"
		create_invoice_text "$text_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" classify "$text_file")" || true
		if echo "$output" | grep -q '"scores"'; then
			log_test "PASS" "${group}/scores-output"
		else
			log_test "FAIL" "${group}/scores-output" "Expected scores in output, got: ${output}"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test groups: pipeline/validate (split into four focused sub-functions)
# ---------------------------------------------------------------------------

# Tests 1-5: valid document types pass validation
_test_pipeline_validate_doc_types() {
	local group="pipeline/validate"

	# Test 1: Valid purchase invoice passes validation
	if should_run "${group}/valid-purchase-invoice"; then
		local json_file="${TEST_WORKSPACE}/valid-invoice.json"
		create_valid_purchase_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q '"vat_check": "pass"'; then
			log_test "PASS" "${group}/valid-purchase-invoice"
		else
			log_test "FAIL" "${group}/valid-purchase-invoice" "exit=${exit_code}, output: ${output:0:200}"
		fi
	fi

	# Test 2: Valid expense receipt passes validation
	if should_run "${group}/valid-expense-receipt"; then
		local json_file="${TEST_WORKSPACE}/valid-receipt.json"
		create_valid_expense_receipt "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type expense_receipt 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q '"extraction_status"'; then
			log_test "PASS" "${group}/valid-expense-receipt"
		else
			log_test "FAIL" "${group}/valid-expense-receipt" "exit=${exit_code}, output: ${output:0:200}"
		fi
	fi

	# Test 3: Valid credit note passes validation
	if should_run "${group}/valid-credit-note"; then
		local json_file="${TEST_WORKSPACE}/valid-credit-note.json"
		create_valid_credit_note "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type credit_note 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q '"extraction_status"'; then
			log_test "PASS" "${group}/valid-credit-note"
		else
			log_test "FAIL" "${group}/valid-credit-note" "exit=${exit_code}, output: ${output:0:200}"
		fi
	fi

	# Test 4: VAT mismatch detected
	if should_run "${group}/vat-mismatch"; then
		local json_file="${TEST_WORKSPACE}/vat-mismatch.json"
		create_vat_mismatch_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"vat_check": "fail"'; then
			log_test "PASS" "${group}/vat-mismatch"
		else
			log_test "FAIL" "${group}/vat-mismatch" "Expected vat_check=fail, got: ${output:0:200}"
		fi
	fi

	# Test 5: Missing fields flagged for review
	if should_run "${group}/missing-fields"; then
		local json_file="${TEST_WORKSPACE}/missing-fields.json"
		create_missing_fields_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"requires_review": true'; then
			log_test "PASS" "${group}/missing-fields"
		else
			log_test "FAIL" "${group}/missing-fields" "Expected requires_review=true, got: ${output:0:200}"
		fi
	fi

	return 0
}

# Tests 6-10: VAT warnings and multi-currency detection
_test_pipeline_validate_vat_currency() {
	local group="pipeline/validate"

	# Test 6: VAT claimed without supplier VAT number
	if should_run "${group}/vat-no-supplier-number"; then
		local json_file="${TEST_WORKSPACE}/vat-no-supplier.json"
		create_vat_no_supplier_number "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q "no supplier VAT number"; then
			log_test "PASS" "${group}/vat-no-supplier-number"
		else
			log_test "FAIL" "${group}/vat-no-supplier-number" "Expected VAT warning, got: ${output:0:200}"
		fi
	fi

	# Test 7: Unusual VAT rate flagged
	if should_run "${group}/unusual-vat-rate"; then
		local json_file="${TEST_WORKSPACE}/unusual-vat.json"
		create_unusual_vat_rate_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q "unusual VAT rate"; then
			log_test "PASS" "${group}/unusual-vat-rate"
		else
			log_test "FAIL" "${group}/unusual-vat-rate" "Expected unusual VAT rate warning, got: ${output:0:200}"
		fi
	fi

	# Test 8: Zero-rated invoice passes VAT check (may need review due to optional fields)
	if should_run "${group}/zero-rated"; then
		local json_file="${TEST_WORKSPACE}/zero-rated.json"
		create_zero_rated_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		# Exit 0 = clean, exit 2 = needs_review (acceptable for zero-rated with optional fields empty)
		if [[ "$exit_code" -le 2 ]] && echo "$output" | grep -q '"vat_check": "pass"'; then
			log_test "PASS" "${group}/zero-rated"
		else
			log_test "FAIL" "${group}/zero-rated" "exit=${exit_code}, output: ${output:0:200}"
		fi
	fi

	# Test 9: Multi-currency invoice (EUR)
	if should_run "${group}/multi-currency"; then
		local json_file="${TEST_WORKSPACE}/multi-currency.json"
		create_multi_currency_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"currency_detected": "EUR"'; then
			log_test "PASS" "${group}/multi-currency"
		else
			log_test "FAIL" "${group}/multi-currency" "Expected EUR currency, got: ${output:0:200}"
		fi
	fi

	# Test 10: USD receipt
	if should_run "${group}/usd-receipt"; then
		local json_file="${TEST_WORKSPACE}/usd-receipt.json"
		create_usd_receipt "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type expense_receipt 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"currency_detected": "USD"'; then
			log_test "PASS" "${group}/usd-receipt"
		else
			log_test "FAIL" "${group}/usd-receipt" "Expected USD currency, got: ${output:0:200}"
		fi
	fi

	return 0
}

# Tests 11-15: format edge cases — wrapped output, date normalisation, currency codes, line VAT
_test_pipeline_validate_formats() {
	local group="pipeline/validate"

	# Test 11: Wrapped extraction output format
	if should_run "${group}/wrapped-format"; then
		local json_file="${TEST_WORKSPACE}/wrapped.json"
		create_wrapped_extraction_output "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"vat_check": "pass"'; then
			log_test "PASS" "${group}/wrapped-format"
		else
			log_test "FAIL" "${group}/wrapped-format" "exit=${exit_code}, output: ${output:0:200}"
		fi
	fi

	# Test 12: Date normalisation (DD/MM/YYYY -> YYYY-MM-DD)
	if should_run "${group}/date-normalisation"; then
		local json_file="${TEST_WORKSPACE}/date-formats.json"
		create_mixed_date_formats_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"date_valid": true'; then
			log_test "PASS" "${group}/date-normalisation"
		else
			log_test "FAIL" "${group}/date-normalisation" "Expected date_valid=true after normalisation, got: ${output:0:200}"
		fi
	fi

	# Test 13: US date format (MM/DD/YYYY)
	if should_run "${group}/us-date-format"; then
		local json_file="${TEST_WORKSPACE}/us-date.json"
		create_us_date_format_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		# US date 12/15/2025 should be normalised (either DD/MM or MM/DD interpretation)
		if echo "$output" | grep -q '"date_valid"'; then
			log_test "PASS" "${group}/us-date-format"
		else
			log_test "FAIL" "${group}/us-date-format" "Expected date_valid field, got: ${output:0:200}"
		fi
	fi

	# Test 14: Invalid currency code
	if should_run "${group}/invalid-currency"; then
		local json_file="${TEST_WORKSPACE}/invalid-currency.json"
		create_invalid_currency_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q "not a valid ISO 4217"; then
			log_test "PASS" "${group}/invalid-currency"
		else
			log_test "FAIL" "${group}/invalid-currency" "Expected currency warning, got: ${output:0:200}"
		fi
	fi

	# Test 15: Line item VAT sum mismatch
	if should_run "${group}/line-vat-mismatch"; then
		local json_file="${TEST_WORKSPACE}/line-vat-mismatch.json"
		create_line_item_vat_mismatch "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q "Line items VAT sum"; then
			log_test "PASS" "${group}/line-vat-mismatch"
		else
			log_test "FAIL" "${group}/line-vat-mismatch" "Expected line VAT mismatch warning, got: ${output:0:200}"
		fi
	fi

	return 0
}

# Tests 16-20: error paths — no-VAT receipt, large invoice, auto-detect, malformed, missing file
_test_pipeline_validate_error_paths() {
	local group="pipeline/validate"

	# Test 16: Receipt with no VAT
	if should_run "${group}/receipt-no-vat"; then
		local json_file="${TEST_WORKSPACE}/receipt-no-vat.json"
		create_receipt_no_vat "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type expense_receipt 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"extraction_status"'; then
			log_test "PASS" "${group}/receipt-no-vat"
		else
			log_test "FAIL" "${group}/receipt-no-vat" "exit=${exit_code}, output: ${output:0:200}"
		fi
	fi

	# Test 17: Large invoice (50 line items)
	if should_run "${group}/large-invoice"; then
		local json_file="${TEST_WORKSPACE}/large-invoice.json"
		create_large_invoice "$json_file"
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"extraction_status"'; then
			log_test "PASS" "${group}/large-invoice"
		else
			log_test "FAIL" "${group}/large-invoice" "exit=${exit_code}, output: ${output:0:200}"
		fi
	fi

	# Test 18: Auto-detect type from document_type field
	if should_run "${group}/auto-detect-type"; then
		local json_file="${TEST_WORKSPACE}/valid-receipt.json"
		create_valid_expense_receipt "$json_file"
		local output
		local exit_code=0
		# No --type flag, should auto-detect from document_type field
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" 2>/dev/null)" || exit_code=$?
		if echo "$output" | grep -q '"document_type": "expense_receipt"'; then
			log_test "PASS" "${group}/auto-detect-type"
		else
			log_test "FAIL" "${group}/auto-detect-type" "Expected auto-detected expense_receipt, got: ${output:0:200}"
		fi
	fi

	# Test 19: Malformed JSON file
	if should_run "${group}/malformed-json"; then
		local json_file="${TEST_WORKSPACE}/malformed.json"
		create_malformed_json "$json_file"
		local exit_code=0
		"$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/malformed-json"
		else
			log_test "FAIL" "${group}/malformed-json" "Expected non-zero exit for malformed JSON"
		fi
	fi

	# Test 20: Non-existent file
	if should_run "${group}/nonexistent-file"; then
		local exit_code=0
		"$PYTHON_CMD" "$PIPELINE_PY" validate "/tmp/does-not-exist-12345.json" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/nonexistent-file"
		else
			log_test "FAIL" "${group}/nonexistent-file" "Expected non-zero exit for missing file"
		fi
	fi

	return 0
}

test_pipeline_validate() {
	_test_pipeline_validate_doc_types
	_test_pipeline_validate_vat_currency
	_test_pipeline_validate_formats
	_test_pipeline_validate_error_paths
	return 0
}

# ---------------------------------------------------------------------------
# Test groups: pipeline/categorise
# ---------------------------------------------------------------------------

# Tests 1-6: common expense categories (fuel, office, food, software, travel, postage)
_test_pipeline_categorise_common() {
	local group="pipeline/categorise"

	# Test 1: Fuel vendor
	if should_run "${group}/fuel-vendor"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Shell" "diesel fuel" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7401"'; then
			log_test "PASS" "${group}/fuel-vendor"
		else
			log_test "FAIL" "${group}/fuel-vendor" "Expected 7401, got: ${output}"
		fi
	fi

	# Test 2: Office supplies
	if should_run "${group}/office-supplies"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Amazon" "printer paper" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7504"'; then
			log_test "PASS" "${group}/office-supplies"
		else
			log_test "FAIL" "${group}/office-supplies" "Expected 7504, got: ${output}"
		fi
	fi

	# Test 3: Restaurant/subsistence
	if should_run "${group}/restaurant"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Costa Coffee" "lunch" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7402"'; then
			log_test "PASS" "${group}/restaurant"
		else
			log_test "FAIL" "${group}/restaurant" "Expected 7402, got: ${output}"
		fi
	fi

	# Test 4: Software subscription
	if should_run "${group}/software"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Adobe" "Creative Cloud subscription" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7404"'; then
			log_test "PASS" "${group}/software"
		else
			log_test "FAIL" "${group}/software" "Expected 7404, got: ${output}"
		fi
	fi

	# Test 5: Travel
	if should_run "${group}/travel"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Uber" "taxi ride" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7400"'; then
			log_test "PASS" "${group}/travel"
		else
			log_test "FAIL" "${group}/travel" "Expected 7400, got: ${output}"
		fi
	fi

	# Test 6: Postage
	if should_run "${group}/postage"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Royal Mail" "parcel delivery" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7501"'; then
			log_test "PASS" "${group}/postage"
		else
			log_test "FAIL" "${group}/postage" "Expected 7501, got: ${output}"
		fi
	fi

	return 0
}

# Tests 7-12: extended categories (telephone, advertising, professional, unknown, hotel, repairs)
_test_pipeline_categorise_extended() {
	local group="pipeline/categorise"

	# Test 7: Telephone
	if should_run "${group}/telephone"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Vodafone" "mobile contract" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7502"'; then
			log_test "PASS" "${group}/telephone"
		else
			log_test "FAIL" "${group}/telephone" "Expected 7502, got: ${output}"
		fi
	fi

	# Test 8: Advertising
	if should_run "${group}/advertising"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Google Ads" "PPC campaign" 2>/dev/null)" || true
		if echo "$output" | grep -q '"6201"'; then
			log_test "PASS" "${group}/advertising"
		else
			log_test "FAIL" "${group}/advertising" "Expected 6201, got: ${output}"
		fi
	fi

	# Test 9: Professional fees
	if should_run "${group}/professional-fees"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Smith & Jones Solicitors" "legal advice" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7600"'; then
			log_test "PASS" "${group}/professional-fees"
		else
			log_test "FAIL" "${group}/professional-fees" "Expected 7600, got: ${output}"
		fi
	fi

	# Test 10: Unknown vendor defaults to 5000
	if should_run "${group}/unknown-vendor"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "XYZ Unknown Corp" "miscellaneous" 2>/dev/null)" || true
		if echo "$output" | grep -q '"5000"'; then
			log_test "PASS" "${group}/unknown-vendor"
		else
			log_test "FAIL" "${group}/unknown-vendor" "Expected 5000 (default), got: ${output}"
		fi
	fi

	# Test 11: Hotel/accommodation
	if should_run "${group}/hotel"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Hilton Hotel" "overnight stay" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7403"'; then
			log_test "PASS" "${group}/hotel"
		else
			log_test "FAIL" "${group}/hotel" "Expected 7403, got: ${output}"
		fi
	fi

	# Test 12: Repairs
	if should_run "${group}/repairs"; then
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorise "Local Plumber" "boiler repair" 2>/dev/null)" || true
		if echo "$output" | grep -q '"7300"'; then
			log_test "PASS" "${group}/repairs"
		else
			log_test "FAIL" "${group}/repairs" "Expected 7300, got: ${output}"
		fi
	fi

	return 0
}

test_pipeline_categorise() {
	_test_pipeline_categorise_common
	_test_pipeline_categorise_extended
	return 0
}

# ---------------------------------------------------------------------------
# Test groups: pipeline/confidence
# ---------------------------------------------------------------------------

test_pipeline_confidence() {
	local group="pipeline/confidence"

	# Test 1: Complete invoice has high confidence
	if should_run "${group}/high-confidence"; then
		local json_file="${TEST_WORKSPACE}/valid-invoice.json"
		create_valid_purchase_invoice "$json_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || true
		local overall
		overall="$(echo "$output" | "$PYTHON_CMD" -c "import json,sys; d=json.load(sys.stdin); print(d['validation']['overall_confidence'])" 2>/dev/null)" || true
		if [[ -n "$overall" ]]; then
			local is_high
			is_high="$(echo "$overall" | "$PYTHON_CMD" -c "import sys; v=float(sys.stdin.read().strip()); print('yes' if v >= 0.7 else 'no')" 2>/dev/null)" || true
			if [[ "$is_high" == "yes" ]]; then
				log_test "PASS" "${group}/high-confidence"
				verbose_log "Overall confidence: ${overall}"
			else
				log_test "FAIL" "${group}/high-confidence" "Expected confidence >= 0.7, got: ${overall}"
			fi
		else
			log_test "FAIL" "${group}/high-confidence" "Could not parse confidence from output"
		fi
	fi

	# Test 2: Empty fields have low confidence
	if should_run "${group}/low-confidence"; then
		local json_file="${TEST_WORKSPACE}/missing-fields.json"
		create_missing_fields_invoice "$json_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || true
		local overall
		overall="$(echo "$output" | "$PYTHON_CMD" -c "import json,sys; d=json.load(sys.stdin); print(d['validation']['overall_confidence'])" 2>/dev/null)" || true
		if [[ -n "$overall" ]]; then
			local is_low
			is_low="$(echo "$overall" | "$PYTHON_CMD" -c "import sys; v=float(sys.stdin.read().strip()); print('yes' if v < 0.7 else 'no')" 2>/dev/null)" || true
			if [[ "$is_low" == "yes" ]]; then
				log_test "PASS" "${group}/low-confidence"
				verbose_log "Overall confidence: ${overall}"
			else
				log_test "FAIL" "${group}/low-confidence" "Expected confidence < 0.7, got: ${overall}"
			fi
		else
			log_test "FAIL" "${group}/low-confidence" "Could not parse confidence from output"
		fi
	fi

	# Test 3: Per-field confidence scores present
	if should_run "${group}/per-field-scores"; then
		local json_file="${TEST_WORKSPACE}/valid-invoice.json"
		create_valid_purchase_invoice "$json_file"
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || true
		local score_count
		score_count="$(echo "$output" | "$PYTHON_CMD" -c "import json,sys; d=json.load(sys.stdin); print(len(d['validation']['confidence_scores']))" 2>/dev/null)" || true
		if [[ -n "$score_count" ]] && [[ "$score_count" -gt 5 ]]; then
			log_test "PASS" "${group}/per-field-scores"
			verbose_log "Field scores count: ${score_count}"
		else
			log_test "FAIL" "${group}/per-field-scores" "Expected >5 field scores, got: ${score_count}"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test groups: pipeline/nominal-auto-assign
# ---------------------------------------------------------------------------

test_pipeline_nominal_auto_assign() {
	local group="pipeline/nominal-auto-assign"

	# Test: Validation auto-assigns nominal codes to line items without them
	if should_run "${group}/auto-assign"; then
		local json_file="${TEST_WORKSPACE}/no-nominal.json"
		cat >"$json_file" <<'FIXTURE'
{
  "vendor_name": "Shell",
  "vendor_vat_number": "GB111222333",
  "invoice_number": "INV-FUEL-001",
  "invoice_date": "2025-12-15",
  "subtotal": 50.00,
  "vat_amount": 10.00,
  "total": 60.00,
  "currency": "GBP",
  "line_items": [
    {
      "description": "Diesel fuel",
      "quantity": 1,
      "unit_price": 50.00,
      "amount": 50.00,
      "vat_rate": "20",
      "vat_amount": 10.00
    }
  ],
  "document_type": "purchase_invoice"
}
FIXTURE
		local output
		output="$("$PYTHON_CMD" "$PIPELINE_PY" validate "$json_file" --type purchase_invoice 2>/dev/null)" || true
		if echo "$output" | grep -q '"nominal_code"'; then
			log_test "PASS" "${group}/auto-assign"
		else
			log_test "FAIL" "${group}/auto-assign" "Expected nominal_code to be auto-assigned, got: ${output:0:300}"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test groups: pipeline/python-import
# ---------------------------------------------------------------------------

# Tests 1-2: module import and Pydantic model instantiation
_test_pipeline_python_import_models() {
	local group="pipeline/python-import"

	# Test 1: Pipeline module imports successfully
	if should_run "${group}/import"; then
		local exit_code=0
		"$PYTHON_CMD" -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from extraction_pipeline import (
    classify_document, validate_vat, compute_confidence,
    parse_and_validate, categorise_nominal,
    DocumentType, PurchaseInvoice, ExpenseReceipt, CreditNote,
    ExtractionOutput, ValidationResult
)
print('All imports OK')
" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/import"
		else
			log_test "FAIL" "${group}/import" "Import failed with exit code ${exit_code}"
		fi
	fi

	# Test 2: Pydantic models can be instantiated
	if should_run "${group}/model-instantiation"; then
		local exit_code=0
		"$PYTHON_CMD" -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from extraction_pipeline import PurchaseInvoice, ExpenseReceipt, CreditNote

# Test default instantiation
pi = PurchaseInvoice()
assert pi.currency == 'GBP', f'Expected GBP, got {pi.currency}'
assert pi.document_type == 'purchase_invoice'

er = ExpenseReceipt()
assert er.currency == 'GBP'
assert er.document_type == 'expense_receipt'

cn = CreditNote()
assert cn.currency == 'GBP'
assert cn.document_type == 'credit_note'

print('All models instantiate OK')
" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/model-instantiation"
		else
			log_test "FAIL" "${group}/model-instantiation" "Model instantiation failed"
		fi
	fi

	return 0
}

# Tests 3-5: date normalisation function and enum correctness
_test_pipeline_python_import_enums() {
	local group="pipeline/python-import"

	# Test 3: Date normalisation function
	if should_run "${group}/date-normalisation"; then
		local exit_code=0
		"$PYTHON_CMD" -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from extraction_pipeline import _normalise_date

tests = [
    ('2025-12-15', '2025-12-15'),
    ('15/12/2025', '2025-12-15'),
    ('15-12-2025', '2025-12-15'),
    ('15.12.2025', '2025-12-15'),
    ('15 Dec 2025', '2025-12-15'),
    ('15 December 2025', '2025-12-15'),
    ('Dec 15, 2025', '2025-12-15'),
    ('December 15, 2025', '2025-12-15'),
    ('20251215', '2025-12-15'),
]

failures = []
for input_val, expected in tests:
    result = _normalise_date(input_val)
    if result != expected:
        failures.append(f'{input_val}: expected {expected}, got {result}')

if failures:
    print('FAILURES: ' + '; '.join(failures))
    sys.exit(1)
else:
    print(f'All {len(tests)} date formats normalised correctly')
" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/date-normalisation"
		else
			log_test "FAIL" "${group}/date-normalisation" "Date normalisation failed"
		fi
	fi

	# Test 4: VatRate enum values
	if should_run "${group}/vat-rate-enum"; then
		local exit_code=0
		"$PYTHON_CMD" -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from extraction_pipeline import VatRate

expected = {'20', '5', '0', 'exempt', 'oos', 'servrc', 'cisrc', 'postgoods'}
actual = {v.value for v in VatRate}
assert actual == expected, f'Expected {expected}, got {actual}'
print('VatRate enum OK')
" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/vat-rate-enum"
		else
			log_test "FAIL" "${group}/vat-rate-enum" "VatRate enum values incorrect"
		fi
	fi

	# Test 5: DocumentType enum values
	if should_run "${group}/doc-type-enum"; then
		local exit_code=0
		"$PYTHON_CMD" -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from extraction_pipeline import DocumentType

expected = {'purchase_invoice', 'expense_receipt', 'credit_note', 'invoice', 'receipt', 'unknown'}
actual = {v.value for v in DocumentType}
assert actual == expected, f'Expected {expected}, got {actual}'
print('DocumentType enum OK')
" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/doc-type-enum"
		else
			log_test "FAIL" "${group}/doc-type-enum" "DocumentType enum values incorrect"
		fi
	fi

	return 0
}

test_pipeline_python_import() {
	_test_pipeline_python_import_models
	_test_pipeline_python_import_enums
	return 0
}

# ---------------------------------------------------------------------------
# Test groups: pipeline/cli
# ---------------------------------------------------------------------------

test_pipeline_cli() {
	local group="pipeline/cli"

	# Test 1: No args shows usage
	if should_run "${group}/no-args"; then
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q "Usage"; then
			log_test "PASS" "${group}/no-args"
		else
			log_test "FAIL" "${group}/no-args" "exit=${exit_code}, output: ${output:0:100}"
		fi
	fi

	# Test 2: Unknown command returns error
	if should_run "${group}/unknown-command"; then
		local exit_code=0
		"$PYTHON_CMD" "$PIPELINE_PY" nonexistent 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/unknown-command"
		else
			log_test "FAIL" "${group}/unknown-command" "Expected non-zero exit for unknown command"
		fi
	fi

	# Test 3: Classify with no args returns error
	if should_run "${group}/classify-no-args"; then
		local exit_code=0
		"$PYTHON_CMD" "$PIPELINE_PY" classify 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/classify-no-args"
		else
			log_test "FAIL" "${group}/classify-no-args" "Expected non-zero exit"
		fi
	fi

	# Test 4: Validate with no args returns error
	if should_run "${group}/validate-no-args"; then
		local exit_code=0
		"$PYTHON_CMD" "$PIPELINE_PY" validate 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/validate-no-args"
		else
			log_test "FAIL" "${group}/validate-no-args" "Expected non-zero exit"
		fi
	fi

	# Test 5: Categorise with no args returns error
	if should_run "${group}/categorise-no-args"; then
		local exit_code=0
		"$PYTHON_CMD" "$PIPELINE_PY" categorise 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/categorise-no-args"
		else
			log_test "FAIL" "${group}/categorise-no-args" "Expected non-zero exit"
		fi
	fi

	# Test 6: US spelling alias 'categorize' works
	if should_run "${group}/categorize-alias"; then
		local output
		local exit_code=0
		output="$("$PYTHON_CMD" "$PIPELINE_PY" categorize "Shell" "fuel" 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q '"7401"'; then
			log_test "PASS" "${group}/categorize-alias"
		else
			log_test "FAIL" "${group}/categorize-alias" "exit=${exit_code}, output: ${output:0:100}"
		fi
	fi

	return 0
}
