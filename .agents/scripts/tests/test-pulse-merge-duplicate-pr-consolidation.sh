#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-duplicate-pr-consolidation.sh — m-20260508-0e27c3 task 2.4 regression guards.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_DUPLICATE_FILE="${SCRIPT_DIR_TEST}/../pulse-merge-duplicate-consolidation.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
TEST_LINKED_ISSUES=""
TEST_PASSING_CHECKS=""
TEST_VERIFY_RC=0
TEST_ISSUE_LABELS=""

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "$detail"
	fi
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_functions_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_pmp_pr_label_csv\(\) \{/,/^}$/ { print }
		/^_pmp_pr_is_worker_owned_for_consolidation\(\) \{/,/^}$/ { print }
		/^_pmp_issue_blocks_pr_consolidation\(\) \{/,/^}$/ { print }
		/^_pmp_pr_consolidation_health_score\(\) \{/,/^}$/ { print }
		/^_pmp_close_superseded_sibling_pr\(\) \{/,/^}$/ { print }
		/^_pmp_consolidate_duplicate_pr_group\(\) \{/,/^}$/ { print }
		/^_pmp_consolidate_duplicate_pr_groups\(\) \{/,/^}$/ { print }
	' "$MERGE_DUPLICATE_FILE")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract consolidation functions from %s\n' "$MERGE_DUPLICATE_FILE" >&2
		return 1
	fi
	eval "$fn_src"
	return 0
}

install_stubs() {
	gh() {
		printf '%s\n' "$*" >>"$GH_CALL_LOG"
		if [[ "$1" == "api" && "$2" == *"/issues/"* ]]; then
			if [[ "$*" == *"--jq"* ]]; then
				printf '%s\n' "$TEST_ISSUE_LABELS"
				return 0
			fi
			printf '%s\n' "$TEST_ISSUE_LABELS" | jq -R 'split(",") | map(select(length > 0)) | {labels: map({name: .})}'
			return 0
		fi
		return 0
	}
	_extract_linked_issue() {
		local pr_number="$1"
		local repo_slug="$2"
		printf '%s\n' "$TEST_LINKED_ISSUES" | awk -F'=' -v pr="$pr_number" '$1 == pr { print $2; found=1 } END { if (!found) exit 0 }'
		return 0
	}
	_pr_required_checks_pass() {
		local pr_number="$1"
		local repo_slug="$2"
		case ",$TEST_PASSING_CHECKS," in
		*,"$pr_number",*) return 0 ;;
		esac
		return 1
	}
	_verify_superseding_pr_for_issue() {
		local linked_issue="$1"
		local superseding_pr="$2"
		local repo_slug="$3"
		printf 'verify %s %s %s\n' "$linked_issue" "$superseding_pr" "$repo_slug" >>"$GH_CALL_LOG"
		return "$TEST_VERIFY_RC"
	}
	return 0
}

reset_case() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	TEST_LINKED_ISSUES=""
	TEST_PASSING_CHECKS=""
	TEST_VERIFY_RC=0
	TEST_ISSUE_LABELS=""
	return 0
}

assert_log_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label" "Expected pattern '$pattern' in $file"
	fi
	return 0
}

assert_log_not_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		fail "$label" "Unexpected pattern '$pattern' in $file"
	else
		pass "$label"
	fi
	return 0
}

test_duplicate_group_closes_older_sibling() {
	reset_case
	TEST_LINKED_ISSUES=$'101=900\n102=900'
	TEST_PASSING_CHECKS="102"
	local pr_json
	pr_json='[
		{"number":101,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":102,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$pr_json"
	assert_log_contains "$GH_CALL_LOG" "verify 900 102 owner/repo" "newest healthy candidate is verified"
	assert_log_contains "$GH_CALL_LOG" "pr close 101" "older duplicate sibling closes"
	assert_log_not_contains "$GH_CALL_LOG" "pr close 102" "candidate remains open"
	return 0
}

test_healthiest_candidate_beats_newer_unhealthy_pr() {
	reset_case
	TEST_LINKED_ISSUES=$'201=901\n202=901'
	TEST_PASSING_CHECKS="201"
	local pr_json
	pr_json='[
		{"number":201,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":202,"mergeable":"MERGEABLE","reviewDecision":"NONE","isDraft":false,"createdAt":"2026-05-08T12:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$pr_json"
	assert_log_contains "$GH_CALL_LOG" "verify 901 201 owner/repo" "healthiest candidate selected before newest tie-break"
	assert_log_contains "$GH_CALL_LOG" "pr close 202" "less healthy sibling closes"
	assert_log_not_contains "$GH_CALL_LOG" "pr close 201" "healthiest candidate remains open"
	return 0
}

test_noop_for_untrusted_gated_or_unverified_groups() {
	reset_case
	TEST_LINKED_ISSUES=$'301=902\n302=902\n303=902'
	TEST_PASSING_CHECKS="301,302,303"
	TEST_ISSUE_LABELS="needs-maintainer-review"
	local gated_json
	gated_json='[
		{"number":301,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":302,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":303,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T12:00:00Z","labels":[{"name":"origin:interactive"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$gated_json"
	assert_log_not_contains "$GH_CALL_LOG" "pr close" "maintainer-gated duplicate group is no-op"

	reset_case
	TEST_LINKED_ISSUES=$'401=903\n402=903'
	TEST_PASSING_CHECKS="401,402"
	TEST_VERIFY_RC=1
	local unverified_json
	unverified_json='[
		{"number":401,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":402,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$unverified_json"
	assert_log_contains "$GH_CALL_LOG" "verify 903 402 owner/repo" "unverified candidate is checked"
	assert_log_not_contains "$GH_CALL_LOG" "pr close" "verification failure leaves siblings open"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	define_functions_under_test
	install_stubs

	test_duplicate_group_closes_older_sibling
	test_healthiest_candidate_beats_newer_unhealthy_pr
	test_noop_for_untrusted_gated_or_unverified_groups

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
