#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Test Suite for OCR Invoice/Receipt Extraction Pipeline (t012.5)
#
# Tests the full extraction pipeline with synthetic invoice/receipt data:
#   - extraction_pipeline.py: classify, validate, categorise
#   - ocr-receipt-helper.sh: argument parsing, file type detection, document type detection
#   - document-extraction-helper.sh: argument parsing, schema listing, status
#   - Edge cases: malformed JSON, missing fields, VAT mismatches, date formats
#
# Usage: test-ocr-extraction-pipeline.sh [--verbose] [--filter <pattern>]
#
# Requires: python3, pydantic>=2.0 (system or venv)
# Optional: shellcheck (for script linting)
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PIPELINE_PY="${SCRIPT_DIR}/extraction_pipeline.py"
OCR_HELPER="${SCRIPT_DIR}/ocr-receipt-helper.sh"
DOC_HELPER="${SCRIPT_DIR}/document-extraction-helper.sh"

# Test workspace (cleaned up on exit)
TEST_WORKSPACE=""
VERBOSE=0
FILTER=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0
PYTHON_CMD=""

# Colours (only if terminal supports them)
if [[ -t 1 ]]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	BLUE='\033[0;34m'
	NC='\033[0m'
else
	RED=''
	GREEN=''
	YELLOW=''
	BLUE=''
	NC=''
fi

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

setup_workspace() {
	TEST_WORKSPACE="$(mktemp -d /tmp/test-ocr-pipeline-XXXXXX)"
	return 0
}

cleanup_workspace() {
	if [[ -n "${TEST_WORKSPACE:-}" ]] && [[ -d "$TEST_WORKSPACE" ]]; then
		rm -rf "$TEST_WORKSPACE"
	fi
	return 0
}

trap cleanup_workspace EXIT

# Find a Python with pydantic available
find_python() {
	local candidates=(
		"/tmp/test-extraction-venv/bin/python3"
		"${HOME}/.aidevops/.agent-workspace/python-env/document-extraction/bin/python3"
		"python3"
	)

	for candidate in "${candidates[@]}"; do
		if { command -v "$candidate" &>/dev/null || [[ -x "$candidate" ]]; } &&
			"$candidate" -c "from pydantic import BaseModel" 2>/dev/null; then
			PYTHON_CMD="$candidate"
			return 0
		fi
	done

	return 1
}

log_test() {
	local status="$1"
	local test_name="$2"
	local detail="${3:-}"

	TOTAL_COUNT=$((TOTAL_COUNT + 1))

	case "$status" in
	PASS)
		PASS_COUNT=$((PASS_COUNT + 1))
		printf '%b  PASS%b  %s\n' "$GREEN" "$NC" "$test_name"
		;;
	FAIL)
		FAIL_COUNT=$((FAIL_COUNT + 1))
		printf '%b  FAIL%b  %s\n' "$RED" "$NC" "$test_name"
		if [[ -n "$detail" ]]; then
			printf '        %s\n' "$detail"
		fi
		;;
	SKIP)
		SKIP_COUNT=$((SKIP_COUNT + 1))
		printf '%b  SKIP%b  %s\n' "$YELLOW" "$NC" "$test_name"
		if [[ -n "$detail" ]]; then
			printf '        %s\n' "$detail"
		fi
		;;
	esac
	return 0
}

should_run() {
	local test_name="$1"
	if [[ -z "$FILTER" ]]; then
		return 0
	fi
	if [[ "$test_name" == *"$FILTER"* ]]; then
		return 0
	fi
	return 1
}

verbose_log() {
	if [[ "$VERBOSE" -eq 1 ]]; then
		printf '%b        [verbose]%b %s\n' "$BLUE" "$NC" "$1"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Load sub-libraries
# ---------------------------------------------------------------------------

# shellcheck source=./test-ocr-extraction-pipeline-fixtures.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-ocr-extraction-pipeline-fixtures.sh"

# shellcheck source=./test-ocr-extraction-pipeline-pipeline-tests.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-ocr-extraction-pipeline-pipeline-tests.sh"

# shellcheck source=./test-ocr-extraction-pipeline-helper-tests.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-ocr-extraction-pipeline-helper-tests.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--verbose | -v)
			VERBOSE=1
			shift
			;;
		--filter | -f)
			FILTER="${2:-}"
			shift 2 || {
				echo "Missing filter pattern"
				exit 1
			}
			;;
		--help | -h)
			echo "Usage: test-ocr-extraction-pipeline.sh [--verbose] [--filter <pattern>]"
			echo ""
			echo "Options:"
			echo "  --verbose, -v       Show detailed output"
			echo "  --filter, -f <pat>  Only run tests matching pattern"
			echo ""
			echo "Test groups:"
			echo "  syntax/              Script syntax and linting"
			echo "  pipeline/classify    Document classification"
			echo "  pipeline/validate    Extraction validation"
			echo "  pipeline/categorise  Nominal code categorisation"
			echo "  pipeline/confidence  Confidence scoring"
			echo "  pipeline/nominal     Auto-assign nominal codes"
			echo "  pipeline/python      Python module imports"
			echo "  pipeline/cli         CLI argument handling"
			echo "  ocr-helper/          OCR receipt helper tests"
			echo "  doc-helper/          Document extraction helper tests"
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			exit 1
			;;
		esac
	done
	return 0
}

main() {
	parse_args "$@"

	echo "OCR Invoice/Receipt Extraction Pipeline - Test Suite (t012.5)"
	echo "============================================================="
	echo ""

	# Prerequisites
	if [[ ! -f "$PIPELINE_PY" ]]; then
		echo "ERROR: extraction_pipeline.py not found at ${PIPELINE_PY}"
		exit 1
	fi

	if [[ ! -f "$OCR_HELPER" ]]; then
		echo "ERROR: ocr-receipt-helper.sh not found at ${OCR_HELPER}"
		exit 1
	fi

	if [[ ! -f "$DOC_HELPER" ]]; then
		echo "ERROR: document-extraction-helper.sh not found at ${DOC_HELPER}"
		exit 1
	fi

	if ! find_python; then
		echo "ERROR: Python with pydantic>=2.0 not found"
		echo "Install: python3 -m venv /tmp/test-extraction-venv && /tmp/test-extraction-venv/bin/pip install pydantic>=2.0"
		exit 1
	fi

	verbose_log "Python: ${PYTHON_CMD}"
	verbose_log "Pipeline: ${PIPELINE_PY}"
	verbose_log "OCR Helper: ${OCR_HELPER}"
	verbose_log "Doc Helper: ${DOC_HELPER}"

	setup_workspace
	verbose_log "Workspace: ${TEST_WORKSPACE}"
	echo ""

	# Run test groups
	printf '%b--- Syntax & Linting ---%b\n' "$BLUE" "$NC"
	test_script_syntax
	echo ""

	printf '%b--- Python Module Tests ---%b\n' "$BLUE" "$NC"
	test_pipeline_python_import
	echo ""

	printf '%b--- Pipeline CLI ---%b\n' "$BLUE" "$NC"
	test_pipeline_cli
	echo ""

	printf '%b--- Document Classification ---%b\n' "$BLUE" "$NC"
	test_pipeline_classify
	echo ""

	printf '%b--- Extraction Validation ---%b\n' "$BLUE" "$NC"
	test_pipeline_validate
	echo ""

	printf '%b--- Confidence Scoring ---%b\n' "$BLUE" "$NC"
	test_pipeline_confidence
	echo ""

	printf '%b--- Nominal Code Categorisation ---%b\n' "$BLUE" "$NC"
	test_pipeline_categorise
	echo ""

	printf '%b--- Nominal Code Auto-Assignment ---%b\n' "$BLUE" "$NC"
	test_pipeline_nominal_auto_assign
	echo ""

	printf '%b--- OCR Helper: File Detection ---%b\n' "$BLUE" "$NC"
	test_ocr_helper_file_detection
	echo ""

	printf '%b--- OCR Helper: Document Type Detection ---%b\n' "$BLUE" "$NC"
	test_ocr_helper_doc_type_detection
	echo ""

	printf '%b--- OCR Helper: Argument Parsing ---%b\n' "$BLUE" "$NC"
	test_ocr_helper_args
	echo ""

	printf '%b--- Document Helper: Argument Parsing ---%b\n' "$BLUE" "$NC"
	test_doc_helper_args
	echo ""

	# Summary
	echo "============================================================="
	printf 'Results: %b%d passed%b, %b%d failed%b, %b%d skipped%b (total: %d)\n' \
		"$GREEN" "$PASS_COUNT" "$NC" "$RED" "$FAIL_COUNT" "$NC" "$YELLOW" "$SKIP_COUNT" "$NC" "$TOTAL_COUNT"

	if [[ "$FAIL_COUNT" -gt 0 ]]; then
		exit 1
	fi

	exit 0
}

main "$@"
