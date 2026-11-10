#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#36626: pressure cleanup is asynchronous; admission stays fail-closed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
AIDEVOPS_WORKTREE_CAPACITY_HELPER="${SCRIPT_DIR}/../cleanup-worktrees-async-helper.sh"
_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN='^[0-9]+$'
LAUNCHES=0
COUNT=149
# shellcheck source=../disk-capacity-lib.sh
source "${SCRIPT_DIR}/../disk-capacity-lib.sh"

extract_helper() {
	local name="$1"
	awk -v name="$name" '$0 ~ "^" name "\\(\\) \\{" {capture=1} capture {print} capture && /^}$/ {exit}' "$CORE_SCRIPT"
	return 0
}
PRODUCTION_COUNT_HELPER=$(extract_helper _dispatch_registered_worktree_count)
eval "${PRODUCTION_COUNT_HELPER/_dispatch_registered_worktree_count/_production_dispatch_registered_worktree_count}"
eval "$(extract_helper _dispatch_launch_pressure_cleanup)"
eval "$(extract_helper _dispatch_worktree_capacity_gate)"
eval "$(extract_helper _dispatch_cleanup_disk_pressure)"

git() {
	local ignored="${1:-}"
	[[ "$ignored" != "" ]] || return 1
	printf 'worktree /repo/main\nHEAD abc\n\nworktree /repo/live\nHEAD def\n\nworktree /repo/gone\nprunable absent\n\n'
	return 0
}
[[ "$(_production_dispatch_registered_worktree_count "$TEST_ROOT")" == 2 ]]

_dispatch_registered_worktree_count() {
	[[ "$COUNT" != unknown ]] || return 1
	printf '%s\n' "$COUNT"
	return 0
}
_preflight_launch_async_cleanup() {
	local helper="$1"
	local log="$2"
	local name="$3"
	[[ "$helper" == "$AIDEVOPS_WORKTREE_CAPACITY_HELPER" && "$name" == worktrees && -n "$log" ]] || return 1
	[[ "$CLEANUP_WORKTREES_ASYNC_CADENCE_MIN" == 0 ]] || return 1
	LAUNCHES=$((LAUNCHES + 1))
	return 0
}
# Calling either inline cleanup or its timeout wrapper is a test failure.
INLINE_RUNS=0
cleanup_worktrees() { INLINE_RUNS=$((INLINE_RUNS + 1)); return 99; }
run_stage_with_timeout() { INLINE_RUNS=$((INLINE_RUNS + 1)); return 99; }

_dispatch_worktree_capacity_gate "$TEST_ROOT" 36626 owner/repo 200
[[ "$LAUNCHES" == 0 ]]
# Absolute cleanup threshold (150) applies before 80% of the cap (160).
COUNT=150
_dispatch_worktree_capacity_gate "$TEST_ROOT" 36626 owner/repo 200
[[ "$LAUNCHES" == 1 ]]
COUNT=199
_dispatch_worktree_capacity_gate "$TEST_ROOT" 36626 owner/repo 200
[[ "$LAUNCHES" == 1 ]]
COUNT=200
if _dispatch_worktree_capacity_gate "$TEST_ROOT" 36626 owner/repo 200; then exit 1; fi
[[ "$LAUNCHES" == 1 ]]
COUNT=unknown
if _dispatch_worktree_capacity_gate "$TEST_ROOT" 36626 owner/repo 200; then exit 1; fi
[[ "$LAUNCHES" == 1 ]]

AIDEVOPS_DISPATCH_PRESSURE_CLEANUP_STARTED=0
if _dispatch_cleanup_disk_pressure 36626 owner/repo "$TEST_ROOT" below-minimum 100 1; then exit 1; fi
[[ "$LAUNCHES" == 2 ]]
if _dispatch_cleanup_disk_pressure 36626 owner/repo "$TEST_ROOT" below-minimum 100 1; then exit 1; fi
[[ "$LAUNCHES" == 2 ]]
[[ "$INLINE_RUNS" == 0 ]]
printf 'PASS: prunable exclusion, cleanup-threshold trigger, launch deduplication, cap/unknown/disk fail-closed, no inline cleanup\n'

# Exercise the production systemd command builder without starting a service.
# shellcheck source=../pulse-dispatch-preflight-lib.sh
source "${SCRIPT_DIR}/../pulse-dispatch-preflight-lib.sh"
systemd-run() {
	local arguments="$*"
	[[ "$arguments" == *"AIDEVOPS_WORKTREE_PRESERVE_PATTERNS=custom-keep"* ]] || return 1
	[[ "$arguments" == *"AIDEVOPS_MAX_WORKTREES=17"* ]] || return 1
	[[ "$arguments" == *"CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=0"* ]] || return 1
	return 0
}
AIDEVOPS_WORKTREE_PRESERVE_PATTERNS=custom-keep
AIDEVOPS_MAX_WORKTREES=17
CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=0
_preflight_launch_systemd_cleanup "$AIDEVOPS_WORKTREE_CAPACITY_HELPER" "$LOGFILE" worktrees
printf 'PASS: systemd retains custom preservation and pressure settings\n'

CORE_SCRIPT="${SCRIPT_DIR}/../cleanup-worktrees-async-helper.sh"
eval "$(extract_helper _worktree_cap_and_threshold)"
eval "$(extract_helper _worktree_pressure_present)"
_missing_metadata_repo_paths() { printf '/repo\n'; return 0; }
DISK_OK=1
aidevops_worktree_capacity_check() { return "$DISK_OK"; }
DISK_OK=0
AIDEVOPS_MAX_WORKTREES=2
_worktree_pressure_present
AIDEVOPS_MAX_WORKTREES=3
if _worktree_pressure_present; then exit 1; fi
DISK_OK=1
_worktree_pressure_present
printf 'PASS: async cadence bypass detects worktree and disk pressure\n'
