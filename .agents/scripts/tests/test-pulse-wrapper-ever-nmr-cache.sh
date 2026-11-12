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
	# Keep lock-timeout cases fast; production defaults to 50 retries.
	EVER_NMR_LOCK_RETRIES=3
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

# Exercise the production module (GH#37869), not a private copy. It has no
# top-level side effects; the gh stub above stands in for the transport.
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../pulse-nmr-approval-cache.sh
source "${TEST_SCRIPT_DIR}/../pulse-nmr-approval-cache.sh"

# Create the cache lock dir, optionally with an owner record, and backdate it.
# Arguments: $1 - owner PID or empty, $2 - touch -t stamp or empty (now)
make_lock_dir() {
	local owner_pid="$1"
	local stamp="$2"
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	mkdir -p "$lock_dir"
	if [[ -n "$owner_pid" ]]; then
		printf '%s\n' "$owner_pid" >"${lock_dir}/owner.pid"
	fi
	if [[ -n "$stamp" ]]; then
		touch -t "$stamp" "$lock_dir"
	fi
	return 0
}

# Print the cached ever_nmr value for a key, or "missing".
cached_value() {
	local issue_num="$1"
	local key=""
	key=$(_ever_nmr_cache_key "$issue_num" "owner/repo")
	[[ -f "$EVER_NMR_CACHE_FILE" ]] || {
		printf 'missing\n'
		return 0
	}
	jq -r --arg key "$key" 'if .[$key] == null then "missing" else (.[$key].ever_nmr | tostring) end' "$EVER_NMR_CACHE_FILE"
	return 0
}

reset_lock_state() {
	rm -f "$GH_MARKER_FILE" "$EVER_NMR_CACHE_FILE" "$LOGFILE"
	rm -rf "${EVER_NMR_CACHE_FILE}.lockdir"
	return 0
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

test_old_ownerless_lock_is_reclaimed() {
	local name="old ownerless lockdir is reclaimed and the cache write lands (GH#37869)"
	reset_lock_state
	make_lock_dir "" "202001010000"
	_ever_nmr_cache_set "17462" "owner/repo" "false"
	local value=""
	value=$(cached_value "17462")
	if [[ "$value" == "false" && ! -d "${EVER_NMR_CACHE_FILE}.lockdir" ]] &&
		grep -q 'clearing stale lock (ownerless' "$LOGFILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "cached=${value} lockdir_exists=$([[ -d "${EVER_NMR_CACHE_FILE}.lockdir" ]] && echo yes || echo no)"
	return 0
}

test_fresh_ownerless_lock_is_respected() {
	local name="fresh ownerless lockdir is not reclaimed; set stays non-fatal"
	reset_lock_state
	make_lock_dir "" ""
	local rc=0
	_ever_nmr_cache_set "17463" "owner/repo" "false" || rc=$?
	local value=""
	value=$(cached_value "17463")
	if [[ "$rc" -eq 0 && "$value" == "missing" && -d "${EVER_NMR_CACHE_FILE}.lockdir" ]] &&
		grep -q 'lock acquisition timed out' "$LOGFILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "rc=${rc} cached=${value}"
	return 0
}

test_dead_owner_lock_is_reclaimed() {
	local name="dead-owner lock is reclaimed by the production function"
	reset_lock_state
	local dead_pid=""
	sh -c 'exit 0' &
	dead_pid=$!
	wait "$dead_pid" 2>/dev/null || true
	make_lock_dir "$dead_pid" ""
	_ever_nmr_cache_set "17464" "owner/repo" "true"
	local value=""
	value=$(cached_value "17464")
	if [[ "$value" == "true" ]] && grep -q "owner PID ${dead_pid} gone" "$LOGFILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "cached=${value}"
	return 0
}

test_live_owner_is_never_reclaimed() {
	local name="live owner is respected however old its lock is"
	reset_lock_state
	make_lock_dir "$$" "202001010000"
	_ever_nmr_cache_set "17466" "owner/repo" "false"
	local value=""
	value=$(cached_value "17466")
	if [[ "$value" == "missing" && -f "${EVER_NMR_CACHE_FILE}.lockdir/owner.pid" ]] &&
		! grep -q 'clearing stale lock' "$LOGFILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "cached=${value}"
	return 0
}

test_leading_zero_settings_are_decimal() {
	local name="leading-zero lock settings are read as decimal, not octal"
	reset_lock_state
	make_lock_dir "$$" ""
	local rc=0
	# 08 is invalid octal; without base-10 normalisation the timeout never fires.
	EVER_NMR_LOCK_RETRIES=08 _ever_nmr_cache_set "17468" "owner/repo" "false" || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -q 'lock acquisition timed out' "$LOGFILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "rc=${rc}"
	return 0
}

test_release_skips_lock_owned_by_another_caller() {
	local name="release leaves a lock that another caller re-acquired"
	reset_lock_state
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	steal_lock() {
		# Simulate reclamation plus re-acquisition by another caller mid-callback.
		printf '%s\n' "999999" >"${EVER_NMR_CACHE_FILE}.lockdir/owner.pid"
		return 0
	}
	_ever_nmr_cache_with_lock steal_lock || true
	local recorded=""
	recorded=$(cat "${lock_dir}/owner.pid" 2>/dev/null || true)
	if [[ -d "$lock_dir" && "$recorded" == "999999" ]]; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "lockdir_exists=$([[ -d "$lock_dir" ]] && echo yes || echo no) recorded=${recorded}"
	return 0
}

test_lost_lock_skips_callback() {
	local name="lost lock before owner registration skips the callback"
	reset_lock_state
	local marker="${TEST_ROOT}/callback-ran"
	rm -f "$marker"
	mark_callback() {
		printf 'ran\n' >"$marker"
		return 0
	}
	# Make the owner write fail right after acquisition, as when the lock is
	# reclaimed while its holder pauses: occupy owner.pid with a directory.
	local lock_path="${EVER_NMR_CACHE_FILE}.lockdir"
	mkdir() {
		command mkdir "$@" || return 1
		if [[ "${1:-}" == "$lock_path" ]]; then
			command mkdir -p "${lock_path}/owner.pid"
		fi
		return 0
	}
	local rc=0
	_ever_nmr_cache_with_lock mark_callback || rc=$?
	unset -f mkdir
	if [[ "$rc" -ne 0 && ! -f "$marker" ]] && grep -q 'lost lock before owner registration' "$LOGFILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "rc=${rc} callback_ran=$([[ -f "$marker" ]] && echo yes || echo no)"
	return 0
}

test_instance_token_tracks_replacement() {
	local name="lock instance token changes when the lock is replaced"
	reset_lock_state
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	make_lock_dir "" ""
	local before="" after_owner=""
	before=$(_ever_nmr_lock_instance "$lock_dir")
	printf '%s\n' "$$" >"${lock_dir}/owner.pid"
	after_owner=$(_ever_nmr_lock_instance "$lock_dir")
	if [[ "$before" == *":none" && "$after_owner" == *":$$" && "$before" != "$after_owner" ]]; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "before=${before} after=${after_owner}"
	return 0
}

test_abandoned_reclaim_marker_is_cleared() {
	local name="abandoned .reclaim marker does not wedge reclamation"
	reset_lock_state
	make_lock_dir "" ""
	mkdir "${EVER_NMR_CACHE_FILE}.lockdir/.reclaim"
	touch -t "202001010000" "${EVER_NMR_CACHE_FILE}.lockdir/.reclaim" "${EVER_NMR_CACHE_FILE}.lockdir"
	_ever_nmr_cache_set "17467" "owner/repo" "true"
	local value=""
	value=$(cached_value "17467")
	if [[ "$value" == "true" && ! -d "${EVER_NMR_CACHE_FILE}.lockdir" ]]; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "cached=${value}"
	return 0
}

test_owner_record_is_current_shell() {
	local name="owner.pid records the holding subshell, not the parent \$\$"
	reset_lock_state
	local recorded="" expected=""
	read_owner() {
		cat "${EVER_NMR_CACHE_FILE}.lockdir/owner.pid"
		return 0
	}
	# Run in a subshell, as parallel dispatch does; capture both PIDs there.
	local pair=""
	pair=$( (
		_ever_nmr_cache_with_lock read_owner
		printf '%s\n' "$(exec sh -c 'printf "%s" "$PPID"')"
	))
	recorded=$(printf '%s\n' "$pair" | sed -n '1p')
	expected=$(printf '%s\n' "$pair" | sed -n '2p')
	if [[ -n "$recorded" && "$recorded" == "$expected" && "$recorded" != "$$" ]]; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "recorded=${recorded} expected=${expected} parent=$$"
	return 0
}

main() {
	setup_test_env
	test_positive_cache_is_reused_without_api_call
	test_negative_cache_is_reused_within_ttl
	test_stale_negative_cache_refreshes_from_api
	test_known_status_short_circuits_cache_and_api
	test_old_ownerless_lock_is_reclaimed
	test_fresh_ownerless_lock_is_respected
	test_dead_owner_lock_is_reclaimed
	test_live_owner_is_never_reclaimed
	test_leading_zero_settings_are_decimal
	test_release_skips_lock_owned_by_another_caller
	test_lost_lock_skips_callback
	test_instance_token_tracks_replacement
	test_abandoned_reclaim_marker_is_cleared
	test_owner_record_is_current_shell
	teardown_test_env

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
