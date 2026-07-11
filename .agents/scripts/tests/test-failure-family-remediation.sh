#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d -t failure-family-remediation.XXXXXX)"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$label"
		return 0
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s: expected=%s actual=%s\n' "$label" "$expected" "$actual"
	return 0
}

assert_absent() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		printf 'PASS %s\n' "$label"
		return 0
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s: found private value %s\n' "$label" "$needle"
	return 0
}

test_stable_failure_fingerprint() {
	local metrics="${TEST_ROOT}/metrics.jsonl"
	local now=""
	now=$(date +%s)
	printf '%s\n' \
		"{\"ts\":$((now - 30)),\"repo_slug\":\"private/example\",\"session_key\":\"one\",\"result\":\"watchdog_stall_killed\",\"exit_code\":79}" \
		"{\"ts\":$((now - 20)),\"repo_slug\":\"private/example\",\"session_key\":\"two\",\"result\":\"watchdog_stall_killed\",\"exit_code\":79}" \
		"{\"ts\":$((now - 10)),\"repo_slug\":\"private/example\",\"session_key\":\"three\",\"result\":\"watchdog_stall_killed\",\"exit_code\":79}" >"$metrics"
	local output=""
	output=$(WAH_METRICS_FILE="$metrics" WAH_PULSE_STATS_FILE="${TEST_ROOT}/missing-stats" \
		"${SCRIPT_DIR}/worker-activity-helper.sh" summary --since 1h --json --no-pr-check)
	assert_eq "watchdog family uses stable fingerprint" "ff-v1:watchdog-stall" \
		"$(printf '%s' "$output" | jq -r '.metrics.failure_families[0].fingerprint')"
	assert_eq "three distinct sessions produce high confidence" "high" \
		"$(printf '%s' "$output" | jq -r '.metrics.failure_families[0].confidence')"
	return 0
}

test_threshold_and_privacy() {
	local family='{"fingerprint":"ff-v1:watchdog-stall","family":"watchdog-stall","count":3,"distinct_sessions":3,"first_ts":1,"last_ts":2,"confidence":"high","recovery_outcome":"recurring"}'
	local report=""
	report=$(jq -n --arg window 15m --arg since 24h --arg recent 1h \
		--argjson threshold 3 --argjson failure_threshold 3 \
		--argjson current '{}' \
		--argjson summary "{\"metrics\":{\"failure_families\":[$family]}}" \
		--argjson recent_summary "{\"metrics\":{\"failure_families\":[$family]}}" \
		--argjson providers '{}' --argjson runner '{}' --argjson api '{}' \
		--argjson queue '{"aggregate":{}}' -f "${SCRIPT_DIR}/pulse-check-report.jq")
	assert_eq "high-confidence recurrence crosses autofile threshold" "true" \
		"$(printf '%s' "$report" | jq -r '.findings[] | select(.id == "worker-failure-family-watchdog-stall") | .autofile')"
	assert_absent "aggregate report omits repository slug" "private/example" "$report"
	assert_absent "aggregate report omits local path" "$HOME" "$report"
	return 0
}

test_dedup_and_recovery_closure() {
	local created="${TEST_ROOT}/created"
	local issue_body="${TEST_ROOT}/issue-body"
	local edited_body="${TEST_ROOT}/edited-body"
	local closed="${TEST_ROOT}/closed"
	local wrappers="${TEST_ROOT}/wrappers.sh"
	local family='{"id":"worker-failure-family-watchdog-stall","title":"Remediate recurrent worker failure family: watchdog-stall","severity":"high","evidence":["fingerprint=ff-v1:watchdog-stall","failures_in_window=3"],"recommendation":"Repair the aggregate family.","family_fingerprint":"ff-v1:watchdog-stall","family_count":3,"family_recent_count":3}'
	local increased_family='{"id":"worker-failure-family-watchdog-stall","title":"Remediate recurrent worker failure family: watchdog-stall","severity":"high","evidence":["fingerprint=ff-v1:watchdog-stall","failures_in_window=4"],"recommendation":"Repair the aggregate family.","family_fingerprint":"ff-v1:watchdog-stall","family_count":4,"family_recent_count":4}'

	cat >"$wrappers" <<'WRAPPERS'
gh_create_issue() {
	local body_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--body-file) body_file="$2"; shift 2 ;;
			*) shift ;;
		esac
	done
	printf '1\n' >>"$TEST_CREATED"
	cp "$body_file" "$TEST_ISSUE_BODY"
	printf 'created-42\n'
	return 0
}
WRAPPERS
	export TEST_CREATED="$created" TEST_ISSUE_BODY="$issue_body"
	export PULSE_CHECK_SOURCE_ONLY=1 PULSE_CHECK_GH_WRAPPERS="$wrappers"
	# shellcheck source=../pulse-check-helper.sh
	source "${SCRIPT_DIR}/pulse-check-helper.sh"

	gh() {
		if [[ "$1 $2" == "issue list" && "$*" == *"failure-family-state:start"* ]]; then
			if [[ -s "$TEST_ISSUE_BODY" ]]; then
				jq -n --rawfile body "$TEST_ISSUE_BODY" '[{number:42,body:$body,createdAt:"2000-01-01T00:00:00Z",url:"https://example.invalid/42"}]'
			else
				printf '[]\n'
			fi
			return 0
		fi
		if [[ "$1 $2" == "issue list" ]]; then
			[[ -s "$TEST_CREATED" ]] && printf '[{"number":42,"url":"https://example.invalid/42"}]\n' || printf '[]\n'
			return 0
		fi
		if [[ "$1" == "api" && "$2" == *"/issues/42" ]]; then
			jq -n --rawfile body "$TEST_ISSUE_BODY" '{body:$body}' | jq -r '.body'
			return 0
		fi
		if [[ "$1 $2" == "issue edit" ]]; then
			local previous=""
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == "--body-file" ]]; then cp "$2" "$edited_body"; cp "$2" "$TEST_ISSUE_BODY"; return 0; fi
				previous="$1"
				shift
			done
			: "$previous"
			return 0
		fi
		if [[ "$1 $2" == "issue close" ]]; then
			printf 'closed\n' >"$closed"
			return 0
		fi
		return 1
	}

	_apply_finding "owner/repo" "$family"
	_apply_finding "owner/repo" "$increased_family"
	assert_eq "recurrence creates one deduplicated task" "1" "$(wc -l <"$created" | tr -d ' ')"
	assert_absent "worker-ready issue body omits private slug" "private/example" "$(<"$issue_body")"
	assert_eq "dedup refreshes existing evidence in place" "yes" "$([[ -s "$edited_body" ]] && printf yes || printf no)"

	_reconcile_failure_family_remediations "owner/repo" '{"failure_family_remediation":[]}'
	assert_eq "zero recurrence after observation closes remediation" "yes" "$([[ -s "$closed" ]] && printf yes || printf no)"
	return 0
}

test_nmr_reason_revalidation() {
	# shellcheck source=../pulse-nmr-approval.sh
	source "${SCRIPT_DIR}/pulse-nmr-approval.sh"
	local authority=""
	authority=$(_nmr_reason_metadata_from_comments '[{"body":"<!-- nmr-reason code=billing class=genuine-authority -->"}]')
	assert_eq "billing reason requires cryptographic authority" "true" "$(printf '%s' "$authority" | jq -r '.requires_crypto')"

	_nmr_reason_metadata() { printf '{"code":"missing_context","class":"temporary","source":"structured-marker","revalidate_after_seconds":1,"requires_crypto":false}\n'; return 0; }
	_nmr_revalidation_due() { return 0; }
	_nmr_temporary_assumption_resolved() { printf 'worker guidance restored\n'; return 0; }
	_nmr_record_revalidation_state() { return 0; }
	_nmr_evaluate_reason_metadata 42 owner/repo 2000-01-01T00:00:00Z
	assert_eq "resolved temporary NMR returns to automation" "auto" "$_NMR_REASON_ACTION"
	assert_eq "temporary NMR never claims cryptographic approval" "temporary NMR revalidated (missing_context): worker guidance restored" "$_NMR_REASON_OVERRIDE"
	return 0
}

main() {
	test_stable_failure_fingerprint
	test_threshold_and_privacy
	test_dedup_and_recovery_closure
	test_nmr_reason_revalidation
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
