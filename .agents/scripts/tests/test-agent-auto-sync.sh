#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit
GITHUB_HELPER="$REPO_ROOT/.agents/scripts/github-cli-helper.sh"
VERSION_HELPER="$REPO_ROOT/.agents/scripts/version-manager.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	mkdir -p "$TEST_DIR/repo/.agents/scripts"
	cat >"$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SYNC_LOG_PATH:?SYNC_LOG_PATH must be set}"
exit "${MOCK_DEPLOY_EXIT_CODE:-0}"
EOF
	chmod +x "$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh"
	: >"$TEST_DIR/sync.log"
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

invoke_github_sync() {
	local repo_slug="$1"
	AIDEVOPS_SYNC_REPO_PATH="$TEST_DIR/repo" \
		AIDEVOPS_SYNC_DEPLOY_SCRIPT="$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" \
		SYNC_LOG_PATH="$TEST_DIR/sync.log" \
		MOCK_DEPLOY_EXIT_CODE="${MOCK_DEPLOY_EXIT_CODE:-0}" \
		bash -c 'source "$1" && trigger_aidevops_post_merge_sync "$2"' _ "$GITHUB_HELPER" "$repo_slug"
	return 0
}

invoke_release_sync() {
	local repo_root="$1"
	AIDEVOPS_SYNC_REPO_ROOT="$repo_root" \
		AIDEVOPS_SYNC_DEPLOY_SCRIPT="$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" \
		SYNC_LOG_PATH="$TEST_DIR/sync.log" \
		MOCK_DEPLOY_EXIT_CODE="${MOCK_DEPLOY_EXIT_CODE:-0}" \
		bash -c 'source "$1" && run_post_release_agent_sync' _ "$VERSION_HELPER"
	return 0
}

create_fake_repo() {
	local repo_name="$1"
	local remote_url="$2"
	local repo_path="$TEST_DIR/$repo_name"

	mkdir -p "$repo_path"
	git init -q "$repo_path"
	git -C "$repo_path" remote add origin "$remote_url"
	printf '%s\n' "$repo_path"
	return 0
}

test_merge_sync_triggers_for_aidevops() {
	: >"$TEST_DIR/sync.log"
	invoke_github_sync "marcusquinn/aidevops"

	if grep -q -- "--repo $TEST_DIR/repo --quiet" "$TEST_DIR/sync.log"; then
		print_result "merge sync triggers for aidevops slug" 0
	else
		print_result "merge sync triggers for aidevops slug" 1 "Sync command was not recorded"
	fi
	return 0
}

test_merge_sync_skips_other_repos() {
	: >"$TEST_DIR/sync.log"
	invoke_github_sync "marcusquinn/another-repo"

	if [[ ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "merge sync skips non-aidevops repos" 0
	else
		print_result "merge sync skips non-aidevops repos" 1 "Unexpected sync invocation recorded"
	fi
	return 0
}

test_release_sync_triggers_for_aidevops_remote() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-aidevops" "https://github.com/marcusquinn/aidevops.git")
	invoke_release_sync "$repo_path"

	if grep -q -- "--repo $repo_path --quiet" "$TEST_DIR/sync.log"; then
		print_result "release sync triggers for aidevops remote" 0
	else
		print_result "release sync triggers for aidevops remote" 1 "Release sync command was not recorded"
	fi
	return 0
}

test_release_sync_skips_other_remotes() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-other" "https://github.com/marcusquinn/other.git")
	invoke_release_sync "$repo_path"

	if [[ ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync skips non-aidevops remotes" 0
	else
		print_result "release sync skips non-aidevops remotes" 1 "Unexpected release sync invocation recorded"
	fi
	return 0
}

main() {
	echo "Running agent auto-sync regression tests"
	setup

	test_merge_sync_triggers_for_aidevops
	test_merge_sync_skips_other_repos
	test_release_sync_triggers_for_aidevops_remote
	test_release_sync_skips_other_remotes

	teardown
	trap - EXIT
	echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
