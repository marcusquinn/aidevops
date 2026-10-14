#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regress account URL validation without network calls or a real secret store.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/librecrawl-login-test.XXXXXX")"

cleanup() {
	local test_root="$TEST_ROOT"
	rm -rf "$test_root"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

print_error() {
	local message="$1"
	printf '%s\n' "$message" >&2
	return 0
}

# shellcheck source=../site-crawler-helper-librecrawl.sh
source "${SCRIPT_DIR}/../site-crawler-helper-librecrawl.sh"

# Override only external boundaries. Any password lookup or API call during URL
# rejection is a failure, including calls made in command-substitution subshells.
_librecrawl_secret() {
	local name="$1"
	case "$name" in
	LIBRECRAWL_USERNAME) printf '%s' "${TEST_USERNAME:-}" ;;
	*) printf '%s\n' "$name" >>"${TEST_ROOT}/unexpected-secret" ;;
	esac
	return 0
}

_librecrawl_api() {
	local method="$1"
	local path="$2"
	printf '%s %s\n' "$method" "$path" >>"${TEST_ROOT}/api-calls"
	case "$method $path" in
	'POST /api/guest-login') printf '%s' '{"success":false}' ;;
	'GET /api/user/info') printf '%s' '{"user":{"tier":"admin"}}' ;;
	*) return 1 ;;
	esac
	return 0
}

TEST_USERNAME="regression-user"
for url in \
	'http://remote.invalid' \
	'http://localhost:5000@remote.invalid' \
	'http://127.0.0.1:5000@remote.invalid' \
	'http://localhost.remote.invalid' \
	'http://127.0.0.1.remote.invalid' \
	'http://localhost:5000/redirect'; do
	LIBRECRAWL_URL="$url"
	LIBRECRAWL_TIER="admin"
	_LIBRECRAWL_ACCOUNT=true
	if _librecrawl_login >"${TEST_ROOT}/output" 2>&1; then
		fail "account login accepted unsafe URL: $url"
	fi
	grep -q 'requires HTTPS (except loopback)' "${TEST_ROOT}/output" || fail "missing URL rejection diagnostic: $url"
	[[ ! -e "${TEST_ROOT}/unexpected-secret" ]] || fail 'URL rejection accessed a password'
	[[ ! -e "${TEST_ROOT}/api-calls" ]] || fail 'URL rejection called the API'
	[[ -z "$LIBRECRAWL_TIER" && "$_LIBRECRAWL_ACCOUNT" == false ]] || fail 'failed login retained session state'
	[[ "$_LIBRECRAWL_ACCOUNT_CONFIGURED" == true ]] || fail 'failed login lost configured-account state'
done

# Guest-disabled local mode must still establish an admin session via user info.
TEST_USERNAME=""
LIBRECRAWL_URL="http://127.0.0.1:5000"
_librecrawl_login || fail 'local-mode guest-disabled login failed'
[[ "$LIBRECRAWL_TIER" == admin ]] || fail 'local-mode admin tier was lost'
[[ "$_LIBRECRAWL_ACCOUNT" == false && "$_LIBRECRAWL_ACCOUNT_CONFIGURED" == false ]] || fail 'guest login retained account state'
librecrawl_is_usable || fail 'local-mode session was not usable'
[[ "$(<"${TEST_ROOT}/api-calls")" == $'POST /api/guest-login\nGET /api/user/info' ]] || fail 'guest login used unexpected API calls'
[[ ! -e "${TEST_ROOT}/unexpected-secret" ]] || fail 'guest login accessed a password'

printf 'PASS LibreCrawl account URL rejection and local-mode login regression cases\n'
