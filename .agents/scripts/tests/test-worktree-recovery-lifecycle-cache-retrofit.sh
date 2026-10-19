#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Cache retrofit fixtures, policy checks, and interrupted prune recovery.
# Sourced by test-worktree-recovery-lifecycle.sh; uses its shared fixtures.

[[ -n "${_TEST_WT_RECOVERY_CACHE_RETROFIT_LOADED:-}" ]] && return 0
_TEST_WT_RECOVERY_CACHE_RETROFIT_LOADED=1

create_mixed_cache_archive() {
	local home_path="$1"
	local fixture_name="$2"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local repo_path="${TEST_DIR}/${fixture_name}-repo"
	local worktree_path="${TEST_DIR}/${fixture_name}-worktree"
	local archive_path=""

	mkdir -p "$recovery_root" || return 1
	create_unarchived_fixture "$repo_path" "$worktree_path" \
		"bugfix/gh31027-${fixture_name}" || return 1
	printf '/.codegraph/\nlogs/\nnested/.codegraph/\nbackend/__pycache__/\n' \
		>>"${repo_path}/.git/info/exclude" || return 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		create_legacy_worktree_recovery_fixture "$worktree_path" "test.sh" "cache-retrofit" || return 1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$worktree_path" "$archive_path" "test.sh" "cache-retrofit" \
		"recovery_path=archive-first" "false" "false" || return 1
	mkdir -p "${archive_path}/.codegraph" "${archive_path}/logs" || return 1
	python3 - "${archive_path}/.codegraph/codegraph.db" <<'PY' || return 1
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"x" * 256 * 1024)
PY
	printf 'preserve user log\n' >"${archive_path}/logs/diagnostic.log" || return 1
	printf '%s\n' "$archive_path"
	return 0
}

install_cache_retrofit_evidence_stubs() {
	_worktree_recovery_plan_git_state() {
		local identity_json="$1"
		local archive_path=""
		local status_path=""
		local policy_status=0

		archive_path=$(printf '%s\n' "$identity_json" | jq -r '.archive_path') || return 1
		status_path=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/cache-retrofit-status.XXXXXX") || return 1
		if ! GIT_OPTIONAL_LOCKS=0 "$GIT_BIN" -C "$archive_path" status --porcelain=v1 -z \
			--untracked-files=all --ignored=matching >"$status_path" 2>/dev/null; then
			rm -f "$status_path"
			printf 'unavailable\n'
			return 0
		fi
		_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
		rm -f "$status_path"
		case "$policy_status" in
		0) printf 'dirty\n' ;;
		1) printf 'clear\n' ;;
		*) printf 'unavailable\n' ;;
		esac
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

run_cache_retrofit_maintenance() {
	local home_path="$1"
	local state_dir="$2"

	(
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=10 \
			AIDEVOPS_WORKTREE_RECOVERY_CACHE_PRUNE_MAX_ROOTS=10 \
			AIDEVOPS_WORKTREE_RECOVERY_CACHE_PRUNE_MAX_BYTES=10485760 \
			worktree_recovery_maintenance_run
	)
	return $?
}

test_cache_retrofit_prunes_mixed_archive_and_accounts_bytes() {
	local home_path="${TEST_DIR}/cache-retrofit-home"
	local state_dir="${home_path}/maintenance-state"
	local plan_path="${TEST_DIR}/cache-retrofit-live-plan.json"
	local archive_path="" bucket_path="" output="" receipt_path=""
	local rc=0

	archive_path=$(create_mixed_cache_archive "$home_path" "mixed") || rc=1
	bucket_path="${archive_path%/*}"
	install_cache_retrofit_evidence_stubs
	output=$(run_cache_retrofit_maintenance "$home_path" "$state_dir") || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "cache-pruned" ]] || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	jq -e '
		.complete == true and .candidate_count == 1 and
		.expected_allocated_bytes > 0 and
		.observed_allocated_bytes == .expected_allocated_bytes and
		.entries[0].maintenance.operation == "cache-prune" and
		.entries[0].maintenance.relative_path == ".codegraph" and
		.entries[0].outcome == "removed"
	' "$receipt_path" >/dev/null || rc=1
	printf '%s\n' "$output" | jq -e '
		.reclaimed_bytes > 0 and .pruned_roots == 1 and
		.reclaimed_bytes == .diagnostics.cache_prune.selected_bytes and
		.diagnostics.cache_prune.selected_roots == 1
	' >/dev/null || rc=1
	[[ -d "$bucket_path" && ! -e "${archive_path}/.codegraph" &&
		"$(<"${archive_path}/logs/diagnostic.log")" == "preserve user log" ]] || rc=1
	(
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" cmd_recovery plan --output "$plan_path" >/dev/null
	) || rc=1
	jq -e '
		.candidate_count == 0 and .protected_count == 1 and
		.entries[0].disposition == "protected" and
		.entries[0].reasons == ["archive-worktree-dirty"]
	' "$plan_path" >/dev/null || rc=1
	print_result "cache_retrofit_prunes_mixed_archive_and_accounts_bytes" "$rc" \
		"Expected only root CodeGraph cache bytes to be reclaimed while the log and protected archive remain"
	return 0
}

test_cache_retrofit_policy_preserves_unsafe_roots() {
	local repo_path="${TEST_DIR}/cache-retrofit-unsafe"
	local symlink_target="${TEST_DIR}/cache-retrofit-symlink-target"
	local noisy_git="${TEST_DIR}/cache-retrofit-noisy-git"
	local deadline_epoch=0
	local manifest=""
	local rc=0

	"$GIT_BIN" init -q -b main "$repo_path" || rc=1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || rc=1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || rc=1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || rc=1
	mkdir -p "${repo_path}/.codegraph" "${repo_path}/nested/.codegraph" \
		"${repo_path}/backend" "$symlink_target" || rc=1
	printf 'tracked\n' >"${repo_path}/.codegraph/config.json" || rc=1
	"$GIT_BIN" -C "$repo_path" add -f .codegraph/config.json || rc=1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || rc=1
	printf '/.codegraph/\nnested/.codegraph/\nbackend/__pycache__/\n' \
		>>"${repo_path}/.git/info/exclude" || rc=1
	printf 'generated\n' >"${repo_path}/.codegraph/codegraph.db" || rc=1
	printf 'nested\n' >"${repo_path}/nested/.codegraph/codegraph.db" || rc=1
	ln -s "$symlink_target" "${repo_path}/backend/__pycache__" || rc=1
	deadline_epoch=$(($(date +%s) + 30)) || rc=1
	manifest=$(_worktree_recovery_cache_policy_helper manifest "$repo_path" \
		"$GIT_BIN" 10 10485760 "$deadline_epoch") || rc=1
	[[ "$(printf '%s\n' "$manifest" | jq -r '.candidate_count')" == "0" ]] || rc=1
	if _worktree_recovery_cache_policy_helper manifest "$repo_path" \
		"${TEST_DIR}/missing-git" 10 10485760 "$deadline_epoch" >/dev/null 2>&1; then rc=1; fi
	cat >"$noisy_git" <<'SH' || rc=1
#!/usr/bin/env bash
python3 - <<'PY'
import sys

sys.stdout.buffer.write(b"!! .codegraph/cache-file\0" * 50000)
PY
SH
	chmod +x "$noisy_git" || rc=1
	if _worktree_recovery_cache_policy_helper manifest "$repo_path" \
		"$noisy_git" 10 10485760 "$deadline_epoch" >/dev/null 2>&1; then rc=1; fi
	[[ -f "${repo_path}/.codegraph/config.json" &&
		-f "${repo_path}/nested/.codegraph/codegraph.db" &&
		-L "${repo_path}/backend/__pycache__" ]] || rc=1
	print_result "cache_retrofit_policy_preserves_unsafe_roots" "$rc" \
		"Expected tracked, nested CodeGraph, symlink roots, and failed Git queries to retain all content"
	return 0
}

test_cache_retrofit_rejects_mutable_evidence_drift_before_mutation() {
	local home_path="${TEST_DIR}/cache-retrofit-evidence-home"
	local state_dir="${home_path}/maintenance-state"
	local plan_path="${TEST_DIR}/cache-retrofit-evidence-plan.json"
	local receipt_path="${TEST_DIR}/cache-retrofit-evidence-receipt.json"
	local archive_path=""
	local rc=0

	archive_path=$(create_mixed_cache_archive "$home_path" "evidence-drift") || rc=1
	install_cache_retrofit_evidence_stubs
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		limits_json=$(_worktree_recovery_maintenance_limits_json \
			"${home_path}/.aidevops/recovery/worktrees")
		_worktree_recovery_maintenance_prepare_selection "$state_dir" "Linux" "$limits_json"
		printf '%s\n' "$WORKTREE_RECOVERY_MAINTENANCE_CACHE_PLAN_JSON" >"$plan_path"
		_worktree_recovery_plan_claim_state() {
			local ignored_identity="$1"
			: "$ignored_identity"
			printf 'active\n'
			return 0
		}
		HOME="$home_path" worktree_recovery_cache_prune_apply_automatic \
			"$plan_path" "$receipt_path" >/dev/null 2>&1
	); then rc=1; fi
	[[ -d "${archive_path}/.codegraph" && -f "${archive_path}/logs/diagnostic.log" &&
		! -e "$receipt_path" ]] || rc=1
	print_result "cache_retrofit_rejects_mutable_evidence_drift_before_mutation" "$rc" \
		"Expected a newly active claim to block cache-root staging before any archive mutation"
	return 0
}

test_cache_retrofit_honors_shared_deadline_before_mutation() {
	local home_path="${TEST_DIR}/cache-retrofit-deadline-home"
	local state_dir="${home_path}/maintenance-state"
	local plan_path="${TEST_DIR}/cache-retrofit-deadline-plan.json"
	local receipt_path="${TEST_DIR}/cache-retrofit-deadline-receipt.json"
	local archive_path=""
	local expired_epoch=0
	local rc=0

	archive_path=$(create_mixed_cache_archive "$home_path" "shared-deadline") || rc=1
	install_cache_retrofit_evidence_stubs
	(
		uname() {
			printf 'Linux\n'
			return 0
		}
		limits_json=$(_worktree_recovery_maintenance_limits_json \
			"${home_path}/.aidevops/recovery/worktrees")
		_worktree_recovery_maintenance_prepare_selection "$state_dir" "Linux" "$limits_json"
		printf '%s\n' "$WORKTREE_RECOVERY_MAINTENANCE_CACHE_PLAN_JSON" >"$plan_path"
	) || rc=1
	expired_epoch=$(($(date +%s) - 1)) || rc=1
	if HOME="$home_path" worktree_recovery_cache_prune_apply_automatic \
		"$plan_path" "$receipt_path" "$expired_epoch" >/dev/null 2>&1; then rc=1; fi
	[[ -d "${archive_path}/.codegraph" && -f "${archive_path}/logs/diagnostic.log" &&
		! -e "$receipt_path" ]] || rc=1
	print_result "cache_retrofit_honors_shared_deadline_before_mutation" "$rc" \
		"Expected an exhausted maintenance deadline to block a fresh cache apply budget"
	return 0
}

test_cache_retrofit_resumes_interrupted_delete() {
	local home_path="${TEST_DIR}/cache-retrofit-delete-home"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" output="" receipt_path=""
	local rc=0

	archive_path=$(create_mixed_cache_archive "$home_path" "delete-resume") || rc=1
	install_cache_retrofit_evidence_stubs
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_DELETE=1 \
		run_cache_retrofit_maintenance "$home_path" "$state_dir" >/dev/null 2>&1; then rc=1; fi
	[[ -d "$state_dir/pending" && ! -e "${archive_path}/.codegraph" &&
		-f "${archive_path}/logs/diagnostic.log" ]] || rc=1
	output=$(run_cache_retrofit_maintenance "$home_path" "$state_dir") || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "resumed-and-pruned" ]] || rc=1
	jq -e '
		.observed_allocated_bytes == .expected_allocated_bytes and
		([.entries[].post_delete_allocated_bytes] | all(. == 0))
	' "$receipt_path" >/dev/null || rc=1
	[[ ! -d "$state_dir/pending" && ! -e "${archive_path}/.codegraph" &&
		-f "${archive_path}/logs/diagnostic.log" ]] || rc=1
	print_result "cache_retrofit_resumes_interrupted_delete" "$rc" \
		"Expected a post-delete crash to resume from the removing journal with zero residual bytes"
	return 0
}

test_cache_retrofit_rejects_unmeasured_legacy_delete_replay() {
	local home_path="${TEST_DIR}/cache-retrofit-legacy-delete-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local plan_path="${state_dir}/pending/plan.json"
	local receipt_path="${state_dir}/pending/receipt.json"
	local archive_path="" plan_json="" plan_digest="" journal_path="" journal_next=""
	local rc=0

	archive_path=$(create_mixed_cache_archive "$home_path" "legacy-delete-replay") || rc=1
	install_cache_retrofit_evidence_stubs
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_DELETE=1 \
		run_cache_retrofit_maintenance "$home_path" "$state_dir" >/dev/null 2>&1; then rc=1; fi
	plan_json=$(<"$plan_path") || rc=1
	plan_digest=$(_worktree_recovery_plan_sha256_text "$plan_json") || rc=1
	journal_path="${recovery_root}/.retention-trash/cache-${plan_digest}/journal.json"
	journal_next="${journal_path}.legacy"
	jq -c '.entries[0].state = "staged" | .entries[0].removal_started_at = null' \
		"$journal_path" >"$journal_next" || rc=1
	mv "$journal_next" "$journal_path" || rc=1
	if run_cache_retrofit_maintenance "$home_path" "$state_dir" >/dev/null 2>&1; then rc=1; fi
	jq -e '
		.schema == "aidevops.worktree-recovery-apply-reservation/v1" and
		(.complete | not)
	' "$receipt_path" >/dev/null || rc=1
	jq -e '.entries[0].state == "staged" and .entries[0].removed_at == null' \
		"$journal_path" >/dev/null || rc=1
	[[ -d "$state_dir/pending" && ! -e "${archive_path}/.codegraph" &&
		-f "${archive_path}/logs/diagnostic.log" ]] || rc=1
	print_result "cache_retrofit_rejects_unmeasured_legacy_delete_replay" "$rc" \
		"Expected staged-and-absent legacy journals to fail closed without a reclaimed-byte receipt"
	return 0
}

test_cache_retrofit_rejects_identity_drift_before_mutation() {
	local home_path="${TEST_DIR}/cache-retrofit-drift-home"
	local state_dir="${home_path}/maintenance-state"
	local plan_path="${TEST_DIR}/cache-retrofit-drift-plan.json"
	local receipt_path="${TEST_DIR}/cache-retrofit-drift-receipt.json"
	local archive_path="" recovery_dir=""
	local rc=0

	archive_path=$(create_mixed_cache_archive "$home_path" "cache-retrofit-identity-drift") || rc=1
	recovery_dir="${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}"
	install_cache_retrofit_evidence_stubs
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		limits_json=$(_worktree_recovery_maintenance_limits_json \
			"${home_path}/.aidevops/recovery/worktrees")
		_worktree_recovery_maintenance_prepare_selection "$state_dir" "Linux" "$limits_json"
		printf '%s\n' "$WORKTREE_RECOVERY_MAINTENANCE_CACHE_PLAN_JSON" >"$plan_path"
		printf 'drifted-context\n' >"${recovery_dir}/producer-context"
		HOME="$home_path" worktree_recovery_cache_prune_apply_automatic \
			"$plan_path" "$receipt_path" >/dev/null 2>&1
	); then rc=1; fi
	[[ -d "${archive_path}/.codegraph" && -f "${archive_path}/logs/diagnostic.log" &&
		! -e "$receipt_path" ]] || rc=1
	print_result "cache_retrofit_rejects_identity_drift_before_mutation" "$rc" \
		"Expected recovery identity drift to fail before staging any approved cache root"
	return 0
}

test_cache_retrofit_resumes_interrupted_move() {
	local home_path="${TEST_DIR}/cache-retrofit-resume-home"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" output=""
	local rc=0

	archive_path=$(create_mixed_cache_archive "$home_path" "resume") || rc=1
	install_cache_retrofit_evidence_stubs
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_MOVE=1 \
		run_cache_retrofit_maintenance "$home_path" "$state_dir" >/dev/null 2>&1; then rc=1; fi
	[[ -d "$state_dir/pending" && ! -e "${archive_path}/.codegraph" &&
		-f "${archive_path}/logs/diagnostic.log" ]] || rc=1
	output=$(run_cache_retrofit_maintenance "$home_path" "$state_dir") || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "resumed-and-pruned" ]] || rc=1
	[[ ! -d "$state_dir/pending" && ! -e "${archive_path}/.codegraph" &&
		-f "${archive_path}/logs/diagnostic.log" ]] || rc=1
	print_result "cache_retrofit_resumes_interrupted_move" "$rc" \
		"Expected a journaled cache-root move to resume without touching protected archive content"
	return 0
}
