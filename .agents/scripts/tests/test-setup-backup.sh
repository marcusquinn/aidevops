#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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

make_snapshot_fixture() {
	local backup_root="$1"
	local snapshot_name="$2"
	mkdir -p "${backup_root}/${snapshot_name}"
	printf '%s\n' "$snapshot_name" >"${backup_root}/${snapshot_name}/data"
	return 0
}

test_retention_plan_combines_limits_and_preserves_newest() {
	local test_home=""
	local backup_root=""
	local plan=""
	test_home="$(mktemp -d)"
	backup_root="${test_home}/.aidevops/agents-backups"
	make_snapshot_fixture "$backup_root" "20260101_000001"
	make_snapshot_fixture "$backup_root" "20260102_000001"
	make_snapshot_fixture "$backup_root" "20260103_000001"
	make_snapshot_fixture "$backup_root" "20260104_000001"

	BACKUP_KEEP_COUNT=2
	BACKUP_MAX_AGE_DAYS=99999
	BACKUP_MAX_BYTES=4294967296
	plan=$(_backup_retention_plan "$backup_root")
	if [[ "$(printf '%s\n' "$plan" | wc -l | tr -d ' ')" == "2" ]] &&
		[[ "$plan" == *"20260101_000001"* ]] &&
		[[ "$plan" == *"20260102_000001"* ]] &&
		[[ "$plan" != *"20260104_000001"* ]]; then
		print_result "retention plan applies count limit and protects newest" 0
	else
		print_result "retention plan applies count limit and protects newest" 1 "$plan"
	fi

	BACKUP_KEEP_COUNT=10
	BACKUP_MAX_BYTES=1
	plan=$(_backup_retention_plan "$backup_root")
	if [[ "$plan" == *"bytes"* ]] && [[ "$plan" != *"20260104_000001"* ]]; then
		print_result "retention plan applies byte limit and protects newest" 0
	else
		print_result "retention plan applies byte limit and protects newest" 1 "$plan"
	fi

	rm -rf "$test_home"
	return 0
}

test_retention_fails_closed_and_stages_before_delete() {
	local test_home=""
	local backup_root=""
	local plan_file=""
	local forged_plan=""
	local newest_size=""
	local staged_match=""
	test_home="$(mktemp -d)"
	backup_root="${test_home}/.aidevops/agents-backups"
	make_snapshot_fixture "$backup_root" "20260101_000001"
	make_snapshot_fixture "$backup_root" "20260102_000001"
	BACKUP_KEEP_COUNT=1
	BACKUP_MAX_AGE_DAYS=99999
	BACKUP_MAX_BYTES=4294967296
	plan_file="${test_home}/plan.tsv"
	_backup_retention_plan "$backup_root" >"$plan_file"

	if _backup_retention_apply "$backup_root" "$plan_file" "wrong-token"; then
		print_result "retention apply rejects missing confirmation" 1 "unexpected success"
	elif [[ -d "${backup_root}/20260101_000001" ]]; then
		print_result "retention apply rejects missing confirmation" 0
	else
		print_result "retention apply rejects missing confirmation" 1 "candidate changed"
	fi
	forged_plan="${test_home}/forged-plan.tsv"
	newest_size=$(_backup_snapshot_size_bytes "${backup_root}/20260102_000001")
	printf '%s\t%s\t%s\n' "${backup_root}/20260102_000001" "$newest_size" "count" >"$forged_plan"
	if _backup_retention_apply "$backup_root" "$forged_plan" "$BACKUP_RETENTION_CONFIRMATION"; then
		print_result "apply-time classification protects newest backup" 1 "forged plan succeeded"
	elif [[ -d "${backup_root}/20260102_000001" ]]; then
		print_result "apply-time classification protects newest backup" 0
	else
		print_result "apply-time classification protects newest backup" 1 "newest backup changed"
	fi

	if AIDEVOPS_RETENTION_TEST_INTERRUPT_AFTER_STAGE=1 \
		_backup_retention_apply "$backup_root" "$plan_file" "$BACKUP_RETENTION_CONFIRMATION"; then
		print_result "interrupted retention leaves recoverable trash" 1 "unexpected success"
	else
		for staged_match in "${backup_root}/.retention-trash"/20260101_000001-*; do
			if [[ -d "$staged_match" && -d "${backup_root}/20260102_000001" ]]; then
				print_result "interrupted retention leaves recoverable trash" 0
				rm -rf "$test_home"
				return 0
			fi
		done
		print_result "interrupted retention leaves recoverable trash" 1 "staged candidate missing"
	fi

	rm -rf "$test_home"
	return 0
}

test_retention_unknown_snapshot_fails_closed() {
	local test_home=""
	local backup_root=""
	local plan=""
	test_home="$(mktemp -d)"
	backup_root="${test_home}/.aidevops/agents-backups"
	make_snapshot_fixture "$backup_root" "20260101_000001"
	make_snapshot_fixture "$backup_root" "20260102_000001"
	ln -s "${backup_root}/20260101_000001" "${backup_root}/20260103_000001"
	BACKUP_KEEP_COUNT=1
	if plan=$(_backup_retention_plan "$backup_root"); then
		print_result "unknown backup entry fails closed" 1 "classification unexpectedly succeeded: $plan"
	elif [[ -z "$plan" ]]; then
		print_result "unknown backup entry fails closed" 0
	else
		print_result "unknown backup entry fails closed" 1 "$plan"
	fi
	rm -rf "$test_home"
	return 0
}

main() {
	test_directory_backup_uses_basename_target
	test_directory_backup_tolerates_rsync_vanished_entries
	test_retention_plan_combines_limits_and_preserves_newest
	test_retention_fails_closed_and_stages_before_delete
	test_retention_unknown_snapshot_fails_closed

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
