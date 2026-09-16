#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GSC quota-project propagation with user ADC.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GSC_SCRIPT="${TEST_SCRIPT_DIR}/../seo-export-gsc.sh"
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export GOOGLE_APPLICATION_CREDENTIALS="${TMP_HOME}/adc.json"
export REQUEST_LOG="${TMP_HOME}/requests.log"
export OUTPUT_LOG="${TMP_HOME}/output.log"
export GCLOUD_TOKEN="test-adc-token"
export CURL_EXIT_CODE=0
mkdir -p "${HOME}/.config/aidevops"

PASS=0
FAIL=0

gcloud() {
	printf '%s\n' "$GCLOUD_TOKEN"
	return 0
}

curl() {
	printf '%s\n' "$*" >>"$REQUEST_LOG"
	if [[ "$CURL_EXIT_CODE" -ne 0 ]]; then
		printf 'simulated curl failure\n' >&2
		return "$CURL_EXIT_CODE"
	fi
	printf '%s\n' '{"rows":[{"keys":["quota test","https://example.com/"],"clicks":1,"impressions":2,"ctr":0.5,"position":1}]}'
	return 0
}

export -f gcloud curl

assert_contains() {
	local name="$1"
	local file="$2"
	local expected="$3"
	if grep -Fq -- "$expected" "$file"; then
		printf 'PASS: %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf 'FAIL: %s - missing %s\n' "$name" "$expected"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local file="$2"
	local unexpected="$3"
	if grep -Fq -- "$unexpected" "$file"; then
		printf 'FAIL: %s - found %s\n' "$name" "$unexpected"
		FAIL=$((FAIL + 1))
	else
		printf 'PASS: %s\n' "$name"
		PASS=$((PASS + 1))
	fi
	return 0
}

assert_occurrence_count() {
	local name="$1"
	local file="$2"
	local needle="$3"
	local expected="$4"
	local actual
	actual=$(grep -Fc -- "$needle" "$file" || true)
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS: %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf 'FAIL: %s - expected %s occurrences, got %s\n' "$name" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

reset_case() {
	: >"$REQUEST_LOG"
	: >"$OUTPUT_LOG"
	: >"${HOME}/.config/aidevops/credentials.sh"
	unset GSC_ACCESS_TOKEN GSC_QUOTA_PROJECT
	CURL_EXIT_CODE=0
	return 0
}

run_export() {
	"$GSC_SCRIPT" example.com --days 1 >"$OUTPUT_LOG" 2>&1
}

reset_case
printf '%s\n' '{"type":"authorized_user","quota_project_id":"quota-project-123"}' >"$GOOGLE_APPLICATION_CREDENTIALS"
run_export
assert_contains "user ADC sends quota project" "$REQUEST_LOG" "x-goog-user-project: quota-project-123"

reset_case
printf '%s\n' '{"type":"authorized_user"}' >"$GOOGLE_APPLICATION_CREDENTIALS"
if run_export; then
	printf 'FAIL: user ADC without quota project should fail\n'
	FAIL=$((FAIL + 1))
else
	printf 'PASS: user ADC without quota project fails\n'
	PASS=$((PASS + 1))
fi
assert_contains "missing quota project is actionable" "$OUTPUT_LOG" "gcloud auth application-default set-quota-project <project>"
assert_not_contains "missing quota project prevents request" "$REQUEST_LOG" "searchconsole.googleapis.com"

reset_case
printf '%s\n' '{"type":"service_account","project_id":"service-project"}' >"$GOOGLE_APPLICATION_CREDENTIALS"
run_export
assert_not_contains "service account omits user quota header" "$REQUEST_LOG" "x-goog-user-project"

reset_case
printf '%s\n' 'GSC_ACCESS_TOKEN="static-test-token"' >"${HOME}/.config/aidevops/credentials.sh"
printf '%s\n' '{"type":"authorized_user","quota_project_id":"ignored-project"}' >"$GOOGLE_APPLICATION_CREDENTIALS"
run_export
assert_not_contains "static token does not inherit ADC quota project" "$REQUEST_LOG" "x-goog-user-project"

reset_case
printf '%s\n' 'GSC_ACCESS_TOKEN="static-test-token"' 'GSC_QUOTA_PROJECT="explicit-project"' >"${HOME}/.config/aidevops/credentials.sh"
printf '%s\n' '{"type":"service_account","project_id":"service-project"}' >"$GOOGLE_APPLICATION_CREDENTIALS"
run_export
assert_contains "explicit quota project overrides credential mode" "$REQUEST_LOG" "x-goog-user-project: explicit-project"

reset_case
printf '%s\n' '{"type":"service_account","project_id":"service-project"}' >"$GOOGLE_APPLICATION_CREDENTIALS"
CURL_EXIT_CODE=7
if run_export; then
	printf 'FAIL: curl transport failure should propagate\n'
	FAIL=$((FAIL + 1))
else
	printf 'PASS: curl transport failure propagates\n'
	PASS=$((PASS + 1))
fi
assert_occurrence_count "transport failure does not retry alternate property" "$REQUEST_LOG" "searchconsole.googleapis.com" "1"
assert_contains "transport diagnostic is retained" "$OUTPUT_LOG" "simulated curl failure"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
