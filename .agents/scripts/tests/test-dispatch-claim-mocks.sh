#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-claim-mocks.sh — mock gh builders for test-dispatch-claim-helper.sh
# Sourced by the orchestrator; pure move, no behaviour change.

[[ -n "${_TEST_DISPATCH_CLAIM_MOCKS_LOADED:-}" ]] && return 0
_TEST_DISPATCH_CLAIM_MOCKS_LOADED=1

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
post_attempts_file="${local_state_dir}/post_attempts.txt"

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
		post_attempts=0
		if [[ -f "$post_attempts_file" ]]; then
			post_attempts=$(<"$post_attempts_file")
		fi
		post_attempts=$((post_attempts + 1))
		printf '%s' "$post_attempts" >"$post_attempts_file"
		if [[ "${MOCK_POST_FAILS:-0}" =~ ^[0-9]+$ && "$post_attempts" -le "${MOCK_POST_FAILS:-0}" ]]; then
			printf 'mock transient claim post failure %s\n' "$post_attempts" >&2
			exit 1
		fi
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
		--argjson hide_new "$("${0%/*}/mock-hide-new-claim")" \
		'[
			{id: 1, body: ("DISPATCH_CLAIM nonce=old-nonce runner=" + $runner + " ts=" + $old_ts + " max_age_s=120" + (if env.MOCK_OLD_CLAIM_DEVICE then " lease_token=old-nonce device=" + env.MOCK_OLD_CLAIM_DEVICE + " session=issue-42 phase=prelaunch expires_at=4102444800" else "" end)), created_at: $old_ts},
			{id: 999, body: $new_body, created_at: $new_ts, user:{login:($new_body | capture("runner=(?<login>[^ ]+)").login)}, author_association:"MEMBER"}
		] | map(. + {user:{login:(.user.login // (.body | capture("runner=(?<login>[^ ]+)").login))}, author_association:(.author_association // "MEMBER")}) | if $hide_new == 1 then map(select(.id != 999)) else . end'
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
	write_mock_hide_new_claim "$mock_bin_dir"
	printf '%s' "$mock_bin_dir"
	return 0
}

#######################################
# GH#34922: helper for create_mock_gh simulating read-after-write lag.
# Prints 1 (hide our new claim) for the first MOCK_HIDE_NEW_CLAIM_READS
# comment reads after the claim POST, else 0.
# Args: $1 = mock bin dir
#######################################
write_mock_hide_new_claim() {
	local mock_bin_dir="$1"
	cat >"${mock_bin_dir}/mock-hide-new-claim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${MOCK_GH_STATE_DIR:?}"
limit="${MOCK_HIDE_NEW_CLAIM_READS:-0}"
hidden_file="${state_dir}/hidden_reads.txt"
hidden=0
[[ -f "$hidden_file" ]] && hidden=$(<"$hidden_file")
if [[ -f "${state_dir}/post_body.txt" && "$limit" =~ ^[0-9]+$ && "$hidden" -lt "$limit" ]]; then
	printf '%s' "$((hidden + 1))" >"$hidden_file"
	printf '1\n'
	exit 0
fi
printf '0\n'
EOF
	chmod +x "${mock_bin_dir}/mock-hide-new-claim"
	return 0
}

#######################################
# Write the header and argument parser for the stale-worker mock gh executable.
# Args: $1 = mock gh executable path
#######################################
write_stale_worker_mock_header() {
	local mock_gh_path="$1"
	cat >"$mock_gh_path" <<'EOF'
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

EOF
	return 0
}

#######################################
# Write the POST handling branch for the stale-worker mock gh executable.
# Args: $1 = mock gh executable path
#######################################
write_stale_worker_mock_post_handler() {
	local mock_gh_path="$1"
	cat >>"$mock_gh_path" <<'EOF'

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

EOF
	return 0
}

#######################################
# Write terminal-comment response branches for the stale-worker mock gh executable.
# Args: $1 = mock gh executable path
#######################################
write_stale_worker_mock_terminal_responses() {
	local mock_gh_path="$1"
	cat >>"$mock_gh_path" <<'EOF'

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
			] | map(map(. + {user:{login:"mockrunner"}, author_association:"MEMBER"}))'
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
		] | map(. + {user:{login:"mockrunner"}, author_association:"MEMBER"})'
		exit 0
	fi

EOF
	return 0
}

#######################################
# Write non-terminal response branches for the stale-worker mock gh executable.
# Args: $1 = mock gh executable path
#######################################
write_stale_worker_mock_active_responses() {
	local mock_gh_path="$1"
	cat >>"$mock_gh_path" <<'EOF'

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
			] | map(map(. + {user:{login:"mockrunner"}, author_association:"MEMBER"}))'
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
	] | map(. + {user:{login:"mockrunner"}, author_association:"MEMBER"})'
	exit 0
fi

exit 1
EOF
	return 0
}

#######################################
# Build a mock gh executable for stale-worker takeover claim tests.
# Uses env vars:
#   MOCK_GH_STATE_DIR, MOCK_DISPATCH_CREATED_AT, MOCK_CLAIM_CREATED_AT
# Returns: path to mock gh directory via stdout
#######################################
create_stale_worker_mock_gh() {
	local state_dir="${1:?state_dir is required}"
	local terminal_body="${2:-}"
	local mock_bin_dir
	local mock_gh_path
	mock_bin_dir="${state_dir}/bin"
	mock_gh_path="${mock_bin_dir}/gh"
	mkdir -p "$mock_bin_dir"

	write_stale_worker_mock_header "$mock_gh_path"
	write_stale_worker_mock_post_handler "$mock_gh_path"
	write_stale_worker_mock_terminal_responses "$mock_gh_path"
	write_stale_worker_mock_active_responses "$mock_gh_path"

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
	printf '%s\n' "${MOCK_ASSIGNEE_COUNT:-0}"
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

	call=1
	[[ ! -f "${local_state_dir}/comment_calls" ]] || call=$(( $(<"${local_state_dir}/comment_calls") + 1 ))
	printf '%s' "$call" >"${local_state_dir}/comment_calls"
	[[ "${MOCK_REFRESH_FAIL:-false}" != true || "$call" -eq 1 ]] || exit 1
	jq -n --arg claim_ts "${MOCK_CLAIM_CREATED_AT:?}" --argjson call "$call" \
		--arg device "${MOCK_CLAIM_DEVICE:-orphan-device}" --arg session "${MOCK_CLAIM_SESSION:-issue-42}" \
		--arg expiry "${MOCK_CLAIM_EXPIRY-auto}" --arg event "${MOCK_NEW_EVENT:-}" '
		(if $expiry == "auto" then (($claim_ts | fromdateiso8601) + 120 | tostring) else $expiry end) as $expiry |
		[
			{id: 999, body: ("DISPATCH_CLAIM nonce=claim-only runner=mockrunner ts=" + $claim_ts +
				" max_age_s=300 lease_token=claim-only device=" + $device + " session=" + $session +
				" phase=prelaunch" + (if $expiry == "missing" then "" else " expires_at=" + $expiry end)), created_at: $claim_ts},
			(if env.MOCK_INCLUDE_DISPATCH == "true" then
				{id:1000, body:"Dispatching worker (deterministic).", created_at:env.MOCK_DISPATCH_CREATED_AT} else empty end),
			(if $call > 1 and $event != "" then
				{id:1001, body:$event, created_at:$claim_ts} else empty end)
		] | map(. + {user:{login:"mockrunner"}, author_association:"MEMBER"})
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
		] | map(map(. + {user:{login:"mockrunner"}, author_association:"MEMBER"}))'
	exit 0
fi

exit 1
EOF
	chmod +x "${mock_bin_dir}/gh"
	printf '%s' "$mock_bin_dir"
	return 0
}

