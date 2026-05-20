#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: worker CLAIM_RELEASED must unlock the issue that dispatch
# locked before worker launch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
CALL_LOG="${TMP_HOME}/gh-calls.log"
: >"$CALL_LOG"
export AIDEVOPS_TEST_MODE=1
export AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1

cleanup() {
	rm -rf "$TMP_HOME"
	return 0
}
trap cleanup EXIT

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >>"$CALL_LOG"
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message" >>"$CALL_LOG"
	return 0
}

clear_active_status_on_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name="$3"
	printf 'CLEAR issue=%s repo=%s runner=%s\n' "$issue_number" "$repo_slug" "$runner_name" >>"$CALL_LOG"
	return 0
}

whoami() {
	printf 'local-os-user\n'
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	api)
		local path="${1:-}"
		shift || true
		if [[ "$path" == "user" ]]; then
			printf 'api-login\n'
			return 0
		fi
		local method="GET" body="" prev=""
		local arg
		for arg in "$@"; do
			if [[ "$prev" == "--method" ]]; then
				method="$arg"
			fi
			if [[ "$arg" == body=* ]]; then
				body="${arg#body=}"
			fi
			prev="$arg"
		done
		printf 'API method=%s path=%s body=%s\n' "$method" "$path" "$body" >>"$CALL_LOG"
		printf '{}\n'
		;;
	issue)
		local subcmd="${1:-}"
		shift || true
		if [[ "$subcmd" == "unlock" ]]; then
			local issue_number="${1:-}"
			shift || true
			local repo_slug="" prev=""
			local arg
			for arg in "$@"; do
				if [[ "$prev" == "--repo" ]]; then
					repo_slug="$arg"
				fi
				prev="$arg"
			done
			printf 'UNLOCK issue=%s repo=%s\n' "$issue_number" "$repo_slug" >>"$CALL_LOG"
		fi
		;;
	*) ;;
	esac
	return 0
}

# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER
_release_dispatch_claim "supervisor-pulse" "process_exit" "1" "0"
if grep -q 'Cannot release claim: missing issue= repo=' "$CALL_LOG"; then
	printf 'FAIL empty non-worker claim release emitted warning\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi
printf 'PASS empty non-worker claim release is a silent no-op\n'
: >"$CALL_LOG"

export DISPATCH_REPO_SLUG="owner/repo"
export WORKER_GITHUB_LOGIN="assigned-bot"
_release_dispatch_claim "issue-12345" "worker_noop" "0" "0"

if grep -q 'CLAIM_RELEASED reason=worker_noop' "$CALL_LOG" &&
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot' "$CALL_LOG" &&
	grep -q 'runner=assigned-bot' "$CALL_LOG" &&
	! grep -q 'runner=local-os-user' "$CALL_LOG" &&
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS release posts claim, clears assigned GitHub login, and unlocks issue\n'
	exit 0
fi

printf 'FAIL release lifecycle missing expected calls\n'
sed 's/^/  /' "$CALL_LOG"
exit 1
