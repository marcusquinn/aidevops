#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit 1

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0
LARGE_ISSUES_JSON=""
LARGE_PRS_JSON=""
LARGE_FINDINGS_JSON=""

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="$TEST_ROOT/home"
	export LOGFILE="$TEST_ROOT/pulse.log"
	export PULSE_PREFETCH_CACHE_FILE="$TEST_ROOT/cache/pulse-prefetch.json"
	export PULSE_QUEUED_SCAN_LIMIT=200
	mkdir -p "$HOME" "$TEST_ROOT/cache"
	: >"$LOGFILE"
	return 0
}

teardown_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

build_large_json() {
	LARGE_ISSUES_JSON=$(python3 - <<'PY'
import json
payload = "x" * 300
print(json.dumps([
    {"number": i, "state": "open", "labels": [{"name": "bug"}], "assignees": [{"login": "dev"}], "updatedAt": "2026-06-26T00:00:00Z", "title": payload}
    for i in range(600)
]))
PY
)
	LARGE_PRS_JSON=$(python3 - <<'PY'
import json
payload = "y" * 300
print(json.dumps([
    {"number": i, "labels": [{"name": "ready"}], "assignees": [{"login": "dev"}], "reviewDecision": "APPROVED", "mergeable": "MERGEABLE", "updatedAt": "2026-06-26T00:00:00Z", "headRefOid": f"sha-{i:040d}", "title": payload}
    for i in range(600)
]))
PY
)
	LARGE_FINDINGS_JSON=$(python3 - <<'PY'
import json
payload = "z" * 300
print(json.dumps([
    {"pr": i, "file": "script.sh", "line": i, "severity": "medium", "body": payload}
    for i in range(600)
]))
PY
)
	return 0
}

gh_issue_list() {
	printf '%s' "$LARGE_ISSUES_JSON"
	return 0
}

pulse_pr_list_get() {
	printf '%s' "$LARGE_PRS_JSON"
	return 0
}

test_prefetch_fingerprint_accepts_large_lists() {
	setup_env
	# shellcheck source=../pulse-prefetch-infra.sh
	source "$SCRIPTS_DIR/pulse-prefetch-infra.sh"
	local issues_snapshot="" prs_snapshot="" hash=""
	issues_snapshot=$(printf '%s' "$LARGE_ISSUES_JSON" | jq -c \
		--arg schema "$_PREFETCH_SNAPSHOT_SCHEMA" --arg projection "$_PREFETCH_ISSUES_PROJECTION" \
		'{schema:$schema,repository:"owner/repo",collection:"issues",projection:$projection,
		  auth_scope:"github.com",generation:"large",source:"fixture",
		  fetched_at:"2026-06-26T00:00:00Z",complete:true,items:.}')
	prs_snapshot=$(printf '%s' "$LARGE_PRS_JSON" | jq -c \
		--arg schema "$_PREFETCH_SNAPSHOT_SCHEMA" --arg projection "$_PREFETCH_PRS_PROJECTION" \
		'{schema:$schema,repository:"owner/repo",collection:"prs",projection:$projection,
		  auth_scope:"github.com",generation:"large",source:"fixture",
		  fetched_at:"2026-06-26T00:00:00Z",complete:true,items:.}')
	hash=$(_compute_repo_state_fingerprint "owner/repo" "$issues_snapshot" "$prs_snapshot")
	if [[ "$hash" =~ ^[0-9a-f]{16}$ ]]; then
		print_result "prefetch fingerprint avoids large jq argv" 0
	else
		print_result "prefetch fingerprint avoids large jq argv" 1
	fi
	teardown_env
	return 0
}

test_prefetch_cache_entry_accepts_large_lists() {
	setup_env
	# shellcheck source=../pulse-prefetch-repo.sh
	source "$SCRIPTS_DIR/pulse-prefetch-repo.sh"
	local entry pr_count issue_count
	entry=$(_prefetch_build_cache_entry \
		"2026-06-26T00:00:00Z" \
		"2026-06-26T00:00:00Z" \
		"fingerprint" \
		"$LARGE_PRS_JSON" \
		"$LARGE_ISSUES_JSON")
	pr_count=$(printf '%s' "$entry" | jq '.prs | length')
	issue_count=$(printf '%s' "$entry" | jq '.issues | length')
	if [[ "$pr_count" == "600" && "$issue_count" == "600" ]]; then
		print_result "prefetch cache entry avoids large jq argv" 0
	else
		print_result "prefetch cache entry avoids large jq argv" 1
	fi
	teardown_env
	return 0
}

test_prefetch_cache_set_accepts_large_entry() {
	setup_env
	# shellcheck source=../pulse-prefetch-infra.sh
	source "$SCRIPTS_DIR/pulse-prefetch-infra.sh"
	local entry stored_count
	entry=$(jq -n \
		--slurpfile prs <(printf '%s' "$LARGE_PRS_JSON") \
		--slurpfile issues <(printf '%s' "$LARGE_ISSUES_JSON") \
		'{last_prefetch:"2026-06-26T00:00:00Z", last_full_sweep:"2026-06-26T00:00:00Z", state_fingerprint:"fp", prs: $prs[0], issues: $issues[0]}')
	_prefetch_cache_set "owner/repo" "$entry"
	stored_count=$(jq '.["owner/repo"].prs | length' "$PULSE_PREFETCH_CACHE_FILE")
	if [[ "$stored_count" == "600" ]]; then
		print_result "prefetch cache set avoids large jq argv" 0
	else
		print_result "prefetch cache set avoids large jq argv" 1
	fi
	teardown_env
	return 0
}

test_quality_feedback_summary_accepts_large_details() {
	setup_env
	# shellcheck source=../quality-feedback-helper.sh
	source "$SCRIPTS_DIR/quality-feedback-helper.sh"
	local output detail_count
	output=$(_print_scan_summary true false false "$LARGE_FINDINGS_JSON" 600 600 0)
	detail_count=$(printf '%s' "$output" | jq '.details | length')
	if [[ "$detail_count" == "600" ]]; then
		print_result "quality feedback summary avoids large jq argv" 0
	else
		print_result "quality feedback summary avoids large jq argv" 1
	fi
	teardown_env
	return 0
}

test_objective_reconciliation_accepts_large_lists() {
	local output issue_count pr_count
	output=$(printf '%s\n%s\n' "$LARGE_ISSUES_JSON" "$LARGE_PRS_JSON" | jq -sc \
		--arg merged '{"42":true}' \
		'{issues: .[0], prs: .[1], merged_lookup: $merged}')
	issue_count=$(printf '%s' "$output" | jq '.issues | length')
	pr_count=$(printf '%s' "$output" | jq '.prs | length')
	if [[ "$issue_count" == "600" && "$pr_count" == "600" ]]; then
		print_result "objective reconciliation avoids large jq argv" 0
	else
		print_result "objective reconciliation avoids large jq argv" 1
	fi
	return 0
}

test_objective_reconciliation_defaults_empty_lists() {
	local issues_json="" objective_prs='[{"number":7}]' output
	output=$(printf '%s\n%s\n' "${issues_json:-[]}" "${objective_prs:-[]}" | jq -sc \
		'{issues: .[0], prs: .[1]}')
	if printf '%s' "$output" | jq -e '.issues == [] and .prs == [{"number":7}]' >/dev/null; then
		print_result "objective reconciliation preserves indices for empty lists" 0
	else
		print_result "objective reconciliation preserves indices for empty lists" 1
	fi
	return 0
}

test_known_large_argjson_patterns_absent() {
	local failed=0
	if grep -nE -- '--argjson (prs|issues) "\$\{PREFETCH_UPDATED_(PRS|ISSUES)' "$SCRIPTS_DIR/pulse-prefetch-fetch.sh" >/dev/null 2>&1; then
		failed=1
	fi
	# shellcheck disable=SC2016 # Literal regex: match shell variable names in source.
	if grep -nE -- '--argjson (issues|prs) "\$(issues_json|prs_json)"|--argjson entry "\$entry"' "$SCRIPTS_DIR/pulse-prefetch-infra.sh" >/dev/null 2>&1; then
		failed=1
	fi
	# shellcheck disable=SC2016 # Literal regex: match shell variable names in source.
	if grep -nE -- '--argjson details "\$details_json"' "$SCRIPTS_DIR/quality-feedback-helper.sh" >/dev/null 2>&1; then
		failed=1
	fi
	# shellcheck disable=SC2016 # Literal regex: match shell variable names in source.
	if grep -nE -- '--argjson (issues|prs) "\$(issues_json|objective_prs)"' "$SCRIPTS_DIR/pulse-issue-reconcile.sh" >/dev/null 2>&1; then
		failed=1
	fi
	print_result "known-large jq --argjson variables stay out of argv" "$failed"
	return 0
}

main() {
	build_large_json
	test_prefetch_fingerprint_accepts_large_lists
	test_prefetch_cache_entry_accepts_large_lists
	test_prefetch_cache_set_accepts_large_entry
	test_quality_feedback_summary_accepts_large_details
	test_objective_reconciliation_accepts_large_lists
	test_objective_reconciliation_defaults_empty_lists
	test_known_large_argjson_patterns_absent
	printf '\nTests run: %d\n' "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		printf 'Tests failed: %d\n' "$TESTS_FAILED"
		return 1
	fi
	printf 'All tests passed\n'
	return 0
}

main "$@"
