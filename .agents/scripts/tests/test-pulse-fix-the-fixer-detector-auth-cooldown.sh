#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23430: deterministic AI research auth failures should
# trip a local cooldown so pulse does not call the LLM classifier every cycle.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

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

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache" "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export ANTHROPIC_API_KEY="test-invalid-key"
	export AIDEVOPS_FIX_THE_FIXER_DETECTOR_AUTH_COOLDOWN_SECONDS=3600
	export CURL_COUNT_FILE="${TEST_ROOT}/curl-count"
	printf '0\n' >"$CURL_COUNT_FILE"

	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '[{"number":1,"labels":[{"name":"auto-dispatch"}]},{"number":2,"labels":[{"name":"auto-dispatch"}]}]\n'
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	printf '{"title":"fix dispatch path","body":"Touches pulse-wrapper.sh dispatch behaviour.","labels":[{"name":"auto-dispatch"}],"state":"OPEN"}\n'
	exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
STUB
	chmod +x "${TEST_ROOT}/bin/gh"

	cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count="0"
if [[ -f "${CURL_COUNT_FILE}" ]]; then
	count=$(tr -cd '0-9' <"${CURL_COUNT_FILE}")
fi
count=$((count + 1))
printf '%s\n' "$count" >"${CURL_COUNT_FILE}"
printf '{"error":{"message":"invalid x-api-key"}}\n'
exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/curl"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_detector() {
	local output_file="$1"
	"${PWD}/.agents/scripts/pulse-fix-the-fixer-detector.sh" run \
		--repo example/repo --limit 2 >"$output_file" 2>&1
	return 0
}

assert_file_mtime_helpers() {
	# shellcheck source=/dev/null
	source "${PWD}/.agents/scripts/pulse-fix-the-fixer-detector.sh"

	if declare -f _file_mtime_epoch >/dev/null 2>&1; then
		print_result "detector imports portable mtime helper" 0
	else
		print_result "detector imports portable mtime helper" 1 "_file_mtime_epoch unavailable"
	fi

	local missing_stamp
	missing_stamp=$(_file_mtime "${TEST_ROOT}/missing-config")
	if [[ "$missing_stamp" == "missing" ]]; then
		print_result "missing config stamp is explicit" 0
	else
		print_result "missing config stamp is explicit" 1 "stamp=${missing_stamp}"
	fi

	_file_mtime_epoch() {
		return 42
	}

	local existing_file="${TEST_ROOT}/existing-config"
	: >"$existing_file"
	local failed_stamp=""
	local rc=0
	failed_stamp=$(_file_mtime "$existing_file") || rc=$?
	if [[ "$rc" -eq 42 && "$failed_stamp" == "unknown" ]]; then
		print_result "mtime helper failures propagate" 0
	else
		print_result "mtime helper failures propagate" 1 "rc=${rc} stamp=${failed_stamp}"
	fi
	return 0
}

main() {
	setup_sandbox
	trap teardown_sandbox EXIT
	assert_file_mtime_helpers

	local first_log="${TEST_ROOT}/first.log"
	local second_log="${TEST_ROOT}/second.log"
	run_detector "$first_log"
	run_detector "$second_log"

	local curl_count
	curl_count=$(tr -cd '0-9' <"$CURL_COUNT_FILE")
	if [[ "$curl_count" == "1" ]]; then
		print_result "invalid credentials trigger cooldown after one LLM call" 0
	else
		print_result "invalid credentials trigger cooldown after one LLM call" 1 "curl calls=${curl_count}"
	fi

	if [[ -f "${HOME}/.aidevops/cache/fix-the-fixer-detector-auth.cooldown" ]]; then
		print_result "auth cooldown state file recorded" 0
	else
		print_result "auth cooldown state file recorded" 1 "cooldown file missing"
	fi

	local first_warn_count
	first_warn_count=$(grep -c 'fix-the-fixer-detector] WARN:' "$first_log" || true)
	if [[ "$first_warn_count" == "1" ]] && ! grep -q 'classification skipped' "$first_log"; then
		print_result "auth failures emit one cycle-level warning" 0
	else
		print_result "auth failures emit one cycle-level warning" 1 "warns=${first_warn_count}; first log: $(tr '\n' ' ' <"$first_log")"
	fi

	local second_warn_count
	second_warn_count=$(grep -c 'fix-the-fixer-detector] WARN:' "$second_log" || true)
	if [[ "$second_warn_count" == "1" ]] && ! grep -q 'classification skipped' "$second_log"; then
		print_result "cooldown skips emit one cycle-level warning" 0
	else
		print_result "cooldown skips emit one cycle-level warning" 1 "warns=${second_warn_count}; second log: $(tr '\n' ' ' <"$second_log")"
	fi

	if grep -q 'skipped:auth-error=2' "$second_log" && grep -q 'AI research credentials invalid' "$second_log"; then
		print_result "subsequent run reports concise auth skip" 0
	else
		print_result "subsequent run reports concise auth skip" 1 "second log: $(tr '\n' ' ' <"$second_log")"
	fi

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
