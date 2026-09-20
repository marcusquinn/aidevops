#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Verify stale-runtime recovery defers only the exact lane revision.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TESTS_FAILED=0

check() {
	local name="$1"
	if "$2"; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

run_exact_attempt_test() (
	# shellcheck source=../release-lane-helper.sh
	source "${SCRIPT_DIR}/release-lane-helper.sh"
	local state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":90,"owner":"process-123","phase":"exact-tag-deployment","tag":"v1.2.3","operation_token":"token","terminal_receipt":null}'
	local head='1111111111111111111111111111111111111111'
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		_AIDEVOPS_RELEASE_LANE_HEAD="$head"
	}
	_release_lane_write() {
		[[ "$3" == "$head" ]] || return 1
		state="$2"
	}
	release_lane_defer_stale_runtime_recovery test/repo 90 v1.2.3 "$head" process-123 || return 1
	jq -e '.phase == "reconcile-required" and .stale_runtime_recovery.type == "stale-runtime/v1" and .stale_runtime_recovery.attempt_head == "1111111111111111111111111111111111111111"' <<<"$state" >/dev/null
)

run_refusal_test() (
	# shellcheck source=../release-lane-helper.sh
	source "${SCRIPT_DIR}/release-lane-helper.sh"
	local state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":90,"owner":"process-123","phase":"exact-tag-deployment","tag":"v1.2.3","operation_token":"token","terminal_receipt":null}'
	local head='1111111111111111111111111111111111111111'
	local writes=0
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		_AIDEVOPS_RELEASE_LANE_HEAD="$head"
	}
	_release_lane_write() {
		writes=$((writes + 1))
		return 0
	}
	if release_lane_defer_stale_runtime_recovery test/repo 90 v1.2.3 '2222222222222222222222222222222222222222' process-123; then return 1; fi
	[[ "$writes" -eq 0 ]]
)

run_owner_refusal_test() (
	# shellcheck source=../release-lane-helper.sh
	source "${SCRIPT_DIR}/release-lane-helper.sh"
	local state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":90,"owner":"process-456","phase":"exact-tag-deployment","tag":"v1.2.3","operation_token":"token","terminal_receipt":null}'
	local head='1111111111111111111111111111111111111111'
	local writes=0
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		_AIDEVOPS_RELEASE_LANE_HEAD="$head"
	}
	_release_lane_write() {
		writes=$((writes + 1))
		return 0
	}
	if release_lane_defer_stale_runtime_recovery test/repo 90 v1.2.3 "$head" process-123; then return 1; fi
	[[ "$writes" -eq 0 ]]
)

run_stale_status_test() (
	# shellcheck source=../version-manager-release.sh
	source "${SCRIPT_DIR}/version-manager-release.sh"
	print_error() { :; }
	git() {
		case "$*" in
		*'rel^{tree}') printf 'release-tree\n' ;;
		*'active^{tree}') printf 'active-tree\n' ;;
		*'fetch origin main'*) return 0 ;;
		*'origin/main^{commit}') printf 'protected-main\n' ;;
		*'merge-base --is-ancestor active protected-main'*) return 0 ;;
		*) return 1 ;;
		esac
	}
	local rc=0
	_verify_release_descendant_active_source repo rel active >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 76 ]]
)

check 'exact stale-runtime attempt defers through lane CAS' run_exact_attempt_test
check 'revision mismatch performs no lane write' run_refusal_test
check 'owner mismatch performs no lane write' run_owner_refusal_test
check 'proven stale descendant propagates dedicated status' run_stale_status_test
printf '\nFailures: %s\n' "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
