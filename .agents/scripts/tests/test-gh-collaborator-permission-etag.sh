#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38562: conditional collaborator permission lookups must accept a 304 in
# both output shapes (`gh api -i` headers on stdout, or a bare stderr status),
# reuse only a verdict stored from an earlier 200, and keep failing closed for
# a 304 without a stored verdict or any other error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"

TEST_ROOT=""
REST_LOG=""
MOCK_MODE=""
TESTS_RUN=0
TESTS_FAILED=0

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
	mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR"
	REST_LOG="${TEST_ROOT}/rest.log"
	: >"$REST_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

check() {
	local name="$1"
	local condition_rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$condition_rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s %s\n' "$name" "$detail" >&2
	return 0
}

# shellcheck source=../shared-gh-collaborator-permission.sh
source "$HELPER_SCRIPT"

# Replaces the REST transport. MOCK_MODE selects the reply shape.
_rest_api_call() {
	printf '%s\n' "$*" >>"$REST_LOG"
	case "$MOCK_MODE" in
	ok)
		printf 'HTTP/2.0 200 OK\r\nETag: W/"perm-etag-1"\r\n\r\n{"permission":"admin","role_name":"admin"}\n'
		return 0
		;;
	not-modified-headers)
		printf 'HTTP/2.0 304 Not Modified\r\nETag: W/"perm-etag-1"\r\nX-RateLimit-Resource: core\r\n'
		printf 'gh: HTTP 304\n' >&2
		return 1
		;;
	not-modified-bare)
		printf 'gh: HTTP 304\n' >&2
		return 1
		;;
	server-error-headers)
		printf 'HTTP/2.0 502 Bad Gateway\r\nX-RateLimit-Resource: core\r\n'
		printf 'gh: HTTP 502\n' >&2
		return 1
		;;
	esac
	return 1
}

# The same-route retry sleeps between attempts; skip the wait in tests.
sleep() { return 0; }

lookup() {
	local out_var="$1"
	local rc=0
	_gh_collaborator_permission_lookup_uncached owner/repo someone "$out_var" || rc=$?
	return "$rc"
}

test_conditional_304_shapes() {
	local perm="" rc=0

	MOCK_MODE=ok
	lookup perm || rc=$?
	check "first 200 lookup returns the verdict" "$([[ "$rc" -eq 0 && "$perm" == admin ]] && printf 0 || printf 1)" "rc=$rc perm=$perm"

	: >"$REST_LOG"
	perm="" rc=0
	MOCK_MODE=not-modified-headers
	lookup perm || rc=$?
	check "304 with headers on stdout reuses the stored verdict" \
		"$([[ "$rc" -eq 0 && "$perm" == admin && "$AIDEVOPS_GH_COLLAB_PERMISSION_HTTP" == 304 && "$AIDEVOPS_GH_COLLAB_PERMISSION_REASON" == ok ]] && printf 0 || printf 1)" \
		"rc=$rc perm=$perm http=$AIDEVOPS_GH_COLLAB_PERMISSION_HTTP reason=$AIDEVOPS_GH_COLLAB_PERMISSION_REASON"
	check "conditional request sends the stored ETag" \
		"$(grep -qF 'If-None-Match: W/"perm-etag-1"' "$REST_LOG" && printf 0 || printf 1)" "log=$(<"$REST_LOG")"

	perm="" rc=0
	MOCK_MODE=not-modified-bare
	lookup perm || rc=$?
	check "304 with empty stdout reuses the stored verdict" \
		"$([[ "$rc" -eq 0 && "$perm" == admin ]] && printf 0 || printf 1)" "rc=$rc perm=$perm"

	perm="" rc=0
	MOCK_MODE=server-error-headers
	lookup perm || rc=$?
	check "502 with a stored ETag still fails closed" \
		"$([[ "$rc" -eq 2 && -z "$perm" ]] && printf 0 || printf 1)" "rc=$rc perm=$perm reason=$AIDEVOPS_GH_COLLAB_PERMISSION_REASON"
	return 0
}

test_304_without_stored_verdict_fails_closed() {
	local perm="" rc=0
	rm -rf "${HOME}/.aidevops/cache/gh-collaborator-permission-etags"
	: >"$REST_LOG"
	MOCK_MODE=not-modified-headers
	lookup perm || rc=$?
	check "304 without a stored verdict fails closed" \
		"$([[ "$rc" -eq 2 && -z "$perm" ]] && printf 0 || printf 1)" "rc=$rc perm=$perm"
	check "no ETag is sent without a stored verdict" \
		"$(grep -qF 'If-None-Match' "$REST_LOG" && printf 1 || printf 0)" "log=$(<"$REST_LOG")"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	test_conditional_304_shapes
	test_304_without_stored_verdict_fails_closed
	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
