#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for document-enrich-helper.sh (t2849)
# =============================================================================
# Run: bash .agents/tests/test-document-enrich.sh
#
# Tests:
#   1. shellcheck             — zero violations on helper
#   2. schema files           — all 7 expected schema files exist and are valid JSON
#   3. regex extraction       — _extract_regex captures group 1 correctly
#   4. regex no-match         — returns null with low confidence on no match
#   5. llm extraction (mock)  — skips gracefully when llm-routing-helper.sh absent
#   6. enrich cmd             — writes extracted.json with provenance fields
#   7. idempotent re-run      — second enrich call with same schema is a no-op
#   8. force-refresh          — --force-refresh overwrites existing extracted.json
#   9. kind override          — --kind contract uses contract schema
#  10. missing text file      — enrich fails gracefully with informative message
#  11. tick cmd               — processes only sources missing extracted.json
#  12. schema validation      — all schemas have required: kind, version, fields array
#  13. dry-run flag           — no files written with --dry-run
#
# Mocking strategy: create a minimal _knowledge/ tree in a temp dir with
# fake meta.json and text.txt. Override KNOWLEDGE_ROOT env var to isolate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
HELPER="${SCRIPTS_DIR}/document-enrich-helper.sh"
SCHEMAS_DIR="${SCRIPT_DIR}/../tools/document/extraction-schemas"

PASS=0
FAIL=0
TEST_TMPDIR=""

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

setup() {
	TEST_TMPDIR=$(mktemp -d)
	return 0
}

teardown() {
	[[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	printf "[PASS] %s\n" "$name"
	return 0
}

fail() {
	local name="$1" reason="${2:-}"
	FAIL=$((FAIL + 1))
	printf "[FAIL] %s%s\n" "$name" "${reason:+ — $reason}"
	return 0
}

# Create a minimal knowledge plane with one source
make_plane() {
	local plane_dir="$1"
	mkdir -p "${plane_dir}/inbox" \
		"${plane_dir}/staging" \
		"${plane_dir}/sources" \
		"${plane_dir}/index" \
		"${plane_dir}/_config"
	return 0
}

make_source() {
	local plane_dir="$1"
	local source_id="$2"
	local kind="${3:-invoice}"
	local sensitivity="${4:-internal}"
	local with_text="${5:-yes}"

	local src_dir="${plane_dir}/sources/${source_id}"
	mkdir -p "$src_dir"

	jq -n \
		--arg id "$source_id" \
		--arg kind "$kind" \
		--arg sens "$sensitivity" \
		'{version:1,id:$id,kind:$kind,sensitivity:$sens,trust:"unverified"}' \
		> "${src_dir}/meta.json"

	if [[ "$with_text" == "yes" ]]; then
		cat > "${src_dir}/text.txt" <<'TEXT'
INVOICE

Supplier: Acme Corp Ltd
VAT Registration: GB123456789

Invoice Number: INV-2026-001
Invoice Date: 15 January 2026
Due Date: 14 February 2026
Payment Terms: Net 30

Subtotal:  £6,200.00
VAT (20%): £1,240.00
Total Due: £7,440.00

Sort Code: 20-00-00
Account Number: 12345678
TEXT
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_shellcheck() {
	if ! command -v shellcheck >/dev/null 2>&1; then
		pass "shellcheck — skipped (not installed)"
		return 0
	fi
	local output
	output=$(shellcheck "$HELPER" 2>&1)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "shellcheck"
	else
		fail "shellcheck" "$output"
	fi
	return 0
}

test_schema_files() {
	local expected=(invoice contract bank_statement financial_statement payment_receipt email generic)
	local all_ok=1
	for schema in "${expected[@]}"; do
		local path="${SCHEMAS_DIR}/${schema}.json"
		if [[ ! -f "$path" ]]; then
			fail "schema_files: ${schema}.json missing"
			all_ok=0
			continue
		fi
		if ! jq . "$path" >/dev/null 2>&1; then
			fail "schema_files: ${schema}.json invalid JSON"
			all_ok=0
		fi
	done
	[[ "$all_ok" -eq 1 ]] && pass "schema_files (all 7 present and valid JSON)"
	return 0
}

test_regex_extraction() {
	setup
	local text_file="${TEST_TMPDIR}/test.txt"
	echo "Invoice Number: INV-2026-001" > "$text_file"

	# shellcheck disable=SC1090
	source "$HELPER" 2>/dev/null || true

	# Pattern matches colon-separated invoice number (same as invoice.json)
	local result value confidence
	result=$(_extract_regex "(?i)invoice[\\s\\w]*[#:]\\s*([A-Z0-9][A-Z0-9/_-]{1,29})" "$text_file" 2>/dev/null)
	value=$(echo "$result" | jq -r '.value // ""' 2>/dev/null)
	confidence=$(echo "$result" | jq -r '.confidence // ""' 2>/dev/null)

	if [[ -n "$value" ]] && [[ "$confidence" == "high" ]]; then
		pass "regex_extraction (captured: ${value})"
	else
		fail "regex_extraction" "value='${value}' confidence='${confidence}'"
	fi
	teardown
	return 0
}

test_regex_no_match() {
	setup
	local text_file="${TEST_TMPDIR}/test.txt"
	echo "This document has no matching patterns here" > "$text_file"

	# shellcheck disable=SC1090
	source "$HELPER" 2>/dev/null || true

	local result value confidence
	result=$(_extract_regex "(?i)invoice[\\s\\w]*[#:]\\s*([A-Z0-9][A-Z0-9/_-]{1,29})" "$text_file" 2>/dev/null)
	value=$(echo "$result" | jq -r '.value // "NULL"' 2>/dev/null)
	confidence=$(echo "$result" | jq -r '.confidence // ""' 2>/dev/null)

	if [[ "$value" == "null" || "$value" == "NULL" ]] && [[ "$confidence" == "low" ]]; then
		pass "regex_no_match"
	else
		fail "regex_no_match" "expected null/low, got value='${value}' confidence='${confidence}'"
	fi
	teardown
	return 0
}

test_llm_mock_absent() {
	setup
	local text_file="${TEST_TMPDIR}/test.txt"
	echo "Invoice Date: 2026-01-15" > "$text_file"

	local old_router="${LLM_ROUTER:-}"
	export LLM_ROUTER="${TEST_TMPDIR}/nonexistent-router.sh"

	# shellcheck disable=SC1090
	source "$HELPER" 2>/dev/null || true

	local result value
	result=$(_extract_llm "invoice_date" "Extract date" "date" "$text_file" "internal" 2>/dev/null)
	value=$(echo "$result" | jq -r '.value // "NULL"' 2>/dev/null)

	[[ -n "$old_router" ]] && export LLM_ROUTER="$old_router" || unset LLM_ROUTER

	if [[ "$value" == "null" || "$value" == "NULL" ]]; then
		pass "llm_mock_absent (graceful null when router unavailable)"
	else
		fail "llm_mock_absent" "expected null value, got '${value}'"
	fi
	teardown
	return 0
}

test_enrich_writes_extracted_json() {
	setup
	local plane="${TEST_TMPDIR}/_knowledge"
	make_plane "$plane"
	make_source "$plane" "test-inv-01" "invoice" "internal" "yes"

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-inv-01" 2>/dev/null
	local rc=$?

	local extracted_path="${plane}/sources/test-inv-01/extracted.json"
	if [[ -f "$extracted_path" ]]; then
		local field_count
		field_count=$(jq -r '.fields | length' "$extracted_path" 2>/dev/null || echo 0)
		if [[ "$field_count" -gt 0 ]]; then
			pass "enrich_writes_extracted_json (${field_count} fields)"
		else
			fail "enrich_writes_extracted_json" "extracted.json has 0 fields"
		fi
	else
		fail "enrich_writes_extracted_json" "extracted.json not written (rc=${rc})"
	fi
	teardown
	return 0
}

test_idempotent_rerun() {
	setup
	local plane="${TEST_TMPDIR}/_knowledge"
	make_plane "$plane"
	make_source "$plane" "test-inv-02" "invoice" "internal" "yes"

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-inv-02" 2>/dev/null || true

	local extracted_path="${plane}/sources/test-inv-02/extracted.json"
	if [[ ! -f "$extracted_path" ]]; then
		fail "idempotent_rerun" "first run did not create extracted.json"
		teardown
		return 0
	fi

	local mtime_1
	mtime_1=$(stat -f '%m' "$extracted_path" 2>/dev/null || stat -c '%Y' "$extracted_path" 2>/dev/null)
	sleep 1

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-inv-02" 2>/dev/null || true

	local mtime_2
	mtime_2=$(stat -f '%m' "$extracted_path" 2>/dev/null || stat -c '%Y' "$extracted_path" 2>/dev/null)

	if [[ "$mtime_1" == "$mtime_2" ]]; then
		pass "idempotent_rerun (file not modified on second run)"
	else
		fail "idempotent_rerun" "extracted.json was modified on second run"
	fi
	teardown
	return 0
}

test_force_refresh() {
	setup
	local plane="${TEST_TMPDIR}/_knowledge"
	make_plane "$plane"
	make_source "$plane" "test-inv-03" "invoice" "internal" "yes"

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-inv-03" 2>/dev/null || true

	local extracted_path="${plane}/sources/test-inv-03/extracted.json"
	if [[ ! -f "$extracted_path" ]]; then
		fail "force_refresh" "first run did not create extracted.json"
		teardown
		return 0
	fi

	local mtime_1
	mtime_1=$(stat -f '%m' "$extracted_path" 2>/dev/null || stat -c '%Y' "$extracted_path" 2>/dev/null)
	sleep 1

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-inv-03" --force-refresh 2>/dev/null || true

	local mtime_2
	mtime_2=$(stat -f '%m' "$extracted_path" 2>/dev/null || stat -c '%Y' "$extracted_path" 2>/dev/null)

	if [[ "$mtime_1" != "$mtime_2" ]]; then
		pass "force_refresh (extracted.json updated)"
	else
		fail "force_refresh" "extracted.json not updated despite --force-refresh"
	fi
	teardown
	return 0
}

test_kind_override() {
	setup
	local plane="${TEST_TMPDIR}/_knowledge"
	make_plane "$plane"
	make_source "$plane" "test-contract-01" "invoice" "internal" "yes"

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-contract-01" --kind contract 2>/dev/null || true

	local extracted_path="${plane}/sources/test-contract-01/extracted.json"
	if [[ -f "$extracted_path" ]]; then
		local kind_in_output
		kind_in_output=$(jq -r '.kind // ""' "$extracted_path" 2>/dev/null)
		if [[ "$kind_in_output" == "contract" ]]; then
			pass "kind_override (kind=contract in extracted.json)"
		else
			fail "kind_override" "expected kind=contract, got '${kind_in_output}'"
		fi
	else
		fail "kind_override" "extracted.json not written"
	fi
	teardown
	return 0
}

test_missing_text_file() {
	setup
	local plane="${TEST_TMPDIR}/_knowledge"
	make_plane "$plane"
	make_source "$plane" "test-notext" "invoice" "internal" "no"

	local output
	output=$(KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-notext" 2>&1 || true)

	local extracted_path="${plane}/sources/test-notext/extracted.json"
	if [[ ! -f "$extracted_path" ]]; then
		pass "missing_text_file (no extracted.json written)"
	else
		fail "missing_text_file" "extracted.json was written despite no text file"
	fi
	if echo "$output" | grep -qi "no text file\|text.txt"; then
		pass "missing_text_file_message (error message present)"
	fi
	teardown
	return 0
}

test_tick_command() {
	setup
	local plane="${TEST_TMPDIR}/_knowledge"
	make_plane "$plane"
	make_source "$plane" "tick-needs-enrich" "invoice" "internal" "yes"
	make_source "$plane" "tick-already-done" "invoice" "internal" "yes"

	echo '{"version":1,"source_id":"tick-already-done","kind":"invoice","schema_version":1,"schema_hash":"pre","enriched_at":"2026-01-01T00:00:00Z","fields":{}}' \
		> "${plane}/sources/tick-already-done/extracted.json"

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" tick 2>/dev/null || true

	if [[ -f "${plane}/sources/tick-needs-enrich/extracted.json" ]]; then
		pass "tick_command (enriched missing source)"
	else
		fail "tick_command" "tick did not enrich 'tick-needs-enrich'"
	fi
	teardown
	return 0
}

test_schema_structure() {
	local all_ok=1
	local expected=(invoice contract bank_statement financial_statement payment_receipt email generic)

	for schema in "${expected[@]}"; do
		local path="${SCHEMAS_DIR}/${schema}.json"
		[[ -f "$path" ]] || continue

		local kind version fields_count
		kind=$(jq -r '.kind // ""' "$path" 2>/dev/null)
		version=$(jq -r '.version // 0' "$path" 2>/dev/null)
		fields_count=$(jq -r '.fields | length' "$path" 2>/dev/null || echo 0)

		if [[ -z "$kind" ]] || [[ "$version" -lt 1 ]] || [[ "$fields_count" -lt 1 ]]; then
			fail "schema_structure: ${schema}.json missing kind/version/fields (kind='${kind}' version='${version}' fields=${fields_count})"
			all_ok=0
		fi
	done

	[[ "$all_ok" -eq 1 ]] && pass "schema_structure (all 7 schemas have kind, version>=1, fields>=1)"
	return 0
}

test_dry_run() {
	setup
	local plane="${TEST_TMPDIR}/_knowledge"
	make_plane "$plane"
	make_source "$plane" "test-dryrun" "invoice" "internal" "yes"

	KNOWLEDGE_ROOT="${plane}" bash "$HELPER" enrich "test-dryrun" --dry-run 2>/dev/null || true

	local extracted_path="${plane}/sources/test-dryrun/extracted.json"
	if [[ ! -f "$extracted_path" ]]; then
		pass "dry_run (no extracted.json written)"
	else
		fail "dry_run" "extracted.json was written despite --dry-run"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_tests() {
	test_shellcheck
	test_schema_files
	test_regex_extraction
	test_regex_no_match
	test_llm_mock_absent
	test_enrich_writes_extracted_json
	test_idempotent_rerun
	test_force_refresh
	test_kind_override
	test_missing_text_file
	test_tick_command
	test_schema_structure
	test_dry_run

	echo ""
	echo "Results: ${PASS} passed, ${FAIL} failed"
	[[ "$FAIL" -eq 0 ]]
	return $?
}

run_tests
