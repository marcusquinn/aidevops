#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d -t aidevops-worker-excerpts.XXXXXX)"
HOME="${TEST_ROOT}/home"
AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export HOME AIDEVOPS_TEMP_DIR

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=../worker-failure-evidence.sh
source "${SCRIPTS_DIR}/worker-failure-evidence.sh"

make_excerpt() {
	local excerpt_dir="$1"
	local excerpt_name="$2"
	mkdir -p "$excerpt_dir"
	printf '%s\n' "$excerpt_name" >"${excerpt_dir}/${excerpt_name}"
	return 0
}

test_plan_preserves_newest_recovery_evidence() {
	local excerpt_dir="${TEST_ROOT}/plan"
	local plan=""
	make_excerpt "$excerpt_dir" "issue-1-20260101T000001Z-1.log"
	make_excerpt "$excerpt_dir" "issue-1-20260101T000002Z-2.log"
	make_excerpt "$excerpt_dir" "issue-1-20260101T000003Z-3.log"
	make_excerpt "$excerpt_dir" "issue-1-20260101T000004Z-4.log"
	WORKER_EXCERPT_KEEP_COUNT=2
	WORKER_EXCERPT_MAX_AGE_DAYS=99999
	WORKER_EXCERPT_MAX_BYTES=999999
	plan=$(_worker_excerpt_retention_plan "$excerpt_dir" "issue-1")
	[[ "$plan" == *"000001Z-1.log"* ]] || fail "oldest duplicate was not selected"
	[[ "$plan" == *"000002Z-2.log"* ]] || fail "second duplicate was not selected"
	[[ "$plan" != *"000004Z-4.log"* ]] || fail "newest recovery evidence was selected"
	printf 'PASS: worker excerpt plan preserves newest recovery evidence\n'
	return 0
}

test_apply_requires_confirmation_and_stages_first() {
	local excerpt_dir="${TEST_ROOT}/apply"
	local plan_file="${TEST_ROOT}/apply-plan.tsv"
	local forged_plan="${TEST_ROOT}/forged-plan.tsv"
	local newest_size=""
	local staged_path=""
	make_excerpt "$excerpt_dir" "issue-2-20260101T000001Z-1.log"
	make_excerpt "$excerpt_dir" "issue-2-20260101T000002Z-2.log"
	WORKER_EXCERPT_KEEP_COUNT=1
	_worker_excerpt_retention_plan "$excerpt_dir" "issue-2" >"$plan_file"
	if _worker_excerpt_retention_apply "$excerpt_dir" "issue-2" "$plan_file" "wrong-token"; then
		fail "apply accepted an invalid confirmation"
	fi
	[[ -f "${excerpt_dir}/issue-2-20260101T000001Z-1.log" ]] || fail "invalid confirmation changed evidence"
	newest_size=$(_worker_excerpt_size_bytes "${excerpt_dir}/issue-2-20260101T000002Z-2.log")
	printf '%s\t%s\t%s\n' "${excerpt_dir}/issue-2-20260101T000002Z-2.log" "$newest_size" "count" >"$forged_plan"
	if _worker_excerpt_retention_apply "$excerpt_dir" "issue-2" "$forged_plan" "$WORKER_EXCERPT_RETENTION_CONFIRMATION"; then
		fail "apply-time classifier accepted newest recovery evidence"
	fi
	[[ -f "${excerpt_dir}/issue-2-20260101T000002Z-2.log" ]] || fail "newest evidence changed after forged plan"
	if AIDEVOPS_RETENTION_TEST_INTERRUPT_AFTER_STAGE=1 \
		_worker_excerpt_retention_apply "$excerpt_dir" "issue-2" "$plan_file" "$WORKER_EXCERPT_RETENTION_CONFIRMATION"; then
		fail "interrupted apply unexpectedly succeeded"
	fi
	for staged_path in "${excerpt_dir}/.retention-trash"/issue-2-20260101T000001Z-1.log-*; do
		[[ -f "$staged_path" ]] || continue
		[[ -f "${excerpt_dir}/issue-2-20260101T000002Z-2.log" ]] || fail "newest evidence did not survive"
		printf 'PASS: worker excerpt apply stages candidates before deletion\n'
		return 0
	done
	fail "interrupted apply did not leave recoverable trash"
}

test_writer_caps_excerpt_and_fails_closed_on_unknown() {
	local source_file="${TEST_ROOT}/large-output.log"
	local excerpt_path=""
	local excerpt_size=""
	local excerpt_dir="${HOME}/.aidevops/logs/worker-failure-excerpts"
	local plan=""
	mkdir -p "$AIDEVOPS_TEMP_DIR"
	dd if=/dev/zero of="$source_file" bs=1024 count=100 2>/dev/null
	excerpt_path=$(_metric_failure_excerpt_path "$source_file" "issue-3")
	[[ -f "$excerpt_path" ]] || fail "writer did not preserve failure excerpt"
	excerpt_size=$(_file_size_bytes "$excerpt_path")
	[[ "$excerpt_size" == "65536" ]] || fail "excerpt cap was ${excerpt_size}, expected 65536"
	ln -s "$excerpt_path" "${excerpt_dir}/issue-3-99999999T999999Z-9.log"
	WORKER_EXCERPT_KEEP_COUNT=1
	if plan=$(_worker_excerpt_retention_plan "$excerpt_dir" "issue-3"); then
		fail "symlinked unknown evidence classification unexpectedly succeeded: $plan"
	fi
	[[ -z "$plan" ]] || fail "unknown evidence emitted reclaimable candidates"
	rm "${excerpt_dir}/issue-3-99999999T999999Z-9.log"
	printf 'ambiguous\n' >"${excerpt_dir}/issue-3-malformed.log"
	if plan=$(_worker_excerpt_retention_plan "$excerpt_dir" "issue-3"); then
		fail "malformed regular evidence classification unexpectedly succeeded: $plan"
	fi
	printf 'PASS: worker excerpt writer caps output and unknown entries fail closed\n'
	return 0
}

test_success_result_never_creates_failure_evidence() {
	local success_home="${TEST_ROOT}/success-home"
	local source_file="${TEST_ROOT}/successful-output.log"
	local candidate_path=""
	local result=""
	printf 'successful worker output\n' >"$source_file"
	candidate_path=$(HOME="$success_home" AIDEVOPS_TEMP_DIR="${success_home}/tmp" _metric_failure_excerpt_candidate_path "$source_file" "issue-4")
	rm "$source_file"
	result=$(HOME="$success_home" _metric_failure_excerpt_for_result "success" "$candidate_path" "issue-4")
	[[ -z "$result" ]] || fail "success returned a failure excerpt path"
	[[ ! -e "${success_home}/.aidevops/logs/worker-failure-excerpts" ]] || fail "success persisted failure evidence"
	result=$(HOME="$success_home" _metric_failure_excerpt_for_result "post_pr_handoff" "$candidate_path" "issue-4")
	[[ -z "$result" ]] || fail "post-PR handoff returned a failure excerpt path"
	[[ ! -e "${success_home}/.aidevops/logs/worker-failure-excerpts" ]] || fail "post-PR handoff persisted failure evidence"
	rm -f "$candidate_path"
	printf 'PASS: successful attempts do not displace failure evidence\n'
	return 0
}

test_failure_result_survives_source_cleanup() {
	local failure_home="${TEST_ROOT}/failure-home"
	local source_file="${TEST_ROOT}/failed-output.log"
	local candidate_path=""
	local excerpt_path=""
	printf 'failed worker output\n' >"$source_file"
	candidate_path=$(HOME="$failure_home" AIDEVOPS_TEMP_DIR="${failure_home}/tmp" _metric_failure_excerpt_candidate_path "$source_file" "issue-5")
	[[ -f "$candidate_path" ]] || fail "failure candidate was not captured before classification"
	rm "$source_file"
	excerpt_path=$(HOME="$failure_home" AIDEVOPS_TEMP_DIR="${failure_home}/tmp" _metric_failure_excerpt_for_result "premature_exit" "$candidate_path" "issue-5")
	[[ -f "$excerpt_path" ]] || fail "failure evidence was lost after source cleanup"
	rm -f "$candidate_path"
	printf 'PASS: failure evidence survives result-handler source cleanup\n'
	return 0
}

main() {
	test_plan_preserves_newest_recovery_evidence
	test_apply_requires_confirmation_and_stages_first
	test_writer_caps_excerpt_and_fails_closed_on_unknown
	test_success_result_never_creates_failure_evidence
	test_failure_result_survives_source_cleanup
	return 0
}

main "$@"
