#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for exact worktree recovery planning and explicit apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
TEST_DIR=""
TEST_LEGACY_RECOVERY_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		[[ -z "$detail" ]] || printf '  %s\n' "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	# Git reports canonical worktree paths and the managed-lifetime fence
	# refuses any other form, so resolve macOS /var -> /private/var.
	TEST_DIR=$(cd "$TEST_DIR" && pwd -P) || return 1
	# Use a fixture-owned ownership registry: the managed-lifetime fence fails
	# closed without one, and the host registry must never be read or written.
	export WORKTREE_REGISTRY_DIR="${TEST_DIR}/registry"
	export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
	declare -F _init_registry_db >/dev/null 2>&1 || return 1
	_init_registry_db || return 1
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 1
	# Maintenance runs must never write session advisories outside the fixture.
	export AIDEVOPS_ADVISORIES_DIR="${TEST_DIR}/advisories"
	export AIDEVOPS_REAL_GIT_BIN="$GIT_BIN"
	# Retention fixtures must not depend on the host's login daemons. Actual
	# CWD guards and degraded visibility are covered by the removal audit suite.
	capture_worktree_process_cwds() {
		printf '%s\n' /
		return 0
	}
	return 0
}

teardown() {
	[[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]] || rm -rf "$TEST_DIR"
	return 0
}

create_unarchived_fixture() {
	local repo_path="$1"
	local worktree_path="$2"
	local branch_name="$3"

	"$GIT_BIN" init -q -b main "$repo_path" || return 1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || return 1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || return 1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || return 1
	printf 'base\n' >"${repo_path}/README.md" || return 1
	"$GIT_BIN" -C "$repo_path" add README.md || return 1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || return 1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "$branch_name" "$worktree_path" || return 1
	return 0
}

create_archived_fixture() {
	local repo_path="$1"
	local worktree_path="$2"
	local recovery_root="$3"
	local branch_name="$4"

	create_unarchived_fixture "$repo_path" "$worktree_path" "$branch_name" || return 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		create_legacy_worktree_recovery_fixture "$worktree_path" "test.sh" "recovery-plan" || return 1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$worktree_path" "$WORKTREE_RECOVERABLE_ARCHIVE_PATH" "test.sh" "recovery-plan" \
		"recovery_path=archive-first" "false" "false" || return 1
	printf '%s\n' "$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	return 0
}

create_candidate_plan_fixture() {
	local home_path="$1"
	local repo_path="$2"
	local worktree_path="$3"
	local recovery_root="$4"
	local branch_name="$5"
	local plan_path="$6"
	local archive_path=""

	mkdir -p "$home_path" "$recovery_root" || return 1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"$branch_name") || return 1
	install_clear_evidence_stubs
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$plan_path" >/dev/null || return 1
	printf '%s\n' "$archive_path"
	return 0
}

resign_test_plan() {
	local plan_path="$1"
	local plan_material=""
	local plan_digest=""
	local candidate_count=""
	local candidate_bytes=""
	local confirmation=""
	local temp_path="${plan_path}.resign.$$"

	plan_material=$(_worktree_recovery_apply_plan_material "$plan_path") || return 1
	plan_digest=$(_worktree_recovery_plan_sha256_text "$plan_material") || return 1
	candidate_count=$(jq -r '.candidate_count' "$plan_path") || return 1
	candidate_bytes=$(jq -r '.candidate_bytes' "$plan_path") || return 1
	confirmation=$(_worktree_recovery_plan_confirmation_token \
		"sha256:$plan_digest" "$candidate_count" "$candidate_bytes") || return 1
	jq -c --arg plan_id "sha256:$plan_digest" --arg confirmation "$confirmation" \
		'.plan_id = $plan_id | .confirmation_token = $confirmation' \
		"$plan_path" >"$temp_path" || return 1
	mv "$temp_path" "$plan_path" || return 1
	return 0
}

write_test_producer_lock() {
	local recovery_root="$1"
	local owner_pid="$2"
	local owner_lstart="$3"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"

	mkdir "$lock_path" || return 1
	printf '%s\n' "$owner_pid" >"$lock_path/pid" || return 1
	printf '%s\n' "$owner_lstart" >"$lock_path/lstart" || return 1
	printf '%s\n' "fixture-lock-token" >"$lock_path/token" || return 1
	printf '%s\n' "complete" >"$lock_path/initialized" || return 1
	return 0
}

remove_test_producer_lock() {
	local recovery_root="$1"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"

	rm -f "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" "$lock_path/initialized" || return 1
	rmdir "$lock_path" || return 1
	return 0
}

archive_tree_digest() {
	local bucket_path="$1"
	local parent_path="${bucket_path%/*}"
	local base_name="${bucket_path##*/}"
	local digest=""

	if command -v shasum >/dev/null 2>&1; then
		digest=$(tar -cf - -C "$parent_path" "$base_name" | shasum -a 256) || return 1
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(tar -cf - -C "$parent_path" "$base_name" | sha256sum) || return 1
	else
		return 1
	fi
	digest="${digest%%[[:space:]]*}"
	printf '%s\n' "$digest"
	return 0
}

install_external_evidence_stub() {
	_worktree_recovery_plan_external_evidence_json() {
		jq -cn '{commit:"merged",open_pr:"clear",task:"closed",issue_number:"29388",repo:"example/repo"}'
		return 0
	}
	return 0
}

install_clear_evidence_stubs() {
	_worktree_recovery_plan_git_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_worktree_reference_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_registry_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_claim_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_process_state() {
		printf 'clear\n'
		return 0
	}
	install_external_evidence_stub
	return 0
}

# shellcheck source=./test-worktree-recovery-lifecycle-plan.sh
# shellcheck disable=SC1091 # sibling test module resolved at runtime
source "${SCRIPT_DIR}/test-worktree-recovery-lifecycle-plan.sh"
# shellcheck source=./test-worktree-recovery-lifecycle-apply.sh
# shellcheck disable=SC1091 # sibling test module resolved at runtime
source "${SCRIPT_DIR}/test-worktree-recovery-lifecycle-apply.sh"
# shellcheck source=./test-worktree-recovery-lifecycle-cache-retrofit.sh
# shellcheck disable=SC1091 # sibling test module resolved at runtime
source "${SCRIPT_DIR}/test-worktree-recovery-lifecycle-cache-retrofit.sh"
# shellcheck source=./test-worktree-recovery-lifecycle-maintenance.sh
# shellcheck disable=SC1091 # sibling test module resolved at runtime
source "${SCRIPT_DIR}/test-worktree-recovery-lifecycle-maintenance.sh"

# shellcheck source=../audit-worktree-removal-helper.sh
source "${SCRIPTS_DIR}/audit-worktree-removal-helper.sh"
# shellcheck source=./legacy-worktree-recovery-fixture.sh
source "${SCRIPT_DIR}/legacy-worktree-recovery-fixture.sh"
# shellcheck source=../worktree-recovery-lifecycle-helper.sh
source "${SCRIPTS_DIR}/worktree-recovery-lifecycle-helper.sh"
# shellcheck source=../worktree-recovery-maintenance-helper.sh
source "${SCRIPTS_DIR}/worktree-recovery-maintenance-helper.sh"
# shellcheck source=../worktree-helper-cmds.sh
source "${SCRIPTS_DIR}/worktree-helper-cmds.sh"

run_all_tests() {
	setup
	printf '=== test-worktree-recovery-lifecycle.sh ===\n'
	test_recovery_size_index_is_advisory
	test_git_state_detects_recovery_data
	test_cache_policy_recognises_python_and_root_codegraph_only
	test_git_state_protects_tracked_regenerable_cache_roots
	test_compact_archive_preserves_ignored_payload
	test_archive_pruning_preserves_tracked_codegraph_root
	test_claim_state_uses_archive_repository
	test_detached_claim_does_not_invent_active_owner
	test_profile_publication_detached_evidence_is_exact_and_fail_closed
	test_profile_publication_detached_archive_plans_without_apply
	test_generic_detached_retention_publication_is_fail_closed
	test_generic_detached_archive_plans_and_applies
	test_recovery_issue_attribution_uses_archived_source_path
	test_unlinked_merged_pr_is_terminal_task_evidence
	test_dirty_recovery_short_circuits_expensive_probes
	test_active_claim_short_circuits_later_probes
	test_exact_plan_writes_candidate_without_mutation
	test_plan_output_refuses_unsafe_targets
	test_classification_fails_closed
	test_plan_records_malformed_bucket_unknown
	test_size_drift_downgrades_only_entry
	test_attributed_remeasurement_uses_explicit_budget
	test_global_inventory_failure_is_explicit
	test_entry_sizing_failure_is_localized
	test_manual_plan_classification_is_bounded_and_resumable
	test_manual_plan_deadline_emits_continuation
	test_apply_removes_only_candidates_and_replays_receipt
	test_apply_rejects_unsafe_manifest_and_cli_inputs
	test_apply_preflight_drift_stages_nothing
	test_apply_resumes_move_and_delete_crash_windows
	test_apply_resumes_transaction_initialization_crashes
	test_receipt_reservation_blocks_conflicting_plan
	test_receipt_publication_owns_only_reserved_temp
	test_shared_producer_lock_fails_closed_and_reclaims_stale
	test_apply_handles_attributable_legacy_root_transaction
	test_cache_retrofit_prunes_mixed_archive_and_accounts_bytes
	test_cache_retrofit_policy_preserves_unsafe_roots
	test_cache_retrofit_rejects_identity_drift_before_mutation
	test_cache_retrofit_rejects_mutable_evidence_drift_before_mutation
	test_cache_retrofit_honors_shared_deadline_before_mutation
	test_cache_retrofit_resumes_interrupted_move
	test_cache_retrofit_resumes_interrupted_delete
	test_cache_retrofit_rejects_unmeasured_legacy_delete_replay
	test_automatic_maintenance_is_bounded_and_policy_bound
	test_automatic_maintenance_checks_capacity_before_aggregate_size
	test_automatic_maintenance_enters_pressure_when_aggregate_size_times_out
	test_automatic_maintenance_deadline_advances_cursor
	test_automatic_maintenance_bounds_classification_subprocesses
	test_automatic_maintenance_preserves_bucket_when_exact_size_is_unavailable
	test_automatic_maintenance_escalates_completed_zero_candidate_cycle
	test_automatic_maintenance_escalates_sustained_churn
	test_automatic_maintenance_reports_unsupported_process_visibility
	test_automatic_maintenance_advisory_tracks_escalation
	test_maintenance_help_does_not_run_maintenance
	test_unreadable_process_listing_matches_degraded_visibility
	test_automatic_maintenance_resumes_interrupted_apply
	test_automatic_maintenance_rejects_symlink_cursor
	test_automatic_maintenance_rejects_symlink_cycle_state
	test_large_plan_avoids_json_argv_limits
	printf '\nResults: %s run, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

run_cache_retrofit_tests() {
	setup
	printf '=== cache retrofit tests ===\n'
	test_cache_retrofit_prunes_mixed_archive_and_accounts_bytes
	test_cache_retrofit_policy_preserves_unsafe_roots
	test_cache_retrofit_rejects_identity_drift_before_mutation
	test_cache_retrofit_rejects_mutable_evidence_drift_before_mutation
	test_cache_retrofit_honors_shared_deadline_before_mutation
	test_cache_retrofit_resumes_interrupted_move
	test_cache_retrofit_resumes_interrupted_delete
	test_cache_retrofit_rejects_unmeasured_legacy_delete_replay
	printf '\nResults: %s run, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" == "cache-retrofit" ]]; then
		run_cache_retrofit_tests
	else
		run_all_tests
	fi
fi
