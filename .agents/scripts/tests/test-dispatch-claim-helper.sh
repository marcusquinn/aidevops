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
export AIDEVOPS_TEST_MODE=1
export AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1

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

if [[ "$endpoint" == repos/*/issues/*/comments* ]]; then
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

	jq -n \
		--arg runner "${MOCK_OLD_CLAIM_RUNNER:?}" \
		--arg old_ts "${MOCK_OLD_CLAIM_CREATED_AT:?}" \
		--arg new_body "$new_body" \
		--arg new_ts "${MOCK_NEW_CLAIM_CREATED_AT:?}" \
		'[
			{id: 1, body: ("DISPATCH_CLAIM nonce=old-nonce runner=" + $runner + " ts=" + $old_ts + " max_age_s=120"), created_at: $old_ts},
			{id: 999, body: $new_body, created_at: $new_ts}
		]'
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

#######################################
# Build a mock gh executable for stale-worker takeover claim tests.
# Uses env vars:
#   MOCK_GH_STATE_DIR, MOCK_DISPATCH_CREATED_AT, MOCK_CLAIM_CREATED_AT
# Returns: path to mock gh directory via stdout
#######################################
create_stale_worker_mock_gh() {
	local state_dir="$1"
	local terminal_body="${2:-}"
	local mock_bin_dir
	mock_bin_dir="${state_dir}/bin"
	mkdir -p "$mock_bin_dir"

	cat >"${mock_bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

local_state_dir="${MOCK_GH_STATE_DIR:?}"
post_body_file="${local_state_dir}/post_body.txt"
terminal_body="${MOCK_TERMINAL_BODY:-}"
dispatch_body="${MOCK_DISPATCH_BODY:-Dispatching worker (PID 12345)}"
paginated_comments="${MOCK_PAGINATED_COMMENTS:-false}"

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

if [[ "$endpoint" == repos/*/issues/*/comments* ]]; then
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

	if [[ -n "$terminal_body" ]]; then
		if [[ "$paginated_comments" == "true" ]]; then
			jq -n \
				--arg dispatch_body "$dispatch_body" \
				--arg dispatch_ts "${MOCK_DISPATCH_CREATED_AT:?}" \
				--arg terminal_body "$terminal_body" \
				--arg terminal_ts "${MOCK_TERMINAL_CREATED_AT:?}" \
				--arg new_body "$new_body" \
				--arg claim_ts "${MOCK_CLAIM_CREATED_AT:?}" \
				'[
					[{id: 1, body_start: "human discussion", body: "human discussion", created_at: "2026-05-01T00:00:00Z"}],
					[
						{id: 10, body_start: $dispatch_body, body: $dispatch_body, created_at: $dispatch_ts},
						{id: 11, body_start: $terminal_body, body: $terminal_body, created_at: $terminal_ts},
						{id: 999, body_start: $new_body, body: $new_body, created_at: $claim_ts}
					]
				]'
			exit 0
		fi
		jq -n \
			--arg dispatch_body "$dispatch_body" \
			--arg dispatch_ts "${MOCK_DISPATCH_CREATED_AT:?}" \
			--arg terminal_body "$terminal_body" \
			--arg terminal_ts "${MOCK_TERMINAL_CREATED_AT:?}" \
			--arg new_body "$new_body" \
			--arg claim_ts "${MOCK_CLAIM_CREATED_AT:?}" \
			'[
				{id: 10, body_start: $dispatch_body, body: $dispatch_body, created_at: $dispatch_ts},
				{id: 11, body_start: $terminal_body, body: $terminal_body, created_at: $terminal_ts},
				{id: 999, body_start: $new_body, body: $new_body, created_at: $claim_ts}
			]'
		exit 0
	fi

	if [[ "$paginated_comments" == "true" ]]; then
		jq -n \
			--arg dispatch_body "$dispatch_body" \
			--arg dispatch_ts "${MOCK_DISPATCH_CREATED_AT:?}" \
			--arg new_body "$new_body" \
			--arg claim_ts "${MOCK_CLAIM_CREATED_AT:?}" \
			'[
				[{id: 1, body_start: "human discussion", body: "human discussion", created_at: "2026-05-01T00:00:00Z"}],
				[
					{id: 10, body_start: $dispatch_body, body: $dispatch_body, created_at: $dispatch_ts},
					{id: 999, body_start: $new_body, body: $new_body, created_at: $claim_ts}
				]
			]'
		exit 0
	fi

	jq -n \
		--arg dispatch_body "$dispatch_body" \
		--arg dispatch_ts "${MOCK_DISPATCH_CREATED_AT:?}" \
		--arg new_body "$new_body" \
		--arg claim_ts "${MOCK_CLAIM_CREATED_AT:?}" \
		'[
			{id: 10, body_start: $dispatch_body, body: $dispatch_body, created_at: $dispatch_ts},
			{id: 999, body_start: $new_body, body: $new_body, created_at: $claim_ts}
		]'
	exit 0
fi

exit 1
EOF
	chmod +x "${mock_bin_dir}/gh"
	MOCK_TERMINAL_BODY="$terminal_body" printf '%s' "$mock_bin_dir"
	return 0
}

#######################################
# Build a mock gh executable for claim-only orphan recovery tests.
# Uses env vars:
#   MOCK_GH_STATE_DIR, MOCK_CLAIM_CREATED_AT, MOCK_ASSIGNEE_COUNT,
#   MOCK_INCLUDE_DISPATCH
# Returns: path to mock gh directory via stdout
#######################################
create_claim_orphan_mock_gh() {
	local state_dir="$1"
	local mock_bin_dir
	mock_bin_dir="${state_dir}/bin"
	mkdir -p "$mock_bin_dir"

	cat >"${mock_bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

local_state_dir="${MOCK_GH_STATE_DIR:?}"
release_body_file="${local_state_dir}/release_body.txt"
issue_call_file="${local_state_dir}/issue_calls.txt"

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

if [[ "$endpoint" == repos/*/issues/[0-9]* && "$endpoint" != */comments* ]]; then
	printf '1\n' >>"$issue_call_file"
	jq -n --argjson count "${MOCK_ASSIGNEE_COUNT:-0}" '
		{assignees: [range(0; $count) | {login: ("runner" + tostring)}]}
	'
	exit 0
fi

if [[ "$endpoint" == repos/*/issues/*/comments* ]]; then
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
		--jq | --paginate | --slurp)
			shift
			[[ "${1:-}" != .* ]] || shift
			;;
		*)
			shift
			;;
		esac
	done

	if [[ "$method" == "POST" ]]; then
		printf '%s' "$body" >"$release_body_file"
		printf '1001\n'
		exit 0
	fi

	if [[ "${MOCK_INCLUDE_DISPATCH:-false}" == "true" ]]; then
		jq -n \
			--arg claim_ts "${MOCK_CLAIM_CREATED_AT:?}" \
			--arg dispatch_ts "${MOCK_DISPATCH_CREATED_AT:?}" '
			[
				{id: 999, body: ("DISPATCH_CLAIM nonce=claim-only runner=mockrunner ts=" + $claim_ts + " max_age_s=300"), created_at: $claim_ts},
				{id: 1000, body: "Dispatching worker (deterministic).", created_at: $dispatch_ts}
			]
		'
		exit 0
	fi

	jq -n --arg claim_ts "${MOCK_CLAIM_CREATED_AT:?}" '
		[
			{id: 999, body: ("DISPATCH_CLAIM nonce=claim-only runner=mockrunner ts=" + $claim_ts + " max_age_s=300"), created_at: $claim_ts}
		]
	'
	exit 0
fi

exit 1
EOF
	chmod +x "${mock_bin_dir}/gh"
	printf '%s' "$mock_bin_dir"
	return 0
}

#######################################
# Build a mock gh executable that returns gh --paginate --slurp shaped output:
# an array of pages. The active claim is only present on the second page, which
# catches regressions where claim readers inspect only the oldest REST page.
# Uses env vars:
#   MOCK_GH_STATE_DIR, MOCK_OLD_CLAIM_CREATED_AT, MOCK_NEW_CLAIM_CREATED_AT
# Returns: path to mock gh directory via stdout
#######################################
create_paginated_mock_gh() {
	local state_dir="$1"
	local mock_bin_dir
	mock_bin_dir="${state_dir}/bin"
	mkdir -p "$mock_bin_dir"

	cat >"${mock_bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

local_state_dir="${MOCK_GH_STATE_DIR:?}"
post_body_file="${local_state_dir}/post_body.txt"

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

if [[ "$endpoint" == repos/*/issues/*/comments* ]]; then
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
		--paginate | --slurp)
			shift
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

	jq -n \
		--arg marker "${MOCK_OLD_CLAIM_MARKER:-DISPATCH_CLAIM}" \
		--arg old_ts "${MOCK_OLD_CLAIM_CREATED_AT:?}" \
		--arg new_body "$new_body" \
		--arg new_ts "${MOCK_NEW_CLAIM_CREATED_AT:?}" \
		'[
			[
				{id: 1, body: "human discussion", created_at: "2026-05-01T00:00:00Z"}
			],
			[
				{id: 2, body: ($marker + " nonce=old-nonce runner=mockrunner ts=" + $old_ts + " max_age_s=1800 version=3.14.23"), created_at: $old_ts},
				{id: 999, body: $new_body, created_at: $new_ts}
			]
		]'
	exit 0
fi

exit 1
EOF
	chmod +x "${mock_bin_dir}/gh"
	printf '%s' "$mock_bin_dir"
	return 0
}

#######################################
# Test: ops-wrapped dispatch comments still annotate stale takeover (t355x)
#######################################
test_claim_marks_stale_worker_takeover_for_ops_wrapped_dispatch_comment() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_stale_worker_mock_gh "$tmp_dir")"

	local dispatch_created_at claim_created_at output exit_code dispatch_body
	dispatch_created_at="$(iso_seconds_ago 120)"
	claim_created_at="$(iso_seconds_ago 1)"
	dispatch_body=$'<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->\nDispatching worker (deterministic).'

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_DISPATCH_CREATED_AT="$dispatch_created_at" \
		MOCK_DISPATCH_BODY="$dispatch_body" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		DISPATCH_ACTIVE_WORKER_MAX_AGE=60 \
		OPENCODE_VERSION=1.14.33 \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "ops-wrapped stale worker takeover claim exits 0" 0
	else
		print_result "ops-wrapped stale worker takeover claim exits 0" 1 "got exit $exit_code output: $output"
	fi

	local post_body=""
	if [[ -f "${tmp_dir}/post_body.txt" ]]; then
		post_body=$(<"${tmp_dir}/post_body.txt")
	fi
	if printf '%s' "$post_body" | grep -q 'reason=stale_worker_takeover'; then
		print_result "ops-wrapped stale worker takeover claim includes reason" 0
	else
		print_result "ops-wrapped stale worker takeover claim includes reason" 1 "body: ${post_body:-none}"
	fi
	if printf '%s' "$post_body" | grep -q '<!-- ops:start' && printf '%s' "$post_body" | grep -q '<!-- ops:end -->'; then
		print_result "claim comments are ops-wrapped" 0
	else
		print_result "claim comments are ops-wrapped" 1 "body: ${post_body:-none}"
	fi

	rm -rf "$tmp_dir"
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

	local tmp_dir="" mock_bin_dir="" output="" exit_code=0
	tmp_dir="$(mktemp -d)"
	mock_bin_dir="${tmp_dir}/bin"
	mkdir -p "$mock_bin_dir"
	cat >"${mock_bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	printf '%s\n' '{"state":"OPEN","assignees":[{"login":"other-runner"}],"labels":[{"name":"status:queued"},{"name":"auto-dispatch"}],"createdAt":"2026-06-02T00:00:00Z"}'
	exit 0
fi

if [[ "${1:-}" == "api" && ("${2:-}" == /repos/*/issues/* || "${2:-}" == repos/*/issues/*) ]]; then
	endpoint="${2:-}"
	shift 2
	if [[ "$endpoint" == */comments* ]]; then
		recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		printf '[{"created_at":"%s","author":"other-runner","body_start":"Dispatching worker (PID 12345)","body":"Dispatching worker (PID 12345)"}]\n' "$recent_ts"
		exit 0
	fi
	printf '%s\n' '{"state":"OPEN","assignees":[{"login":"other-runner"}],"labels":[{"name":"status:queued"},{"name":"auto-dispatch"}],"created_at":"2026-06-02T00:00:00Z"}'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	printf 'self-runner\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == repos/*/issues/*/comments* ]]; then
	if [[ "$*" == *"--method POST"* ]]; then
		printf 'unexpected claim post\n' >"${MOCK_POST_FILE:?}"
		printf '999\n'
		exit 0
	fi
	printf '%s\n' '[]'
	exit 0
fi

printf 'unsupported gh invocation in claim guard stub: %s\n' "$*" >&2
exit 1
EOF
	chmod +x "${mock_bin_dir}/gh"

	set +e
	output=$(PATH="${mock_bin_dir}:$PATH" MOCK_POST_FILE="${tmp_dir}/post_body.txt" \
		DISPATCH_CLAIM_WINDOW=0 "$DEDUP_HELPER" claim 42 owner/repo self-runner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 && "$output" == *"CLAIM_BLOCKED: active_assignment"* ]]; then
		print_result "queued non-self assignee blocks dedup claim before post" 0
	else
		print_result "queued non-self assignee blocks dedup claim before post" 1 "exit=${exit_code} output=${output}"
	fi
	if [[ ! -f "${tmp_dir}/post_body.txt" ]]; then
		print_result "blocked dedup claim does not post DISPATCH_CLAIM" 0
	else
		print_result "blocked dedup claim does not post DISPATCH_CLAIM" 1 "post file exists"
	fi
	rm -rf "$tmp_dir"
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
# Test: claim-only orphan older than grace no longer blocks dispatch.
#######################################
test_check_releases_claim_only_orphan() {
	local tmp_dir=""
	tmp_dir="$(mktemp -d)"
	local mock_path=""
	mock_path="$(create_claim_orphan_mock_gh "$tmp_dir")"
	local claim_created_at="" output="" exit_code=0 release_body=""
	claim_created_at="$(iso_seconds_ago 300)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		MOCK_ASSIGNEE_COUNT=0 \
		DISPATCH_CLAIM_MAX_AGE=600 \
		DISPATCH_CLAIM_ORPHAN_GRACE=120 \
		"$CLAIM_HELPER" check 42 owner/repo 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "claim-only orphan check returns no active claim" 0
	else
		print_result "claim-only orphan check returns no active claim" 1 "exit=${exit_code} output=${output}"
	fi
	if [[ -f "${tmp_dir}/release_body.txt" ]]; then
		release_body=$(<"${tmp_dir}/release_body.txt")
	fi
	if printf '%s' "$release_body" | grep -q 'CLAIM_RELEASED reason=claim_only_no_worker'; then
		print_result "claim-only orphan posts release marker" 0
	else
		print_result "claim-only orphan posts release marker" 1 "body=${release_body:-none}"
	fi
	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: fresh claim-only marker stays active during the grace window.
#######################################
test_check_preserves_fresh_claim_only_marker() {
	local tmp_dir=""
	tmp_dir="$(mktemp -d)"
	local mock_path=""
	mock_path="$(create_claim_orphan_mock_gh "$tmp_dir")"
	local claim_created_at="" output="" exit_code=0
	claim_created_at="$(iso_seconds_ago 30)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		MOCK_ASSIGNEE_COUNT=0 \
		DISPATCH_CLAIM_MAX_AGE=600 \
		DISPATCH_CLAIM_ORPHAN_GRACE=120 \
		"$CLAIM_HELPER" check 42 owner/repo 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | grep -q 'ACTIVE_CLAIM'; then
		print_result "fresh claim-only marker remains active" 0
	else
		print_result "fresh claim-only marker remains active" 1 "exit=${exit_code} output=${output}"
	fi
	if [[ ! -f "${tmp_dir}/release_body.txt" ]]; then
		print_result "fresh claim-only marker does not post release" 0
	else
		print_result "fresh claim-only marker does not post release" 1 "body=$(<"${tmp_dir}/release_body.txt")"
	fi
	if [[ ! -f "${tmp_dir}/issue_calls.txt" ]]; then
		print_result "fresh claim-only marker skips issue details fetch" 0
	else
		print_result "fresh claim-only marker skips issue details fetch" 1 "calls=$(<"${tmp_dir}/issue_calls.txt")"
	fi
	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: launch evidence after a claim keeps the claim active.
#######################################
test_check_preserves_claim_with_launch_evidence() {
	local tmp_dir=""
	tmp_dir="$(mktemp -d)"
	local mock_path=""
	mock_path="$(create_claim_orphan_mock_gh "$tmp_dir")"
	local claim_created_at="" dispatch_created_at="" output="" exit_code=0
	claim_created_at="$(iso_seconds_ago 300)"
	dispatch_created_at="$(iso_seconds_ago 250)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		MOCK_DISPATCH_CREATED_AT="$dispatch_created_at" \
		MOCK_INCLUDE_DISPATCH=true \
		MOCK_ASSIGNEE_COUNT=0 \
		DISPATCH_CLAIM_MAX_AGE=600 \
		DISPATCH_CLAIM_ORPHAN_GRACE=120 \
		"$CLAIM_HELPER" check 42 owner/repo 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | grep -q 'ACTIVE_CLAIM'; then
		print_result "claim with launch evidence remains active" 0
	else
		print_result "claim with launch evidence remains active" 1 "exit=${exit_code} output=${output}"
	fi
	if [[ ! -f "${tmp_dir}/release_body.txt" ]]; then
		print_result "claim with launch evidence does not post release" 0
	else
		print_result "claim with launch evidence does not post release" 1 "body=$(<"${tmp_dir}/release_body.txt")"
	fi
	rm -rf "$tmp_dir"
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

	# GH#17503: claim comments are retained for audit; stale same-runner claims
	# are rejected without deleting either the old or the fresh comment.
	if [[ ! -f "${tmp_dir}/delete_ids.log" ]]; then
		print_result "stale self-claim retains audit comments" 0
	else
		local delete_log=""
		if [[ -f "${tmp_dir}/delete_ids.log" ]]; then
			delete_log=$(<"${tmp_dir}/delete_ids.log")
		fi
		print_result "stale self-claim retains audit comments" 1 "deleted: ${delete_log:-none}"
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

	# GH#17503: claim comments are retained for audit; duplicate same-runner
	# claims are rejected without deleting either comment.
	if [[ ! -f "${tmp_dir}/delete_ids.log" ]]; then
		print_result "fresh same-runner retains audit comments" 0
	else
		local delete_log=""
		if [[ -f "${tmp_dir}/delete_ids.log" ]]; then
			delete_log=$(<"${tmp_dir}/delete_ids.log")
		fi
		print_result "fresh same-runner retains audit comments" 1 "deleted: ${delete_log:-none}"
	fi
	return 0
}

#######################################
# Test: long issue threads still see active claims beyond the first REST page.
#######################################
test_claim_reads_paginated_comment_tail() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_paginated_mock_gh "$tmp_dir")"

	local old_created_at new_created_at output exit_code
	old_created_at="$(iso_seconds_ago 10)"
	new_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_OLD_CLAIM_CREATED_AT="$old_created_at" \
		MOCK_NEW_CLAIM_CREATED_AT="$new_created_at" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "paginated comments find prior same-runner claim" 0
	else
		print_result "paginated comments find prior same-runner claim" 1 "got exit $exit_code output: $output"
	fi

	if printf '%s' "$output" | grep -q "CLAIM_STALE_SELF:"; then
		print_result "paginated prior claim emits CLAIM_STALE_SELF" 0
	else
		print_result "paginated prior claim emits CLAIM_STALE_SELF" 1 "output: $output"
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: claim marker detection is literal and case-insensitive.
#######################################
test_claim_reads_lowercase_paginated_claim_marker() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_paginated_mock_gh "$tmp_dir")"

	local old_created_at new_created_at output exit_code
	old_created_at="$(iso_seconds_ago 10)"
	new_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_OLD_CLAIM_CREATED_AT="$old_created_at" \
		MOCK_NEW_CLAIM_CREATED_AT="$new_created_at" \
		MOCK_OLD_CLAIM_MARKER="dispatch_claim" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "lowercase paginated claim marker is detected" 0
	else
		print_result "lowercase paginated claim marker is detected" 1 "got exit $exit_code output: $output"
	fi

	if printf '%s' "$output" | grep -q "CLAIM_STALE_SELF:"; then
		print_result "lowercase claim marker remains authoritative" 0
	else
		print_result "lowercase claim marker remains authoritative" 1 "output: $output"
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: override filters are peer-only and preserve this runner's own claim.
#######################################
test_claim_ignore_filter_preserves_self_claim() {
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
		MOCK_OLD_CLAIM_RUNNER="mockrunner" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		DISPATCH_CLAIM_IGNORE_RUNNERS="mockrunner" \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "legacy ignore filter preserves self claim" 0
	else
		print_result "legacy ignore filter preserves self claim" 1 "got exit $exit_code output: $output"
	fi

	if printf '%s' "$output" | grep -q "CLAIM_STALE_SELF:"; then
		print_result "self-preserved ignored claim remains authoritative" 0
	else
		print_result "self-preserved ignored claim remains authoritative" 1 "output: $output"
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: structured dispatch overrides are peer-only for this runner's claim.
#######################################
test_claim_structured_override_preserves_self_claim() {
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
		MOCK_OLD_CLAIM_RUNNER="mockrunner" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		DISPATCH_OVERRIDE_MOCKRUNNER="ignore" \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 1 ]]; then
		print_result "structured override preserves self claim" 0
	else
		print_result "structured override preserves self claim" 1 "got exit $exit_code output: $output"
	fi

	if printf '%s' "$output" | grep -q "CLAIM_STALE_SELF:"; then
		print_result "self-preserved structured claim remains authoritative" 0
	else
		print_result "self-preserved structured claim remains authoritative" 1 "output: $output"
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: stale worker takeover claims are annotated (GH#22356)
#######################################
test_claim_marks_stale_worker_takeover() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_stale_worker_mock_gh "$tmp_dir")"

	local dispatch_created_at claim_created_at output exit_code
	dispatch_created_at="$(iso_seconds_ago 120)"
	claim_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_DISPATCH_CREATED_AT="$dispatch_created_at" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		DISPATCH_ACTIVE_WORKER_MAX_AGE=60 \
		OPENCODE_VERSION=1.14.33 \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "stale worker takeover claim exits 0" 0
	else
		print_result "stale worker takeover claim exits 0" 1 "got exit $exit_code output: $output"
	fi

	local post_body=""
	if [[ -f "${tmp_dir}/post_body.txt" ]]; then
		post_body=$(<"${tmp_dir}/post_body.txt")
	fi
	if printf '%s' "$post_body" | grep -q 'reason=stale_worker_takeover'; then
		print_result "stale worker takeover claim includes reason" 0
	else
		print_result "stale worker takeover claim includes reason" 1 "body: ${post_body:-none}"
	fi
	if printf '%s' "$post_body" | grep -q 'version=[0-9][0-9.]*'; then
		print_result "claim includes aidevops version" 0
	else
		print_result "claim includes aidevops version" 1 "body: ${post_body:-none}"
	fi
	if printf '%s' "$post_body" | grep -q 'opencode_version=1.14.33'; then
		print_result "claim includes OpenCode version" 0
	else
		print_result "claim includes OpenCode version" 1 "body: ${post_body:-none}"
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: stale takeover detection scans every paginated issue-comment page.
#######################################
test_claim_marks_paginated_stale_worker_takeover() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_stale_worker_mock_gh "$tmp_dir")"

	local dispatch_created_at claim_created_at output exit_code
	dispatch_created_at="$(iso_seconds_ago 120)"
	claim_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_DISPATCH_CREATED_AT="$dispatch_created_at" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		MOCK_PAGINATED_COMMENTS=true \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		DISPATCH_ACTIVE_WORKER_MAX_AGE=60 \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "paginated stale worker takeover claim exits 0" 0
	else
		print_result "paginated stale worker takeover claim exits 0" 1 "got exit $exit_code output: $output"
	fi

	local post_body=""
	if [[ -f "${tmp_dir}/post_body.txt" ]]; then
		post_body=$(<"${tmp_dir}/post_body.txt")
	fi
	if printf '%s' "$post_body" | grep -q 'reason=stale_worker_takeover'; then
		print_result "paginated stale worker takeover includes reason" 0
	else
		print_result "paginated stale worker takeover includes reason" 1 "body: ${post_body:-none}"
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: terminal worker comments suppress stale takeover annotation (GH#22356)
#######################################
test_claim_skips_takeover_reason_after_terminal() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_stale_worker_mock_gh "$tmp_dir" "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=worker_complete
<!-- ops:end -->")"

	local dispatch_created_at terminal_created_at claim_created_at output exit_code
	dispatch_created_at="$(iso_seconds_ago 120)"
	terminal_created_at="$(iso_seconds_ago 30)"
	claim_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_DISPATCH_CREATED_AT="$dispatch_created_at" \
		MOCK_TERMINAL_CREATED_AT="$terminal_created_at" \
		MOCK_TERMINAL_BODY="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=worker_complete
<!-- ops:end -->" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		DISPATCH_ACTIVE_WORKER_MAX_AGE=60 \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "terminal worker claim exits 0" 0
	else
		print_result "terminal worker claim exits 0" 1 "got exit $exit_code output: $output"
	fi

	local post_body=""
	if [[ -f "${tmp_dir}/post_body.txt" ]]; then
		post_body=$(<"${tmp_dir}/post_body.txt")
	fi
	if printf '%s' "$post_body" | grep -q 'reason=stale_worker_takeover'; then
		print_result "terminal worker claim omits takeover reason" 1 "body: $post_body"
	else
		print_result "terminal worker claim omits takeover reason" 0
	fi

	rm -rf "$tmp_dir"
	return 0
}

#######################################
# Test: terminal worker marker matching is case-insensitive.
#######################################
test_claim_skips_takeover_reason_after_lowercase_terminal() {
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	local mock_path
	mock_path="$(create_stale_worker_mock_gh "$tmp_dir" "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
claim_released reason=worker_complete
<!-- ops:end -->")"

	local dispatch_created_at terminal_created_at claim_created_at output exit_code
	dispatch_created_at="$(iso_seconds_ago 120)"
	terminal_created_at="$(iso_seconds_ago 30)"
	claim_created_at="$(iso_seconds_ago 1)"

	set +e
	output=$(PATH="${mock_path}:$PATH" \
		MOCK_GH_STATE_DIR="$tmp_dir" \
		MOCK_DISPATCH_CREATED_AT="$dispatch_created_at" \
		MOCK_TERMINAL_CREATED_AT="$terminal_created_at" \
		MOCK_TERMINAL_BODY="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
claim_released reason=worker_complete
<!-- ops:end -->" \
		MOCK_CLAIM_CREATED_AT="$claim_created_at" \
		DISPATCH_CLAIM_WINDOW=0 \
		DISPATCH_CLAIM_MAX_AGE=300 \
		DISPATCH_ACTIVE_WORKER_MAX_AGE=60 \
		"$CLAIM_HELPER" claim 42 owner/repo mockrunner 2>&1)
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "lowercase terminal worker claim exits 0" 0
	else
		print_result "lowercase terminal worker claim exits 0" 1 "got exit $exit_code output: $output"
	fi

	local post_body=""
	if [[ -f "${tmp_dir}/post_body.txt" ]]; then
		post_body=$(<"${tmp_dir}/post_body.txt")
	fi
	if printf '%s' "$post_body" | grep -q 'reason=stale_worker_takeover'; then
		print_result "lowercase terminal marker omits takeover reason" 1 "body: $post_body"
	else
		print_result "lowercase terminal marker omits takeover reason" 0
	fi

	rm -rf "$tmp_dir"
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
	test_check_releases_claim_only_orphan
	test_check_preserves_fresh_claim_only_marker
	test_check_preserves_claim_with_launch_evidence
	test_claim_rejects_stale_same_runner_claim
	test_claim_rejects_fresh_same_runner_claim
	test_claim_reads_paginated_comment_tail
	test_claim_reads_lowercase_paginated_claim_marker
	test_claim_ignore_filter_preserves_self_claim
	test_claim_structured_override_preserves_self_claim
	test_claim_marks_stale_worker_takeover
	test_claim_marks_paginated_stale_worker_takeover
	test_claim_marks_stale_worker_takeover_for_ops_wrapped_dispatch_comment
	test_claim_skips_takeover_reason_after_terminal
	test_claim_skips_takeover_reason_after_lowercase_terminal

	echo ""
	echo "Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
