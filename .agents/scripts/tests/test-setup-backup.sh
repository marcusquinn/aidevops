#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
BACKUP_HELPER="${SCRIPT_DIR}/../setup/_backup.sh"

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

print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

BACKUP_KEEP_COUNT=10

# shellcheck disable=SC1090
source "$BACKUP_HELPER"

backup_file_exists() {
	local backup_root="$1"
	local backup_match
	for backup_match in "$backup_root"/*/source-tree/nested/file.txt; do
		if [[ -f "$backup_match" ]]; then
			return 0
		fi
	done
	return 1
}

test_directory_backup_uses_basename_target() {
	local test_home
	test_home="$(mktemp -d)"
	local source_dir="${test_home}/source-tree"
	mkdir -p "${source_dir}/nested"
	printf 'ok\n' >"${source_dir}/nested/file.txt"

	HOME="$test_home" create_backup_with_rotation "$source_dir" "agents"

	if backup_file_exists "${test_home}/.aidevops/agents-backups"; then
		print_result "directory backup preserves source basename" 0
	else
		print_result "directory backup preserves source basename" 1 "backup file missing"
	fi

	rm -rf "$test_home"
	return 0
}

test_directory_backup_tolerates_rsync_vanished_entries() {
	local test_home
	test_home="$(mktemp -d)"
	local source_dir="${test_home}/source-tree"
	local real_rsync
	mkdir -p "${source_dir}/nested"
	printf 'ok\n' >"${source_dir}/nested/file.txt"

	real_rsync="$(command -v rsync || true)"
	if [[ -z "$real_rsync" ]]; then
		print_result "directory backup tolerates rsync vanished entries" 1 "rsync unavailable"
		rm -rf "$test_home"
		return 0
	fi

	rsync() {
		"$real_rsync" "$@"
		return 24
	}

	local status=0
	if ! HOME="$test_home" create_backup_with_rotation "$source_dir" "agents"; then
		status=$?
	fi

	unset -f rsync

	if [[ "$status" -ne 0 ]]; then
		print_result "directory backup tolerates rsync vanished entries" 1 "status=${status}"
	elif backup_file_exists "${test_home}/.aidevops/agents-backups"; then
		print_result "directory backup tolerates rsync vanished entries" 0
	else
		print_result "directory backup tolerates rsync vanished entries" 1 "backup file missing"
	fi

	rm -rf "$test_home"
	return 0
}

main() {
	test_directory_backup_uses_basename_target
	test_directory_backup_tolerates_rsync_vanished_entries

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
