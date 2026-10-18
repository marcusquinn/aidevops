#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Automatic maintenance, process visibility, and advisory size indexes.
# Sourced by test-worktree-recovery-lifecycle.sh; uses its shared fixtures.

[[ -n "${_TEST_WT_RECOVERY_MAINTENANCE_LOADED:-}" ]] && return 0
_TEST_WT_RECOVERY_MAINTENANCE_LOADED=1

test_automatic_maintenance_is_bounded_and_policy_bound() {
	local home_path="${TEST_DIR}/automatic-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_a="" archive_b="" archive_protected=""
	local bucket_a="" bucket_b="" protected_bucket=""
	local output="" receipt_path="" removed_count=0
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_a=$(create_archived_fixture "${TEST_DIR}/automatic-repo-a" \
		"${TEST_DIR}/automatic-worktree-a" "$recovery_root" \
		"bugfix/gh29832-automatic-a") || rc=1
	archive_b=$(create_archived_fixture "${TEST_DIR}/automatic-repo-b" \
		"${TEST_DIR}/automatic-worktree-b" "$recovery_root" \
		"bugfix/gh29832-automatic-b") || rc=1
	archive_protected=$(create_archived_fixture "${TEST_DIR}/automatic-repo-protected" \
		"${TEST_DIR}/automatic-worktree-protected" "$recovery_root" \
		"bugfix/gh29832-automatic-protected") || rc=1
	bucket_a="${archive_a%/*}"
	bucket_b="${archive_b%/*}"
	protected_bucket="${archive_protected%/*}"
	# The existing clear-evidence fixture permits a size differential without
	# adding any production/test interface. One slot must select the larger bucket.
	python3 - "$archive_b" <<'PY' || rc=1
from pathlib import Path
import sys
Path(sys.argv[1], "size-fixture").write_bytes(b"x" * 1048576)
PY
	printf 'pending\n' >"${protected_bucket}/${_WT_RECOVERY_DIR_NAME}/source-removal-outcome" || rc=1
	install_clear_evidence_stubs
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_CANDIDATES=1 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "removed" ]] || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.removed')" == "1" ]] || rc=1
	printf '%s\n' "$output" | jq -e '
		.diagnostics.inventory_count == 3 and .diagnostics.scanned_count == 3 and
		.diagnostics.coverage_complete == true and .diagnostics.coverage_percent == 100 and
		.diagnostics.reason_counts.protected_evidence == 1 and
		.diagnostics.reason_counts.protected_limit == 1 and
		.diagnostics.classification_reason_counts.source_removal_not_complete == 1 and
		.diagnostics.classification_reason_counts.selection_limit == 1
	' >/dev/null || rc=1
	[[ -d "$protected_bucket" ]] || rc=1
	[[ -d "$bucket_a" ]] && removed_count=$((removed_count + 0)) || removed_count=$((removed_count + 1))
	[[ -d "$bucket_b" ]] && removed_count=$((removed_count + 0)) || removed_count=$((removed_count + 1))
	[[ "$removed_count" -eq 1 ]] || rc=1
	[[ ! -e "$bucket_b" && -d "$bucket_a" ]] || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	jq -e --arg policy_id "$WORKTREE_RECOVERY_AUTOMATION_POLICY_ID" '
		.complete == true and .candidate_count == 1 and
		(.confirmation | startswith("automatic-sha256:")) and
		.automatic_policy.policy_id == $policy_id and
		.entries[0].maintenance.selected_reason == "pressure"
	' "$receipt_path" >/dev/null || rc=1
	print_result "automatic_maintenance_is_bounded_and_policy_bound" "$rc" \
		"Expected pressure cleanup to remove one exact candidate and preserve protected evidence"
	return 0
}

test_automatic_maintenance_checks_capacity_before_aggregate_size() {
	local home_path="${TEST_DIR}/automatic-capacity-first-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output="" receipt_path=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-capacity-first-repo" \
		"${TEST_DIR}/automatic-capacity-first-worktree" "$recovery_root" \
		"bugfix/gh30443-capacity-first") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
			return 0
		}
		_worktree_recovery_maintenance_measure_store() {
			return 1
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS=3650 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "removed" ]] || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	jq -e '
		.automatic_policy.pressure_active == true and
		.automatic_policy.pressure_reason == "filesystem-free-kb-soft-limit" and
		.automatic_policy.store_bytes > 0 and
		.automatic_policy.store_size_source == "indexed-estimate" and
		.entries[0].maintenance.selected_reason == "pressure"
	' "$receipt_path" >/dev/null || rc=1
	[[ ! -e "$bucket_path" ]] || rc=1
	print_result "automatic_maintenance_checks_capacity_before_aggregate_size" "$rc" \
		"Expected known low capacity to bypass aggregate sizing and retain exact candidate checks"
	return 0
}

test_automatic_maintenance_enters_pressure_when_aggregate_size_times_out() {
	local home_path="${TEST_DIR}/automatic-age-fallback-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output="" receipt_path=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-age-fallback-repo" \
		"${TEST_DIR}/automatic-age-fallback-worktree" "$recovery_root" \
		"bugfix/gh30443-age-fallback") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	# Simulate unavailable advisory telemetry as well as the exact-store timeout.
	ln -s "$home_path" "$recovery_root/.size-index" || rc=1
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=90000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=90
			return 0
		}
		_worktree_recovery_maintenance_measure_store() {
			local ignored_root="$1"
			local aggregate_timeout="$2"
			: "$ignored_root"
			[[ "$aggregate_timeout" == "73" ]] || return 1
			printf 'null|unavailable|sizing-timeout'
			return 0
		}
		_worktree_recovery_maintenance_age_seconds() {
			local ignored_entry="$1"
			: "$ignored_entry"
			printf '0\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_AGGREGATE_SIZE_TIMEOUT_TENTHS=73 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS=7 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "removed" ]] || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	jq -e '
		.automatic_policy.pressure_active == true and
		.automatic_policy.pressure_reason == "aggregate-size-unavailable" and
		.automatic_policy.store_bytes == null and
		.entries[0].maintenance.selected_reason == "pressure"
	' "$receipt_path" >/dev/null || rc=1
	[[ ! -e "$bucket_path" ]] || rc=1
	print_result "automatic_maintenance_enters_pressure_when_aggregate_size_times_out" "$rc" \
		"Expected aggregate sizing uncertainty to trigger bounded pressure cleanup"
	return 0
}

test_automatic_maintenance_deadline_advances_cursor() {
	local home_path="${TEST_DIR}/automatic-deadline-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local bucket_path="" output=""
	local started_epoch=0 elapsed_seconds=0
	local index=0 remaining_buckets=0
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	while [[ "$index" -lt 300 ]]; do
		printf -v bucket_path '%s/aidevops-worktree-cleanup-%03d' "$recovery_root" "$index"
		mkdir "$bucket_path" || rc=1
		index=$((index + 1))
	done
	started_epoch=$(date +%s) || rc=1
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
			return 0
		}
		_worktree_recovery_inventory_bucket_state() {
			local ignored_bucket="$1"
			local ignored_root="$2"
			local deadline_epoch="$3"
			: "$ignored_bucket" "$ignored_root"
			_worktree_recovery_run_before_epoch "$deadline_epoch" sleep 5
			return $?
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_DEADLINE_SECONDS=2 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run
	) || rc=1
	elapsed_seconds=$(($(date +%s) - started_epoch)) || rc=1
	for bucket_path in "$recovery_root"/aidevops-worktree-cleanup-*; do
		[[ -d "$bucket_path" ]] && remaining_buckets=$((remaining_buckets + 1))
	done
	printf '%s\n' "$output" | jq -e '
		.outcome == "no-candidates" and .policy.pressure_active == true and
		.diagnostics.inventory_count == 300 and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 1 and
		.diagnostics.deadline_seconds == 2 and .diagnostics.deadline_exhausted == true and
		.diagnostics.reason_counts.unknown_archive == 1
	' >/dev/null || rc=1
	[[ "$elapsed_seconds" -le 7 && "$remaining_buckets" -eq 300 ]] || rc=1
	print_result "automatic_maintenance_deadline_advances_cursor" "$rc" \
		"Expected 300 delayed validations to stop within the deadline, advance one cursor entry, and preserve every bucket"
	return 0
}

test_automatic_maintenance_bounds_classification_subprocesses() {
	local home_path="${TEST_DIR}/automatic-classification-timeout-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local bucket_path="${recovery_root}/aidevops-worktree-cleanup-timeout"
	local output=""
	local started_epoch=0
	local elapsed_seconds=0
	local rc=0

	mkdir -p "$bucket_path" || rc=1
	started_epoch=$(date +%s) || rc=1
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
			return 0
		}
		_worktree_recovery_maintenance_inventory_file() {
			local output_path="$1"
			local ignored_platform="$2"
			: "$ignored_platform"
			printf '%s\n' "$bucket_path" >"$output_path"
			return $?
		}
		_worktree_recovery_inventory_bucket_state() {
			local ignored_bucket="$1"
			local ignored_root="$2"
			local ignored_deadline="$3"
			: "$ignored_bucket" "$ignored_root" "$ignored_deadline"
			printf 'attributed\n'
			return 0
		}
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			local ignored_timeout="$2"
			: "$ignored_path" "$ignored_timeout"
			printf '1024|exact|\n'
			return 0
		}
		_worktree_recovery_plan_attributed_entry_json() {
			local ignored_role="$1"
			local ignored_path="$2"
			local ignored_bytes="$3"
			: "$ignored_role" "$ignored_path" "$ignored_bytes"
			sleep 10
			return 1
		}
		# Allow inventory startup to finish before timing out the classifier.
		# The unchanged six-second bound still rejects an unbounded ten-second child.
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_DEADLINE_SECONDS=3 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run
	) || rc=1
	elapsed_seconds=$(($(date +%s) - started_epoch)) || rc=1
	printf '%s\n' "$output" | jq -e '
		.outcome == "no-candidates" and .policy.pressure_active == true and
		.diagnostics.inventory_count == 1 and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 0 and
		.diagnostics.deadline_exhausted == true and
		.diagnostics.reason_counts.unknown_classification == 1
	' >/dev/null || rc=1
	[[ "$elapsed_seconds" -le 6 && -d "$bucket_path" ]] || rc=1
	if [[ "$rc" -ne 0 ]]; then
		printf '  elapsed_seconds=%s result=%s\n' "$elapsed_seconds" "$output"
	fi
	print_result "automatic_maintenance_bounds_classification_subprocesses" "$rc" \
		"Expected classification and descendants to stop at the aggregate deadline without deleting the bucket"
	return 0
}

test_automatic_maintenance_preserves_bucket_when_exact_size_is_unavailable() {
	local home_path="${TEST_DIR}/automatic-bucket-timeout-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-bucket-timeout-repo" \
		"${TEST_DIR}/automatic-bucket-timeout-worktree" "$recovery_root" \
		"bugfix/gh30443-bucket-timeout") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=90000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=90
			return 0
		}
		_worktree_recovery_maintenance_measure_store() {
			local ignored_root="$1"
			local ignored_timeout="$2"
			: "$ignored_root" "$ignored_timeout"
			printf '1024|exact|'
			return 0
		}
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			: "$ignored_path"
			printf 'null|unavailable|sizing-timeout'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS=1 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "no-candidates" ]] || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.policy.unknown_count')" == "1" ]] || rc=1
	printf '%s\n' "$output" | jq -e '
		.diagnostics.inventory_count == 1 and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 0 and
		.diagnostics.coverage_complete == true and
		.diagnostics.reason_counts.unknown_sizing == 1 and
		.diagnostics.classification_reason_counts.sizing_timeout == 1
	' >/dev/null || rc=1
	[[ -d "$bucket_path" ]] || rc=1
	print_result "automatic_maintenance_preserves_bucket_when_exact_size_is_unavailable" "$rc" \
		"Expected per-bucket sizing uncertainty to remain non-destructive"
	return 0
}

run_zero_candidate_cycle_fixture() {
	local home_path="$1"
	local recovery_root="$2"
	local state_dir="$3"
	local extra_archives="${4:-0}"

	uname() {
		printf 'Linux\n'
		return 0
	}
	aidevops_disk_capacity_snapshot() {
		local ignored_path="$1"
		: "$ignored_path"
		AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
		return 0
	}
	_worktree_recovery_maintenance_inventory_file() {
		local output_path="$1"
		local ignored_platform="$2"
		: "$ignored_platform"
		printf '%s/unknown-a\n%s/protected\n%s/unknown-b\n' \
			"$recovery_root" "$recovery_root" "$recovery_root" >"$output_path"
		while [[ "$extra_archives" -gt 0 ]]; do
			printf '%s/unknown-extra-%s\n' "$recovery_root" "$extra_archives" >>"$output_path"
			extra_archives=$((extra_archives - 1))
		done
		return $?
	}
	_worktree_recovery_inventory_bucket_state() {
		local bucket_path="$1"
		local ignored_root="$2"
		local ignored_deadline="$3"
		: "$ignored_root" "$ignored_deadline"
		case "$bucket_path" in
		*/protected) printf 'attributed\n' ;;
		*) printf 'unknown\n' ;;
		esac
		return 0
	}
	_worktree_recovery_measure_path() {
		local ignored_path="$1"
		: "$ignored_path"
		printf '1024|exact|\n'
		return 0
	}
	_worktree_recovery_plan_attributed_entry_json() {
		local ignored_role="$1"
		local ignored_path="$2"
		local ignored_bytes="$3"
		: "$ignored_role" "$ignored_path" "$ignored_bytes"
		jq -cn --arg disposition "$WORKTREE_RECOVERY_PLAN_DISPOSITION_PROTECTED" \
			'{disposition:$disposition,reasons:["source-removal-not-complete"]}'
		return $?
	}
	HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
		AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=2 \
		AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
		AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
		worktree_recovery_maintenance_run
	return $?
}

test_automatic_maintenance_escalates_sustained_churn() {
	local home_path="${TEST_DIR}/automatic-churn-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local first_output="" second_output="" third_output=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	first_output=$(run_zero_candidate_cycle_fixture "$home_path" "$recovery_root" "$state_dir" 0) || rc=1
	second_output=$(run_zero_candidate_cycle_fixture "$home_path" "$recovery_root" "$state_dir" 1) || rc=1
	third_output=$(run_zero_candidate_cycle_fixture "$home_path" "$recovery_root" "$state_dir" 2) || rc=1
	printf '%s\n' "$first_output" | jq -e '
		.diagnostics.zero_candidate_cycle.completed_this_run == false and
		.diagnostics.sustained_non_reclamation.scanned_count == 2 and
		.escalation.required == false
	' >/dev/null || rc=1
	printf '%s\n' "$second_output" | jq -e '
		.diagnostics.inventory_count == 4 and
		.diagnostics.zero_candidate_cycle.completed_this_run == false and
		.diagnostics.sustained_non_reclamation.scanned_count == 4 and
		.escalation.required == true and
		.escalation.reason == "pressure-sustained-no-candidates"
	' >/dev/null || rc=1
	printf '%s\n' "$third_output" | jq -e '
		.diagnostics.inventory_count == 5 and
		.diagnostics.zero_candidate_cycle.completed_this_run == false and
		.diagnostics.sustained_non_reclamation.scanned_count == 6 and
		.escalation.required == true
	' >/dev/null || rc=1
	print_result "automatic_maintenance_escalates_sustained_churn" "$rc" \
		"Expected persistent non-reclamation accounting to survive inventory changes"
	return 0
}

test_automatic_maintenance_escalates_completed_zero_candidate_cycle() {
	local home_path="${TEST_DIR}/automatic-cycle-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local first_output="" second_output=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	first_output=$(run_zero_candidate_cycle_fixture "$home_path" "$recovery_root" "$state_dir") || rc=1
	second_output=$(run_zero_candidate_cycle_fixture "$home_path" "$recovery_root" "$state_dir") || rc=1
	printf '%s\n' "$first_output" | jq -e '
		.outcome == "no-candidates" and .policy.pressure_active == true and
		.policy.store_bytes == 0 and .policy.store_size_source == "indexed-estimate" and
		.diagnostics.scanned_count == 2 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 2 and
		.diagnostics.classification_reason_counts.unknown_archive == 1 and
		.diagnostics.classification_reason_counts.source_removal_not_complete == 1 and
		.diagnostics.zero_candidate_cycle.scanned_count == 2 and
		.diagnostics.zero_candidate_cycle.completed_this_run == false and
		.escalation.required == false
	' >/dev/null || rc=1
	printf '%s\n' "$second_output" | jq -e '
		.outcome == "no-candidates" and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 2 and .diagnostics.cursor_after == 0 and
		.diagnostics.classification_reason_counts.unknown_archive == 1 and
		.diagnostics.zero_candidate_cycle.scanned_count == 3 and
		.diagnostics.zero_candidate_cycle.completed_this_run == true and
		.diagnostics.zero_candidate_cycle.reason_counts.unknown_archive == 2 and
		.diagnostics.zero_candidate_cycle.reason_counts.source_removal_not_complete == 1 and
		.escalation.required == true and .escalation.authority == "read-only" and
		.escalation.command == ["worktree-helper.sh","recovery","plan","--output","<absolute-new-path>"]
	' >/dev/null || rc=1
	[[ ! -e "$state_dir/pending" ]] || rc=1
	print_result "automatic_maintenance_escalates_completed_zero_candidate_cycle" "$rc" \
		"Expected bounded rotation to preserve mixed reasons and request a read-only manual plan"
	return 0
}

test_automatic_maintenance_reports_unsupported_process_visibility() {
	local policy='{"pressure_active":true}'
	local diagnostics=''
	local output=''
	local rc=0

	diagnostics=$(jq -cn '
		{classification_reason_counts:{process_evidence_unavailable:2},
		zero_candidate_cycle:{reason_counts:{process_evidence_unavailable:3}},
		sustained_non_reclamation:{escalation_threshold_reached:true}}') || rc=1
	output=$(_worktree_recovery_maintenance_no_candidates_json "$policy" "$diagnostics") || rc=1
	printf '%s\n' "$output" | jq -e '
		.outcome == "operator-intervention-required" and .reclaimed_bytes == 0 and
		.unsupported_condition.code == "unsupported-process-visibility" and
		.unsupported_condition.deletion_authority == false and
		.unsupported_condition.blocked_archive_observations == 3 and
		(.unsupported_condition.guidance | length) == 4 and
		any(.unsupported_condition.guidance[]; contains("reference/worktree-cwd-visibility.md")) and
		any(.unsupported_condition.guidance[]; contains("recovery unreadable-processes")) and
		any(.unsupported_condition.guidance[]; contains("sealed generation") and contains("without root")) and
		any(.unsupported_condition.guidance[]; contains("NixOS adapter never invokes")) and
		all(.unsupported_condition.guidance[]; contains("stop them through") | not) and
		.escalation.required == true and .escalation.reason == "unsupported-process-visibility" and
		.escalation.dominant_reason == "process_evidence_unavailable" and
		.escalation.authority == "read-only" and
		.escalation.command == ["worktree-helper.sh","recovery","plan","--output","<absolute-new-path>"]
	' >/dev/null || rc=1
	diagnostics=$(printf '%s\n' "$diagnostics" | jq -c \
		'.sustained_non_reclamation.escalation_threshold_reached = false') || rc=1
	output=$(_worktree_recovery_maintenance_no_candidates_json "$policy" "$diagnostics") || rc=1
	printf '%s\n' "$output" | jq -e '
		.outcome == "no-candidates" and .unsupported_condition == null and
		.escalation.required == false
	' >/dev/null || rc=1
	diagnostics=$(printf '%s\n' "$diagnostics" | jq -c '
		.classification_reason_counts.process_evidence_unavailable = 0 |
		.zero_candidate_cycle.reason_counts.process_evidence_unavailable = 0 |
		.sustained_non_reclamation.escalation_threshold_reached = true') || rc=1
	output=$(_worktree_recovery_maintenance_no_candidates_json "$policy" "$diagnostics") || rc=1
	printf '%s\n' "$output" | jq -e '
		.outcome == "no-candidates" and .unsupported_condition == null and
		.escalation.required == true and
		.escalation.reason == "pressure-sustained-no-candidates"
	' >/dev/null || rc=1
	# A minority of process-visibility observations must not be blamed when
	# detached protection dominates (GH#32832 reporter sample: 80/10/10).
	diagnostics=$(jq -cn '
		{classification_reason_counts:{detached_or_unresolved_branch:8,
			archive_worktree_dirty:1,process_evidence_unavailable:1},
		zero_candidate_cycle:{reason_counts:{detached_or_unresolved_branch:80,
			archive_worktree_dirty:10,process_evidence_unavailable:10}},
		sustained_non_reclamation:{escalation_threshold_reached:true}}') || rc=1
	output=$(_worktree_recovery_maintenance_no_candidates_json "$policy" "$diagnostics") || rc=1
	printf '%s\n' "$output" | jq -e '
		.outcome == "no-candidates" and .unsupported_condition == null and
		.escalation.required == true and
		.escalation.reason == "pressure-sustained-no-candidates" and
		.escalation.dominant_reason == "detached_or_unresolved_branch" and
		.escalation.dominant_reason_count == 80
	' >/dev/null || rc=1
	print_result "automatic_maintenance_reports_unsupported_process_visibility" "$rc" \
		"Expected escalation to follow the dominant retained reason and only blame dominant process visibility"
	return 0
}

test_automatic_maintenance_advisory_tracks_escalation() {
	local advisory_dir="${TEST_DIR}/maintenance-advisories"
	local advisory_path="${advisory_dir}/worktree-recovery-retention.advisory"
	local result=''
	local first_line=''
	local rc=0

	result=$(jq -cn '{outcome:"no-candidates",policy:{pressure_active:true,store_bytes:113816633344},
		diagnostics:{inventory_count:1717},
		escalation:{required:true,reason:"pressure-sustained-no-candidates",
			dominant_reason:"detached_or_unresolved_branch",dominant_reason_count:80,
			command:["worktree-helper.sh","recovery","plan","--output","<absolute-new-path>"]}}') || rc=1
	AIDEVOPS_ADVISORIES_DIR="$advisory_dir" \
		_worktree_recovery_maintenance_update_advisory "$result" || rc=1
	[[ -f "$advisory_path" ]] || rc=1
	first_line=$(head -n 1 "$advisory_path" 2>/dev/null) || rc=1
	[[ "$first_line" == '[WARN] Worktree recovery store is not reclaiming space under pressure (1717 archives, 106 GiB; dominant blocker: detached-or-unresolved-branch)' ]] || {
		printf '  advisory first line: %s\n' "$first_line"
		rc=1
	}
	grep -qF 'worktree-helper.sh recovery plan --output <absolute-new-path>' "$advisory_path" || rc=1
	grep -qF 'recovery unreadable-processes' "$advisory_path" && rc=1
	# GH#32871: a process-visibility escalation names the diagnostic command.
	AIDEVOPS_ADVISORIES_DIR="$advisory_dir" _worktree_recovery_maintenance_update_advisory \
		"$(printf '%s\n' "$result" | jq -c '.outcome = "operator-intervention-required"')" || rc=1
	grep -qF 'worktree-helper.sh recovery unreadable-processes' "$advisory_path" || rc=1
	grep -qF 'worktree-lifecycle-helper.sh report --summary' "$advisory_path" || rc=1
	grep -qF 'rootless managed-lifetime proof' "$advisory_path" || rc=1
	grep -qF 'Do not stop session services or seek sudo' "$advisory_path" || rc=1
	AIDEVOPS_ADVISORIES_DIR="$advisory_dir" \
		_worktree_recovery_maintenance_update_advisory '{"escalation":{"required":false}}' || rc=1
	[[ ! -e "$advisory_path" ]] || rc=1
	print_result "automatic_maintenance_advisory_tracks_escalation" "$rc" \
		"Expected a path-free session advisory while escalation holds and automatic clearing afterwards"
	return 0
}

test_maintenance_help_does_not_run_maintenance() {
	local home_path="${TEST_DIR}/maintenance-help-home"
	local output=''
	local argument=''
	local status=0
	local rc=0

	mkdir -p "$home_path" || rc=1
	for argument in help --help; do
		status=0
		output=$(HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT='' \
			bash "${SCRIPTS_DIR}/worktree-recovery-maintenance-helper.sh" "$argument" 2>&1) || status=$?
		[[ "$status" -eq 0 && "$output" == Usage:* ]] || rc=1
	done
	status=0
	output=$(HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT='' \
		bash "${SCRIPTS_DIR}/worktree-recovery-maintenance-helper.sh" --bogus 2>&1) || status=$?
	[[ "$status" -eq 2 && "$output" == *'Unknown argument: --bogus'* ]] || rc=1
	# No maintenance state, lock, or recovery root may be created.
	[[ -z "$(find "$home_path" -mindepth 1 -print -quit 2>/dev/null)" ]] || rc=1
	print_result "maintenance_help_does_not_run_maintenance" "$rc" \
		"Expected help and unknown arguments to print usage without acquiring the maintenance lock"
	return 0
}

# GH#32853: the manual diagnostic names exactly the entries that degrade
# process visibility: same-UID, live, non-zombie, unreadable CWD.
# $3 is one UID for all four Uid: fields, or four space-separated fields
# (real effective saved filesystem) for mixed-UID processes (GH#32871).
make_fake_proc_entry() {
	local proc_root="$1"
	local pid="$2"
	local uid_fields="$3"
	local state="$4"
	local comm="$5"
	local cwd_kind="$6"
	local entry="${proc_root}/${pid}"
	local real_uid="" effective_uid="" saved_uid="" filesystem_uid=""

	read -r real_uid effective_uid saved_uid filesystem_uid <<<"$uid_fields"
	mkdir -p "$entry" || return 1
	printf 'Name:\t%s\nState:\t%s\nUid:\t%s\t%s\t%s\t%s\n' \
		"$comm" "$state" "$real_uid" "${effective_uid:-$real_uid}" \
		"${saved_uid:-$real_uid}" "${filesystem_uid:-$real_uid}" >"${entry}/status" || return 1
	printf '%s\n' "$comm" >"${entry}/comm" || return 1
	if [[ "$cwd_kind" == readable ]]; then
		ln -s "$proc_root" "${entry}/cwd" || return 1
	else
		# A regular file makes readlink fail while the entry still exists.
		: >"${entry}/cwd" || return 1
	fi
	return 0
}

test_unreadable_process_listing_matches_degraded_visibility() {
	local proc_root="${TEST_DIR}/fake-proc"
	local uid=''
	local foreign_uid=''
	local listing=''
	local expected=''
	local capture_rc=0
	local rc=0

	uid=$(id -u) || rc=1
	foreign_uid=$((uid + 1))
	make_fake_proc_entry "$proc_root" 101 "$uid" 'S (sleeping)' 'gpg-agent' unreadable || rc=1
	make_fake_proc_entry "$proc_root" 102 "$uid" 'S (sleeping)' 'bash' readable || rc=1
	make_fake_proc_entry "$proc_root" 103 "$uid" 'Z (zombie)' 'defunct' unreadable || rc=1
	make_fake_proc_entry "$proc_root" 104 "$foreign_uid" 'S (sleeping)' 'sshd' unreadable || rc=1
	make_fake_proc_entry "$proc_root" 105 "$uid" 'S (sleeping)' $'bad\033name' unreadable || rc=1
	# GH#32871: same-user setuid-root helper (fusermount3 auto_unmount, sudo)
	# is inspector-readable; a foreign effective UID or a root real UID is
	# still not provably foreign, but only stopping the process clears it.
	make_fake_proc_entry "$proc_root" 106 "$uid 0 0 0" 'S (sleeping)' 'fusermount3' unreadable || rc=1
	make_fake_proc_entry "$proc_root" 107 "$uid $foreign_uid $foreign_uid $foreign_uid" 'S (sleeping)' 'setuid-other' unreadable || rc=1
	make_fake_proc_entry "$proc_root" 108 "0 $uid $uid $uid" 'S (sleeping)' 'root-real' unreadable || rc=1
	listing=$(list_worktree_unreadable_proc_cwds "$proc_root") || rc=1
	expected=$(printf '101\tgpg-agent\tinspector\n105\tbadname\tinspector\n106\tfusermount3\tinspector\n107\tsetuid-other\tstop-only\n108\troot-real\tstop-only')
	if ! worktree_process_inspector_allowed; then
		expected=$(printf '101\tgpg-agent\tunprivileged-review\n105\tbadname\tunprivileged-review\n106\tfusermount3\tunprivileged-review\n107\tsetuid-other\tunprivileged-review\n108\troot-real\tunprivileged-review')
	fi
	[[ "$listing" == "$expected" ]] || {
		printf '  listing:\n%s\n' "$listing"
		rc=1
	}
	# The degraded capture agrees on the same fixture.
	_capture_worktree_proc_cwds "$proc_root" >/dev/null 2>&1 || capture_rc=$?
	[[ "$capture_rc" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	list_worktree_unreadable_proc_cwds "${TEST_DIR}/missing-proc" >/dev/null 2>&1 && rc=1
	print_result "unreadable_process_listing_matches_degraded_visibility" "$rc" \
		"Expected only live same-UID unreadable-CWD processes, with sanitized comm"
	return 0
}

test_automatic_maintenance_rejects_symlink_cycle_state() {
	local home_path="${TEST_DIR}/automatic-cycle-symlink-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local cycle_target="${home_path}/cycle-target"
	local rc=0

	mkdir -p "$recovery_root" "$state_dir" || rc=1
	printf 'preserve\n' >"$cycle_target" || rc=1
	ln -s "$cycle_target" "${state_dir}/zero-candidate-cycle.json" || rc=1
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run >/dev/null 2>&1
	); then rc=1; fi
	[[ "$(<"$cycle_target")" == "preserve" && -L "${state_dir}/zero-candidate-cycle.json" ]] || rc=1
	print_result "automatic_maintenance_rejects_symlink_cycle_state" "$rc" \
		"Expected completed-cycle diagnostics to fail closed without following a state symlink"
	return 0
}

test_automatic_maintenance_resumes_interrupted_apply() {
	local home_path="${TEST_DIR}/automatic-resume-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-resume-repo" \
		"${TEST_DIR}/automatic-resume-worktree" "$recovery_root" \
		"bugfix/gh29832-automatic-resume") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_MOVE=1 \
			HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run >/dev/null 2>&1
	); then rc=1; fi
	[[ -d "$state_dir/pending" && ! -e "$bucket_path" ]] || rc=1
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "resumed-and-removed" ]] || rc=1
	[[ ! -e "$bucket_path" && ! -d "$state_dir/pending" ]] || rc=1
	print_result "automatic_maintenance_resumes_interrupted_apply" "$rc" \
		"Expected the exact pending plan and journal to resume after interruption"
	return 0
}

test_automatic_maintenance_rejects_symlink_cursor() {
	local home_path="${TEST_DIR}/automatic-cursor-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local cursor_target="${home_path}/cursor-target"
	local rc=0

	mkdir -p "$recovery_root" "$state_dir" || rc=1
	printf 'preserve\n' >"$cursor_target" || rc=1
	ln -s "$cursor_target" "${state_dir}/cursor" || rc=1
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run >/dev/null 2>&1
	); then rc=1; fi
	[[ "$(<"$cursor_target")" == "preserve" && -L "${state_dir}/cursor" ]] || rc=1
	print_result "automatic_maintenance_rejects_symlink_cursor" "$rc" \
		"Expected maintenance to fail closed without following a cursor symlink"
	return 0
}

test_large_plan_avoids_json_argv_limits() {
	local output_path="${TEST_DIR}/large-plan.json"
	local second_output_path="${TEST_DIR}/large-plan-second.json"
	local padding=""
	local detail=""
	local output_size=0
	local apply_entries=""
	local apply_metadata=""
	local expected_journal=""
	local journal_path="${TEST_DIR}/large-apply-journal.json"
	local rc=0

	padding=$(printf '%060000d' 0) || rc=1
	worktree_recovery_lifecycle_json() {
		printf '%s\n' '{"error":"synthetic-incomplete","buckets":['
		printf '%s\n' \
			'{"role":"current","state":"unknown","path":"/recovery/bucket-1","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"current","state":"unknown","path":"/recovery/bucket-2","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"current","state":"unknown","path":"/recovery/bucket-3","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"legacy","state":"unknown","path":"/recovery/bucket-4","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"legacy","state":"unknown","path":"/recovery/bucket-5","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"legacy","state":"unknown","path":"/recovery/bucket-6","bytes":null,"sizing_confidence":"unavailable"}'
		printf '%s\n' ']}'
		return 0
	}
	_worktree_recovery_plan_unknown_entry_json() {
		local role="$1"
		local bucket_path="$2"
		local ignored_bytes="$3"
		local reason="$4"
		: "$ignored_bytes"
		jq -cn --arg role "$role" --arg path "$bucket_path" --arg reason "$reason" \
			--arg padding "$padding" \
			'{role:$role,path:$path,archive_path:$path,expected_allocated_bytes:null,
			disposition:"unknown",reasons:[$reason],evidence:{padding:$padding}}'
		return $?
	}
	cmd_recovery plan --output "$output_path" >/dev/null || {
		detail="first oversized plan write failed"
		rc=1
	}
	cmd_recovery plan --output "$second_output_path" >/dev/null || {
		detail="second oversized plan write failed"
		rc=1
	}
	if [[ -f "$output_path" ]]; then
		output_size=$(wc -c <"$output_path") || rc=1
	fi
	if [[ "$output_size" -le 300000 ]]; then
		detail="oversized plan was only ${output_size} bytes"
		rc=1
	fi
	jq -e '.entry_count == 6 and .candidate_count == 0 and .unknown_count == 6' \
		"$output_path" >/dev/null || {
		detail="oversized plan counts were invalid"
		rc=1
	}
	if [[ "$(jq -r '.plan_id' "$output_path")" != "$(jq -r '.plan_id' "$second_output_path")" ]]; then
		detail="oversized plan digest was not deterministic"
		rc=1
	fi
	apply_entries=$(jq -c '[.entries | to_entries[] | {
		index:.key,role:.value.role,original_path:.value.path,
		staged_path:("/recovery/.trash/transaction/" + (.key | tostring)),
		archive_name:("bucket-" + (.key | tostring)),
		expected_allocated_bytes:.value.expected_allocated_bytes,
		identity:.value.identity,evidence:.value.evidence,reasons:.value.reasons,
		maintenance:null,state:"planned"}]' "$output_path") || rc=1
	apply_metadata=$(jq -c '{plan_id,plan_digest:(.plan_id | sub("^sha256:"; "")),
		confirmation:.confirmation_token,automatic_policy:null}' "$output_path") || rc=1
	expected_journal=$(_worktree_recovery_apply_expected_journal \
		"large-transaction" "$apply_metadata" "$apply_entries" "2026-08-10T00:00:00Z") || rc=1
	printf '%s\n' "$expected_journal" >"$journal_path" || rc=1
	_worktree_recovery_apply_validate_existing_journal \
		"$journal_path" "$expected_journal" || {
		detail="oversized apply journal validation failed"
		rc=1
	}
	print_result "large_plan_avoids_json_argv_limits" "$rc" \
		"${detail:-Expected a deterministic oversized plan without jq argv transport}"
	return 0
}

test_recovery_size_index_is_advisory() {
	local root="${TEST_DIR}/size-index-store"
	local rc=0

	python3 - "$SCRIPTS_DIR" "$root" <<'PY' || rc=1
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
import worktree_recovery_size_index as index

root = Path(sys.argv[2])
root.mkdir()
small = root / (index.PREFIX + "a")
large = root / (index.PREFIX + "b")
small.mkdir()
large.mkdir()
(large / "data").write_bytes(b"x" * 1048576)
assert index.snapshot(root, 0)["store_bytes"] is None
summary = index.snapshot(root, 2)
assert summary["store_bytes"] >= 1048576 and summary["indexed_count"] == 2
inventory = root / "inventory"
inventory.write_text(f"{small}\n{large}\n")
helper = Path(sys.argv[1]) / "worktree_recovery_size_index.py"
ordered = subprocess.check_output([sys.executable, str(helper), "order", str(inventory)], text=True)
assert ordered.splitlines() == [str(large), str(small)]
trash = root / ".retention-trash"
trash.mkdir()
(trash / "pending").mkdir()
assert index.snapshot(root, 0)["store_bytes"] is None
directory = index.index_directory(root)
record = directory / (large.name + ".json")
expired = json.loads(record.read_text())
expired["measured_at"] = 0
record.write_text(json.dumps(expired))
assert index.read_hint(large, directory) is None
index.record_size(large, directory, 2)
plan = root / "plan"
plan.write_text(json.dumps({"entries": [{"bucket_path": str(large)}]}))
subprocess.run([sys.executable, str(helper), "invalidate-plan", str(plan)], check=True)
assert not record.exists()
record.symlink_to(large / "data")
assert index.read_hint(large, directory) is None
record.unlink()
small.rename(root / "old-bucket")
small.mkdir()
assert index.read_hint(small, directory) is None
original_record = index.record_size
def interrupted(*args):
    raise SystemExit(99)
index.record_size = interrupted
try:
    index.snapshot(root, 2)
    raise AssertionError("expected interrupted sizing")
except SystemExit as error:
    assert error.code == 99
finally:
    index.record_size = original_record
assert (directory / ".backfill-cursor").read_text() == "1"
PY
	print_result "recovery_size_index_is_advisory" "$rc" \
		"Expected indexed ordering, incomplete/staged totals, invalidation and replaced/symlink hints to remain non-authoritative"
	return 0
}
