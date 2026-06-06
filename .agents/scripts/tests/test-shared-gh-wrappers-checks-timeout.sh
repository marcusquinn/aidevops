#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)"
CHECKS_LIB="${SCRIPTS_DIR}/shared-gh-wrappers-checks.sh"

if [[ ! -f "$CHECKS_LIB" ]]; then
	printf 'ERROR: shared-gh-wrappers-checks.sh not found at %s\n' "$CHECKS_LIB" >&2
	exit 1
fi

# shellcheck source=../shared-gh-wrappers-checks.sh
source "$CHECKS_LIB"

WRAPPER_LOG="$(mktemp)"
export WRAPPER_LOG

_gh_with_timeout() {
	local op_class="$1"
	shift
	printf '%s\t%s\n' "$op_class" "$*" >>"$WRAPPER_LOG"
	case "$*" in
	*check-suites*)
		printf 'PASS\n'
		;;
	*check-runs*)
		printf '[{"name":"quality","conclusion":"success","status":"completed"}]\n'
		;;
	*status*)
		printf '[]\n'
		;;
	*)
		return 1
		;;
	esac
	return 0
}

status="$(gh_pr_check_status_rest "owner/repo" "abc123")"
runs="$(gh_pr_check_runs_rest "owner/repo" "abc123")"

if [[ "$status" != "PASS" ]]; then
	printf 'FAIL: expected PASS status, got %s\n' "$status" >&2
	exit 1
fi

if ! printf '%s' "$runs" | jq -e '. == [{"name":"quality","conclusion":"success","status":"completed"}]' >/dev/null; then
	printf 'FAIL: unexpected runs JSON: %s\n' "$runs" >&2
	exit 1
fi

if [[ "$(grep -c '^read	gh api repos/owner/repo/commits/abc123/' "$WRAPPER_LOG")" -ne 3 ]]; then
	printf 'FAIL: expected 3 wrapped gh api calls\n' >&2
	cat "$WRAPPER_LOG" >&2
	exit 1
fi

rm -f "$WRAPPER_LOG"
printf 'PASS shared-gh-wrappers-checks gh api timeout wrapper\n'
