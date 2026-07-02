#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="${TMP_DIR}/home"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache"

TIMEOUT_CALL_LOG="${TMP_DIR}/timeout-calls.log"
export TIMEOUT_CALL_LOG

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../pulse-rate-limit-circuit-breaker.sh"

_gh_with_timeout() {
	local op_class="$1"
	shift
	printf '_gh_with_timeout %s %s\n' "$op_class" "$*" >>"$TIMEOUT_CALL_LOG"
	if [[ "$op_class" == "read" && "$*" == "gh api rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":4000,"limit":5000},"core":{"remaining":4999,"limit":5000}}}\n'
		return 0
	fi
	return 1
}

rate_json="$(_cb_rate_limit_json normal)"
if [[ "$rate_json" != *'"remaining":4000'* ]]; then
	printf 'FAIL: expected rate_limit JSON from _gh_with_timeout, got: %s\n' "$rate_json" >&2
	exit 1
fi
if ! grep -q '_gh_with_timeout read gh api rate_limit' "$TIMEOUT_CALL_LOG"; then
	printf 'FAIL: _cb_rate_limit_json did not call _gh_with_timeout read gh api rate_limit\n' >&2
	exit 1
fi

rm -f "$TIMEOUT_CALL_LOG" "${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json"
unset -f _gh_with_timeout

timeout_sec() {
	local secs="$1"
	shift
	printf 'timeout_sec %s %s\n' "$secs" "$*" >>"$TIMEOUT_CALL_LOG"
	if [[ "$*" == "gh api rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":3000,"limit":5000},"core":{"remaining":4999,"limit":5000}}}\n'
		return 0
	fi
	return 1
}

rate_json="$(_cb_rate_limit_json normal)"
if [[ "$rate_json" != *'"remaining":3000'* ]]; then
	printf 'FAIL: expected rate_limit JSON from timeout_sec fallback, got: %s\n' "$rate_json" >&2
	exit 1
fi
if ! grep -q 'timeout_sec 15 gh api rate_limit' "$TIMEOUT_CALL_LOG"; then
	printf 'FAIL: _cb_rate_limit_json did not call timeout_sec fallback\n' >&2
	exit 1
fi

rm -f "$TIMEOUT_CALL_LOG" "${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json"
unset -f timeout_sec
OLD_PATH="$PATH"
EMPTY_BIN="${TMP_DIR}/empty-bin"
mkdir -p "$EMPTY_BIN"
PATH="$EMPTY_BIN"
if _cb_gh_read gh api rate_limit >/dev/null 2>&1; then
	PATH="$OLD_PATH"
	printf 'FAIL: _cb_gh_read should fail closed when no timeout wrapper is available\n' >&2
	exit 1
fi
PATH="$OLD_PATH"

printf 'PASS pulse-rate-limit-circuit-breaker-timeout\n'
