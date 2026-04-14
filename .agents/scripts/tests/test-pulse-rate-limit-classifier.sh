#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-rate-limit-classifier.sh — unit test for _pulse_gh_err_is_rate_limit
# and _pulse_mark_rate_limited from pulse-prefetch.sh (GH#18979 / t2097).
#
# Verifies:
#   - Positive matches: known gh CLI rate-limit strings
#   - Negative matches: unrelated errors (network, auth, 404)
#   - Edge cases: empty file, missing file
#   - Flag file: _pulse_mark_rate_limited appends without stomping prior entries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Stub environment — the helpers read $LOGFILE and $PULSE_RATE_LIMIT_FLAG
LOGFILE=$(mktemp)
PULSE_RATE_LIMIT_FLAG=$(mktemp -u)
export LOGFILE PULSE_RATE_LIMIT_FLAG

cleanup() {
	rm -f "$LOGFILE" "$PULSE_RATE_LIMIT_FLAG"
}
trap cleanup EXIT

# Stub module guard (pulse-prefetch.sh checks this) + stub helpers we don't need
_PULSE_PREFETCH_LOADED=""

# Source only the helper functions we need, in a minimal way. We can't source
# the whole pulse-prefetch.sh because it transitively depends on pulse-wrapper
# state. Extract the two helper function bodies instead.
eval "$(awk '
	/^_pulse_gh_err_is_rate_limit\(\) \{$/,/^\}$/ { print }
	/^_pulse_mark_rate_limited\(\) \{$/,/^\}$/ { print }
' "${REPO_ROOT}/.agents/scripts/pulse-prefetch.sh")"

# Verify the helpers were extracted
if ! declare -F _pulse_gh_err_is_rate_limit >/dev/null; then
	echo "FAIL: _pulse_gh_err_is_rate_limit not loaded" >&2
	exit 1
fi
if ! declare -F _pulse_mark_rate_limited >/dev/null; then
	echo "FAIL: _pulse_mark_rate_limited not loaded" >&2
	exit 1
fi

PASS=0
FAIL=0

assert_rate_limit() {
	local label="$1" content="$2"
	local tmp
	tmp=$(mktemp)
	printf '%s\n' "$content" >"$tmp"
	if _pulse_gh_err_is_rate_limit "$tmp"; then
		echo "PASS: $label"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $label — expected rate-limit match on: $content" >&2
		FAIL=$((FAIL + 1))
	fi
	rm -f "$tmp"
}

assert_not_rate_limit() {
	local label="$1" content="$2"
	local tmp
	tmp=$(mktemp)
	printf '%s\n' "$content" >"$tmp"
	if _pulse_gh_err_is_rate_limit "$tmp"; then
		echo "FAIL: $label — false positive on: $content" >&2
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $label"
		PASS=$((PASS + 1))
	fi
	rm -f "$tmp"
}

# ----- Positive matches: real gh CLI error strings -----
assert_rate_limit "graphql-rate-limit" \
	"GraphQL: API rate limit exceeded for user ID 6428977. (rateLimitExceeded)"

assert_rate_limit "rest-rate-limit" \
	"HTTP 403: API rate limit exceeded for 1.2.3.4. (https://api.github.com/repos/foo/bar/issues)"

assert_rate_limit "secondary-rate-limit" \
	"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."

assert_rate_limit "submitted-too-quickly" \
	"You have triggered an abuse detection mechanism. Your request was submitted too quickly."

assert_rate_limit "rate-limit-exceeded-for" \
	"API rate limit exceeded for user ID 12345."

assert_rate_limit "case-insensitive-match" \
	"graphql: api rate limit exceeded"

# ----- Negative matches: unrelated errors must NOT match -----
assert_not_rate_limit "network-timeout" \
	"request failed: Get https://api.github.com: dial tcp: i/o timeout"

assert_not_rate_limit "auth-failure" \
	"HTTP 401: Bad credentials (https://api.github.com/repos/foo/bar)"

assert_not_rate_limit "404-not-found" \
	"HTTP 404: Not Found (https://api.github.com/repos/foo/bar/issues/999)"

assert_not_rate_limit "500-server-error" \
	"HTTP 500: Internal Server Error"

assert_not_rate_limit "dns-failure" \
	"could not resolve host: api.github.com"

assert_not_rate_limit "unrelated-graphql-error" \
	"GraphQL: Field 'xyz' doesn't exist on type 'Repository'"

# ----- Edge cases -----
empty_file=$(mktemp)
if _pulse_gh_err_is_rate_limit "$empty_file"; then
	echo "FAIL: edge-empty — empty file should not match" >&2
	FAIL=$((FAIL + 1))
else
	echo "PASS: edge-empty"
	PASS=$((PASS + 1))
fi
rm -f "$empty_file"

if _pulse_gh_err_is_rate_limit "/nonexistent/path/to/err"; then
	echo "FAIL: edge-missing — missing file should not match" >&2
	FAIL=$((FAIL + 1))
else
	echo "PASS: edge-missing"
	PASS=$((PASS + 1))
fi

if _pulse_gh_err_is_rate_limit ""; then
	echo "FAIL: edge-empty-arg — empty arg should not match" >&2
	FAIL=$((FAIL + 1))
else
	echo "PASS: edge-empty-arg"
	PASS=$((PASS + 1))
fi

# ----- Flag file appends correctly across multiple sites -----
rm -f "$PULSE_RATE_LIMIT_FLAG"
_pulse_mark_rate_limited "site_one:owner/repo1"
_pulse_mark_rate_limited "site_two:owner/repo2"
_pulse_mark_rate_limited "site_three:owner/repo3"

if [[ -f "$PULSE_RATE_LIMIT_FLAG" ]]; then
	line_count=$(wc -l <"$PULSE_RATE_LIMIT_FLAG" | tr -d ' ')
	if [[ "$line_count" == "3" ]]; then
		echo "PASS: flag-append-3-sites"
		PASS=$((PASS + 1))
	else
		echo "FAIL: flag-append-3-sites — expected 3 lines, got $line_count" >&2
		FAIL=$((FAIL + 1))
	fi
else
	echo "FAIL: flag-append-3-sites — flag file not created" >&2
	FAIL=$((FAIL + 1))
fi

if grep -q "site_one:owner/repo1" "$PULSE_RATE_LIMIT_FLAG" 2>/dev/null; then
	echo "PASS: flag-contains-context"
	PASS=$((PASS + 1))
else
	echo "FAIL: flag-contains-context — context string missing" >&2
	FAIL=$((FAIL + 1))
fi

# ----- Log line emitted on mark -----
if grep -q "RATE_LIMIT_EXHAUSTED during site_one:owner/repo1" "$LOGFILE" 2>/dev/null; then
	echo "PASS: log-line-emitted"
	PASS=$((PASS + 1))
else
	echo "FAIL: log-line-emitted — expected loud log line" >&2
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" == "0" ]] || exit 1
exit 0
