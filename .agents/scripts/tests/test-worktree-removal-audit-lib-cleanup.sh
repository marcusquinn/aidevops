#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Guard, native Git removal, recovery archive, and cleanup integration tests.
# Source from test-worktree-removal-audit-lib.sh after the shared test framework.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_TEST_WORKTREE_REMOVAL_AUDIT_CLEANUP_LOADED:-}" ]] && return 0
_TEST_WORKTREE_REMOVAL_AUDIT_CLEANUP_LOADED=1

# shellcheck source=./legacy-worktree-recovery-fixture.sh
source "${BASH_SOURCE[0]%/*}/legacy-worktree-recovery-fixture.sh"

# =============================================================================
# Test 7: shared guard refuses current working directory removals
# =============================================================================
test_guard_refuses_current_cwd() {
	local log_file="${TEST_DIR}/t7-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/current-wt"
	mkdir -p "$wt_path"

	local rc=0
	(
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		cd "$wt_path" || exit 2
		if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
			exit 1
		fi
	) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		assert_file_contains "$log_file" "worktree-skipped.*current-worktree.*mode=skipped" || rc=$?
	fi
	print_result "guard_refuses_current_cwd" "$rc" \
		"Expected current-worktree skip. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 8: shared guard refuses another live process with cwd in worktree
# =============================================================================
test_guard_refuses_other_process_cwd() {
	local log_file="${TEST_DIR}/t8-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/active-process-wt"
	mkdir -p "$wt_path"

	local sleeper_pid=""
	(
		cd "$wt_path" || exit 2
		sleep 30
	) &
	sleeper_pid=$!

	local rc=0
	local attempts=0
	while [[ "$attempts" -lt 20 ]]; do
		(
			unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
			# shellcheck source=../audit-worktree-removal-helper.sh
			source "$AUDIT_HELPER"
			if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
				exit 1
			fi
		) && break
		rc=$?
		attempts=$((attempts + 1))
		sleep 0.1
	done

	kill "$sleeper_pid" 2>/dev/null || true
	wait "$sleeper_pid" 2>/dev/null || true

	if [[ "$rc" -eq 0 ]]; then
		assert_file_contains "$log_file" "worktree-skipped.*active-cwd.*mode=skipped" || rc=$?
	fi
	print_result "guard_refuses_other_process_cwd" "$rc" \
		"Expected active-cwd skip. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# A clear legacy guard cannot authorize removal without the new registry.
# =============================================================================
test_permanent_helper_requires_registry() {
	local log_file="${TEST_DIR}/t9-cleanup.log"
	local repo_path="${TEST_DIR}/old-repo"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/old-wt"
	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/old" || return 1

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local rc=0
	if (
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		with_complete_cwd_snapshot remove_worktree_path_permanently \
			"$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	if [[ -f "$log_file" ]] && assert_file_contains "$log_file" "worktree-removed"; then
		rc=1
	fi
	print_result "permanent_helper_requires_registry" "$rc" \
		"Expected source retention and no false removal audit without registry authority"
	return 0
}

# =============================================================================
# An inaccessible candidate must not be inferred to be a non-Git directory.
# =============================================================================
test_guard_fails_closed_on_inaccessible_candidate() {
	local log_file="${TEST_DIR}/inaccessible-cleanup.log"
	local repo_path="${TEST_DIR}/inaccessible-repo"
	local wt_path="${TEST_DIR}/inaccessible-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/inaccessible" || rc=1
	chmod 000 "$wt_path" || rc=1
	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		worktree_removal_guard "$wt_path" "test.sh" "manual" ""
	); then
		rc=1
	fi
	chmod 700 "$wt_path" || rc=1
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "guard_fails_closed_on_inaccessible_candidate" "$rc" \
		"Expected inaccessible candidate to remain and report unreadable metadata"
	return 0
}

# =============================================================================
# NUL-delimited porcelain parsing preserves unusual paths and exact block
# ownership: a lock in the adjacent block must not taint an unlocked candidate.
# =============================================================================
test_git_lock_parser_handles_unusual_paths_and_adjacent_blocks() {
	local repo_path="${TEST_DIR}/parser-repo"
	local wt_path="${TEST_DIR}/parser-worktree"$'\n'"with-newline"
	local adjacent_path="${TEST_DIR}/parser-adjacent"
	local wt_path_real=""
	local git_state=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/parser" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "feature/parser-adjacent" "$adjacent_path" main || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "adjacent-preservation" "$adjacent_path" || rc=1
	wt_path_real=$(cd "$wt_path" && pwd -P) || rc=1
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") || rc=1
	[[ "$git_state" == "$_WT_GIT_STATE_CLEAR" ]] || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "candidate-preservation" "$wt_path" || rc=1
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") || rc=1
	[[ "$git_state" == "$_WT_GIT_STATE_LOCKED" ]] || rc=1
	print_result "git_lock_parser_handles_unusual_paths_and_adjacent_blocks" "$rc" \
		"Expected exact NUL-safe lock ownership for unusual worktree paths"
	return 0
}

# =============================================================================
# A status-zero list is not authoritative unless every block is structurally
# complete. Missing, duplicate, contradictory, or nested fields fail closed.
# =============================================================================
test_git_lock_parser_rejects_malformed_blocks() {
	local wt_path="${TEST_DIR}/malformed-parser-worktree"
	local other_path="${TEST_DIR}/malformed-parser-other"
	local valid_head="0123456789abcdef0123456789abcdef01234567"
	local other_head="89abcdef0123456789abcdef0123456789abcdef"
	local malformed_mode=""
	local git_state=""
	local rc=0
	mkdir -p "$wt_path"

	git() {
		local all_args="$*"
		case "$all_args" in
		*"rev-parse --show-toplevel"*) printf '%s\n' "$wt_path" ;;
		*"worktree list --porcelain -z"*)
			case "$malformed_mode" in
			unterminated) printf 'worktree %s\0HEAD %s\0branch refs/heads/test\0' "$wt_path" "$valid_head" ;;
			duplicate-start) printf 'worktree %s\0HEAD %s\0worktree %s\0HEAD %s\0branch refs/heads/other\0\0' "$wt_path" "$valid_head" "$other_path" "$other_head" ;;
			missing-head) printf 'worktree %s\0branch refs/heads/test\0\0' "$wt_path" ;;
			missing-identity) printf 'worktree %s\0HEAD %s\0\0' "$wt_path" "$valid_head" ;;
			contradictory) printf 'worktree %s\0HEAD %s\0branch refs/heads/test\0detached\0\0' "$wt_path" "$valid_head" ;;
			duplicate-head) printf 'worktree %s\0HEAD %s\0HEAD %s\0branch refs/heads/test\0\0' "$wt_path" "$valid_head" "$other_head" ;;
			empty-head) printf 'worktree %s\0HEAD \0branch refs/heads/test\0\0' "$wt_path" ;;
			empty-branch) printf 'worktree %s\0HEAD %s\0branch \0\0' "$wt_path" "$valid_head" ;;
			whitespace-head) printf 'worktree %s\0HEAD \t\0branch refs/heads/test\0\0' "$wt_path" ;;
			invalid-head) printf 'worktree %s\0HEAD deadbeef\0branch refs/heads/test\0\0' "$wt_path" ;;
			whitespace-branch) printf 'worktree %s\0HEAD %s\0branch \t\0\0' "$wt_path" "$valid_head" ;;
			invalid-branch) printf 'worktree %s\0HEAD %s\0branch refs/heads/bad..name\0\0' "$wt_path" "$valid_head" ;;
			invalid-namespace) printf 'worktree %s\0HEAD %s\0branch refs/tags/test\0\0' "$wt_path" "$valid_head" ;;
			esac
			;;
		*) return 1 ;;
		esac
		return 0
	}
	for malformed_mode in unterminated duplicate-start missing-head missing-identity contradictory duplicate-head \
		empty-head empty-branch whitespace-head invalid-head whitespace-branch invalid-branch invalid-namespace; do
		git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path") || rc=1
		[[ "$git_state" == "$_WT_GIT_STATE_UNREADABLE" ]] || rc=1
	done
	unset -f git
	print_result "git_lock_parser_rejects_malformed_blocks" "$rc" \
		"Expected malformed structure, object IDs, and branch refs to remain unreadable"
	return 0
}

# =============================================================================
# Missing paths are normalized through their physical parent so aliases such as
# macOS /var and /private/var compare to the same Git metadata path.
# =============================================================================
test_missing_worktree_physical_parent_alias() {
	local physical_parent="${TEST_DIR}/physical-parent"
	local alias_parent="${TEST_DIR}/alias-parent"
	local expected_parent=""
	local resolved_path=""
	local rc=0
	mkdir -p "$physical_parent"
	ln -s "$physical_parent" "$alias_parent" || rc=1
	expected_parent=$(cd "$physical_parent" && pwd -P) || rc=1
	resolved_path=$(_worktree_physical_path "${alias_parent}/missing-worktree") || rc=1
	[[ "$resolved_path" == "${expected_parent}/missing-worktree" ]] || rc=1
	print_result "missing_worktree_physical_parent_alias" "$rc" \
		"Expected a missing aliased path to resolve through its physical parent"
	return 0
}

# =============================================================================
# Missing registry authority must stop before a legacy native-Git wrapper runs.
# Real late-lock and late-write races are exercised against the retirement
# executor in worker-lifecycle/tests/test_retirement.py.
# =============================================================================
test_permanent_helper_refuses_before_legacy_git_injection() {
	local log_file="${TEST_DIR}/race-cleanup.log"
	local repo_path="${TEST_DIR}/race-repo"
	local wt_path="${TEST_DIR}/race-worktree"
	local wrapper_path="${TEST_DIR}/race-git"
	local marker_path="${TEST_DIR}/race-lock-injected"
	local metadata=""
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/race" || rc=1
	cat >"$wrapper_path" <<'RACE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${RACE_MARKER:?}" ]]; then
	: >"$RACE_MARKER"
	"${REAL_GIT:?}" -C "${RACE_REPO:?}" worktree lock --reason "foreign-race-lock" "${RACE_WORKTREE:?}" || exit 1
fi
exec "${REAL_GIT:?}" "$@"
RACE_GIT
	chmod +x "$wrapper_path" || rc=1
	if (
		export AIDEVOPS_REAL_GIT_BIN="$wrapper_path"
		export REAL_GIT="$GIT_BIN"
		export RACE_MARKER="$marker_path"
		export RACE_REPO="$repo_path"
		export RACE_WORKTREE="$wt_path"
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		with_complete_cwd_snapshot remove_worktree_path_permanently \
			"$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" && ! -e "$marker_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	print_result "permanent_helper_refuses_before_legacy_git_injection" "$rc" \
		"Expected registry refusal before invoking an injected native-removal command"
	return 0
}

# =============================================================================
# Archive creation preserves evidence but cannot authorize source removal.
# =============================================================================
test_recovery_store_selects_platform_semantics() {
	local fixture_home="${TEST_DIR}/platform-home"
	local override_root="${TEST_DIR}/operator-archive-root"
	local actual=""
	local rc=0

	mkdir -p "$fixture_home" || rc=1
	actual=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" _worktree_recovery_store_root "Linux") || rc=1
	[[ "$actual" == "$fixture_home/.aidevops/recovery/worktrees" ]] || rc=1
	actual=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" _worktree_recovery_store_root "Darwin") || rc=1
	[[ "$actual" == "$fixture_home/.Trash" ]] || rc=1
	actual=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$override_root" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" _worktree_recovery_store_root "Linux") || rc=1
	[[ "$actual" == "$override_root" ]] || rc=1
	actual=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_ARCHIVE_ROOT="" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="" AIDEVOPS_ORPHAN_TRASH_ROOT="" \
		_worktree_recovery_producer_root) || rc=1
	[[ "$actual" == "$fixture_home/.aidevops/recovery/archives" ]] || rc=1
	actual=$(AIDEVOPS_WORKTREE_ARCHIVE_ROOT="$override_root" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="$fixture_home/old-trash" \
		_worktree_recovery_producer_root) || rc=1
	[[ "$actual" == "$override_root" ]] || rc=1
	print_result "recovery_store_selects_platform_semantics" "$rc" \
		"Expected legacy platform roots, a common compact archive default, and explicit override precedence"
	return 0
}

test_recovery_inventory_reports_legacy_buckets_fail_closed() {
	local fixture_home="${TEST_DIR}/inventory-home"
	local current_root="${fixture_home}/.aidevops/recovery/worktrees"
	local override_link="${fixture_home}/operator-recovery"
	local legacy_alias="${fixture_home}/legacy-recovery-alias"
	local legacy_root="${fixture_home}/.Trash"
	local spoofed_bucket="${current_root}/aidevops-worktree-cleanup-spoofed"
	local unknown_bucket="${legacy_root}/aidevops-worktree-cleanup-interrupted"
	local current_repo="${TEST_DIR}/current-inventory-repo"
	local current_worktree="${TEST_DIR}/current-inventory-worktree"
	local current_archive=""
	local current_bucket=""
	local interrupted_repo="${TEST_DIR}/interrupted-inventory-repo"
	local interrupted_worktree="${TEST_DIR}/interrupted-inventory-worktree"
	local interrupted_archive=""
	local interrupted_bucket=""
	local compat_repo="${TEST_DIR}/compat-v1-inventory-repo"
	local compat_worktree="${TEST_DIR}/compat-v1-inventory-worktree"
	local compat_archive=""
	local compat_bucket=""
	local legacy_repo="${TEST_DIR}/legacy-v1-inventory-repo"
	local legacy_worktree="${TEST_DIR}/legacy-v1-inventory-worktree"
	local legacy_archive=""
	local legacy_bucket=""
	local recovery_dir=""
	local output=""
	local alias_output=""
	local rc=0

	mkdir -p "$spoofed_bucket/${_WT_RECOVERY_DIR_NAME}" \
		"$unknown_bucket/${_WT_RECOVERY_DIR_NAME}" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT" >"$spoofed_bucket/${_WT_RECOVERY_DIR_NAME}/format" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT" > \
		"$spoofed_bucket/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT" > \
		"$unknown_bucket/${_WT_RECOVERY_DIR_NAME}/format" || rc=1
	spoofed_bucket=$(cd "$spoofed_bucket" 2>/dev/null && pwd -P) || rc=1
	unknown_bucket=$(cd "$unknown_bucket" 2>/dev/null && pwd -P) || rc=1
	ln -s "$current_root" "$override_link" || rc=1
	ln -s "$legacy_root" "$legacy_alias" || rc=1
	create_git_worktree_fixture "$current_repo" "$current_worktree" "feature/current-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$current_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		create_legacy_worktree_recovery_fixture "$current_worktree" "test.sh" "current-inventory" || rc=1
	current_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	current_bucket="${current_archive%/*}"
	create_git_worktree_fixture "$interrupted_repo" "$interrupted_worktree" \
		"feature/interrupted-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		create_legacy_worktree_recovery_fixture "$interrupted_worktree" "test.sh" \
		"interrupted-inventory" || rc=1
	interrupted_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	interrupted_bucket="${interrupted_archive%/*}"
	rm -f "$interrupted_bucket/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" || rc=1
	create_git_worktree_fixture "$compat_repo" "$compat_worktree" "feature/compat-v1-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		create_legacy_worktree_recovery_fixture "$compat_worktree" "test.sh" "compat-v1-inventory" || rc=1
	compat_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	compat_bucket="${compat_archive%/*}"
	recovery_dir="$compat_bucket/${_WT_RECOVERY_DIR_NAME}"
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V1" >"$recovery_dir/format" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V1" >"$recovery_dir/${_WT_RECOVERY_COMPLETE_MARKER}" || rc=1
	rm -f "$recovery_dir/created-at" "$recovery_dir/producer" \
		"$recovery_dir/producer-context" "$recovery_dir/session-id" \
		"$recovery_dir/archive-outcome" "$recovery_dir/source-removal-outcome" || rc=1
	create_git_worktree_fixture "$legacy_repo" "$legacy_worktree" "feature/legacy-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		create_legacy_worktree_recovery_fixture "$legacy_worktree" "test.sh" "legacy-inventory" || rc=1
	legacy_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	legacy_bucket="${legacy_archive%/*}"
	recovery_dir="$legacy_bucket/${_WT_RECOVERY_DIR_NAME}"
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V1" >"$recovery_dir/format" || rc=1
	rm -f "$recovery_dir/${_WT_RECOVERY_COMPLETE_MARKER}" \
		"$recovery_dir/storage-owner" "$recovery_dir/storage-class" \
		"$recovery_dir/storage-policy" "$recovery_dir/storage-root" \
		"$recovery_dir/created-at" "$recovery_dir/producer" \
		"$recovery_dir/producer-context" "$recovery_dir/session-id" \
		"$recovery_dir/archive-outcome" "$recovery_dir/source-removal-outcome" || rc=1
	output=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$override_link" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" worktree_recovery_inventory "Linux") || rc=1
	printf '%s\n' "$output" | grep -Fq $'store\tcurrent\tjoint\trecovery\tmanual-review\tpresent\t' || rc=1
	printf '%s\n' "$output" | grep -Fq $'store\tlegacy\tjoint\trecovery\tmanual-review\tpresent\t' || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tcurrent\tframework\tattributed\t'"$current_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tcurrent\tframework\tunknown\t'"$spoofed_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tunknown\t'"$unknown_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tunknown\t'"$interrupted_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tattributed\t'"$compat_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tattributed-legacy\t'"$legacy_bucket" || rc=1
	alias_output=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_alias" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" worktree_recovery_inventory "Linux") || rc=1
	[[ "$(printf '%s\n' "$alias_output" | grep -c '^store')" -eq 1 ]] || rc=1
	print_result "recovery_inventory_reports_legacy_buckets_fail_closed" "$rc" \
		"Expected attributed current and unknown legacy buckets to remain visible and protected"
	return 0
}

test_recoverable_archive_does_not_authorize_removal() {
	local repo_path="${TEST_DIR}/archive-repo"
	local wt_path="${TEST_DIR}/archive-worktree"
	local trash_root="${TEST_DIR}/archive-trash"
	local archive_path=""
	local wt_root=""
	local metadata=""
	local index_path="" index_before="" index_after=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	index_path=$("$GIT_BIN" -C "$wt_path" rev-parse --path-format=absolute --git-path index) || rc=1
	# Stat-only drift triggers git diff's auto-refresh unless explicitly disabled.
	touch -t 202001010000 "$wt_path/README.md" || rc=1
	index_before=$("$GIT_BIN" hash-object "$index_path") || rc=1
	AIDEVOPS_SESSION_ID="ses_test_recovery" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "archive-test" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	index_after=$("$GIT_BIN" hash-object "$index_path") || rc=1
	[[ "$index_after" == "$index_before" ]] || rc=1
	[[ -d "$wt_path" && -f "$archive_path/manifest.json" && ! -e "$archive_path/.git" ]] || rc=1
	_worktree_recovery_archive_is_valid "$archive_path" || rc=1
	jq -e '.phase == "archived" and .source.capture_policy == "git-only"
		and .caller == "test.sh" and .context == "archive-test"
		and .session_id == "ses_test_recovery" and .source_removal_outcome == "pending"' \
		"$trash_root"/.producer-transactions/*/journal.json >/dev/null || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fx "worktree $wt_root" >/dev/null || rc=1
	if AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "recoverable-test" \
		"recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	"$GIT_BIN" -C "$repo_path" worktree list --porcelain | grep -Fx "worktree $wt_root" >/dev/null || rc=1
	[[ -d "$wt_path" && -f "$archive_path/manifest.json" ]] || rc=1
	jq -e '.source_removal_outcome == "pending"' \
		"$trash_root"/.producer-transactions/*/journal.json >/dev/null || rc=1
	print_result "recoverable_archive_does_not_authorize_removal" "$rc" \
		"Expected archive/source retention; index before=$index_before after=$index_after; journal=$(jq -c '{phase, caller, context, session_id, source_removal_outcome}' "$trash_root"/.producer-transactions/*/journal.json 2>/dev/null)"
	return 0
}

# =============================================================================
# A completed archive cannot enable a legacy injected native-removal command.
# =============================================================================
test_recoverable_archive_refuses_legacy_git_injection() {
	local repo_path="${TEST_DIR}/archive-race-repo"
	local wt_path="${TEST_DIR}/archive-race-worktree"
	local trash_root="${TEST_DIR}/archive-race-trash"
	local wrapper_path="${TEST_DIR}/archive-race-git"
	local marker_path="${TEST_DIR}/archive-race-lock-injected"
	local archive_path=""
	local metadata=""
	local wt_root=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-race" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "archive-race" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	cat >"$wrapper_path" <<'RACE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${RACE_MARKER:?}" ]]; then
	: >"$RACE_MARKER"
	"${REAL_GIT:?}" -C "${RACE_REPO:?}" worktree lock \
		--reason "foreign-after-archive" "${RACE_WORKTREE:?}" || exit 1
fi
exec "${REAL_GIT:?}" "$@"
RACE_GIT
	chmod +x "$wrapper_path" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if REAL_GIT="$GIT_BIN" RACE_MARKER="$marker_path" RACE_REPO="$repo_path" \
		RACE_WORKTREE="$wt_path" AIDEVOPS_REAL_GIT_BIN="$wrapper_path" \
		with_complete_cwd_snapshot remove_archived_worktree_path "$wt_path" "$archive_path" "test.sh" \
		"recoverable-test" "recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	[[ -d "$wt_path" && -f "$archive_path/manifest.json" && ! -e "$marker_path" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	print_result "recoverable_archive_refuses_legacy_git_injection" "$rc" \
		"Expected registry refusal before an injected Git removal, with archive retained"
	return 0
}

# =============================================================================
# Git-only recovery preserves staging and working files without ignored data;
# the common Git repository remains a declared dependency.
# =============================================================================
# Populate the caller's fixture paths; all mutations stay under TEST_DIR.
create_compact_removal_fixture() {
	local label="$1"
	local output="${TEST_DIR}/${label}-archives"
	local -a journals=()
	repo_path="${TEST_DIR}/${label}-repo"
	wt_path="${TEST_DIR}/${label}-worktree"
	create_git_worktree_fixture "$repo_path" "$wt_path" feature/compact || return 1
	printf 'staged\n' >"$wt_path/README.md" || return 1
	"$GIT_BIN" -C "$wt_path" add README.md || return 1
	printf 'unstaged\n' >"$wt_path/README.md" || return 1
	printf '*.ignored\n' >"$wt_path/.gitignore" || return 1
	printf 'unique ignored\n' >"$wt_path/unique.ignored" || return 1
	archive_path=$(python3 "${SCRIPT_DIR}/../worktree_recovery_producer.py" \
		capture "$wt_path" "$output" test.sh compact-guard-fixture) || return 1
	journals=("$output/.producer-transactions/"*/journal.json)
	[[ "${#journals[@]}" -eq 1 && -f "${journals[0]}" ]] || return 1
	journal_path="${journals[0]}"
	return 0
}

test_compact_archive_retains_source_and_restores_git_only() {
	local repo_path="" wt_path="" archive_path="" journal_path=""
	local restored="${TEST_DIR}/compact-independent-restore"
	local rc=0
	create_compact_removal_fixture compact-success || return 1
	if AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
		"$wt_path" "$archive_path" test.sh compact-test "" false true; then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	jq -e '.source_removal_outcome == "pending"' "$journal_path" >/dev/null || rc=1
	_worktree_recovery_archive_is_valid "$archive_path" || rc=1
	# Git-only archives retain their common-repository dependency, not ignored data.
	bash "${SCRIPT_DIR}/../worktree-archive-helper.sh" restore "$archive_path" --target "$restored" --verification-copy >/dev/null || rc=1
	[[ "$("$GIT_BIN" -C "$restored" show :README.md)" == staged ]] || rc=1
	assert_file_contains "$restored/README.md" '^unstaged$' || rc=1
	[[ ! -e "$restored/unique.ignored" && -f "$wt_path/unique.ignored" ]] || rc=1
	print_result compact_archive_retains_source_and_restores_git_only "$rc" "Expected source retention and a Git-only restoration using the common repository"
	return 0
}

damage_compact_removal_fixture() {
	local mode="$1"
	local admin=""
	case "$mode" in
	source-write) printf 'late ignored\n' >"$wt_path/unique.ignored" || return 1 ;;
	admin-replaced)
		admin=$("$GIT_BIN" -C "$wt_path" rev-parse --absolute-git-dir) || return 1
		mv "$admin" "$admin-original" || return 1
		cp -a "$admin-original" "$admin" || return 1
		;;
	missing-receipt) mv "$journal_path" "$journal_path-missing" || return 1 ;;
	corrupt-receipt) printf '{}\n' >"$journal_path" || return 1 ;;
	corrupt-archive) printf '\n' >>"$archive_path/manifest.json" || return 1 ;;
	current-cwd) cd "$wt_path" || return 1 ;;
	invalid-proof)
		python3 - "$WORKTREE_REGISTRY_DB" "$wt_path" <<'PY' || return 1
from contextlib import closing
import sqlite3
import sys
with closing(sqlite3.connect(sys.argv[1])) as db:
    db.execute("CREATE TABLE IF NOT EXISTS worktree_managed_lifetimes (path TEXT PRIMARY KEY, record TEXT)")
    db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?, ?)", (sys.argv[2], "{}"))
    db.commit()
PY
		;;
	esac
	return 0
}

inject_compact_late_probe() {
	local mode="$1"
	case "$mode" in
	late-write)
		worktree_managed_require_removal_proof() {
			local path="$1"
			printf 'late data\n' >"$path/late.ignored" || return 1
			return 0
		}
		;;
	late-lock)
		_worktree_archive_source_matches() {
			local path="$1" archive="$2"
			_worktree_recovery_producer_command 0 source-matches "$archive" "$path" || return 1
			checks=$((checks + 1))
			if [[ "$checks" -eq 2 ]]; then
				"$GIT_BIN" -C "$path" worktree lock "$path" || return 1
			fi
			return 0
		}
		;;
	esac
	return 0
}

compact_removal_refusal_case() {
	local mode="$1"
	local repo_path="" wt_path="" archive_path="" journal_path=""
	local checks=0
	create_compact_removal_fixture "compact-$mode" || return 1
	damage_compact_removal_fixture "$mode" || return 1
	inject_compact_late_probe "$mode" || return 1
	if AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
		"$wt_path" "$archive_path" test.sh compact-test "" false true; then
		return 1
	fi
	[[ -d "$wt_path" && -d "$archive_path" ]] || return 1
	return 0
}

test_compact_removal_refusals() {
	local mode="" rc=0
	for mode in source-write admin-replaced missing-receipt corrupt-receipt corrupt-archive current-cwd invalid-proof late-write late-lock; do
		rc=0
		(compact_removal_refusal_case "$mode") || rc=$?
		print_result "compact_removal_preserves_$mode" "$rc" "Expected the source and archive to remain"
	done
	return 0
}

test_recovery_archive_preserves_index_and_dirty_files() {
	local repo_path="${TEST_DIR}/archive-dirty-repo"
	local wt_path="${TEST_DIR}/archive-dirty-worktree"
	local trash_root="${TEST_DIR}/archive-dirty-trash"
	local archive_path=""
	local restored="${TEST_DIR}/archive-dirty-restored"
	local expected_status=""
	local actual_status=""
	local expected_head=""
	local actual_head=""
	local recorded_branch=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-dirty" || rc=1
	printf 'staged state\n' >>"$wt_path/README.md" || rc=1
	"$GIT_BIN" -C "$wt_path" add README.md || rc=1
	printf 'unstaged state\n' >>"$wt_path/README.md" || rc=1
	printf 'untracked state\n' >"$wt_path/untracked.txt" || rc=1
	printf '{}\n' >"$wt_path/manifest.json" || rc=1
	expected_status=$("$GIT_BIN" -C "$wt_path" status --porcelain=v1 --untracked-files=all) || rc=1
	expected_head=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "dirty-archive" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	if AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "dirty-archive" \
		"recovery_path=archive-first" "false" "true"; then
		rc=1
	fi
	bash "${SCRIPT_DIR}/../worktree-archive-helper.sh" restore "$archive_path" --target "$restored" --verification-copy >/dev/null || rc=1
	actual_status=$("$GIT_BIN" -C "$restored" status --porcelain=v1 --untracked-files=all) || rc=1
	actual_head=$("$GIT_BIN" -C "$restored" rev-parse --verify HEAD) || rc=1
	recorded_branch=$(jq -r '.branch' "$archive_path/manifest.json") || rc=1
	[[ -d "$wt_path" && "$actual_status" == "$expected_status" ]] || rc=1
	[[ "$actual_head" == "$expected_head" ]] || rc=1
	[[ "$recorded_branch" == "feature/archive-dirty" ]] || rc=1
	[[ "$("$GIT_BIN" -C "$wt_path" symbolic-ref -q HEAD)" == "refs/heads/feature/archive-dirty" ]] || rc=1
	print_result "recovery_archive_preserves_index_and_dirty_files" "$rc" \
		"Expected source retention, original branch metadata, and exact index/dirty restoration"
	return 0
}

test_recovery_archive_preserves_detached_head_identity() {
	local repo_path="${TEST_DIR}/archive-detached-repo"
	local wt_path="${TEST_DIR}/archive-detached-worktree"
	local trash_root="${TEST_DIR}/archive-detached-trash"
	local archive_path=""
	local restored="${TEST_DIR}/archive-detached-restored"
	local expected_head=""
	local actual_head=""
	local recorded_branch=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-detached" || rc=1
	"$GIT_BIN" -C "$wt_path" checkout -q --detach || rc=1
	expected_head=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "detached-archive" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	if AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "detached-archive" \
		"recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	bash "${SCRIPT_DIR}/../worktree-archive-helper.sh" restore "$archive_path" --target "$restored" --verification-copy >/dev/null || rc=1
	actual_head=$("$GIT_BIN" -C "$restored" rev-parse --verify HEAD) || rc=1
	recorded_branch=$(jq -r '.branch' "$archive_path/manifest.json") || rc=1
	[[ -d "$wt_path" && "$actual_head" == "$expected_head" && "$recorded_branch" == "detached" ]] || rc=1
	if "$GIT_BIN" -C "$restored" symbolic-ref -q HEAD >/dev/null 2>&1; then
		rc=1
	fi
	print_result "recovery_archive_preserves_detached_head_identity" "$rc" \
		"Expected source retention and detached identity/HEAD to survive restoration"
	return 0
}

# =============================================================================
# The archive and final removal must refer to the same source/admin identity.
# Replacing the registered worktree at the same pathname must fail closed.
# =============================================================================
test_recoverable_archive_refuses_replacement_worktree() {
	local log_file="${TEST_DIR}/archive-replacement.log"
	local repo_path="${TEST_DIR}/archive-replacement-repo"
	local wt_path="${TEST_DIR}/archive-replacement-worktree"
	local trash_root="${TEST_DIR}/archive-replacement-trash"
	local archive_path=""
	local metadata=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-original" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "replacement-test" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	"$GIT_BIN" -C "$repo_path" worktree remove "$wt_path" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "feature/archive-replacement" "$wt_path" main || rc=1
	if AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "replacement-test" \
		"recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	[[ -d "$wt_path" && -d "$archive_path" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "branch refs/heads/feature/archive-replacement" || rc=1
	assert_file_contains "$log_file" "git-worktree-identity-changed.*mode=skipped" || rc=1
	print_result "recoverable_archive_refuses_replacement_worktree" "$rc" \
		"Expected replacement identity to preserve both replacement and archive"
	return 0
}

test_recoverable_archive_does_not_execute_legacy_remove_wrapper() {
	local log_file="${TEST_DIR}/archive-late-write.log"
	local repo_path="${TEST_DIR}/archive-late-write-repo"
	local wt_path="${TEST_DIR}/archive-late-write-worktree"
	local trash_root="${TEST_DIR}/archive-late-write-trash"
	local wrapper_path="${TEST_DIR}/archive-late-write-git"
	local marker_path="${TEST_DIR}/archive-late-write-injected"
	local archive_path=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-late-write" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "late-write-test" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	cat >"$wrapper_path" <<'LATE_WRITE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${LATE_WRITE_MARKER:?}" ]]; then
	printf 'late state\n' >"${LATE_WRITE_WORKTREE:?}/late-write.txt" || exit 1
	: >"$LATE_WRITE_MARKER"
fi
exec "${REAL_GIT:?}" "$@"
LATE_WRITE_GIT
	chmod +x "$wrapper_path" || rc=1
	if REAL_GIT="$GIT_BIN" LATE_WRITE_MARKER="$marker_path" \
		LATE_WRITE_WORKTREE="$wt_path" AIDEVOPS_REAL_GIT_BIN="$wrapper_path" \
		with_complete_cwd_snapshot remove_archived_worktree_path "$wt_path" "$archive_path" "test.sh" \
		"late-write-test" "recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	[[ -d "$wt_path" && -f "$archive_path/manifest.json" && ! -e "$marker_path" ]] || rc=1
	[[ ! -e "$wt_path/late-write.txt" ]] || rc=1
	print_result "recoverable_archive_does_not_execute_legacy_remove_wrapper" "$rc" \
		"Expected source/archive retention and no legacy native-removal invocation"
	return 0
}

test_removal_helpers_refuse_direct_symlink_alias() {
	local log_file="${TEST_DIR}/symlink-alias.log"
	local repo_path="${TEST_DIR}/symlink-alias-repo"
	local wt_path="${TEST_DIR}/symlink-alias-worktree"
	local alias_path="${TEST_DIR}/symlink-alias"
	local trash_root="${TEST_DIR}/symlink-alias-trash"
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/symlink-alias" || rc=1
	ln -s "$wt_path" "$alias_path" || rc=1
	if remove_worktree_path_permanently "$alias_path" "test.sh" "alias-test"; then
		rc=1
	fi
	if archive_worktree_path_recoverably "$alias_path" "test.sh" "alias-test"; then
		rc=1
	fi
	[[ -L "$alias_path" && -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "git-worktree-identity-changed.*mode=skipped" || rc=1
	print_result "removal_helpers_refuse_direct_symlink_alias" "$rc" \
		"Expected direct symlink aliases to fail before source removal"
	return 0
}

# =============================================================================
# Manual cleanup archives first, removes through native Git, and verifies exact
# metadata absence before ownership is unregistered.
# =============================================================================
test_manual_cleanup_refusal_preserves_receipt_and_registration() {
	local log_file="${TEST_DIR}/manual-archive-cleanup.log"
	local repo_path="${TEST_DIR}/manual-archive-repo"
	local wt_path="${TEST_DIR}/manual-archive-worktree"
	local trash_destination="${TEST_DIR}/manual-archive-trash"
	local unregister_log="${TEST_DIR}/manual-archive-unregister.log"
	local cleanup_receipt_dir="${TEST_DIR}/manual-cleanup-receipts"
	local cleanup_receipt="${TEST_DIR}/manual-cleanup-receipts/example_repo-321.json"
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/manual-archive" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
		unset _FULL_LOOP_CLEANUP_RECEIPT_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		SCRIPT_NAME="worktree-helper.sh"
		_WTAR_WH_CALLER="worktree-helper.sh"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		export AIDEVOPS_REAL_GIT_BIN="$GIT_BIN"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_destination"
		export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir"
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		full_loop_write_cleanup_deferred example/repo 321 "$wt_path" feature/manual-archive \
			"$$" manual-cleanup-test not-requested >/dev/null
		get_repo_root() {
			printf '%s\n' "$repo_path"
			return 0
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		is_registered_canonical() { return 1; }
		unregister_worktree() {
			local removed_path="$1"
			printf '%s\n' "$removed_path" >>"$unregister_log"
			return 0
		}
		localdev_auto_branch_rm() { return 0; }
		preview_proxy_auto_free() { return 0; }
		_remove_resolve_path() {
			local target="$1"
			printf '%s\n' "$target"
			return 0
		}
		local receipt_before=""
		receipt_before=$("$GIT_BIN" hash-object "$cleanup_receipt") || exit 1
		if cmd_remove "$wt_path" --force; then
			exit 1
		fi
		[[ "$("$GIT_BIN" hash-object "$cleanup_receipt")" == "$receipt_before" ]] || exit 1
	); then
		rc=1
	fi
	[[ -d "$wt_path" && ! -e "$trash_destination" && ! -e "$unregister_log" ]] || rc=1
	"$GIT_BIN" -C "$repo_path" worktree list --porcelain | grep -Fx "worktree $wt_root" >/dev/null || rc=1
	jq -e '.repository == "example/repo" and .pr_number == 321
		and .resource_cleanup_state != "CLEANED"' \
		"$cleanup_receipt" >/dev/null || rc=1
	print_result "manual_cleanup_refusal_preserves_receipt_and_registration" "$rc" \
		"Expected registry refusal without pruning, legacy unregister or a false cleanup receipt"
	return 0
}

# =============================================================================
# Even exact-head merged-PR and legacy lease evidence cannot replace the registry.
# =============================================================================
test_manual_cleanup_rejects_legacy_exact_head_proof() {
	local log_file="${TEST_DIR}/manual-degraded-cleanup.log" repo_path="${TEST_DIR}/manual-degraded-repo"
	local wt_path="${TEST_DIR}/manual-degraded-worktree" trash_destination="${TEST_DIR}/manual-degraded-trash"
	local unregister_log="${TEST_DIR}/manual-degraded-unregister.log" branch_name="feature/manual-degraded"
	local head_sha="" metadata="" rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if (
		cd "$repo_path" || exit 1
		unset _WORKTREE_CMDS_LIB_LOADED _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		SCRIPT_NAME="worktree-helper.sh"
		_WTAR_WH_CALLER="worktree-helper.sh"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		export AIDEVOPS_REAL_GIT_BIN="$GIT_BIN"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_destination"
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		get_repo_root() {
			printf '%s\n' "$repo_path"
			return 0
		}
		worktree_removal_guard() {
			local candidate="$1"
			local caller="$2"
			local reason="$3"
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			: "$candidate" "$caller" "$reason"
			return 2
		}
		worktree_has_changes() {
			local candidate="$1"
			[[ -n "$("$GIT_BIN" -C "$candidate" status --porcelain 2>/dev/null)" ]]
			return $?
		}
		is_registered_canonical() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		is_worktree_owned_by_others_for_pid() { return 1; }
		worktree_has_exact_owner_contract() { return 0; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$head_sha"
				;;
			*"--state open"*) printf '%s\n' '[]' ;;
			*) return 1 ;;
			esac
			return 0
		}
		_clean_acquire_removal_lease() {
			local candidate="$1"
			local branch="$2"
			: "$candidate" "$branch"
			return 0
		}
		unregister_worktree_if_owner_pid() { return 0; }
		unregister_worktree_if_owner_contract() {
			local candidate="$1"
			unregister_worktree "$candidate"
			return 0
		}
		unregister_worktree() {
			local removed_path="$1"
			printf '%s\n' "$removed_path" >>"$unregister_log"
			return 0
		}
		localdev_auto_branch_rm() { return 0; }
		preview_proxy_auto_free() { return 0; }
		_remove_resolve_path() {
			local target="$1"
			printf '%s\n' "$target"
			return 0
		}
		cmd_remove "$wt_path" --force
	); then
		rc=1
	fi
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	[[ -d "$wt_path" && ! -e "$trash_destination" && ! -e "$unregister_log" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fx "branch refs/heads/${branch_name}" >/dev/null || rc=1
	"$GIT_BIN" -C "$repo_path" show-ref --verify --quiet "refs/heads/${branch_name}" || rc=1
	print_result "manual_cleanup_rejects_legacy_exact_head_proof" "$rc" \
		"Expected registry refusal despite legacy merged proof, with source/branch retained"
	return 0
}

# =============================================================================
# A degraded cleanup lease is owned by the leaf executor PID, not the stable
# runtime PID used by generic interactive ownership checks. Rechecks after lease
# acquisition require the complete PID/session/task contract and fail closed if
# that evidence is replaced, deleted, or unavailable.
# =============================================================================
test_manual_degraded_recheck_requires_live_exact_lease() {
	local repo_path="${TEST_DIR}/manual-degraded-lease-repo"
	local wt_path="${TEST_DIR}/manual-degraded-lease-worktree"
	local registry_dir="${TEST_DIR}/manual-degraded-lease-registry"
	local branch_name="feature/manual-degraded-lease"
	local head_sha=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED _WORKTREE_CLEAN_LIB_LOADED \
			_SHARED_WORKTREE_REGISTRY_LOADED 2>/dev/null || true
		export WORKTREE_REGISTRY_DIR="$registry_dir"
		export WORKTREE_REGISTRY_DB="${registry_dir}/worktree-registry.db"
		# shellcheck source=../shared-worktree-registry.sh
		source "$REGISTRY_HELPER"
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		sleep 30 &
		local runtime_pid=$!
		# Expand now: Bash 3.2 runs a subshell EXIT trap after function locals
		# are gone, so a deferred "$runtime_pid" is unbound under set -u.
		# shellcheck disable=SC2064
		trap "kill ${runtime_pid} 2>/dev/null || true" EXIT
		export OPENCODE_PID="$runtime_pid"
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$head_sha"
				;;
			*"--state open"*) printf '%s\n' '[]' ;;
			*) return 1 ;;
			esac
			return 0
		}
		export WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		_clean_acquire_removal_lease "$wt_path" "$branch_name" || exit 1
		is_worktree_owned_by_others "$wt_path" || exit 1
		if is_worktree_owned_by_others_for_pid "$wt_path" "$$"; then
			exit 1
		fi
		_remove_degraded_fallback_allowed "$wt_path" "$$" || exit 1

		local registry_path=""
		registry_path=$(_wt_registry_lookup_path "$wt_path") || exit 1
		sqlite3 "$WORKTREE_REGISTRY_DB" "
			UPDATE worktree_owners
			SET owner_session = 'cleanup-replaced'
			WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
		" || exit 1
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi

		sqlite3 "$WORKTREE_REGISTRY_DB" "
			DELETE FROM worktree_owners
			WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
		" || exit 1
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi

		WORKTREE_REGISTRY_DB="${registry_dir}/missing.db"
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi
		exit 0
	); then
		rc=1
	fi
	print_result "manual_degraded_recheck_requires_live_exact_lease" "$rc" \
		"Expected post-lease checks to accept only the live exact PID/session/task contract"
	return 0
}

test_manual_degraded_recovery_rejects_unsafe_candidates() {
	local repo_path="${TEST_DIR}/manual-degraded-refusal-repo"
	local wt_path="${TEST_DIR}/manual-degraded-refusal-worktree"
	local branch_name="feature/manual-degraded-refusal"
	local head_sha=""
	local proof_mode="head-mismatch"
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		RED="" NC=""
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		worktree_has_changes() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			local proof_head="$head_sha"
			[[ "$proof_mode" != "head-mismatch" ]] || proof_head="0000000000000000000000000000000000000000"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$proof_head"
				;;
			*"--state open"*)
				if [[ "$proof_mode" == "open-pr" ]]; then
					printf '[{"number":43,"headRefName":"%s","headRefOid":"%s"}]\n' "$branch_name" "$head_sha"
				else
					printf '%s\n' '[]'
				fi
				;;
			*) return 1 ;;
			esac
			return 0
		}
		WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		proof_mode="open-pr"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		printf 'dirty\n' >"${wt_path}/untracked.txt"
		worktree_has_changes() {
			local candidate="$1"
			[[ -n "$("$GIT_BIN" -C "$candidate" status --porcelain 2>/dev/null)" ]]
			return $?
		}
		proof_mode="valid"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		exit 0
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	print_result "manual_degraded_recovery_rejects_unsafe_candidates" "$rc" \
		"Expected head mismatch, open PR, and dirty state to fail closed"
	return 0
}

# GH#34488: a local_only repo (no origin, registered in repos.json) accepts
# local default-branch ancestry as degraded-visibility merge proof; unmerged
# and dirty candidates still fail closed.
test_local_only_degraded_recovery_uses_ancestry() {
	local repo_path="${TEST_DIR}/local-only-degraded-repo"
	local wt_path="${TEST_DIR}/local-only-degraded-worktree"
	local branch_name="feature/local-only-degraded"
	local repos_json="${TEST_DIR}/local-only-repos.json"
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	printf '{"initialized_repos":[{"path":"%s","local_only":true}]}\n' "$repo_path" >"$repos_json" || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		RED="" NC=""
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		export AIDEVOPS_REPOS_JSON="$repos_json"
		worktree_has_changes() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		_remove_degraded_fallback_allowed "$wt_path" || exit 1
		[[ "$_WT_REMOVE_DEGRADED_PR" == "local-ancestry" ]] || exit 1
		# Unmerged commit must refuse.
		printf 'more\n' >"${wt_path}/more.txt"
		"$GIT_BIN" -C "$wt_path" add more.txt
		"$GIT_BIN" -C "$wt_path" commit -q -m unmerged || exit 1
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		# Unregistered repo must not use the ancestry path.
		printf '{"initialized_repos":[]}\n' >"$repos_json"
		"$GIT_BIN" -C "$wt_path" reset -q --hard main || exit 1
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		exit 0
	); then
		rc=1
	fi
	print_result "local_only_degraded_recovery_uses_ancestry" "$rc" \
		"Expected local_only ancestry proof to allow only merged candidates"
	return 0
}

# =============================================================================
# A recoverable caller cannot rely on stale guard evidence. If a foreign lock
# exists when archive preparation starts, source removal must not start.
# =============================================================================
test_recoverable_cleanup_preserves_lock_acquired_after_guard() {
	local log_file="${TEST_DIR}/recoverable-race-cleanup.log"
	local repo_path="${TEST_DIR}/recoverable-race-repo"
	local wt_path="${TEST_DIR}/recoverable-race-worktree"
	local wt_root=""
	local metadata=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/recoverable-race" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "foreign-race-lock" "$wt_path" || rc=1
	if (
		unset _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${CLEAN_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		_WTAR_WH_CALLER="test.sh"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		worktree_removal_guard() {
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			return 2
		}
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_clean_has_exact_removal_lease() { return 0; }
		_clean_remove_classified_worktree "$wt_path" "feature/recoverable-race" \
			"false" "false" "test=context" "$repo_path" \
			"$_WT_CLEAN_MODE_RECOVERABLE" "true"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-worktree-locked.*mode=skipped" || rc=1
	print_result "recoverable_cleanup_preserves_lock_acquired_after_guard" "$rc" \
		"Expected archive preparation to preserve a lock after a stale guard"
	return 0
}

# =============================================================================
# Recoverable cleanup must retain both source and completed archive if its exact
# lease disappears while the archive copy is in progress.
# =============================================================================
test_recoverable_cleanup_preserves_lease_loss_after_archive() {
	local log_file="${TEST_DIR}/recoverable-lease-race-cleanup.log"
	local repo_path="${TEST_DIR}/recoverable-lease-race-repo"
	local wt_path="${TEST_DIR}/recoverable-lease-race-worktree"
	local trash_root="${TEST_DIR}/recoverable-lease-race-trash"
	local metadata=""
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/recoverable-lease-race" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if (
		unset _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${CLEAN_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		_WTAR_WH_CALLER="test.sh"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		worktree_removal_guard() {
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			return 2
		}
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		local lease_checks=0
		_clean_has_exact_removal_lease() {
			lease_checks=$((lease_checks + 1))
			[[ "$lease_checks" -eq 1 ]]
			return $?
		}
		_clean_remove_classified_worktree "$wt_path" "feature/recoverable-lease-race" \
			"false" "false" "test=context" "$repo_path" \
			"$_WT_CLEAN_MODE_RECOVERABLE" "true"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	jq -e '.phase == "archived" and .source.capture_policy == "git-only"
		and .source_removal_outcome == "pending"' \
		"$trash_root"/.producer-transactions/*/journal.json >/dev/null || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cleanup-lease-changed-after-archive.*mode=skipped" || rc=1
	print_result "recoverable_cleanup_preserves_lease_loss_after_archive" "$rc" \
		"Expected source, metadata, and archive retention after cleanup lease replacement; audit: $(cat "$log_file" 2>/dev/null); journal: $(jq -c '{phase, source_removal_outcome}' "$trash_root"/.producer-transactions/*/journal.json 2>/dev/null)"
	return 0
}

# =============================================================================
# Skill-update cleanup must not delete the branch or unregister ownership when
# the guarded permanent-removal primitive refuses the worktree.
# =============================================================================
test_skill_cleanup_has_no_removal_failure_fallback() {
	local wt_path="${TEST_DIR}/skill-fallback-worktree"
	local side_effect_log="${TEST_DIR}/skill-fallback-effects.log"
	local rc=0
	mkdir -p "$wt_path"

	if ! (
		unset _SKILL_UPDATE_PR_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${SKILL_PR_HELPER%/*}"
		_WTAR_SU_CALLER="skill-update-helper.sh"
		# shellcheck source=../skill-update-pr-lib.sh
		source "$SKILL_PR_HELPER"
		get_default_branch() {
			printf '%s\n' "main"
			return 0
		}
		git() {
			local all_args="$*"
			case "$all_args" in
			*"rev-list --count main..HEAD"*) printf '%s\n' "0" ;;
			*"worktree remove"* | *"branch -D"*) printf '%s\n' "$all_args" >>"$side_effect_log" ;;
			*) "$GIT_BIN" "$@" || return $? ;;
			esac
			return 0
		}
		is_worktree_owned_by_others() { return 1; }
		worktree_removal_guard() { return 0; }
		remove_worktree_path_permanently() { return 1; }
		log_info() { return 0; }
		log_warning() { return 0; }
		unregister_worktree() {
			printf '%s\n' "unregister:$1" >>"$side_effect_log"
			return 0
		}
		_cleanup_worktree "$wt_path" "feature/skill-fallback"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	[[ ! -s "$side_effect_log" ]] || rc=1
	print_result "skill_cleanup_has_no_removal_failure_fallback" "$rc" \
		"Expected failed guarded removal to preserve the path, branch, and registry"
	return 0
}

# =============================================================================
# Shared removal guard treats Git worktree locks as a non-overridable safety
# boundary. Direct permanent deletion must not bypass the lock.
# =============================================================================
test_permanent_helper_preserves_git_locked_worktree() {
	local log_file="${TEST_DIR}/locked-cleanup.log"
	local repo_path="${TEST_DIR}/locked-repo"
	local wt_path="${TEST_DIR}/locked-worktree"
	local wt_root=""
	local metadata=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/locked" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "observation-provenance" "$wt_path" || rc=1
	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain 2>/dev/null) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-worktree-locked.*mode=skipped" || rc=1
	print_result "permanent_helper_preserves_git_locked_worktree" "$rc" \
		"Expected locked worktree path and metadata to remain. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Git metadata failures are not evidence that a worktree is unlocked.
# =============================================================================
test_permanent_helper_fails_closed_on_unreadable_git_metadata() {
	local log_file="${TEST_DIR}/unreadable-cleanup.log"
	local wt_path="${TEST_DIR}/unreadable-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"
	printf 'gitdir: unavailable\n' >"${wt_path}/.git"

	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		git() {
			return 1
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "permanent_helper_fails_closed_on_unreadable_git_metadata" "$rc" \
		"Expected unreadable Git metadata to block permanent removal. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# A successful metadata query that omits the exact candidate is ambiguous and
# must not be treated as proof that the candidate is unlocked.
# =============================================================================
test_permanent_helper_fails_closed_on_ambiguous_git_metadata() {
	local log_file="${TEST_DIR}/ambiguous-cleanup.log"
	local wt_path="${TEST_DIR}/ambiguous-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"
	printf 'gitdir: ambiguous\n' >"${wt_path}/.git"

	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		git() {
			local all_args="$*"
			case "$all_args" in
			*"rev-parse --show-toplevel"*) printf '%s\n' "$wt_path" ;;
			*"worktree list --porcelain -z"*)
				printf 'worktree %s\0HEAD 0123456789abcdef0123456789abcdef01234567\0detached\0\0' \
					"${TEST_DIR}/different-worktree"
				;;
			*) return 1 ;;
			esac
			return 0
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "permanent_helper_fails_closed_on_ambiguous_git_metadata" "$rc" \
		"Expected ambiguous Git metadata to block permanent removal. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Verified unlocked worktrees remain eligible for the caller's existing policy.
# =============================================================================
test_guard_allows_verified_unlocked_worktree() {
	local repo_path="${TEST_DIR}/unlocked-repo"
	local wt_path="${TEST_DIR}/unlocked-worktree"
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/unlocked" || rc=1
	if ! (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		worktree_removal_guard "$wt_path" "test.sh" "manual" ""
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	print_result "guard_allows_verified_unlocked_worktree" "$rc" \
		"Expected verified unlocked worktree to pass the shared guard"
	return 0
}

# =============================================================================
# Test 10: optional guard context includes predicates needed for safe cleanup audit
# =============================================================================
test_optional_guard_context_logged() {
	local log_file="${TEST_DIR}/t10-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local context="branch=feature/gh23074 issue=23074 owner_guard=clear process_guard=clear recent_session_guard=clear commits=1 pr_state=none recovery_path=none"
	log_worktree_removal_event "$_WTAR_SKIPPED" "pulse-cleanup.sh" "/wt/context" "local-commits-no-pr" "skipped" "$context"
	local branch_merged_context="target_branch=main merge_proof=merge-base-is-ancestor merge_proof_result=ancestor branch=feature/gh23076 owner_guard=clear protected_status=clear"
	log_worktree_removal_event "$_WTAR_REMOVED" "worktree-helper.sh" "/wt/merged" "branch-merged" "permanent" "$branch_merged_context"

	local rc=0
	assert_file_contains "$log_file" "worktree-skipped.*local-commits-no-pr.*mode=skipped.*branch=feature/gh23074.*owner_guard=clear.*process_guard=clear.*recent_session_guard=clear.*commits=1.*pr_state=none.*recovery_path=none" || rc=1
	assert_file_contains "$log_file" "worktree-removed.*branch-merged.*mode=permanent.*target_branch=main.*merge_proof=merge-base-is-ancestor.*merge_proof_result=ancestor.*protected_status=clear" || rc=1
	print_result "optional_guard_context_logged" "$rc" \
		"Expected guard context audit. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Guard refusals expose a machine-readable reason without changing the
# exactly-once audit contract.
# =============================================================================
test_guard_reason_is_machine_readable() {
	local log_file="${TEST_DIR}/t15-cleanup.log"
	local wt_path="${TEST_DIR}/reason-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path"; then
		rc=1
	fi
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_line_count "$log_file" 1 || rc=1
	print_result "guard_reason_is_machine_readable" "$rc" \
		"Expected active-cwd reason and exactly one audit row"
	return 0
}

# =============================================================================
# Test 16: manual removal renders safe actionable diagnostics for each shared
# guard reason. The guard remains the sole audit writer.
# =============================================================================
test_manual_guard_refusal_diagnostics() {
	local output_file="${TEST_DIR}/t16-output.log"
	local log_file="${TEST_DIR}/t16-cleanup.log"
	local rc=0
	local reason=""
	local guard_reason_to_test=""
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
	RED=""
	NC=""
	# shellcheck source=../worktree-helper-cmds.sh
	source "$COMMANDS_HELPER"
	worktree_removal_guard() {
		local path_to_remove="$1"
		local caller="$2"
		local removal_mode="$3"
		WORKTREE_REMOVAL_GUARD_REASON="$guard_reason_to_test"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$path_to_remove" \
			"$guard_reason_to_test" "skipped"
		: "$removal_mode"
		return 1
	}
	for reason in active-cwd current-worktree canonical-skip git-worktree-locked git-metadata-unreadable; do
		guard_reason_to_test="$reason"
		if _remove_validate_path "/safe/example-worktree" 2>>"$output_file"; then
			rc=1
		fi
	done
	assert_file_contains "$output_file" "Reason: active-cwd.*live process" || rc=1
	assert_file_contains "$output_file" "Reason: current-worktree.*inside the target" || rc=1
	assert_file_contains "$output_file" "Reason: canonical-skip.*canonical checkout" || rc=1
	assert_file_contains "$output_file" "Reason: git-worktree-locked.*explicitly locked" || rc=1
	assert_file_contains "$output_file" "Reason: git-metadata-unreadable.*could not prove" || rc=1
	assert_file_contains "$output_file" "cannot bypass this protection" || rc=1
	assert_line_count "$log_file" 5 || rc=1
	print_result "manual_guard_refusal_diagnostics" "$rc" \
		"Expected safe diagnostics and exactly one audit row per refusal"
	return 0
}

# =============================================================================
# Archive publication uses the same exclusive producer lock as recovery apply.
# =============================================================================
test_recoverable_archive_honours_shared_producer_lock() {
	local repo_path="${TEST_DIR}/producer-lock-repo"
	local wt_path="${TEST_DIR}/producer-lock-worktree"
	local recovery_root="${TEST_DIR}/producer-lock-recovery"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"
	local process_lstart=""
	local archive_path=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/producer-lock" || rc=1
	mkdir -p "$recovery_root" "$lock_path" || rc=1
	process_lstart=$(_worktree_recovery_process_lstart "$$") || rc=1
	printf '%s\n' "$$" >"$lock_path/pid" || rc=1
	printf '%s\n' "$process_lstart" >"$lock_path/lstart" || rc=1
	printf '%s\n' "archive-lock-fixture" >"$lock_path/token" || rc=1
	printf '%s\n' "complete" >"$lock_path/initialized" || rc=1
	if AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "producer-lock"; then
		rc=1
	fi
	[[ -d "$wt_path" && -d "$lock_path" ]] || rc=1
	[[ ! -e "$recovery_root/.producer-transactions" ]] || rc=1
	if compgen -G "${recovery_root}/aidevops-worktree-cleanup-*" >/dev/null; then rc=1; fi
	rm -f "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" "$lock_path/initialized" || rc=1
	rmdir "$lock_path" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "producer-lock" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ -f "$archive_path/manifest.json" && ! -e "$lock_path" ]] || rc=1
	_worktree_recovery_archive_is_valid "$archive_path" || rc=1
	print_result "recoverable_archive_honours_shared_producer_lock" "$rc" \
		"Expected a live apply-compatible lock to block compact capture through receipt verification"
	return 0
}

test_archive_copy_filters_before_io_and_bounds_retries() {
	local repo_path="${TEST_DIR}/filtered-copy-repo"
	local wt_path="${TEST_DIR}/filtered-copy-source"
	local first_archive=""
	local rc=0
	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/filtered-copy" || rc=1
	python3 - "$SCRIPT_DIR/.." "$wt_path" "$TEST_DIR" "$GIT_BIN" <<'PY' || rc=1
import hashlib
import pathlib
import subprocess
import sys
sys.path.insert(0, sys.argv[1])
from worktree_recovery_archive_copy import copy_without_caches, reserve_archive

source, scratch, git = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]
(source / '.gitignore').write_text('node_modules/\n.next/\n.env\n')
(source / 'node_modules').mkdir()
(source / 'node_modules' / 'regenerable').write_text('cache')
(source / '.next' / 'cache').mkdir(parents=True)
(source / '.next' / 'cache' / 'regenerable').write_text('cache')
(source / '.next' / 'user-note').write_text('preserve unknown ignored content')
(source / '.env').write_text('fixture data, not a credential')
destination = scratch / 'filtered-copy'
copy_without_caches(source, destination, git)
assert not (destination / 'node_modules').exists()
assert not (destination / '.next' / 'cache').exists()
assert (destination / '.next' / 'user-note').read_bytes() == (source / '.next' / 'user-note').read_bytes()
assert (destination / '.env').read_bytes() == (source / '.env').read_bytes()

# A tracked file makes the entire otherwise recognised directory protected.
subprocess.run([git, '-C', str(source), 'add', '-f', 'node_modules/regenerable'], check=True)
protected = scratch / 'protected-copy'
copy_without_caches(source, protected, git)
assert (protected / 'node_modules' / 'regenerable').is_file()

store = scratch / 'bounded-attempts'
store.mkdir()
bucket = pathlib.Path(reserve_archive(source, store, git))
for _ in range(3):
    try:
        reserve_archive(source, store, git)
    except ValueError as error:
        assert 'recovery-archive-incomplete' in str(error)
    else:
        raise AssertionError('interrupted attempt must block another copy')
# reserve_archive resolves the store, but glob retains the caller's path spelling
# (e.g. /var vs /private/var on macOS). Compare identities, not spellings.
buckets = list(store.glob('aidevops-worktree-cleanup-*'))
assert [path.resolve() for path in buckets] == [bucket.resolve()], (buckets, bucket)
# Exercise the same alias discrepancy on Linux, where /var is not a symlink.
alias = scratch / 'bounded-attempts-alias'
alias.symlink_to(store, target_is_directory=True)
alias_buckets = list(alias.glob('aidevops-worktree-cleanup-*'))
assert alias_buckets != [bucket], (alias_buckets, bucket)
assert [path.resolve() for path in alias_buckets] == [bucket.resolve()], (alias_buckets, bucket)
PY
	_test_missing_reservation_review "$wt_path" "$TEST_DIR" "$GIT_BIN" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_DIR}/reuse-completed" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "reuse-test" || rc=1
	first_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_DIR}/reuse-completed" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "reuse-test" || rc=1
	[[ "$first_archive" == "$WORKTREE_RECOVERABLE_ARCHIVE_PATH" ]] || rc=1
	printf 'new user data\n' >"$wt_path/new-user-note"
	if AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_DIR}/reuse-completed" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "reuse-test"; then
		rc=1
	fi
	[[ -f "$wt_path/new-user-note" && ! -e "$first_archive/new-user-note" ]] || rc=1
	print_result "archive_copy_filters_before_io_and_bounds_retries" "$rc" \
		"Expected cache exclusion before copy, preservation of user/tracked data, and bounded retries"
	return 0
}

_test_missing_reservation_review() {
	local source_path="$1"
	local scratch="$2"
	local git_bin="$3"
	python3 - "$SCRIPT_DIR/.." "$source_path" "$scratch" "$git_bin" <<'PY' || return 1
import hashlib
import pathlib
import sys
sys.path.insert(0, sys.argv[1])
from worktree_recovery_archive_copy import reserve_archive
source, store, git = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]) / 'bounded-attempts', sys.argv[4]
bucket = next(store.glob('aidevops-worktree-cleanup-*')).resolve()
# A vanished bucket does not authorize replacement of its reservation.
# Reproduce the reference host's failure without touching a real archive.
reservation = next(store.glob('.archive-attempt-*.json'))
reservation_before = reservation.read_bytes()
bucket.rmdir()
try:
    reserve_archive(source, store, git)
except ValueError as error:
    assert 'archive bucket unavailable' in str(error)
else:
    raise AssertionError('missing archive must remain an explicit review boundary')
assert reservation.read_bytes() == reservation_before
assert not list(store.glob('aidevops-worktree-cleanup-*'))
assert source.is_dir()
PY
	return 0
}

test_recovery_store_permission_preflight() {
	local wt_path="${TEST_DIR}/permission-source"
	local recovery_root="${TEST_DIR}/permission-store"
	local log_file="${TEST_DIR}/permission-audit.log"
	local output_file="${TEST_DIR}/permission-error.log"
	local rc=0
	local expected=""
	local probe_mode=""
	mkdir -p "$wt_path" || rc=1
	# Execute the real probe with deterministic OS responses, including on root CI.
	for probe_mode in unwritable privilege; do
		if (
			python3() {
				command python3 -c '
import os, sys
from types import SimpleNamespace
mode = sys.argv.pop(1)
sys.argv = sys.argv[1:]
if mode == "unwritable":
    os.geteuid = lambda: 12345
    os.access = lambda *args, **kwargs: False
else:
    os.geteuid = lambda: 0
    original_stat = os.stat
    os.stat = lambda path, *args, **kwargs: SimpleNamespace(st_uid=12345) if path == sys.argv[1] else original_stat(path, *args, **kwargs)
exec(compile(sys.stdin.read(), "recovery-probe", "exec"))
' "$probe_mode" "$@"
			}
			AIDEVOPS_CLEANUP_LOG="$log_file" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
				archive_worktree_path_recoverably "$wt_path" "test.sh" "permission-test"
		) 2>>"$output_file"; then
			rc=1
		fi
	done
	for expected in recovery-store-not-writable recovery-privilege-mismatch; do
		assert_file_contains "$log_file" "$expected" || rc=1
		assert_file_contains "$output_file" "$expected" || rc=1
	done
	[[ -d "$wt_path" && ! -e "$recovery_root" ]] || rc=1
	print_result "recovery_store_permission_preflight" "$rc" \
		"Expected actionable refusal before creating storage or changing source"
	return 0
}
