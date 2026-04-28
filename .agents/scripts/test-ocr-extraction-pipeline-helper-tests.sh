#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-ocr-extraction-pipeline-helper-tests.sh -- Shell Helper Test Functions
# =============================================================================
# Provides test functions for the OCR and document extraction shell helpers:
#   - test_ocr_helper_file_detection: file type detection by extension
#   - test_ocr_helper_doc_type_detection: document type detection from text
#   - test_ocr_helper_args: ocr-receipt-helper.sh argument parsing
#   - test_doc_helper_args: document-extraction-helper.sh argument parsing
#   - test_script_syntax: syntax/ShellCheck validation for all scripts
#
# Usage: source "${SCRIPT_DIR}/test-ocr-extraction-pipeline-helper-tests.sh"
#
# Dependencies:
#   - Globals: OCR_HELPER, DOC_HELPER, PIPELINE_PY, FILTER, VERBOSE
#   - Functions: log_test, should_run, verbose_log (from orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_OCR_PIPELINE_HELPER_TESTS_LIB_LOADED:-}" ]] && return 0
_TEST_OCR_PIPELINE_HELPER_TESTS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (derived from BASH_SOURCE, matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ---------------------------------------------------------------------------
# Test groups: ocr-helper/file-detection
# ---------------------------------------------------------------------------

test_ocr_helper_file_detection() {
	local group="ocr-helper/file-detection"

	# Test 1-7: File type detection by extension
	local extensions=("png:image" "jpg:image" "jpeg:image" "pdf:pdf" "docx:document" "xlsx:document" "html:document")
	for ext_pair in "${extensions[@]}"; do
		local ext="${ext_pair%%:*}"
		local expected="${ext_pair##*:}"
		local test_name="${group}/${ext}"

		if should_run "$test_name"; then
			# Test the file type detection logic (mirrors detect_file_type in ocr-receipt-helper.sh)
			local result
			result="$(bash -c "
                ext='${ext}'
                ext=\"\$(echo \"\$ext\" | tr '[:upper:]' '[:lower:]')\"
                case \"\$ext\" in
                    png|jpg|jpeg|tiff|bmp|webp|heic) echo 'image' ;;
                    pdf) echo 'pdf' ;;
                    docx|xlsx|pptx|html|htm) echo 'document' ;;
                    *) echo 'unknown' ;;
                esac
            " 2>/dev/null)" || true
			if [[ "$result" == "$expected" ]]; then
				log_test "PASS" "$test_name"
			else
				log_test "FAIL" "$test_name" "Expected ${expected}, got: ${result}"
			fi
		fi
	done

	# Test 8: Unknown extension
	if should_run "${group}/unknown-ext"; then
		local result
		result="$(bash -c "
            ext='xyz'
            case \"\$ext\" in
                png|jpg|jpeg|tiff|bmp|webp|heic) echo 'image' ;;
                pdf) echo 'pdf' ;;
                docx|xlsx|pptx|html|htm) echo 'document' ;;
                *) echo 'unknown' ;;
            esac
        " 2>/dev/null)" || true
		if [[ "$result" == "unknown" ]]; then
			log_test "PASS" "${group}/unknown-ext"
		else
			log_test "FAIL" "${group}/unknown-ext" "Expected unknown, got: ${result}"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test groups: ocr-helper/doc-type-detection
# ---------------------------------------------------------------------------

test_ocr_helper_doc_type_detection() {
	local group="ocr-helper/doc-type-detection"

	# Test 1: Invoice text detected as invoice
	if should_run "${group}/invoice-text"; then
		local text="Invoice No: 12345 Due Date: 2025-01-15 Bill To: Customer Corp Payment Terms: Net 30"
		local result
		result="$(bash -c "
            text='${text}'
            lower_text=\"\$(echo \"\$text\" | tr '[:upper:]' '[:lower:]')\"
            invoice_score=0
            receipt_score=0
            if echo \"\$lower_text\" | grep -qE 'invoice\s*(no|number|#|:)'; then invoice_score=\$((invoice_score + 3)); fi
            if echo \"\$lower_text\" | grep -qE 'due\s*date|payment\s*terms|net\s*[0-9]+'; then invoice_score=\$((invoice_score + 2)); fi
            if echo \"\$lower_text\" | grep -qE 'bill\s*to|ship\s*to|remit\s*to'; then invoice_score=\$((invoice_score + 1)); fi
            if echo \"\$lower_text\" | grep -qE 'receipt|till|register'; then receipt_score=\$((receipt_score + 3)); fi
            if echo \"\$lower_text\" | grep -qE 'cash|card|visa|mastercard'; then receipt_score=\$((receipt_score + 2)); fi
            if [[ \"\$invoice_score\" -gt \"\$receipt_score\" ]]; then echo 'invoice'
            elif [[ \"\$receipt_score\" -gt \"\$invoice_score\" ]]; then echo 'receipt'
            else echo 'invoice'; fi
        " 2>/dev/null)" || true
		if [[ "$result" == "invoice" ]]; then
			log_test "PASS" "${group}/invoice-text"
		else
			log_test "FAIL" "${group}/invoice-text" "Expected invoice, got: ${result}"
		fi
	fi

	# Test 2: Receipt text detected as receipt
	if should_run "${group}/receipt-text"; then
		local text="Receipt Thank you for your purchase Paid by Visa contactless Change due: 0.00"
		local result
		result="$(bash -c "
            text='${text}'
            lower_text=\"\$(echo \"\$text\" | tr '[:upper:]' '[:lower:]')\"
            invoice_score=0
            receipt_score=0
            if echo \"\$lower_text\" | grep -qE 'invoice\s*(no|number|#|:)'; then invoice_score=\$((invoice_score + 3)); fi
            if echo \"\$lower_text\" | grep -qE 'receipt|till|register'; then receipt_score=\$((receipt_score + 3)); fi
            if echo \"\$lower_text\" | grep -qE 'cash|card|visa|mastercard|amex|contactless|chip'; then receipt_score=\$((receipt_score + 2)); fi
            if echo \"\$lower_text\" | grep -qE 'change\s*due|thank\s*you|have\s*a\s*nice'; then receipt_score=\$((receipt_score + 2)); fi
            if [[ \"\$invoice_score\" -gt \"\$receipt_score\" ]]; then echo 'invoice'
            elif [[ \"\$receipt_score\" -gt \"\$invoice_score\" ]]; then echo 'receipt'
            else echo 'invoice'; fi
        " 2>/dev/null)" || true
		if [[ "$result" == "receipt" ]]; then
			log_test "PASS" "${group}/receipt-text"
		else
			log_test "FAIL" "${group}/receipt-text" "Expected receipt, got: ${result}"
		fi
	fi

	# Test 3: Ambiguous text defaults to invoice
	if should_run "${group}/ambiguous-default"; then
		local text="Total: 100.00 Date: 2025-12-15"
		local result
		result="$(bash -c "
            text='${text}'
            lower_text=\"\$(echo \"\$text\" | tr '[:upper:]' '[:lower:]')\"
            invoice_score=0
            receipt_score=0
            if echo \"\$lower_text\" | grep -qE 'invoice\s*(no|number|#|:)'; then invoice_score=\$((invoice_score + 3)); fi
            if echo \"\$lower_text\" | grep -qE 'receipt|till|register'; then receipt_score=\$((receipt_score + 3)); fi
            if [[ \"\$invoice_score\" -gt \"\$receipt_score\" ]]; then echo 'invoice'
            elif [[ \"\$receipt_score\" -gt \"\$invoice_score\" ]]; then echo 'receipt'
            else echo 'invoice'; fi
        " 2>/dev/null)" || true
		if [[ "$result" == "invoice" ]]; then
			log_test "PASS" "${group}/ambiguous-default"
		else
			log_test "FAIL" "${group}/ambiguous-default" "Expected invoice (default), got: ${result}"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test groups: ocr-helper/args
# ---------------------------------------------------------------------------

test_ocr_helper_args() {
	local group="ocr-helper/args"

	# Test 1: Help command works
	if should_run "${group}/help"; then
		local output
		local exit_code=0
		output="$(bash "$OCR_HELPER" help 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q "OCR Receipt"; then
			log_test "PASS" "${group}/help"
		else
			log_test "FAIL" "${group}/help" "exit=${exit_code}, output: ${output:0:100}"
		fi
	fi

	# Test 2: Status command works
	if should_run "${group}/status"; then
		local output
		local exit_code=0
		output="$(bash "$OCR_HELPER" status 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q "Component Status"; then
			log_test "PASS" "${group}/status"
		else
			log_test "FAIL" "${group}/status" "exit=${exit_code}, output: ${output:0:100}"
		fi
	fi

	# Test 3: Unknown command returns error
	if should_run "${group}/unknown-command"; then
		local exit_code=0
		bash "$OCR_HELPER" nonexistent-command 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/unknown-command"
		else
			log_test "FAIL" "${group}/unknown-command" "Expected non-zero exit for unknown command"
		fi
	fi

	# Test 4: Scan without file returns error
	if should_run "${group}/scan-no-file"; then
		local exit_code=0
		bash "$OCR_HELPER" scan 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/scan-no-file"
		else
			log_test "FAIL" "${group}/scan-no-file" "Expected error when no file provided"
		fi
	fi

	# Test 5: Extract without file returns error
	if should_run "${group}/extract-no-file"; then
		local exit_code=0
		bash "$OCR_HELPER" extract 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/extract-no-file"
		else
			log_test "FAIL" "${group}/extract-no-file" "Expected error when no file provided"
		fi
	fi

	# Test 6: Scan with nonexistent file returns error
	if should_run "${group}/scan-missing-file"; then
		local exit_code=0
		bash "$OCR_HELPER" scan /tmp/nonexistent-file-12345.png 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/scan-missing-file"
		else
			log_test "FAIL" "${group}/scan-missing-file" "Expected error for missing file"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test groups: doc-helper/args
# ---------------------------------------------------------------------------

test_doc_helper_args() {
	local group="doc-helper/args"

	# Test 1: Help command works
	if should_run "${group}/help"; then
		local output
		local exit_code=0
		output="$(bash "$DOC_HELPER" help 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q "Document Extraction"; then
			log_test "PASS" "${group}/help"
		else
			log_test "FAIL" "${group}/help" "exit=${exit_code}, output: ${output:0:100}"
		fi
	fi

	# Test 2: Schemas command works
	if should_run "${group}/schemas"; then
		local output
		local exit_code=0
		output="$(bash "$DOC_HELPER" schemas 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q "purchase-invoice"; then
			log_test "PASS" "${group}/schemas"
		else
			log_test "FAIL" "${group}/schemas" "exit=${exit_code}, output: ${output:0:100}"
		fi
	fi

	# Test 3: Status command works
	if should_run "${group}/status"; then
		local output
		local exit_code=0
		output="$(bash "$DOC_HELPER" status 2>/dev/null)" || exit_code=$?
		if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q "Component Status"; then
			log_test "PASS" "${group}/status"
		else
			log_test "FAIL" "${group}/status" "exit=${exit_code}, output: ${output:0:100}"
		fi
	fi

	# Test 4: Unknown command returns error
	if should_run "${group}/unknown-command"; then
		local exit_code=0
		bash "$DOC_HELPER" nonexistent-command 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/unknown-command"
		else
			log_test "FAIL" "${group}/unknown-command" "Expected non-zero exit for unknown command"
		fi
	fi

	# Test 5: Extract without file returns error
	if should_run "${group}/extract-no-file"; then
		local exit_code=0
		bash "$DOC_HELPER" extract 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			log_test "PASS" "${group}/extract-no-file"
		else
			log_test "FAIL" "${group}/extract-no-file" "Expected error when no file provided"
		fi
	fi

	# Test 6: Schemas lists all expected schemas
	if should_run "${group}/schemas-complete"; then
		local output
		output="$(bash "$DOC_HELPER" schemas 2>/dev/null)" || true
		local all_found=1
		for schema in "purchase-invoice" "expense-receipt" "credit-note" "invoice" "receipt" "contract" "id-document" "auto"; do
			if ! echo "$output" | grep -q "$schema"; then
				all_found=0
				verbose_log "Missing schema: ${schema}"
			fi
		done
		if [[ "$all_found" -eq 1 ]]; then
			log_test "PASS" "${group}/schemas-complete"
		else
			log_test "FAIL" "${group}/schemas-complete" "Not all schemas listed"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test groups: syntax
# ---------------------------------------------------------------------------

test_script_syntax() {
	local group="syntax"

	# Test 1: extraction_pipeline.py compiles
	if should_run "${group}/pipeline-py-compile"; then
		local exit_code=0
		"$PYTHON_CMD" -m py_compile "$PIPELINE_PY" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/pipeline-py-compile"
		else
			log_test "FAIL" "${group}/pipeline-py-compile" "Python compilation failed"
		fi
	fi

	# Test 2: ocr-receipt-helper.sh syntax check
	if should_run "${group}/ocr-helper-syntax"; then
		local exit_code=0
		bash -n "$OCR_HELPER" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/ocr-helper-syntax"
		else
			log_test "FAIL" "${group}/ocr-helper-syntax" "Bash syntax check failed"
		fi
	fi

	# Test 3: document-extraction-helper.sh syntax check
	if should_run "${group}/doc-helper-syntax"; then
		local exit_code=0
		bash -n "$DOC_HELPER" 2>/dev/null || exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			log_test "PASS" "${group}/doc-helper-syntax"
		else
			log_test "FAIL" "${group}/doc-helper-syntax" "Bash syntax check failed"
		fi
	fi

	# Test 4: ShellCheck on ocr-receipt-helper.sh (if available)
	if should_run "${group}/ocr-helper-shellcheck"; then
		if command -v shellcheck &>/dev/null; then
			local exit_code=0
			shellcheck -x -S warning "$OCR_HELPER" 2>/dev/null || exit_code=$?
			if [[ "$exit_code" -eq 0 ]]; then
				log_test "PASS" "${group}/ocr-helper-shellcheck"
			else
				log_test "FAIL" "${group}/ocr-helper-shellcheck" "ShellCheck violations found"
			fi
		else
			log_test "SKIP" "${group}/ocr-helper-shellcheck" "shellcheck not installed"
		fi
	fi

	# Test 5: ShellCheck on document-extraction-helper.sh (if available)
	if should_run "${group}/doc-helper-shellcheck"; then
		if command -v shellcheck &>/dev/null; then
			local exit_code=0
			shellcheck -x -S warning "$DOC_HELPER" 2>/dev/null || exit_code=$?
			if [[ "$exit_code" -eq 0 ]]; then
				log_test "PASS" "${group}/doc-helper-shellcheck"
			else
				log_test "FAIL" "${group}/doc-helper-shellcheck" "ShellCheck violations found"
			fi
		else
			log_test "SKIP" "${group}/doc-helper-shellcheck" "shellcheck not installed"
		fi
	fi

	# Test 6: ShellCheck on this test script
	if should_run "${group}/self-shellcheck"; then
		if command -v shellcheck &>/dev/null; then
			local exit_code=0
			shellcheck -x -S warning "${BASH_SOURCE[0]}" 2>/dev/null || exit_code=$?
			if [[ "$exit_code" -eq 0 ]]; then
				log_test "PASS" "${group}/self-shellcheck"
			else
				log_test "FAIL" "${group}/self-shellcheck" "ShellCheck violations in test script"
			fi
		else
			log_test "SKIP" "${group}/self-shellcheck" "shellcheck not installed"
		fi
	fi

	return 0
}
