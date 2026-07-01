#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-capture.sh - Local fixture tests for reach capture artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../reach-helper.sh"

PASS=0
FAIL=0

assert_contains() {
	local output="$1"
	local expected="$2"
	local description="$3"

	if grep -Fq -- "$expected" <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Expected output to contain: %s\n' "$expected"
		printf '    Output: %s\n' "$output"
	fi
	return 0
}

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local description="$3"

	if grep -Fq -- "$unexpected" <<<"$output"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Unexpected output: %s\n' "$unexpected"
		printf '    Output: %s\n' "$output"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_json_valid() {
	local output="$1"
	local description="$2"

	if python3 -m json.tool >/dev/null 2>&1 <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Invalid JSON: %s\n' "$output"
	fi
	return 0
}

json_value() {
	local json_text="$1"
	local field_name="$2"
	if python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))' "$field_name" <<<"$json_text"; then
		return 0
	fi
	return 1
}

meta_value() {
	local file_path="$1"
	local field_name="$2"
	if python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], ""))' "$file_path" "$field_name"; then
		return 0
	fi
	return 1
}

cleanup() {
	local temp_dir="$1"
	if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
		rm -rf "$temp_dir"
	fi
	return 0
}

printf '=== Reach Capture Tests ===\n\n'

temp_dir="$(mktemp -d)"
trap 'cleanup "$temp_dir"' EXIT

fixture="${temp_dir}/fixture.html"
cat >"$fixture" <<'HTML'
<!doctype html>
<html><body><h1>Fixture capture</h1><p>Local deterministic evidence.</p></body></html>
HTML

pushd "$temp_dir" >/dev/null

capture_output="$($HELPER capture --input "$fixture" --dest inbox --method file --format json)"
assert_json_valid "$capture_output" "capture emits valid JSON"
assert_contains "$capture_output" '"dest":"inbox"' "capture reports inbox destination"
assert_contains "$capture_output" '"sensitivity":"unverified"' "capture output keeps sensitivity unverified"
assert_contains "$capture_output" '"trust":"unverified"' "capture output keeps trust unverified"
assert_not_contains "$capture_output" "$temp_dir" "capture output omits private temp path"

artifact_path="$(json_value "$capture_output" artifact_path)"
meta_path="$(json_value "$capture_output" meta_path)"
if [[ -f "$artifact_path" && -f "$meta_path" ]]; then
	PASS=$((PASS + 1))
	printf '  PASS: capture writes artifact and metadata\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL: capture writes artifact and metadata\n'
fi

metadata_text="$(<"$meta_path")"
assert_json_valid "$metadata_text" "metadata is valid JSON"
assert_contains "$metadata_text" '"source_ref": "local-file:fixture.html"' "metadata uses sanitized source ref"
assert_contains "$metadata_text" '"method": "file"' "metadata records method"
assert_contains "$metadata_text" '"sensitivity": "unverified"' "metadata sensitivity is unverified"
assert_contains "$metadata_text" '"trust": "unverified"' "metadata trust is unverified"
assert_contains "$metadata_text" '"review_required": true' "metadata requires review"
assert_not_contains "$metadata_text" "$temp_dir" "metadata omits private temp path"

metadata_bytes="$(meta_value "$meta_path" bytes)"
if [[ "$metadata_bytes" -gt 0 ]]; then
	PASS=$((PASS + 1))
	printf '  PASS: metadata records non-zero byte count\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL: metadata records non-zero byte count\n'
fi

triage_text="$(<"_inbox/triage.log")"
assert_contains "$triage_text" '"source":"reach-capture"' "triage log records reach capture source"
assert_contains "$triage_text" '"sub":"web"' "triage log records web sub-folder"
assert_contains "$triage_text" '"status":"pending"' "triage log leaves capture pending"
assert_contains "$triage_text" '"trust":"unverified"' "triage log records unverified trust"
assert_not_contains "$triage_text" "$temp_dir" "triage log omits private temp path"

knowledge_output="$($HELPER capture --input "$fixture" --dest knowledge-inbox --method file --format json)"
assert_json_valid "$knowledge_output" "knowledge-inbox capture emits valid JSON"
assert_contains "$knowledge_output" '"dest":"knowledge-inbox"' "knowledge capture reports knowledge-inbox destination"
knowledge_artifact="$(json_value "$knowledge_output" artifact_path)"
if [[ "$knowledge_artifact" == _knowledge/inbox/web/* && -f "$knowledge_artifact" ]]; then
	PASS=$((PASS + 1))
	printf '  PASS: knowledge capture stays in knowledge inbox\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL: knowledge capture stays in knowledge inbox\n'
	printf '    Artifact: %s\n' "$knowledge_artifact"
fi

popd >/dev/null

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
