#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
GH_MARKER_FILE=""
LOGFILE=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/.agent-workspace/supervisor" "${HOME}/.aidevops/logs"
	EVER_NMR_CACHE_FILE="${HOME}/.aidevops/.agent-workspace/supervisor/ever-nmr-cache.json"
	EVER_NMR_NEGATIVE_CACHE_TTL_SECS=300
	LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	GH_MARKER_FILE="${TEST_ROOT}/gh-called"
	return 0
}

teardown_test_env() {
	export HOME="${ORIGINAL_HOME}"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh() {
	printf 'called\n' >>"$GH_MARKER_FILE"
	if [[ "${1:-}" == "api" ]]; then
		printf '1\n'
		return 0
	fi
	return 1
}

_ever_nmr_cache_key() {
	local issue_num="$1"
	local slug="$2"
	printf '%s\n' "${slug}#${issue_num}"
	return 0
}

_ever_nmr_cache_load() {
	if [[ ! -f "$EVER_NMR_CACHE_FILE" ]]; then
		printf '{}\n'
		return 0
	fi

	local content
	content=$(cat "$EVER_NMR_CACHE_FILE" 2>/dev/null) || content="{}"
	if ! printf '%s' "$content" | jq empty >/dev/null 2>&1; then
		content="{}"
	fi

	printf '%s\n' "$content"
	return 0
}

_ever_nmr_cache_with_lock() {
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		sleep 0.1
	done

	local rc=0
	"$@" || rc=$?
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

_ever_nmr_cache_get() {
	local issue_num="$1"
	local slug="$2"
	local key now_epoch cache_json cache_value checked_at age

	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	cache_json=$(_ever_nmr_cache_load)
	cache_value=$(printf '%s' "$cache_json" | jq -r --arg key "$key" 'if .[$key] == null then "unknown" elif .[$key].ever_nmr == true then "true" elif .[$key].ever_nmr == false then "false" else "unknown" end' 2>/dev/null) || cache_value="unknown"
	checked_at=$(printf '%s' "$cache_json" | jq -r --arg key "$key" '.[$key].checked_at // 0' 2>/dev/null) || checked_at=0
	[[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0

	if [[ "$cache_value" == "true" ]]; then
		printf 'true\n'
		return 0
	fi

	if [[ "$cache_value" == "false" ]]; then
		age=$((now_epoch - checked_at))
		if [[ "$age" -lt "$EVER_NMR_NEGATIVE_CACHE_TTL_SECS" ]]; then
			printf 'false\n'
			return 0
		fi
	fi

	printf 'unknown\n'
	return 0
}

_ever_nmr_cache_set_locked() {
	local issue_num="$1"
	local slug="$2"
	local cache_value="$3"
	local state_dir cache_json key now_epoch tmp_file

	[[ "$cache_value" == "true" || "$cache_value" == "false" ]] || return 1

	state_dir=$(dirname "$EVER_NMR_CACHE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	cache_json=$(_ever_nmr_cache_load)
	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	tmp_file=$(mktemp "${state_dir}/.ever-nmr-cache.XXXXXX" 2>/dev/null) || return 0

	if printf '%s' "$cache_json" | jq --arg key "$key" --argjson checked_at "$now_epoch" --argjson ever_nmr "$cache_value" '.[$key] = {ever_nmr: $ever_nmr, checked_at: $checked_at}' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$EVER_NMR_CACHE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to move cache file" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to write cache entry" >>"$LOGFILE"
	fi

	return 0
}

_ever_nmr_cache_set() {
	_ever_nmr_cache_with_lock _ever_nmr_cache_set_locked "$@" || return 0
	return 0
}

issue_was_ever_nmr() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 1

	case "$known_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local cache_status
	cache_status=$(_ever_nmr_cache_get "$issue_num" "$slug")
	case "$cache_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local ever_count
	ever_count=$(gh api "repos/${slug}/issues/${issue_num}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")] | length' \
		2>/dev/null) || ever_count=0
	[[ "$ever_count" =~ ^[0-9]+$ ]] || ever_count=0

	if [[ "$ever_count" -gt 0 ]]; then
		_ever_nmr_cache_set "$issue_num" "$slug" "true"
		return 0
	fi

	_ever_nmr_cache_set "$issue_num" "$slug" "false"
	return 1
}

test_positive_cache_is_reused_without_api_call() {
	rm -f "$GH_MARKER_FILE" "$EVER_NMR_CACHE_FILE"
	_ever_nmr_cache_set "17458" "owner/repo" "true"
	if issue_was_ever_nmr "17458" "owner/repo"; then
		if [[ ! -f "$GH_MARKER_FILE" ]]; then
			print_result "positive ever-NMR cache avoids timeline API call" 0
			return 0
		fi
		print_result "positive ever-NMR cache avoids timeline API call" 1 "gh api was called unexpectedly"
		return 0
	fi
	print_result "positive ever-NMR cache avoids timeline API call" 1 "function returned false"
	return 0
}

test_negative_cache_is_reused_within_ttl() {
	rm -f "$GH_MARKER_FILE" "$EVER_NMR_CACHE_FILE"
	_ever_nmr_cache_set "17459" "owner/repo" "false"
	if issue_was_ever_nmr "17459" "owner/repo"; then
		print_result "negative ever-NMR cache avoids timeline API call within TTL" 1 "function returned true"
		return 0
	fi
	if [[ ! -f "$GH_MARKER_FILE" ]]; then
		print_result "negative ever-NMR cache avoids timeline API call within TTL" 0
		return 0
	fi
	print_result "negative ever-NMR cache avoids timeline API call within TTL" 1 "gh api was called unexpectedly"
	return 0
}

test_stale_negative_cache_refreshes_from_api() {
	rm -f "$GH_MARKER_FILE" "$EVER_NMR_CACHE_FILE"
	local old_ts key stale_json
	old_ts=$(($(date +%s) - EVER_NMR_NEGATIVE_CACHE_TTL_SECS - 10))
	key=$(_ever_nmr_cache_key "17460" "owner/repo")
	stale_json=$(jq -n --arg key "$key" --argjson checked_at "$old_ts" '{($key): {ever_nmr: false, checked_at: $checked_at}}')
	printf '%s\n' "$stale_json" >"$EVER_NMR_CACHE_FILE"

	if ! issue_was_ever_nmr "17460" "owner/repo"; then
		print_result "stale negative cache refreshes via timeline API" 1 "function returned false after refresh"
		return 0
	fi
	if [[ -f "$GH_MARKER_FILE" ]]; then
		print_result "stale negative cache refreshes via timeline API" 0
		return 0
	fi
	print_result "stale negative cache refreshes via timeline API" 1 "expected gh api call did not happen"
	return 0
}

test_known_status_short_circuits_cache_and_api() {
	rm -f "$GH_MARKER_FILE" "$EVER_NMR_CACHE_FILE"
	if issue_was_ever_nmr "17461" "owner/repo" "true"; then
		if [[ ! -f "$GH_MARKER_FILE" && ! -f "$EVER_NMR_CACHE_FILE" ]]; then
			print_result "known ever-NMR status short-circuits cache and API" 0
			return 0
		fi
		print_result "known ever-NMR status short-circuits cache and API" 1 "unexpected cache or API activity"
		return 0
	fi
	print_result "known ever-NMR status short-circuits cache and API" 1 "function returned false"
	return 0
}

main() {
	setup_test_env
	test_positive_cache_is_reused_without_api_call
	test_negative_cache_is_reused_within_ttl
	test_stale_negative_cache_refreshes_from_api
	test_known_status_short_circuits_cache_and_api
	teardown_test_env

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
