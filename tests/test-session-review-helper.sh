#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-session-review-helper.sh — Regression tests for security summary helpers (GH#4149)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${REPO_DIR}/.agents/scripts"
VERBOSE="${1:-}"

PASS_COUNT=0
FAIL_COUNT=0
TEST_TMPDIR=""

cleanup() {
	if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
		rm -rf "${TEST_TMPDIR}"
		TEST_TMPDIR=""
	fi
	return 0
}
trap cleanup EXIT

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "  PASS: ${name}"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "  FAIL: ${name}"
	if [[ -n "${detail}" ]]; then
		echo "        ${detail}"
	fi
	return 0
}

verbose() {
	local msg="$1"
	if [[ "${VERBOSE}" == "--verbose" ]]; then
		echo "  [v] ${msg}"
	fi
	return 0
}

setup_fixtures() {
	TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${TEST_TMPDIR}/home/.aidevops/.agent-workspace/observability"
	cp "${SOURCE_DIR}/session-review-helper.sh" "${TEST_TMPDIR}/session-review-helper.sh"
	cp "${SOURCE_DIR}/shared-constants.sh" "${TEST_TMPDIR}/shared-constants.sh"
	chmod +x "${TEST_TMPDIR}/session-review-helper.sh"
	return 0
}

# run_test <label> <test_fn> — sets up fixtures, runs the test function, then cleans up.
# Each test function receives no arguments and uses TEST_TMPDIR for its fixtures.
run_test() {
	local label="$1"
	local test_fn="$2"
	echo "Test: ${label}"
	setup_fixtures
	"${test_fn}"
	cleanup
	return 0
}

run_security_json() {
	local session_id="$1"
	HOME="${TEST_TMPDIR}/home" "${TEST_TMPDIR}/session-review-helper.sh" security --json --session "${session_id}"
	local status=$?
	return "$status"
}

_test_session_helper_uses_session_id_flag() {
	cat >"${TEST_TMPDIR}/session-security-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "get-context" && "${2:-}" == "--session-id" && "${3:-}" == "abc.123" ]]; then
	printf '{"session_id":"%s","threat_level":"LOW"}\n' "${3}"
	exit 0
fi
exit 1
EOF
	chmod +x "${TEST_TMPDIR}/session-security-helper.sh"

	local result
	if ! result="$(run_security_json "abc.123")"; then
		fail "security --json command" "command failed"
		return 0
	fi

	local available
	available="$(printf '%s' "${result}" | jq -r '.session_context.available')"
	local context_session
	context_session="$(printf '%s' "${result}" | jq -r '.session_context.session_id')"

	if [[ "${available}" == "true" && "${context_session}" == "abc.123" ]]; then
		pass "get-context call accepted --session-id"
	else
		fail "get-context call accepted --session-id" "available=${available} session_id=${context_session}"
		verbose "output=${result}"
	fi
	return 0
}

_test_invalid_context_falls_back_to_unavailable() {
	cat >"${TEST_TMPDIR}/session-security-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "get-context" ]]; then
	echo "not-json"
	exit 0
fi
exit 1
EOF
	chmod +x "${TEST_TMPDIR}/session-security-helper.sh"

	local result
	if ! result="$(run_security_json "abc123")"; then
		fail "security --json command" "command failed"
		return 0
	fi

	local available
	available="$(printf '%s' "${result}" | jq -r '.session_context.available')"
	if [[ "${available}" == "false" ]]; then
		pass "fallback keeps session_context.available false"
	else
		fail "fallback keeps session_context.available false" "available=${available}"
		verbose "output=${result}"
	fi
	return 0
}

_test_sqlite_cost_query_param_binding() {
	cat >"${TEST_TMPDIR}/session-security-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
	chmod +x "${TEST_TMPDIR}/session-security-helper.sh"

	local db_path="${TEST_TMPDIR}/home/.aidevops/.agent-workspace/observability/llm-requests.db"
	sqlite3 "${db_path}" \
		'CREATE TABLE llm_requests(model_id TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER, cost REAL, session_id TEXT);' \
		"INSERT INTO llm_requests VALUES('openai/gpt-5.3-codex',100,40,10,1.25,'session-A');" \
		"INSERT INTO llm_requests VALUES('openai/gpt-5.3-codex',10,5,1,0.50,'session-B');"

	local result
	if ! result="$(run_security_json "session-A")"; then
		fail "security --json command" "command failed"
		return 0
	fi

	local total requests
	total="$(printf '%s' "${result}" | jq -r '.cost.total')"
	requests="$(printf '%s' "${result}" | jq -r '.cost.breakdown[0].requests // 0')"
	if [[ "${total}" == "1.25" && "${requests}" == "1" ]]; then
		pass "sqlite query returns filtered session totals"
	else
		fail "sqlite query returns filtered session totals" "total=${total} requests=${requests}"
		verbose "output=${result}"
	fi
	return 0
}

main() {
	echo "Running session-review-helper regression tests (GH#4149)..."
	echo ""

	if ! command -v jq >/dev/null 2>&1; then
		echo "ERROR: jq is required"
		return 1
	fi

	if ! command -v sqlite3 >/dev/null 2>&1; then
		echo "ERROR: sqlite3 is required"
		return 1
	fi

	run_test "session helper uses --session-id" _test_session_helper_uses_session_id_flag
	run_test "invalid helper context falls back unavailable" _test_invalid_context_falls_back_to_unavailable
	run_test "sqlite cost query uses working param binding" _test_sqlite_cost_query_param_binding

	echo ""
	echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

	if [[ "${FAIL_COUNT}" -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
