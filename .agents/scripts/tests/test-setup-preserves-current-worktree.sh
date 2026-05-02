#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
MIGRATIONS_SCRIPT="${REPO_ROOT}/.agents/scripts/setup/modules/migrations.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

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

print_info() {
	local message="$1"
	printf '[INFO] %s\n' "$message"
	return 0
}

print_warning() {
	local message="$1"
	printf '[WARNING] %s\n' "$message"
	return 0
}

print_error() {
	local message="$1"
	printf '[ERROR] %s\n' "$message"
	return 0
}

make_temp_dir() {
	local tmp_parent=""
	local tmp_dir=""
	tmp_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
	tmp_dir=$(mktemp -d "$tmp_parent/aidevops-setup-worktree-test.XXXXXX")
	tmp_dir=$(cd "$tmp_dir" && pwd -P)
	printf '%s' "$tmp_dir"
	return 0
}

remove_test_dir() {
	local tmp_dir="$1"
	local tmp_parent=""
	local resolved_tmp=""
	local resolved_pwd=""
	local resolved_worker=""
	[[ -n "$tmp_dir" && -d "$tmp_dir" ]] || return 0

	tmp_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
	resolved_tmp=$(cd "$tmp_dir" 2>/dev/null && pwd -P) || return 0
	resolved_pwd=$(pwd -P 2>/dev/null || pwd)
	if [[ -n "${WORKER_WORKTREE_PATH:-}" && -d "${WORKER_WORKTREE_PATH:-}" ]]; then
		resolved_worker=$(cd "$WORKER_WORKTREE_PATH" 2>/dev/null && pwd -P) || resolved_worker=""
	fi

	case "$resolved_tmp" in
		"$tmp_parent"/aidevops-setup-worktree-test.*)
			;;
		*)
			print_warning "Refusing to remove non-fixture test directory: $resolved_tmp"
			return 0
			;;
	esac

	if [[ "$resolved_tmp" == "$resolved_pwd" || ( -n "$resolved_worker" && "$resolved_tmp" == "$resolved_worker" ) || "$resolved_tmp" == "$REPO_ROOT" ]]; then
		print_warning "Refusing to remove active worktree/cwd fixture path: $resolved_tmp"
		return 0
	fi

	rm -rf "$resolved_tmp"
	return 0
}

load_cleanup_function() {
	# shellcheck source=/dev/null
	source "$MIGRATIONS_SCRIPT"
	return 0
}

write_repos_json() {
	local repos_file="$1"
	local canonical_path="$2"
	local current_worktree_path="$3"
	local stale_worktree_path="$4"
	mkdir -p "$(dirname "$repos_file")"
	jq -n \
		--arg canonical "$canonical_path" \
		--arg current "$current_worktree_path" \
		--arg stale "$stale_worktree_path" \
		'{initialized_repos: [
			{path: $canonical, slug: "example/repo", pulse: true},
			{path: $current, slug: "example/repo-current", pulse: true},
			{path: $stale, slug: "example/repo-stale", pulse: true}
		], git_parent_dirs: []}' >"$repos_file"
	return 0
}

init_repo_with_worktrees() {
	local base_dir="$1"
	local canonical_path="$2"
	local current_worktree_path="$3"
	local stale_worktree_path="$4"
	mkdir -p "$canonical_path"
	git -C "$canonical_path" init -q
	git -C "$canonical_path" config user.email test@example.invalid
	git -C "$canonical_path" config user.name "Setup Test"
	git -C "$canonical_path" config commit.gpgsign false
	printf 'root\n' >"$canonical_path/README.md"
	git -C "$canonical_path" add README.md
	git -C "$canonical_path" commit -q -m initial
	git -C "$canonical_path" worktree add -q -b current-worktree "$current_worktree_path" HEAD
	git -C "$canonical_path" worktree add -q -b stale-worktree "$stale_worktree_path" HEAD
	[[ -d "$base_dir" ]]
	return 0
}

test_preserves_current_worktree_entry() {
	local tmp_dir=""
	local canonical_path=""
	local current_worktree_path=""
	local stale_worktree_path=""
	local repos_file=""
	local flag_file=""
	local output=""
	local current_count=""
	local stale_count=""
	tmp_dir=$(make_temp_dir)
	canonical_path="$tmp_dir/canonical"
	current_worktree_path="$tmp_dir/current-worktree"
	stale_worktree_path="$tmp_dir/stale-worktree"
	repos_file="$tmp_dir/home/.config/aidevops/repos.json"
	flag_file="$tmp_dir/home/.aidevops/logs/.migrated-worktree-repos-json-t2250"

	init_repo_with_worktrees "$tmp_dir" "$canonical_path" "$current_worktree_path" "$stale_worktree_path"
	write_repos_json "$repos_file" "$canonical_path" "$current_worktree_path" "$stale_worktree_path"

	output=$(
		export HOME="$tmp_dir/home"
		load_cleanup_function
		cd "$current_worktree_path"
		cleanup_worktree_entries_in_repos_json
		return 0
	) 2>&1 || true

	current_count=$(jq --arg path "$current_worktree_path" '[.initialized_repos[] | select(.path == $path)] | length' "$repos_file")
	stale_count=$(jq --arg path "$stale_worktree_path" '[.initialized_repos[] | select(.path == $path)] | length' "$repos_file")

	if [[ "$current_count" == "1" && "$stale_count" == "0" && ! -f "$flag_file" && "$output" == *"Skipped 1 active current worktree"* ]]; then
		remove_test_dir "$tmp_dir"
		print_result "cleanup preserves the current linked worktree entry" 0
		return 0
	fi

	remove_test_dir "$tmp_dir"
	print_result "cleanup preserves the current linked worktree entry" 1 "current_count=${current_count} stale_count=${stale_count} output=${output}"
	return 0
}

test_canonical_run_removes_worktree_entries_and_writes_flag() {
	local tmp_dir=""
	local canonical_path=""
	local current_worktree_path=""
	local stale_worktree_path=""
	local repos_file=""
	local flag_file=""
	local output=""
	local worktree_count=""
	tmp_dir=$(make_temp_dir)
	canonical_path="$tmp_dir/canonical"
	current_worktree_path="$tmp_dir/current-worktree"
	stale_worktree_path="$tmp_dir/stale-worktree"
	repos_file="$tmp_dir/home/.config/aidevops/repos.json"
	flag_file="$tmp_dir/home/.aidevops/logs/.migrated-worktree-repos-json-t2250"

	init_repo_with_worktrees "$tmp_dir" "$canonical_path" "$current_worktree_path" "$stale_worktree_path"
	write_repos_json "$repos_file" "$canonical_path" "$current_worktree_path" "$stale_worktree_path"

	output=$(
		export HOME="$tmp_dir/home"
		load_cleanup_function
		cd "$canonical_path"
		cleanup_worktree_entries_in_repos_json
		return 0
	) 2>&1 || true

	worktree_count=$(jq --arg current "$current_worktree_path" --arg stale "$stale_worktree_path" '[.initialized_repos[] | select(.path == $current or .path == $stale)] | length' "$repos_file")

	if [[ "$worktree_count" == "0" && -f "$flag_file" && "$output" == *"Removed 2 worktree"* ]]; then
		remove_test_dir "$tmp_dir"
		print_result "canonical cleanup removes linked worktree entries" 0
		return 0
	fi

	remove_test_dir "$tmp_dir"
	print_result "canonical cleanup removes linked worktree entries" 1 "worktree_count=${worktree_count} output=${output}"
	return 0
}

main() {
	test_preserves_current_worktree_entry
	test_canonical_run_removes_worktree_entries_and_writes_flag

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
