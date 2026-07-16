#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27967 and GH#27972: MCP health checks must reject
# unrelated responses, validate service identities, and honor configured ports.

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
	local gateway_port="${2:-}"
	local dashboard_port="${3:-}"

	: >"${SANDBOX}/curl-args.log"
	OUTPUT=$(PATH="${SANDBOX}/bin:${PATH}" \
		MCP_HEALTH_FIXTURE="$fixture" \
		FAKE_CURL_ARGS_LOG="${SANDBOX}/curl-args.log" \
		API_GATEWAY_TOKEN="$TEST_TOKEN" \
		API_GATEWAY_PORT="$gateway_port" \
		MCP_DASHBOARD_PORT="$dashboard_port" \
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
gateway_port="${API_GATEWAY_PORT:-3100}"
dashboard_port="${MCP_DASHBOARD_PORT:-3101}"
for argument in "$@"; do
	if [[ "$argument" == http://* || "$argument" == https://* ]]; then
		url="$argument"
	fi
done
printf '%s\n' "$*" >>"$FAKE_CURL_ARGS_LOG"

case "${MCP_HEALTH_FIXTURE}:${url}" in
"valid:http://localhost:${gateway_port}/health")
	printf '%s\n' '{"status":"healthy","service":"api-gateway"}'
	;;
"valid:http://localhost:${dashboard_port}/health")
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
"unrelated:http://localhost:${gateway_port}/health")
	printf '%s\n' '<html>redirect</html>'
	;;
"unrelated:http://localhost:${dashboard_port}/health")
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
"wrong-service:http://localhost:${gateway_port}/health")
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
"wrong-service:http://localhost:${dashboard_port}/health")
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
"unhealthy:http://localhost:${gateway_port}/health")
	printf '%s\n' '{"status":"unhealthy","service":"api-gateway"}'
	;;
"unhealthy:http://localhost:${dashboard_port}/health")
	printf '%s\n' '{"status":"healthy","service":"mcp-dashboard"}'
	;;
gateway-test:*)
	if [[ "$url" != "http://localhost:${gateway_port}/"* ]]; then
		exit 22
	fi
	printf '%s\n' '{}'
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

run_health_fixture valid 3200 3201
assert_contains "configured gateway port is used locally" "localhost:3200 - healthy"
assert_contains "configured dashboard port is used locally" "localhost:3201 - healthy"
assert_contains "configured gateway URL honors its port" "api-gateway (streamable-http) - healthy"
assert_contains "configured dashboard URL honors its port" "mcp-dashboard (streamable-http) - healthy"
if grep -Eq 'localhost:3100|localhost:3101' "${SANDBOX}/curl-args.log"; then
	fail "configured health checks fell back to default ports"
	exit 1
fi
pass "configured health checks avoid default ports"

: >"${SANDBOX}/curl-args.log"
OUTPUT=$(PATH="${SANDBOX}/bin:${PATH}" \
	MCP_HEALTH_FIXTURE="gateway-test" \
	FAKE_CURL_ARGS_LOG="${SANDBOX}/curl-args.log" \
	API_GATEWAY_TOKEN="$TEST_TOKEN" \
	API_GATEWAY_PORT=3200 \
	bash "$HELPER" test-gateway 2>&1)
assert_contains "gateway test runs on configured port" "GET /health"
if grep -Fq 'localhost:3100' "${SANDBOX}/curl-args.log"; then
	fail "gateway test fell back to default port"
	exit 1
fi
if ! grep -Fq 'localhost:3200' "${SANDBOX}/curl-args.log"; then
	fail "gateway test did not call configured port"
	exit 1
fi
pass "gateway test uses configured port"
if grep -Fq "$TEST_TOKEN" "${SANDBOX}/curl-args.log"; then
	fail "gateway token leaked into curl argv"
	exit 1
fi
pass "gateway token stays out of curl argv"

: >"${SANDBOX}/curl-args.log"
invalid_rc=0
OUTPUT=$(PATH="${SANDBOX}/bin:${PATH}" \
	MCP_HEALTH_FIXTURE="valid" \
	FAKE_CURL_ARGS_LOG="${SANDBOX}/curl-args.log" \
	API_GATEWAY_TOKEN="$TEST_TOKEN" \
	API_GATEWAY_PORT="not-a-port" \
	bash "$HELPER" health 2>&1) || invalid_rc=$?
if [[ "$invalid_rc" -eq 0 ]]; then
	fail "invalid gateway port was accepted"
	exit 1
fi
assert_contains "invalid gateway port reports validation error" "API_GATEWAY_PORT must be an integer between 1 and 65535"
if [[ -s "${SANDBOX}/curl-args.log" ]]; then
	fail "invalid gateway port reached curl"
	exit 1
fi
pass "invalid gateway port fails before curl"

printf 'All MCP inspector health identity tests passed.\n'
exit 0
