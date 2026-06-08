#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-orphan-remote-children-hold.sh — GH#24565 regression guard.
#
# Verifies that worker_branch_orphan redispatch is held when remote child issues
# reference a parent but local TODO.md lacks their ref:GH# state. This prevents a
# retry from allocating replacement task IDs and creating duplicate children.

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
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/posts"
	export PATH="${TEST_ROOT}/bin:${PATH}"
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
	cat >"${TEST_ROOT}/comments-orphan.json" <<'EOF'
[
  [
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/reused session=issue-100 ts=2026-06-08T20:00:00Z\n<!-- ops:end -->"}
  ]
]
EOF

	cat >"${TEST_ROOT}/comments-clean.json" <<'EOF'
[
  [
    {"body":"ordinary maintainer note"}
  ]
]
EOF

	cat >"${TEST_ROOT}/children.json" <<'EOF'
[
  {"number":501,"title":"t501: plan audit child","body":"For #100 — recover canonical plan-audit child","labels":[]},
  {"number":502,"title":"t502: implementation child","body":"Parent issue #100; blocked-by:t501","labels":[]}
]
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
		printf '%s\n' "$*" >>"${TEST_ROOT}/posts/${issue}.argv"
		exit 0
	fi
	if [[ "${ORPHAN_REMOTE_CHILDREN_COMMENTS:-orphan}" == "clean" ]]; then
		cat "${TEST_ROOT}/comments-clean.json"
	else
		cat "${TEST_ROOT}/comments-orphan.json"
	fi
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	cat "${TEST_ROOT}/children.json"
	exit 0
fi

printf 'unsupported gh invocation in orphan-remote-children stub: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

test_remote_children_without_local_refs_blocks() {
	local todo_file="${TEST_ROOT}/TODO-empty.md"
	local output=""
	: >"$todo_file"
	rm -f "${TEST_ROOT}/posts/100.argv"

	if output=$(TEST_ROOT="$TEST_ROOT" "$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/reused "$todo_file" 2>/dev/null); then
		if [[ "$output" == *"WORKER_BRANCH_ORPHAN_REMOTE_CHILDREN_BLOCKED"* && -f "${TEST_ROOT}/posts/100.argv" ]]; then
			print_result "remote children missing local refs block redispatch" 0
			return 0
		fi
		print_result "remote children missing local refs block redispatch" 1 "unexpected output or missing post: ${output}"
		return 0
	fi
	print_result "remote children missing local refs block redispatch" 1 "expected dispatch hold"
	return 0
}

test_remote_children_with_local_refs_do_not_block() {
	local todo_file="${TEST_ROOT}/TODO-synced.md"
	printf '%s\n' '- [ ] t501 plan audit ref:GH#501 logged:2026-06-08' '- [ ] t502 implementation ref:GH#502 logged:2026-06-08' >"$todo_file"
	rm -f "${TEST_ROOT}/posts/100.argv"

	if TEST_ROOT="$TEST_ROOT" "$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/reused "$todo_file" >/dev/null 2>&1; then
		print_result "remote children with local refs stay dispatchable" 1 "unexpected hold"
		return 0
	fi
	if [[ ! -f "${TEST_ROOT}/posts/100.argv" ]]; then
		print_result "remote children with local refs stay dispatchable" 0
		return 0
	fi
	print_result "remote children with local refs stay dispatchable" 1 "unexpected diagnostic post"
	return 0
}

test_no_orphan_telemetry_does_not_block() {
	local todo_file="${TEST_ROOT}/TODO-no-orphan.md"
	: >"$todo_file"
	rm -f "${TEST_ROOT}/posts/100.argv"

	if ORPHAN_REMOTE_CHILDREN_COMMENTS=clean TEST_ROOT="$TEST_ROOT" "$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/reused "$todo_file" >/dev/null 2>&1; then
		print_result "remote children without orphan telemetry stay dispatchable" 1 "unexpected hold"
		return 0
	fi
	print_result "remote children without orphan telemetry stay dispatchable" 0
	return 0
}

main() {
	setup_test_env
	test_remote_children_without_local_refs_blocks
	test_remote_children_with_local_refs_do_not_block
	test_no_orphan_telemetry_does_not_block
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
