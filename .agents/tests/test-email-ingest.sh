#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-email-ingest.sh — Tests for the .eml ingestion handler (t2854)
#
# Usage: bash .agents/tests/test-email-ingest.sh
#
# Runs against the sample .eml fixtures in tests/fixtures/sample-emails/
# and verifies parser output + ingestion behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${SCRIPT_DIR%/tests}"
SCRIPTS_DIR="${AGENTS_DIR}/scripts"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/sample-emails"
EMAIL_PARSER="${SCRIPTS_DIR}/email_parse.py"
EMAIL_INGEST="${SCRIPTS_DIR}/email-ingest-helper.sh"

PASS=0
FAIL=0
TOTAL=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

_test_pass() {
	local name="$1"
	PASS=$((PASS + 1))
	TOTAL=$((TOTAL + 1))
	printf "  PASS: %s\n" "$name"
	return 0
}

_test_fail() {
	local name="$1"
	local reason="${2:-}"
	FAIL=$((FAIL + 1))
	TOTAL=$((TOTAL + 1))
	printf "  FAIL: %s — %s\n" "$name" "$reason"
	return 0
}

_assert_file_exists() {
	local path="$1"
	local label="$2"
	if [[ -f "$path" ]]; then
		_test_pass "$label"
	else
		_test_fail "$label" "file not found: $path"
	fi
	return 0
}

_assert_json_field() {
	local json="$1"
	local field="$2"
	local expected="$3"
	local label="$4"
	local actual
	actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "")
	if [[ "$actual" == "$expected" ]]; then
		_test_pass "$label"
	else
		_test_fail "$label" "expected '$expected', got '$actual'"
	fi
	return 0
}

_assert_json_nonempty() {
	local json="$1"
	local field="$2"
	local label="$3"
	local actual
	actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "")
	if [[ -n "$actual" && "$actual" != "null" ]]; then
		_test_pass "$label"
	else
		_test_fail "$label" "field $field is empty or null"
	fi
	return 0
}

_assert_contains() {
	local content="$1"
	local needle="$2"
	local label="$3"
	if echo "$content" | grep -qi "$needle" 2>/dev/null; then
		_test_pass "$label"
	else
		_test_fail "$label" "content does not contain '$needle'"
	fi
	return 0
}

_assert_not_contains() {
	local content="$1"
	local needle="$2"
	local label="$3"
	if echo "$content" | grep -qi "$needle" 2>/dev/null; then
		_test_fail "$label" "content unexpectedly contains '$needle'"
	else
		_test_pass "$label"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: Plaintext email parsing
# ---------------------------------------------------------------------------

test_plaintext_parse() {
	printf "\n--- Test: plaintext email parsing ---\n"
	local tmp_dir
	tmp_dir=$(mktemp -d -t "test-eml-XXXXXX")
	local json
	json=$(python3 "$EMAIL_PARSER" "${FIXTURES_DIR}/plaintext.eml" --output-dir "$tmp_dir" 2>&1)
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		_test_fail "plaintext parse exits 0" "exit code: $rc"
		rm -rf "$tmp_dir"
		return 0
	fi
	_test_pass "plaintext parse exits 0"

	_assert_json_field "$json" '.from' 'sender@example.com' "plaintext: from header"
	_assert_json_field "$json" '.to' 'recipient@example.com' "plaintext: to header"
	_assert_json_field "$json" '.cc' 'cc-user@example.com' "plaintext: cc header"
	_assert_json_field "$json" '.subject' 'Plain text test email' "plaintext: subject"
	_assert_json_field "$json" '.message_id' '<plaintext-001@example.com>' "plaintext: message_id"
	_assert_json_nonempty "$json" '.body_text_path' "plaintext: body_text_path set"
	_assert_json_field "$json" '.body_html_path' 'null' "plaintext: no html body"

	local text_path
	text_path=$(echo "$json" | jq -r '.body_text_path')
	if [[ -f "$text_path" ]]; then
		local content
		content=$(<"$text_path")
		_assert_contains "$content" "plain text email" "plaintext: body content correct"
	else
		_test_fail "plaintext: body file exists" "missing $text_path"
	fi

	local att_count
	att_count=$(echo "$json" | jq '.attachments | length')
	_assert_json_field "$json" '.attachments | length' '0' "plaintext: zero attachments"

	rm -rf "$tmp_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: HTML-only email (with encoded headers)
# ---------------------------------------------------------------------------

test_html_only_parse() {
	printf "\n--- Test: HTML-only email parsing ---\n"
	local tmp_dir
	tmp_dir=$(mktemp -d -t "test-eml-XXXXXX")
	local json
	json=$(python3 "$EMAIL_PARSER" "${FIXTURES_DIR}/html-only.eml" --output-dir "$tmp_dir" 2>&1)
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		_test_fail "html-only parse exits 0" "exit code: $rc"
		rm -rf "$tmp_dir"
		return 0
	fi
	_test_pass "html-only parse exits 0"

	# UTF-8 subject should be decoded
	_assert_json_nonempty "$json" '.subject' "html-only: subject decoded"
	_assert_json_nonempty "$json" '.body_text_path' "html-only: text extracted from HTML"
	_assert_json_nonempty "$json" '.body_html_path' "html-only: html body saved"

	local text_path
	text_path=$(echo "$json" | jq -r '.body_text_path')
	if [[ -f "$text_path" ]]; then
		local content
		content=$(<"$text_path")
		_assert_contains "$content" "HTML Only Email" "html-only: text extracted correctly"
	else
		_test_fail "html-only: text file exists" "missing"
	fi

	rm -rf "$tmp_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Email with attachments
# ---------------------------------------------------------------------------

test_with_attachments_parse() {
	printf "\n--- Test: email with attachments ---\n"
	local tmp_dir
	tmp_dir=$(mktemp -d -t "test-eml-XXXXXX")
	local json
	json=$(python3 "$EMAIL_PARSER" "${FIXTURES_DIR}/with-attachments.eml" --output-dir "$tmp_dir" 2>&1)
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		_test_fail "attachments parse exits 0" "exit code: $rc"
		rm -rf "$tmp_dir"
		return 0
	fi
	_test_pass "attachments parse exits 0"

	_assert_json_nonempty "$json" '.body_text_path' "attachments: text body present"
	_assert_json_nonempty "$json" '.body_html_path' "attachments: html body present"

	local att_count
	att_count=$(echo "$json" | jq '.attachments | length')
	if [[ "$att_count" -eq 2 ]]; then
		_test_pass "attachments: 2 attachments found"
	else
		_test_fail "attachments: 2 attachments found" "got $att_count"
	fi

	# Check first attachment is notes.txt
	local first_fn
	first_fn=$(echo "$json" | jq -r '.attachments[0].filename')
	_assert_json_field "$json" '.attachments[0].filename' 'notes.txt' "attachments: first is notes.txt"

	# Check second attachment is data.bin (base64 decoded)
	local second_fn
	second_fn=$(echo "$json" | jq -r '.attachments[1].filename')
	_assert_json_field "$json" '.attachments[1].filename' 'data.bin' "attachments: second is data.bin"

	# Verify data.bin content was decoded from base64
	local data_path
	data_path=$(echo "$json" | jq -r '.attachments[1].content_path')
	if [[ -f "$data_path" ]]; then
		local data_content
		data_content=$(<"$data_path")
		_assert_contains "$data_content" "Hello World" "attachments: base64 decoded correctly"
	else
		_test_fail "attachments: data.bin exists" "missing"
	fi

	rm -rf "$tmp_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Tracking pixel removal
# ---------------------------------------------------------------------------

test_tracking_pixel_removal() {
	printf "\n--- Test: tracking pixel removal ---\n"
	local tmp_dir
	tmp_dir=$(mktemp -d -t "test-eml-XXXXXX")
	local json
	json=$(python3 "$EMAIL_PARSER" "${FIXTURES_DIR}/with-tracking-pixel.eml" --output-dir "$tmp_dir" 2>&1)
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		_test_fail "tracking parse exits 0" "exit code: $rc"
		rm -rf "$tmp_dir"
		return 0
	fi
	_test_pass "tracking parse exits 0"

	# Run full ingestion which applies sanitisation
	local tmp_repo
	tmp_repo=$(mktemp -d -t "test-repo-track-XXXXXX")
	local kroot="${tmp_repo}/_knowledge"
	mkdir -p "${kroot}/sources" "${kroot}/inbox" "${kroot}/staging" \
		"${kroot}/index" "${kroot}/collections" "${kroot}/_config"
	printf '{"version":1}\n' > "${kroot}/_config/knowledge.json"

	local ingest_out
	ingest_out=$(bash "$EMAIL_INGEST" ingest "${FIXTURES_DIR}/with-tracking-pixel.eml" \
		--repo-path "$tmp_repo" --id "track-test" 2>&1)
	local ingest_rc=$?

	if [[ $ingest_rc -ne 0 ]]; then
		_test_fail "tracking: ingest exits 0" "exit code: $ingest_rc"
		rm -rf "$tmp_repo"
	else
		_test_pass "tracking: ingest exits 0"
		local html_stored="${kroot}/sources/track-test/body.html"
		if [[ -f "$html_stored" ]]; then
			local content
			content=$(<"$html_stored")
			_assert_not_contains "$content" "tracker.example.com/pixel.gif\"" "tracking: pixel img stripped"
			_assert_contains "$content" "tracker stripped" "tracking: replaced with comment"
			_assert_not_contains "$content" "utm_source" "tracking: UTM params stripped"
			_assert_contains "$content" "Newsletter" "tracking: content preserved"
		else
			_test_fail "tracking: html body exists" "missing $html_stored"
		fi
		rm -rf "$tmp_repo"
	fi

	rm -rf "$tmp_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Full ingestion via email-ingest-helper.sh
# ---------------------------------------------------------------------------

test_full_ingestion() {
	printf "\n--- Test: full ingestion pipeline ---\n"

	# Create a temp knowledge plane
	local tmp_repo
	tmp_repo=$(mktemp -d -t "test-repo-XXXXXX")
	local kroot="${tmp_repo}/_knowledge"
	mkdir -p "${kroot}/sources" "${kroot}/inbox" "${kroot}/staging" \
		"${kroot}/index" "${kroot}/collections" "${kroot}/_config"

	# Write minimal knowledge.json
	printf '{"version":1}\n' > "${kroot}/_config/knowledge.json"

	# Run ingestion
	local output
	output=$(bash "$EMAIL_INGEST" ingest "${FIXTURES_DIR}/with-attachments.eml" \
		--repo-path "$tmp_repo" --id "test-email" 2>&1)
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		_test_fail "full ingest exits 0" "exit code: $rc, output: $output"
		rm -rf "$tmp_repo"
		return 0
	fi
	_test_pass "full ingest exits 0"

	# Check parent source directory exists
	local parent_dir="${kroot}/sources/test-email"
	_assert_file_exists "${parent_dir}/meta.json" "ingest: parent meta.json exists"
	_assert_file_exists "${parent_dir}/text.txt" "ingest: parent text.txt exists"

	# Check parent meta has kind=email
	if [[ -f "${parent_dir}/meta.json" ]]; then
		local meta
		meta=$(<"${parent_dir}/meta.json")
		_assert_json_field "$meta" '.kind' 'email' "ingest: parent kind=email"
		_assert_json_nonempty "$meta" '.from' "ingest: parent has from field"
		_assert_json_nonempty "$meta" '.subject' "ingest: parent has subject field"
		_assert_json_nonempty "$meta" '.message_id' "ingest: parent has message_id"

		# Check attachments array in parent
		local att_count
		att_count=$(echo "$meta" | jq '.attachments | length')
		if [[ "$att_count" -eq 2 ]]; then
			_test_pass "ingest: parent lists 2 attachment children"
		else
			_test_fail "ingest: parent lists 2 attachment children" "got $att_count"
		fi
	fi

	# Check child source directories exist
	local child_dirs
	child_dirs=$(find "${kroot}/sources" -mindepth 1 -maxdepth 1 -type d -name "test-email-att-*" | wc -l | tr -d ' ')
	if [[ "$child_dirs" -eq 2 ]]; then
		_test_pass "ingest: 2 child source dirs created"
	else
		_test_fail "ingest: 2 child source dirs created" "got $child_dirs"
	fi

	# Check a child meta has parent_source link
	local first_child
	first_child=$(find "${kroot}/sources" -mindepth 1 -maxdepth 1 -type d -name "test-email-att-*" | head -1)
	if [[ -n "$first_child" && -f "${first_child}/meta.json" ]]; then
		local child_meta
		child_meta=$(<"${first_child}/meta.json")
		_assert_json_field "$child_meta" '.parent_source' 'test-email' "ingest: child has parent_source link"
		_assert_json_nonempty "$child_meta" '.attachment_filename' "ingest: child has attachment_filename"
	else
		_test_fail "ingest: child meta.json exists" "missing"
	fi

	rm -rf "$tmp_repo"
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: Sanitisation idempotency
# ---------------------------------------------------------------------------

test_sanitise_idempotency() {
	printf "\n--- Test: sanitisation idempotency ---\n"

	# Ingest the tracking email twice into separate repos and compare body.html
	local tmp_repo1 tmp_repo2
	tmp_repo1=$(mktemp -d -t "test-repo-idem1-XXXXXX")
	tmp_repo2=$(mktemp -d -t "test-repo-idem2-XXXXXX")

	for repo in "$tmp_repo1" "$tmp_repo2"; do
		local kroot="${repo}/_knowledge"
		mkdir -p "${kroot}/sources" "${kroot}/inbox" "${kroot}/staging" \
			"${kroot}/index" "${kroot}/collections" "${kroot}/_config"
		printf '{"version":1}\n' > "${kroot}/_config/knowledge.json"
	done

	bash "$EMAIL_INGEST" ingest "${FIXTURES_DIR}/with-tracking-pixel.eml" \
		--repo-path "$tmp_repo1" --id "idem-test" >/dev/null 2>&1 || true
	bash "$EMAIL_INGEST" ingest "${FIXTURES_DIR}/with-tracking-pixel.eml" \
		--repo-path "$tmp_repo2" --id "idem-test" >/dev/null 2>&1 || true

	local html1="${tmp_repo1}/_knowledge/sources/idem-test/body.html"
	local html2="${tmp_repo2}/_knowledge/sources/idem-test/body.html"

	if [[ -f "$html1" && -f "$html2" ]]; then
		if diff -q "$html1" "$html2" >/dev/null 2>&1; then
			_test_pass "sanitise: idempotent (two runs same result)"
		else
			_test_fail "sanitise: idempotent" "output differs between runs"
		fi
	else
		_test_fail "sanitise: idempotent" "body.html missing from one or both runs"
	fi

	rm -rf "$tmp_repo1" "$tmp_repo2"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	printf "=== Email Ingestion Tests (t2854) ===\n"

	# Pre-flight checks
	if ! command -v python3 >/dev/null 2>&1; then
		printf "SKIP: python3 not available\n"
		exit 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		printf "SKIP: jq not available\n"
		exit 0
	fi
	if [[ ! -f "$EMAIL_PARSER" ]]; then
		printf "SKIP: email_parse.py not found at %s\n" "$EMAIL_PARSER"
		exit 1
	fi

	test_plaintext_parse
	test_html_only_parse
	test_with_attachments_parse
	test_tracking_pixel_removal
	test_full_ingestion
	test_sanitise_idempotency

	printf "\n=== Results: %d passed, %d failed, %d total ===\n" "$PASS" "$FAIL" "$TOTAL"

	if [[ "$FAIL" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
