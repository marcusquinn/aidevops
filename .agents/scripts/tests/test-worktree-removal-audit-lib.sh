#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Shared fixtures and orchestrator for the worktree-removal audit regressions.
# Logging cases live in test-worktree-removal-audit-events.sh; cleanup and
# process-visibility cases live in the sibling test-worktree-removal-audit-lib-*
# modules. Source from test-worktree-removal-audit.sh, or execute directly.
# All tests use isolated temporary directories and a fixture-owned registry.

set -euo pipefail

[[ -n "${_TEST_WORKTREE_REMOVAL_AUDIT_LIB_LOADED:-}" ]] && return 0
_TEST_WORKTREE_REMOVAL_AUDIT_LIB_LOADED=1

# Resolve relative to this file even when the caller supplied another SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_HELPER="${SCRIPT_DIR}/../audit-worktree-removal-helper.sh"
COMMANDS_HELPER="${SCRIPT_DIR}/../worktree-helper-cmds.sh"
CLEAN_HELPER="${SCRIPT_DIR}/../worktree-clean-lib.sh"
REGISTRY_HELPER="${SCRIPT_DIR}/../shared-worktree-registry.sh"
SKILL_PR_HELPER="${SCRIPT_DIR}/../skill-update-pr-lib.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

# =============================================================================
# Test framework
# =============================================================================

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
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
	export AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_DIR}/recovery"
	# Fixture-owned ownership registry: the managed-lifetime fence fails closed
	# without one, and the host registry must never be read or written. Tests
	# that need a different registry still override these per subshell.
	export WORKTREE_REGISTRY_DIR="${TEST_DIR}/registry"
	export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
	(
		# shellcheck source=../shared-worktree-registry.sh
		source "$REGISTRY_HELPER" && _init_registry_db
	) || return 1
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 1
	strip_git_shims_from_path || return 1
	return 0
}

# Race tests inject a non-native AIDEVOPS_REAL_GIT_BIN wrapper. A deployed
# aidevops git shim on PATH correctly rejects such overrides, which would make
# the helper fail closed before the race; shim behaviour has its own tests.
strip_git_shims_from_path() {
	local entry="" kept="" old_ifs="$IFS"
	local -a entries=()
	IFS=':'
	read -r -a entries <<<"${PATH:-}"
	IFS="$old_ifs"
	for entry in "${entries[@]}"; do
		[[ -n "$entry" ]] || continue
		if [[ -e "${entry}/git" ]] && (
			AIDEVOPS_RUNTIME_ENV_LIBRARY_ONLY=1
			# shellcheck source=../runtime-env.sh
			source "${SCRIPT_DIR}/../runtime-env.sh" && aidevops_is_git_shim "${entry}/git"
		); then
			continue
		fi
		kept="${kept:+${kept}:}${entry}"
	done
	[[ -n "$kept" ]] || return 1
	export PATH="$kept"
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"
	grep -qE "$pattern" "$file" 2>/dev/null
	return $?
}

assert_line_count() {
	local file="$1"
	local expected="$2"
	local actual
	actual=$(wc -l <"$file" 2>/dev/null | tr -d ' ')
	if [[ "$actual" -eq "$expected" ]]; then
		return 0
	fi
	echo "  expected $expected lines, got $actual"
	return 1
}

create_git_worktree_fixture() {
	local repo_path="$1"
	local wt_path="$2"
	local branch_name="$3"

	"$GIT_BIN" init -q -b main "$repo_path" || return 1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || return 1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || return 1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || return 1
	printf 'base\n' >"${repo_path}/README.md" || return 1
	"$GIT_BIN" -C "$repo_path" add README.md || return 1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || return 1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "$branch_name" "$wt_path" main || return 1
	return 0
}

# Removal cases exercise their native Git/archive invariants. Give them a
# deterministic complete snapshot so unrelated host processes cannot turn the
# fixture into a degraded-visibility cleanup path.
with_complete_cwd_snapshot() (
	capture_worktree_process_cwds() {
		printf '/\n'
		return 0
	}
	"$@"
)

# shellcheck source=./test-worktree-removal-audit-events.sh
# shellcheck disable=SC1091  # test module resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-worktree-removal-audit-events.sh"
# shellcheck source=./test-worktree-removal-audit-lib-cleanup.sh
# shellcheck disable=SC1091  # test module resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-worktree-removal-audit-lib-cleanup.sh"
# shellcheck source=./test-worktree-removal-audit-lib-process.sh
# shellcheck disable=SC1091  # test module resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-worktree-removal-audit-lib-process.sh"

# =============================================================================
# Main
# =============================================================================

setup

echo "=== test-worktree-removal-audit.sh ==="

test_log_writes_one_line
test_log_format_correct
test_custom_log_path
test_all_event_types
test_should_skip_cleanup_owned_skip_logs
test_idempotent_sourcing
test_guard_refuses_current_cwd
test_guard_refuses_other_process_cwd
test_permanent_helper_removes_and_logs
test_guard_fails_closed_on_inaccessible_candidate
test_git_lock_parser_handles_unusual_paths_and_adjacent_blocks
test_git_lock_parser_rejects_malformed_blocks
test_missing_worktree_physical_parent_alias
test_permanent_helper_preserves_lock_acquired_after_guard
test_recovery_store_selects_platform_semantics
test_archive_copy_filters_before_io_and_bounds_retries
test_recovery_store_permission_preflight
test_recovery_inventory_reports_legacy_buckets_fail_closed
test_recoverable_archive_then_native_remove
test_recoverable_archive_preserves_late_lock
test_compact_archive_native_removal
test_compact_removal_refusals
test_recovery_archive_preserves_index_and_dirty_files
test_recovery_archive_preserves_detached_head_identity
test_recoverable_archive_refuses_replacement_worktree
test_recoverable_archive_refuses_late_unarchived_write_without_force
test_removal_helpers_refuse_direct_symlink_alias
test_manual_cleanup_archives_removes_and_prunes
test_manual_cleanup_recovers_degraded_visibility_exact_head
test_manual_degraded_recheck_requires_live_exact_lease
test_manual_degraded_recovery_rejects_unsafe_candidates
test_local_only_degraded_recovery_uses_ancestry
test_recoverable_cleanup_preserves_lock_acquired_after_guard
test_recoverable_cleanup_preserves_lease_loss_after_archive
test_skill_cleanup_has_no_removal_failure_fallback
test_permanent_helper_preserves_git_locked_worktree
test_permanent_helper_fails_closed_on_unreadable_git_metadata
test_permanent_helper_fails_closed_on_ambiguous_git_metadata
test_guard_allows_verified_unlocked_worktree
test_optional_guard_context_logged
test_process_cwd_guard_refuses_empty_paths
test_process_cwd_snapshot_failure_is_fail_closed
test_snapshot_backend_requires_visible_target
test_lsof_snapshot_visibility_states
test_proc_snapshot_preserves_degraded_visibility
test_proc_snapshot_skips_foreign_uid_unreadable_entry
test_proc_snapshot_skips_foreign_uid_when_status_unreadable
test_proc_snapshot_marks_same_uid_unreadable_entry_degraded
test_proc_snapshot_recovers_protected_same_uid_cwd
test_privileged_inspector_rejects_untrusted_proc_root
test_privileged_inspector_uses_bounded_execution
test_process_platform_policy
test_unprivileged_proc_collector
test_nixos_process_inspector_never_escalates
test_privileged_inspector_uid_rule
test_proc_snapshot_rejects_failed_inspector_output
test_proc_snapshot_skips_zombie_cwd_denial
test_proc_snapshot_marks_same_uid_daemon_denial_degraded
test_degraded_visibility_preserves_positive_candidate_match
test_proc_snapshot_requires_usable_evidence_after_foreign_skips
test_proc_snapshot_ignores_vanished_entry
test_guard_reason_is_machine_readable
test_manual_guard_refusal_diagnostics
test_recoverable_archive_honours_shared_producer_lock

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed."

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
