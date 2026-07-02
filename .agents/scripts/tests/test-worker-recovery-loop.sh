#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-worker-recovery-loop.sh — issue-level recovery failure fuse.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export TEST_ROOT
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/posts" "${TEST_ROOT}/edits"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export WORKER_RECOVERY_FAILURE_LOOP_THRESHOLD=2
	export WORKER_RECOVERY_FAILURE_LOOP_WINDOW_S=7200
	create_gh_stub
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

create_gh_stub() {
	local now_iso old_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	old_iso=$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)

	cat >"${TEST_ROOT}/comments-100.json" <<EOF
[[
  {"created_at":"${old_iso}","body":"WORKER_BRANCH_ORPHAN branch=feature/old session=issue-100 ts=${old_iso}"},
  {"created_at":"${now_iso}","body":"CLAIM_RELEASED reason=worker_branch_orphan runner=runner ts=${now_iso}"},
  {"created_at":"${now_iso}","body":"WORKER_BRANCH_ORPHAN branch=feature/one session=issue-100 ts=${now_iso}"},
  {"created_at":"${now_iso}","body":"WORKER_LOCAL_BRANCH_UNPUSHED branch=feature/two session=issue-100 ts=${now_iso}"}
]]
EOF

	cat >"${TEST_ROOT}/comments-200.json" <<EOF
[[
  {"created_at":"${now_iso}","body":"WORKER_LOCAL_BRANCH_UNPUSHED branch=feature/one session=issue-200 ts=${now_iso}"}
]]
EOF

	cat >"${TEST_ROOT}/comments-300.json" <<EOF
[[
  {"created_at":"${now_iso}","body":"WORKER_BRANCH_ORPHAN branch=feature/one session=issue-300 ts=${now_iso}"},
  {"created_at":"${now_iso}","body":"WORKER_LOCAL_BRANCH_UNPUSHED branch=feature/two session=issue-300 ts=${now_iso}"},
  {"created_at":"${now_iso}","body":"<!-- worker-recovery-loop:blocked count=2 threshold=2 window_s=7200 latest=${now_iso} -->"}
]]
EOF

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "api" ]]; then
	issue=""
	for arg in "$@"; do
		if [[ "$arg" =~ /issues/([0-9]+)/comments ]]; then
			issue="${BASH_REMATCH[1]}"
			break
		fi
	done
	[[ -n "$issue" ]] || exit 1
	if [[ " $* " == *" --method POST "* ]]; then
		printf '%s\n' "$*" >"${TEST_ROOT}/posts/${issue}.argv"
		exit 0
	fi
	comments_file="${TEST_ROOT}/comments-${issue}.json"
	if [[ -f "$comments_file" ]]; then
		cat "$comments_file"
	else
		printf '[[]]\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
	printf '%s\n' "$*" >"${TEST_ROOT}/edits/${3}.argv"
	exit 0
fi

printf 'unsupported gh invocation in recovery-loop stub: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

test_cross_branch_recovery_failures_block() {
	local output=""
	if output=$("$HELPER_SCRIPT" check-recovery-loop 100 owner/repo 2>/dev/null); then
		if [[ "$output" == *"WORKER_RECOVERY_LOOP_BLOCKED"* && -f "${TEST_ROOT}/posts/100.argv" ]] &&
			grep -q 'worker-recovery-loop:blocked .* version=[0-9]' "${TEST_ROOT}/posts/100.argv"; then
			print_result "cross-branch recovery failures trip issue-level hold" 0
			return 0
		fi
		print_result "cross-branch recovery failures trip issue-level hold" 1 "Unexpected output, missing diagnostic post, or missing version metadata: ${output}"
		return 0
	fi
	print_result "cross-branch recovery failures trip issue-level hold" 1 "Expected dispatch hold"
	return 0
}

test_single_recovery_failure_does_not_block() {
	if "$HELPER_SCRIPT" check-recovery-loop 200 owner/repo >/dev/null 2>&1; then
		print_result "single recovery failure remains dispatchable" 1 "Expected exit 1 (safe)"
		return 0
	fi
	print_result "single recovery failure remains dispatchable" 0
	return 0
}

test_existing_hold_is_idempotent() {
	local output=""
	if output=$("$HELPER_SCRIPT" check-recovery-loop 300 owner/repo 2>/dev/null); then
		if [[ "$output" == *"WORKER_RECOVERY_LOOP_BLOCKED"* && ! -f "${TEST_ROOT}/posts/300.argv" ]]; then
			print_result "existing recovery hold suppresses duplicate diagnostic" 0
			return 0
		fi
		print_result "existing recovery hold suppresses duplicate diagnostic" 1 "Unexpected duplicate post or output: ${output}"
		return 0
	fi
	print_result "existing recovery hold suppresses duplicate diagnostic" 1 "Expected dispatch hold"
	return 0
}

main() {
	setup_test_env
	test_cross_branch_recovery_failures_block
	test_single_recovery_failure_does_not_block
	test_existing_hold_is_idempotent
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
