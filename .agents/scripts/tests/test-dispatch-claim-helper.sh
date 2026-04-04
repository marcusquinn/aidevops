#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-claim-helper.sh — Tests for dispatch-claim-helper.sh (t1686)
#
# Tests the offline/unit-testable parts of the claim helper:
# - Nonce generation
# - ISO timestamp generation
# - Help output
# - Argument validation
#
# Note: The claim/release/check commands require live GitHub API access
# and are tested via integration tests, not unit tests. This file tests
# the deterministic, offline-safe parts of the helper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_HELPER="${SCRIPT_DIR}/../dispatch-claim-helper.sh"
DEDUP_HELPER="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

#######################################
# Run a helper command without triggering set -e on failure.
# Captures exit status so test bodies can check it explicitly.
# Usage: run_helper [args...]; LAST_EXIT=$?
#######################################
run_helper() {
	set +e
	"$@"
	LAST_EXIT=$?
	set -e
	return 0
}

#######################################
# Generate an ISO 8601 UTC timestamp N seconds ago.
# Args: $1 = seconds ago
# Returns: timestamp via stdout
#######################################
iso_seconds_ago() {
	local seconds_ago="$1"
	python3 - "$seconds_ago" <<'PY'
import datetime
import sys

seconds = int(sys.argv[1])
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)
print(ts.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
	return 0
}

#######################################
# Build a mock gh executable for claim protocol tests.
# Uses env vars:
#   MOCK_GH_STATE_DIR, MOCK_OLD_CLAIM_CREATED_AT, MOCK_NEW_CLAIM_CREATED_AT,
#   MOCK_OLD_CLAIM_RUNNER
# Returns: path to mock gh directory via stdout
#######################################
create_mock_gh() {
	local state_dir="$1"
	local mock_bin_dir
	mock_bin_dir="${state_dir}/bin"
	mkdir -p "$mock_bin_dir"

	cat >"${mock_bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

local_state_dir="${MOCK_GH_STATE_DIR:?}"
post_body_file="${local_state_dir}/post_body.txt"
delete_log_file="${local_state_dir}/delete_ids.log"

if [[ "${1:-}" != "api" ]]; then
	exit 1
fi
shift

endpoint="${1:-}"
shift || true

if [[ "$endpoint" == "user" ]]; then
	printf 'mockrunner\n'
	exit 0
fi

if [[ "$endpoint" == repos/*/issues/*/comments ]]; then
	method="GET"
	body=""
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		--method)
			method="$2"
			shift 2
			;;
		--field)
			if [[ "$2" == body=* ]]; then
				body="${2#body=}"
			fi
			shift 2
			;;
		--jq)
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ "$method" == "POST" ]]; then
		printf '%s' "$body" >"$post_body_file"
		printf '999\n'
		exit 0
	fi

	if [[ -f "$post_body_file" ]]; then
		new_body=$(<"$post_body_file")
	else
		new_body=""
	fi

	printf '[{"id":1,"body":"DISPATCH_CLAIM nonce=old-nonce runner=%s ts=%s max_age_s=120","created_at":"%s"},{"id":999,"body":"%s","created_at":"%s"}]\n' \
		"${MOCK_OLD_CLAIM_RUNNER:?}" \
		"${MOCK_OLD_CLAIM_CREATED_AT:?}" \
		"${MOCK_OLD_CLAIM_CREATED_AT:?}" \
		"$new_body" \
		"${MOCK_NEW_CLAIM_CREATED_AT:?}"
	exit 0
fi

if [[ "$endpoint" == repos/*/issues/comments/* ]]; then
	comment_id="${endpoint##*/}"
	printf '%s\n' "$comment_id" >>"$delete_log_file"
	exit 0
fi

exit 1
EOF
	chmod +x "${mock_bin_dir}/gh"
	printf '%s' "$mock_bin_dir"
	return 0
}

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

#######################################
# Test: help command exits 0 and produces output
#######################################
test_help_exits_zero() {
	local output
	run_helper "$CLAIM_HELPER" help
	output=$("$CLAIM_HELPER" help 2>&1)
	local has_usage=1
	if printf '%s' "$output" | grep -q "dispatch-claim-helper.sh"; then
		has_usage=0
	fi
	print_result "help exits 0" "$LAST_EXIT"
	print_result "help contains script name" "$has_usage"
	return 0
}

#######################################
# Test: claim with missing args returns exit 2
#######################################
test_claim_missing_args() {
	run_helper "$CLAIM_HELPER" claim
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "claim with no args returns exit 2" 0
	else
		print_result "claim with no args returns exit 2" 1 "got exit $LAST_EXIT"
	fi

	run_helper "$CLAIM_HELPER" claim 42
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "claim with one arg returns exit 2" 0
	else
		print_result "claim with one arg returns exit 2" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: claim with non-numeric issue returns exit 2
#######################################
test_claim_non_numeric_issue() {
	run_helper "$CLAIM_HELPER" claim "abc" "owner/repo"
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "claim with non-numeric issue returns exit 2" 0
	else
		print_result "claim with non-numeric issue returns exit 2" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: check with missing args returns exit 2
#######################################
test_check_missing_args() {
	run_helper "$CLAIM_HELPER" check
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "check with no args returns exit 2" 0
	else
		print_result "check with no args returns exit 2" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: unknown command returns exit 1
#######################################
test_unknown_command() {
	run_helper "$CLAIM_HELPER" foobar
	if [[ "$LAST_EXIT" -eq 1 ]]; then
		print_result "unknown command returns exit 1" 0
	else
		print_result "unknown command returns exit 1" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: dispatch-dedup-helper.sh claim subcommand routes correctly
#######################################
test_dedup_claim_routing() {
	# With missing args, should return exit 1 (from dedup helper's arg check)
	run_helper "$DEDUP_HELPER" claim
	if [[ "$LAST_EXIT" -eq 1 ]]; then
		print_result "dedup claim with no args returns exit 1" 0
	else
		print_result "dedup claim with no args returns exit 1" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: DISPATCH_CLAIM_WINDOW env var is respected
#######################################
test_env_var_defaults() {
	# Source the helper to check defaults (without executing main)
	local output
	output=$(DISPATCH_CLAIM_WINDOW=15 DISPATCH_CLAIM_MAX_AGE=300 DISPATCH_CLAIM_SELF_RECLAIM_AGE=45 \
		bash -c 'source "'"$CLAIM_HELPER"'" 2>/dev/null; echo "window=$DISPATCH_CLAIM_WINDOW max_age=$DISPATCH_CLAIM_MAX_AGE self_reclaim=$DISPATCH_CLAIM_SELF_RECLAIM_AGE"' 2>/dev/null || true)

	if printf '%s' "$output" | grep -q "window=15"; then
		print_result "DISPATCH_CLAIM_WINDOW env var respected" 0
	else
		print_result "DISPATCH_CLAIM_WINDOW env var respected" 1 "got: $output"
	fi

	if printf '%s' "$output" | grep -q "max_age=300"; then
		print_result "DISPATCH_CLAIM_MAX_AGE env var respected" 0
	else
		print_result "DISPATCH_CLAIM_MAX_AGE env var respected" 1 "got: $output"
	fi

	if printf '%s' "$output" | grep -q "self_reclaim=45"; then
		print_result "DISPATCH_CLAIM_SELF_RECLAIM_AGE env var respected" 0
	else
		print_result "DISPATCH_CLAIM_SELF_RECLAIM_AGE env var respected" 1 "got: $output"
	fi
	return 0
}

#######################################
# Test: stale same-runner oldest claim is cleaned up and rejected (GH#15317)
#
# Previously this tested self-reclaim (CLAIM_RECLAIMED, exit 0). After
# GH#15317, same-runner stale claims are treated as lost to prevent
# dispatch loops. The stale claim and fresh claim are both deleted.
#######################################
test_claim_rejects_stale_same_runner_claim() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_mock_gh "$tmp_dir")"

	local old_created_at new_created_at output exit_code
	old_created_at="$(iso_seconds_ago 45)"
	new_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_OLD_CLAIM_CREATED_AT="$old_created_at" \
		MOCK_NEW_CLAIM_CREATED_AT="$new_created_at" \
		MOCK_OLD_CLAIM_RUNNER="marcusquinn" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_SELF_RECLAIM_AGE=30 \
		"$CLAIM_HELPER" claim 42 owner/repo marcusquinn 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "stale same-runner claim exits 1 (rejected)" 0
	else
		print_result "stale same-runner claim exits 1 (rejected)" 1 "got exit $exit_code output: $output"
	fi

	if printf '%s' "$output" | grep -q "CLAIM_STALE_SELF:"; then
		print_result "stale same-runner claim emits CLAIM_STALE_SELF" 0
	else
		print_result "stale same-runner claim emits CLAIM_STALE_SELF" 1 "output: $output"
	fi

	# Both the stale claim (id=1) and fresh claim (id=999) should be deleted
	if [[ -f "${tmp_dir}/delete_ids.log" ]] && grep -q '^1$' "${tmp_dir}/delete_ids.log" && grep -q '^999$' "${tmp_dir}/delete_ids.log"; then
		print_result "stale self-claim deletes both stale and fresh claims" 0
	else
		local delete_log=""
		if [[ -f "${tmp_dir}/delete_ids.log" ]]; then
			delete_log=$(<"${tmp_dir}/delete_ids.log")
		fi
		print_result "stale self-claim deletes both stale and fresh claims" 1 "deleted: ${delete_log:-none}"
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: fresh same-runner oldest claim is also rejected (GH#15317)
#
# After GH#15317, ALL same-runner duplicate claims (fresh or stale)
# are rejected with CLAIM_STALE_SELF. Both the stale and fresh claims
# are deleted. This prevents dispatch loops where the same runner
# keeps reclaiming its own stale claims.
#######################################
test_claim_rejects_fresh_same_runner_claim() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_mock_gh "$tmp_dir")"

	local old_created_at new_created_at output exit_code
	old_created_at="$(iso_seconds_ago 10)"
	new_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_OLD_CLAIM_CREATED_AT="$old_created_at" \
		MOCK_NEW_CLAIM_CREATED_AT="$new_created_at" \
		MOCK_OLD_CLAIM_RUNNER="marcusquinn" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_SELF_RECLAIM_AGE=30 \
		"$CLAIM_HELPER" claim 42 owner/repo marcusquinn 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "fresh same-runner claim exits 1 (rejected)" 0
	else
		print_result "fresh same-runner claim exits 1 (rejected)" 1 "got exit $exit_code output: $output"
	fi

	if printf '%s' "$output" | grep -q "CLAIM_STALE_SELF:"; then
		print_result "fresh same-runner claim emits CLAIM_STALE_SELF" 0
	else
		print_result "fresh same-runner claim emits CLAIM_STALE_SELF" 1 "output: $output"
	fi

	# Both claims should be deleted
	if [[ -f "${tmp_dir}/delete_ids.log" ]] && grep -q '^1$' "${tmp_dir}/delete_ids.log" && grep -q '^999$' "${tmp_dir}/delete_ids.log"; then
		print_result "fresh same-runner deletes both claims" 0
	else
		local delete_log=""
		if [[ -f "${tmp_dir}/delete_ids.log" ]]; then
			delete_log=$(<"${tmp_dir}/delete_ids.log")
		fi
		print_result "fresh same-runner deletes both claims" 1 "deleted: ${delete_log:-none}"
	fi
	return 0
}

#######################################
# Main
#######################################
main() {
	echo "=== dispatch-claim-helper.sh tests (t1686) ==="
	echo ""

	test_help_exits_zero
	test_claim_missing_args
	test_claim_non_numeric_issue
	test_check_missing_args
	test_unknown_command
	test_dedup_claim_routing
	test_env_var_defaults
	test_claim_rejects_stale_same_runner_claim
	test_claim_rejects_fresh_same_runner_claim

	echo ""
	echo "Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
