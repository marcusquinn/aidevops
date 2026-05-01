#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#21973: overlapping non-interactive deploy paths
# must not enter the wipe/swap phase concurrently, and failed deploy verification
# must restore the newest agents backup before .deployed-sha can be written.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SETUP_SH="${REPO_ROOT}/setup.sh"
AGENT_DEPLOY="${REPO_ROOT}/setup-modules/agent-deploy.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
print_error() { return 0; }

setup() {
	TEST_ROOT=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

_make_setup_sourceable_copy() {
	local target_file="$1"
	local line=""
	local in_lock_block="false"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "SETUP_NONINTERACTIVE_LOCK_HELD=false" ]]; then
			in_lock_block="true"
		fi
		if [[ "$in_lock_block" == "true" ]]; then
			printf '%s\n' "$line" >>"$target_file"
		fi
		if [[ "$line" == "# Non-interactive path:"* ]]; then
			break
		fi
	done <"$SETUP_SH"
	return 0
}

_run_lock_contender() {
	local setup_copy="$1"
	local marker_dir="$2"
	local hold_seconds="$3"
	local contender_id="$4"

	# shellcheck source=/dev/null
	source "$setup_copy"
	if _setup_acquire_noninteractive_setup_lock --non-interactive; then
		printf '%s\n' "$contender_id" >>"$marker_dir/acquired"
		sleep "$hold_seconds"
		_setup_release_noninteractive_setup_lock
		return 0
	fi
	printf '%s\n' "$contender_id" >>"$marker_dir/skipped"
	return 0
}

test_noninteractive_setup_lock_single_owner() {
	local test_name="non-interactive setup lock allows one concurrent owner"
	local setup_copy="${TEST_ROOT}/setup-sourceable.sh"
	local marker_dir="${TEST_ROOT}/markers"
	local lock_dir="${TEST_ROOT}/locks/setup-noninteractive.lock.d"
	local pid1="" pid2="" pid3=""
	mkdir -p "$marker_dir"
	_make_setup_sourceable_copy "$setup_copy"

	(
		HOME="$TEST_ROOT" AIDEVOPS_SETUP_LOCK_DIR="$lock_dir" \
			_run_lock_contender "$setup_copy" "$marker_dir" 1 1
	) &
	pid1=$!
	(
		HOME="$TEST_ROOT" AIDEVOPS_SETUP_LOCK_DIR="$lock_dir" \
			_run_lock_contender "$setup_copy" "$marker_dir" 1 2
	) &
	pid2=$!
	(
		HOME="$TEST_ROOT" AIDEVOPS_SETUP_LOCK_DIR="$lock_dir" \
			_run_lock_contender "$setup_copy" "$marker_dir" 1 3
	) &
	pid3=$!

	wait "$pid1" || true
	wait "$pid2" || true
	wait "$pid3" || true

	local acquired_count="0"
	local skipped_count="0"
	if [[ -f "$marker_dir/acquired" ]]; then
		acquired_count=$(wc -l <"$marker_dir/acquired" | tr -d '[:space:]')
	fi
	if [[ -f "$marker_dir/skipped" ]]; then
		skipped_count=$(wc -l <"$marker_dir/skipped" | tr -d '[:space:]')
	fi
	[[ "$acquired_count" =~ ^[0-9]+$ ]] || acquired_count=0
	[[ "$skipped_count" =~ ^[0-9]+$ ]] || skipped_count=0

	if [[ "$acquired_count" -eq 1 && "$skipped_count" -eq 2 ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "acquired=$acquired_count skipped=$skipped_count"
	fi
	return 0
}

_make_agent_tree() {
	local dir="$1"
	local count="$2"
	mkdir -p "$dir/scripts"
	local index=1
	while [[ "$index" -le "$count" ]]; do
		printf 'file %s\n' "$index" >"$dir/file-${index}.md"
		index=$((index + 1))
	done
	printf '#!/usr/bin/env bash\n' >"$dir/scripts/helper.sh"
	return 0
}

test_failed_deploy_verification_restores_backup() {
	local test_name="failed deploy verification restores newest agents backup"
	local src="${TEST_ROOT}/repo/.agents"
	local target="${TEST_ROOT}/.aidevops/agents"
	local backup="${TEST_ROOT}/.aidevops/agents-backups/20260501_120000/agents"
	mkdir -p "$(dirname "$backup")"
	_make_agent_tree "$src" 1
	_make_agent_tree "$backup" 120

	# shellcheck source=/dev/null
	source "$AGENT_DEPLOY"

	local rc=0
	HOME="$TEST_ROOT" AIDEVOPS_AGENT_DEPLOY_MIN_FILES=100 INSTALL_DIR="${TEST_ROOT}/repo" \
		deploy_aidevops_agents || rc=$?

	if [[ "$rc" -ne 0 && -f "$target/file-120.md" ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "rc=$rc restored_file=$([[ -f "$target/file-120.md" ]] && printf yes || printf no)"
	fi
	return 0
}

main() {
	setup
	test_noninteractive_setup_lock_single_owner
	test_failed_deploy_verification_restores_backup

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
