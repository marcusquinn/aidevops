#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-worker-branch-orphan-loop.sh — GH#22049 regression guard.
#
# Asserts that repeated WORKER_BRANCH_ORPHAN markers for the same issue+branch
# trip the dispatch hold, while a different branch or unrelated failure class
# remains dispatchable.

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
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/posts"
	mkdir -p "${TEST_ROOT}/wt-with-commits/.git" "${TEST_ROOT}/wt-zero-commits/.git"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export AIDEVOPS_REPOS_JSON="${TEST_ROOT}/repos.json"
	export WORKER_BRANCH_ORPHAN_LOOP_THRESHOLD=2
	export WORKER_BRANCH_ORPHAN_LOOP_WINDOW_S=7200
	cat >"$AIDEVOPS_REPOS_JSON" <<'EOF'
{"initialized_repos":[{"slug":"owner/develop-repo","pr_base_branch":"develop"}]}
EOF
	create_gh_stub
	create_git_stub
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
[
  [
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/reused session=issue-100 ts=${old_iso}\n<!-- ops:end -->"},
    {"body":"<!-- ops:start -->\nWORKER_NOOP branch=feature/reused session=issue-100 ts=${now_iso}\n<!-- ops:end -->"}
  ],
  [
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/reused session=issue-100 ts=${now_iso}\n<!-- ops:end -->"},
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/reused session=issue-100 ts=${now_iso}\n<!-- ops:end -->"},
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/other session=issue-100 ts=${now_iso}\n<!-- ops:end -->"},
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/missing session=issue-100 ts=${now_iso}\n<!-- ops:end -->"},
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/empty session=issue-100 ts=${now_iso}\n<!-- ops:end -->"}
  ]
]
EOF

	cat >"${TEST_ROOT}/comments-200.json" <<EOF
[
  [
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/reused session=issue-200 ts=${now_iso}\n<!-- ops:end -->"}
  ]
]
EOF

	cat >"${TEST_ROOT}/comments-300.json" <<EOF
[
  [
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/reused session=issue-300 ts=${now_iso}\n<!-- ops:end -->"},
    {"body":"<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=feature/reused session=issue-300 ts=${now_iso}\n<!-- ops:end -->"}
  ]
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
	comments_file="${TEST_ROOT}/comments-${issue}.json"
	if [[ -f "$comments_file" ]]; then
		cat "$comments_file"
	else
		printf '[[]]\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	if [[ "$*" == *"owner/develop-repo"* ]]; then
		exit 0
	fi
	printf '#123 (OPEN) https://example.invalid/pr/123\n'
	exit 0
fi

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
	printf 'main\n'
	exit 0
fi

printf 'unsupported gh invocation in orphan-loop stub: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

create_git_stub() {
	cat >"${TEST_ROOT}/bin/git" <<'GITEOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-C" ]]; then
	worktree_path="${2:-}"
	shift 2
else
	worktree_path=""
fi

if [[ "${1:-}" == "ls-remote" ]]; then
	branch_ref=""
	for arg in "$@"; do
		branch_ref="$arg"
	done
	case "$branch_ref" in
		refs/heads/feature/missing)
			exit 2
			;;
		*)
			printf '0000000000000000000000000000000000000000\t%s\n' "$branch_ref"
			exit 0
			;;
	esac
fi

if [[ "${1:-}" == "rev-list" && "${2:-}" == "--count" ]]; then
	case "${3:-}" in
		origin/main..origin/feature/empty|origin/feature/empty)
			printf '0\n'
			;;
		*)
			printf '2\n'
			;;
	esac
	exit 0
fi

printf 'unsupported git invocation in orphan-loop stub: %s\n' "$*" >&2
exit 1
GITEOF
	chmod +x "${TEST_ROOT}/bin/git"
	return 0
}

test_same_issue_branch_blocks_and_posts_diagnostic() {
	local output=""
	if output=$("$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/reused "" "${TEST_ROOT}/wt-with-commits" 2>/dev/null); then
		if [[ "$output" == *"WORKER_BRANCH_ORPHAN_LOOP_BLOCKED"* && -f "${TEST_ROOT}/posts/100.argv" ]]; then
			print_result "same issue+branch crosses threshold and posts diagnostic" 0
			return 0
		fi
		print_result "same issue+branch crosses threshold and posts diagnostic" 1 "Unexpected output or missing post: ${output}"
		return 0
	fi
	print_result "same issue+branch crosses threshold and posts diagnostic" 1 "Expected dispatch hold"
	return 0
}

test_different_branch_does_not_block() {
	if "$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/fresh "" "${TEST_ROOT}/wt-with-commits" >/dev/null 2>&1; then
		print_result "different branch does not inherit orphan count" 1 "Expected exit 1 (safe)"
		return 0
	fi
	print_result "different branch does not inherit orphan count" 0
	return 0
}

test_different_issue_does_not_block() {
	if "$HELPER_SCRIPT" check-orphan-loop 200 owner/repo feature/reused "" "${TEST_ROOT}/wt-with-commits" >/dev/null 2>&1; then
		print_result "different issue does not inherit orphan count" 1 "Expected exit 1 (safe)"
		return 0
	fi
	print_result "different issue does not inherit orphan count" 0
	return 0
}

test_unrelated_failure_class_does_not_block() {
	if "$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/noop-only "" "${TEST_ROOT}/wt-with-commits" >/dev/null 2>&1; then
		print_result "different failure class does not block" 1 "Expected exit 1 (safe)"
		return 0
	fi
	print_result "different failure class does not block" 0
	return 0
}

test_orphan_loop_next_action_uses_configured_base() {
	local output=""
	if output=$("$HELPER_SCRIPT" check-orphan-loop 300 owner/develop-repo feature/reused "" "${TEST_ROOT}/wt-with-commits" 2>/dev/null); then
		if [[ "$output" == *"WORKER_BRANCH_ORPHAN_LOOP_BLOCKED"* ]] && grep -q -- "gh pr create --repo owner/develop-repo --head feature/reused --base develop" "${TEST_ROOT}/posts/300.argv"; then
			print_result "orphan-loop diagnostic uses configured PR base" 0
			return 0
		fi
		print_result "orphan-loop diagnostic uses configured PR base" 1 "Output/post missing develop base: ${output}"
		return 0
	fi
	print_result "orphan-loop diagnostic uses configured PR base" 1 "Expected dispatch hold"
	return 0
}

test_orphan_comment_without_remote_branch_blocks_immediately() {
	local output=""
	if output=$("$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/missing "" "${TEST_ROOT}/wt-with-commits" 2>/dev/null); then
		if [[ "$output" == *"WORKER_BRANCH_ORPHAN_UNRECOVERABLE_BLOCKED"* && "$output" == *"reason=remote_branch_missing"* && -f "${TEST_ROOT}/posts/100.argv" ]] && grep -q -- "Remote branch exists: \`no\`" "${TEST_ROOT}/posts/100.argv"; then
			print_result "orphan marker with missing remote branch holds dispatch" 0
			return 0
		fi
		print_result "orphan marker with missing remote branch holds dispatch" 1 "Output/post missing remote evidence: ${output}"
		return 0
	fi
	print_result "orphan marker with missing remote branch holds dispatch" 1 "Expected dispatch hold"
	return 0
}

test_orphan_comment_with_zero_commits_blocks_immediately() {
	local output=""
	if output=$("$HELPER_SCRIPT" check-orphan-loop 100 owner/repo feature/empty "" "${TEST_ROOT}/wt-zero-commits" 2>/dev/null); then
		if [[ "$output" == *"WORKER_BRANCH_ORPHAN_UNRECOVERABLE_BLOCKED"* && "$output" == *"reason=zero_commits"* ]] && grep -q -- "Branch commit count: \`0\`" "${TEST_ROOT}/posts/100.argv"; then
			print_result "orphan marker with zero remote branch commits holds dispatch" 0
			return 0
		fi
		print_result "orphan marker with zero remote branch commits holds dispatch" 1 "Output/post missing zero-commit evidence: ${output}"
		return 0
	fi
	print_result "orphan marker with zero remote branch commits holds dispatch" 1 "Expected dispatch hold"
	return 0
}

main() {
	setup_test_env
	test_same_issue_branch_blocks_and_posts_diagnostic
	test_different_branch_does_not_block
	test_different_issue_does_not_block
	test_unrelated_failure_class_does_not_block
	test_orphan_loop_next_action_uses_configured_base
	test_orphan_comment_without_remote_branch_blocks_immediately
	test_orphan_comment_with_zero_commits_blocks_immediately
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
