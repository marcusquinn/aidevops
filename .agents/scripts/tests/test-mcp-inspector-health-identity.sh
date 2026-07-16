#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27967: MCP health checks must reject unrelated
# HTTP responses and accept only explicit aidevops service identities.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../mcp-inspector-helper.sh"
SANDBOX=""
OUTPUT=""
TEST_TOKEN="test-only-mcp-health-token-0123456789"

cleanup() {
	[[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_contains() {
	local description="$1"
	local expected="$2"

	if [[ "$OUTPUT" != *"$expected"* ]]; then
		fail "$description (missing: $expected)"
		return 1
	fi
	pass "$description"
	return 0
}

assert_not_contains() {
	local description="$1"
	local unexpected="$2"

	if [[ "$OUTPUT" == *"$unexpected"* ]]; then
		fail "$description (unexpected: $unexpected)"
		return 1
	fi
	pass "$description"
	return 0
}

run_health_fixture() {
	local fixture="$1"

	OUTPUT=$(PATH="${SANDBOX}/bin:${PATH}" \
		MCP_HEALTH_FIXTURE="$fixture" \
		FAKE_CURL_ARGS_LOG="${SANDBOX}/curl-args.log" \
		API_GATEWAY_TOKEN="$TEST_TOKEN" \
		bash "$HELPER" health 2>&1)
	return 0
}

SANDBOX=$(mktemp -d -t aidevops-mcp-health-XXXXXX)
mkdir -p "${SANDBOX}/bin"

cat >"${SANDBOX}/bin/npx" <<'EOF_NPX'
#!/usr/bin/env bash
exit 0
EOF_NPX

cat >"${SANDBOX}/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail

url=""
for argument in "$@"; do
	if [[ "$argument" == http://* || "$argument" == https://* ]]; then
		url="$argument"
	fi
done
printf '%s\n' "$*" >>"$FAKE_CURL_ARGS_LOG"

case "${MCP_HEALTH_FIXTURE}:${url}" in
valid:*:3100/health)
	printf '%s\n' '{"status":"healthy","service":"api-gateway"}'
	;;
valid:*:3101/health)
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
unrelated:*:3100/health)
	printf '%s\n' '<html>redirect</html>'
	;;
unrelated:*:3101/health)
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
wrong-service:*:3100/health)
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
wrong-service:*:3101/health)
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
unhealthy:*:3100/health)
	printf '%s\n' '{"status":"unhealthy","service":"api-gateway"}'
	;;
unhealthy:*:3101/health)
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
*)
	exit 22
	;;
esac
exit 0
EOF_CURL

chmod +x "${SANDBOX}/bin/npx" "${SANDBOX}/bin/curl"

run_health_fixture valid
assert_contains "valid gateway identity is healthy" "localhost:3100 - healthy"
assert_contains "valid dashboard identity is healthy" "localhost:3101 - healthy"
assert_contains "configured gateway identity is healthy" "api-gateway (streamable-http) - healthy"
assert_contains "configured dashboard identity is healthy" "mcp-dashboard (streamable-http) - healthy"

run_health_fixture unrelated
assert_contains "non-JSON gateway response is rejected locally" "localhost:3100 - unexpected service health response"
assert_contains "non-JSON gateway response is rejected from config" "api-gateway (streamable-http) - unexpected service health response"
assert_not_contains "non-JSON gateway response is not reported healthy" "localhost:3100 - healthy"

run_health_fixture wrong-service
assert_contains "wrong service identity is rejected" "localhost:3100 - unexpected service health response"

run_health_fixture unhealthy
assert_contains "unhealthy status is rejected" "localhost:3100 - unexpected service health response"

if grep -Fq "$TEST_TOKEN" "${SANDBOX}/curl-args.log"; then
	fail "gateway token leaked into curl argv"
	exit 1
fi
pass "gateway token stays out of curl argv"

printf 'All MCP inspector health identity tests passed.\n'
exit 0
