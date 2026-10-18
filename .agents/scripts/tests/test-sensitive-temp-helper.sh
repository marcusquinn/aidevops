#!/usr/bin/env bash
# shellcheck disable=SC2218  # Test command shims intentionally replace external commands below.
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for managed sensitive artifacts and detached cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENSITIVE_TEMP_HELPER="${SCRIPT_DIR}/../sensitive-temp-helper.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sensitive-temp-helper-XXXXXX")"
AIDEVOPS_SENSITIVE_TEMP_DIR="${TEST_ROOT}/managed"
export AIDEVOPS_SENSITIVE_TEMP_DIR

# shellcheck source=../sensitive-temp-helper.sh
source "$SENSITIVE_TEMP_HELPER"
MANAGED_ROOT=$(aidevops_sensitive_temp_root)

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

file_mode() {
	local path="$1"
	if stat -f '%Lp' "$path" >/dev/null 2>&1; then
		stat -f '%Lp' "$path"
		return 0
	fi
	stat -c '%a' "$path"
	return 0
}

file_owner_uid() {
	local path="$1"
	if stat -f '%u' "$path" >/dev/null 2>&1; then
		stat -f '%u' "$path"
		return 0
	fi
	stat -c '%u' "$path"
	return 0
}

wait_for_absence() {
	local path="$1"
	local attempts="$2"
	local attempt=0
	while [[ "$attempt" -lt "$attempts" ]]; do
		[[ -e "$path" ]] || return 0
		sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

stat() {
	local flag="${1:-}"
	local format="${2:-}"
	local path="${3:-}"
	: "$path"
	if [[ "$flag" == "-c" && "$format" == "%u" ]]; then
		printf '4242\n'
		return 0
	fi
	if [[ "$flag" == "-c" && "$format" == "%a" ]]; then
		printf '1777\n'
		return 0
	fi
	if [[ "$flag" == "-f" ]]; then
		printf '  File: filesystem statistics\n0\n'
		return 0
	fi
	return 1
}
[[ "$(_aidevops_sensitive_temp_stat_owner_uid /fixture)" == "4242" ]] || \
	fail "GNU owner stat did not win over successful filesystem-mode output"
[[ "$(_aidevops_sensitive_temp_stat_mode /fixture '%p')" == "1777" ]] || \
	fail "GNU mode stat did not win over successful filesystem-mode output"
unset -f stat

stat() {
	local flag="${1:-}"
	local format="${2:-}"
	local path="${3:-}"
	: "$path"
	[[ "$flag" == "-c" ]] && return 1
	if [[ "$flag" == "-f" && "$format" == "%u" ]]; then
		printf '501\n'
		return 0
	fi
	if [[ "$flag" == "-f" && "$format" == "%p" ]]; then
		printf '41777\n'
		return 0
	fi
	if [[ "$flag" == "-f" && "$format" == "%Lp" ]]; then
		printf '700\n'
		return 0
	fi
	return 1
}
[[ "$(_aidevops_sensitive_temp_stat_owner_uid /fixture)" == "501" ]] || \
	fail "BSD owner stat fallback failed"
[[ "$(_aidevops_sensitive_temp_stat_mode /fixture '%p')" == "41777" ]] || \
	fail "BSD ancestor mode fallback lost sticky-bit mode"
[[ "$(_aidevops_sensitive_temp_stat_mode /fixture '%Lp')" == "700" ]] || \
	fail "BSD final-root mode fallback failed"
unset -f stat

managed_dir=$(aidevops_sensitive_temp_create_dir "test-private") || \
	fail "failed to create a managed sensitive directory"
[[ "${managed_dir%/*}" == "$MANAGED_ROOT" && \
	"${managed_dir##*/}" == aidevops-test-private.* ]] || \
	fail "sensitive directory escaped the managed root: $managed_dir"
[[ "$(file_mode "$MANAGED_ROOT")" == "700" ]] || \
	fail "managed root mode is not 700"
[[ "$(file_owner_uid "$MANAGED_ROOT")" == "$(id -u)" ]] || \
	fail "managed root is not owned by the current user"
expected_physical_root=$(cd "$AIDEVOPS_SENSITIVE_TEMP_DIR" && pwd -P) || \
	fail "failed to resolve expected managed root"
[[ "$MANAGED_ROOT" == "$expected_physical_root" ]] || \
	fail "managed root was not canonicalized physically"
[[ "$(file_mode "$managed_dir")" == "700" ]] || \
	fail "sensitive directory mode is not 700"
aidevops_sensitive_temp_cleanup "$managed_dir" || fail "synchronous cleanup failed"
[[ ! -e "$managed_dir" ]] || fail "synchronous cleanup left the directory behind"

symlink_target="${TEST_ROOT}/symlink-target"
symlink_root="${TEST_ROOT}/symlink-root"
mkdir -p "$symlink_target"
chmod 700 "$symlink_target"
ln -s "$symlink_target" "$symlink_root"
if AIDEVOPS_SENSITIVE_TEMP_DIR="$symlink_root" aidevops_sensitive_temp_root >/dev/null 2>&1; then
	fail "sensitive root accepted an exact symlink"
fi

physical_parent="${TEST_ROOT}/physical-parent"
logical_parent="${TEST_ROOT}/logical-parent"
mkdir -p "$physical_parent"
ln -s "$physical_parent" "$logical_parent"
resolved_nested_root=$(AIDEVOPS_SENSITIVE_TEMP_DIR="${logical_parent}/nested" aidevops_sensitive_temp_root) || \
	fail "sensitive root could not canonicalize a symlinked ancestor"
expected_nested_root=$(cd "${physical_parent}/nested" && pwd -P) || \
	fail "failed to resolve canonical nested root"
[[ "$resolved_nested_root" == "$expected_nested_root" && ! -L "$resolved_nested_root" && \
	"$(file_mode "$resolved_nested_root")" == "700" ]] || \
	fail "sensitive root retained a logical symlink traversal"

unsafe_parent="${TEST_ROOT}/unsafe-parent"
mkdir -p "$unsafe_parent"
chmod 777 "$unsafe_parent"
unsafe_parent=$(cd "$unsafe_parent" && pwd -P) || \
	fail "failed to canonicalize unsafe ancestor fixture"
unsafe_output=""
if unsafe_output=$(AIDEVOPS_SENSITIVE_TEMP_DIR="${unsafe_parent}/nested" aidevops_sensitive_temp_root 2>&1); then
	fail "sensitive root accepted a non-sticky writable ancestor"
fi
[[ "$unsafe_output" == *"component=${unsafe_parent}"* && \
	"$unsafe_output" == *"owner_uid=$(id -u)"* && \
	"$unsafe_output" == *"mode="*"777"* && \
	"$unsafe_output" == *"reason=writable_non_sticky_ancestor"* ]] || \
	fail "unsafe ancestor diagnostic omitted component, owner, mode, or invariant: $unsafe_output"

trusted_sticky_parent="${TEST_ROOT}/trusted-sticky-parent"
mkdir -p "$trusted_sticky_parent"
chmod 1777 "$trusted_sticky_parent"
AIDEVOPS_SENSITIVE_TEMP_DIR="${trusted_sticky_parent}/nested" aidevops_sensitive_temp_root >/dev/null || \
	fail "sensitive root rejected a current-user-owned sticky ancestor"

foreign_sticky_parent="${TEST_ROOT}/foreign-sticky-parent"
mkdir -p "$foreign_sticky_parent"
chmod 1777 "$foreign_sticky_parent"
foreign_sticky_parent=$(cd "$foreign_sticky_parent" && pwd -P) || \
	fail "failed to canonicalize foreign-owner fixture"
foreign_uid=$(( $(id -u) + 1 ))
stat() {
	local flag="${1:-}"
	local format="${2:-}"
	local path="${3:-}"
	if [[ "$path" == "$foreign_sticky_parent" && "$format" == "%u" && \
		( "$flag" == "-f" || "$flag" == "-c" ) ]]; then
		printf '%s\n' "$foreign_uid"
		return 0
	fi
	command stat "$@"
	return $?
}
if AIDEVOPS_SENSITIVE_TEMP_DIR="${foreign_sticky_parent}/nested" aidevops_sensitive_temp_root >/dev/null 2>&1; then
	unset -f stat
	fail "sensitive root accepted an attacker-owned sticky ancestor"
fi
unset -f stat

chmod_failure_root="${TEST_ROOT}/chmod-failure"
mkdir -p "$chmod_failure_root"
chmod 755 "$chmod_failure_root"
chmod() { return 1; }
if AIDEVOPS_SENSITIVE_TEMP_DIR="$chmod_failure_root" aidevops_sensitive_temp_root >/dev/null 2>&1; then
	unset -f chmod
	fail "sensitive root ignored permission-hardening failure"
fi
unset -f chmod

retained_dir=$(aidevops_sensitive_temp_create_dir "test-retained") || \
	fail "failed to create retained-path fixture"
cleanup_status=0
rm() { return 0; }
aidevops_sensitive_temp_cleanup "$retained_dir" || cleanup_status=$?
unset -f rm
[[ "$cleanup_status" -ne 0 && -d "$retained_dir" ]] || \
	fail "synchronous cleanup trusted rm success without verifying deletion"
command rm -rf "$retained_dir"

if grep -qF 'ignore_errors=True' "$SENSITIVE_TEMP_HELPER" || \
	! grep -qF 'cleanup_until' "$SENSITIVE_TEMP_HELPER"; then
	fail "detached guardian does not retry and verify cleanup"
fi

mkdir -p "${TEST_ROOT}/outside"
traversal_path="${MANAGED_ROOT}/aidevops-test-private/../../outside"
if aidevops_sensitive_temp_cleanup "$traversal_path" 2>/dev/null; then
	fail "cleanup accepted a traversal path"
fi
[[ -d "${TEST_ROOT}/outside" ]] || fail "cleanup traversal removed an outside directory"

# All sweep fixtures live in the isolated managed root, never the runner root.
mkdir -p "${MANAGED_ROOT}/aidevops-stale-dir/nested" "${MANAGED_ROOT}/aidevops-active-dir"
touch "${MANAGED_ROOT}/aidevops-stale-file" "${MANAGED_ROOT}/other-stale-file" \
	"${MANAGED_ROOT}/aidevops-stale-dir/nested/old"
touch -t 202601010000 "${MANAGED_ROOT}/aidevops-stale-file" "${MANAGED_ROOT}/other-stale-file" \
	"${MANAGED_ROOT}/aidevops-stale-dir/nested/old" "${MANAGED_ROOT}/aidevops-stale-dir/nested" \
	"${MANAGED_ROOT}/aidevops-stale-dir"
touch "${MANAGED_ROOT}/aidevops-fresh-file" "${MANAGED_ROOT}/aidevops-active-dir/fresh"
touch -t 202601010000 "${MANAGED_ROOT}/aidevops-active-dir"
touch "${TEST_ROOT}/outside/untouched"
ln -s "${TEST_ROOT}/outside" "${MANAGED_ROOT}/aidevops-stale-link"
touch -h -t 202601010000 "${MANAGED_ROOT}/aidevops-stale-link"
sweep_output=$(HEADLESS_RUNTIME_TEMP_MAX_AGE_SECONDS=invalid aidevops_sensitive_temp_sweep_stale)
[[ -z "$sweep_output" ]] || fail "sweep printed artifact names"
[[ ! -e "${MANAGED_ROOT}/aidevops-stale-file" && ! -e "${MANAGED_ROOT}/aidevops-stale-dir" ]] || \
	fail "sweep retained stale managed entries"
[[ -e "${MANAGED_ROOT}/aidevops-fresh-file" && -e "${MANAGED_ROOT}/other-stale-file" && \
	-e "${MANAGED_ROOT}/aidevops-active-dir/fresh" ]] || fail "sweep removed retained entries"
[[ -L "${MANAGED_ROOT}/aidevops-stale-link" && -e "${TEST_ROOT}/outside/untouched" ]] || \
	fail "sweep followed or removed a symlink"

mkdir -p "${MANAGED_ROOT}/aidevops-linked-dir"
ln -s "${TEST_ROOT}/outside" "${MANAGED_ROOT}/aidevops-linked-dir/link"
touch -h -t 202601010000 "${MANAGED_ROOT}/aidevops-linked-dir/link"
touch -t 202601010000 "${MANAGED_ROOT}/aidevops-linked-dir"
touch "${MANAGED_ROOT}/aidevops-age-window"
python3 - "${MANAGED_ROOT}/aidevops-age-window" <<'PY'
import os
import sys
import time
old = time.time() - 90000
os.utime(sys.argv[1], (old, old))
PY
HEADLESS_RUNTIME_TEMP_MAX_AGE_SECONDS=50000 aidevops_sensitive_temp_sweep_stale
[[ -e "${MANAGED_ROOT}/aidevops-age-window" ]] || fail "sweep ignored raised guardian limit"
HEADLESS_RUNTIME_TEMP_MAX_AGE_SECONDS=25200 aidevops_sensitive_temp_sweep_stale
[[ ! -e "${MANAGED_ROOT}/aidevops-age-window" ]] || fail "sweep ignored minimum day window"
[[ -L "${MANAGED_ROOT}/aidevops-linked-dir/link" ]] || fail "sweep removed a nested symlink"

# Exercise macOS dispatch without touching real backup settings on any platform.
uname() { printf 'Darwin\n'; return 0; }
tmutil() {
	local operation="$1"
	local root="$2"
	[[ "$root" == "$MANAGED_ROOT" ]] || return 1
	case "$operation" in
	isexcluded) printf '[Included] fixture\n' ;;
	addexclusion) touch "${TEST_ROOT}/backup-excluded" ;;
	*) return 1 ;;
	esac
	return 0
}
aidevops_sensitive_temp_sweep_stale
[[ -e "${TEST_ROOT}/backup-excluded" ]] || fail "sweep did not exclude the macOS temp root"
unset -f uname tmutil

sleep 5 &
owner_pid=$!
owner_exit_dir=$(aidevops_sensitive_temp_create_dir "test-owner-exit") || \
	fail "failed to create owner-exit fixture"
aidevops_sensitive_temp_start_guardian "$owner_exit_dir" "$owner_pid" 10 1 || \
	fail "failed to start owner-exit guardian"
kill "$owner_pid" 2>/dev/null || true
wait "$owner_pid" 2>/dev/null || true
wait_for_absence "$owner_exit_dir" 30 || \
	fail "guardian did not clean after its owner exited"

sleep 5 &
owner_pid=$!
retention_dir=$(aidevops_sensitive_temp_create_dir "test-retention") || \
	fail "failed to create retention fixture"
aidevops_sensitive_temp_start_guardian "$retention_dir" "$owner_pid" 1 1 || \
	fail "failed to start retention guardian"
wait_for_absence "$retention_dir" 30 || \
	fail "guardian did not enforce maximum retention"
kill "$owner_pid" 2>/dev/null || true
wait "$owner_pid" 2>/dev/null || true

printf '%s\n' 'PASS managed sensitive temp paths are private, bounded, and crash-resilient'
