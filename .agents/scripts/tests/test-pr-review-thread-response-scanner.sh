#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="${TEST_SCRIPT_DIR}/../pr-review-thread-response-scanner.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	unset STUB_PR_LIST STUB_THREADS_MODE
	TEST_ROOT="$(mktemp -d -t prrts.XXXXXX)"
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${TEST_ROOT}/scanner.log"
	export AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR="${TEST_ROOT}/state"
	export HEADLESS_LOG="${TEST_ROOT}/headless.log"
	export HEADLESS_PROMPT_CAPTURE="${TEST_ROOT}/prompt.md"
	mkdir -p "${HOME}" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo" "${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}"
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "${2:-}" == "list" ]]; then
	printf '%s\n' "${STUB_PR_LIST:-1	Fix active PR	false	origin:worker	feature/review	worker-bot}"
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "graphql" ]]; then
	case "${STUB_THREADS_MODE:-unresolved}" in
	none)
		printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\n'
		;;
	*)
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"},"path":".agents/scripts/example.sh","line":42,"url":"https://example.invalid/thread","updatedAt":"2026-06-03T00:00:00Z"}]}},{"id":"THREAD2","isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"old.sh","line":1,"url":"https://example.invalid/resolved","updatedAt":"2026-06-03T00:00:00Z"}]}}]}}}}}'
		;;
	esac
	exit 0
fi
printf '[]\n'
exit 0
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	cat >"${TEST_ROOT}/headless-runtime-helper.sh" <<'HEADLESS_STUB'
#!/usr/bin/env bash
prompt_file=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--prompt-file)
		prompt_file="${2:-}"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
printf '%s\n' "${prompt_file}" >>"${HEADLESS_LOG}"
if [[ -n "$prompt_file" && -f "$prompt_file" ]]; then
	cp "$prompt_file" "${HEADLESS_PROMPT_CAPTURE}"
fi
exit 0
HEADLESS_STUB
	chmod +x "${TEST_ROOT}/headless-runtime-helper.sh"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-runtime-helper.sh"
	export PR_REVIEW_THREAD_RESPONSE_COOLDOWN=3600
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

wait_for_headless_log() {
	local attempts=0
	while [[ "$attempts" -lt 10 ]]; do
		if [[ -s "$HEADLESS_LOG" ]]; then
			return 0
		fi
		sleep 1
		attempts=$((attempts + 1))
	done
	return 1
}

test_scan_finds_unresolved_bot_thread() {
	setup_test_env
	local output=""
	output="$($SCANNER scan owner/repo "${TEST_ROOT}/repo")"
	if [[ "$output" == *$'1\t1\t'* && "$output" == *"gemini-code-assist"* ]]; then
		print_result "scan finds unresolved bot review thread" 0
	else
		print_result "scan finds unresolved bot review thread" 1 "output=${output}"
	fi
	teardown_test_env
	return 0
}

test_scan_skips_draft_prs() {
	setup_test_env
	export STUB_PR_LIST=$'2\tDraft PR\ttrue\torigin:worker\tfeature/draft\tworker-bot'
	local output=""
	output="$($SCANNER scan owner/repo "${TEST_ROOT}/repo")"
	if [[ -z "$output" ]]; then
		print_result "scan skips draft PRs" 0
	else
		print_result "scan skips draft PRs" 1 "output=${output}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_launches_worker_and_writes_state() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ -s "$HEADLESS_LOG" && -f "$state_file" ]] && grep -q 'Do not use blanket auto-resolution scripts' "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null; then
		print_result "dispatch launches bounded worker and writes state" 0
	else
		print_result "dispatch launches bounded worker and writes state" 1 "headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), state=${state_file}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_is_idempotent_for_same_fingerprint() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	: >"$HEADLESS_LOG"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if [[ ! -s "$HEADLESS_LOG" ]]; then
		print_result "dispatch skips same fingerprint during cooldown" 0
	else
		print_result "dispatch skips same fingerprint during cooldown" 1 "second dispatch unexpectedly launched"
	fi
	teardown_test_env
	return 0
}

main() {
	test_scan_finds_unresolved_bot_thread
	test_scan_skips_draft_prs
	test_dispatch_launches_worker_and_writes_state
	test_dispatch_is_idempotent_for_same_fingerprint

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
