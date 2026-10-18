#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Read-only planning, evidence classification, and archive cache policy.
# Sourced by test-worktree-recovery-lifecycle.sh; uses its shared fixtures.

[[ -n "${_TEST_WT_RECOVERY_PLAN_LOADED:-}" ]] && return 0
_TEST_WT_RECOVERY_PLAN_LOADED=1

test_exact_plan_writes_candidate_without_mutation() {
	local home_path="${TEST_DIR}/candidate-home"
	local repo_path="${TEST_DIR}/candidate-repo"
	local worktree_path="${TEST_DIR}/candidate-worktree"
	local recovery_root="${home_path}/recovery"
	local output_path="${TEST_DIR}/candidate-plan.json"
	local second_output_path="${TEST_DIR}/candidate-plan-second.json"
	local archive_path="" marker_path="" marker_digest_before="" marker_digest_after=""
	local bucket_path="" tree_digest_before="" tree_digest_after=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh29388-recovery-plan") || rc=1
	"$GIT_BIN" -C "$archive_path" remote add origin \
		"https://github.com/example/repo.git" || rc=1
	marker_path="${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}"
	bucket_path="${archive_path%/*}"
	marker_digest_before=$(_worktree_recovery_plan_sha256_file "$marker_path") || rc=1
	tree_digest_before=$(archive_tree_digest "$bucket_path") || rc=1
	install_external_evidence_stub
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$output_path" >/dev/null || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$second_output_path" >/dev/null || rc=1
	marker_digest_after=$(_worktree_recovery_plan_sha256_file "$marker_path") || rc=1
	tree_digest_after=$(archive_tree_digest "$bucket_path") || rc=1
	[[ "$marker_digest_before" == "$marker_digest_after" ]] || rc=1
	[[ "$tree_digest_before" == "$tree_digest_after" ]] || rc=1
	[[ ! -e "$worktree_path" && -d "$archive_path" ]] || rc=1
	jq -e --arg archive "$archive_path" '
		.schema == "aidevops.worktree-recovery-plan/v2" and .producer == "worktree-helper" and
		.read_only == true and .inventory_complete == true and .inventory_error == null and
		(.source_roots | length == 1) and .entry_count == 1 and
		.sized_entry_count == 1 and .unavailable_size_count == 0 and
		.candidate_count == 1 and .protected_count == 0 and .unknown_count == 0 and
		(.candidate_bytes > 0) and .candidate_bytes == .expected_allocated_bytes and
		(.plan_id | startswith("sha256:")) and
		(.confirmation_token | startswith("apply-sha256:")) and
		(.entries | length == 1) and .entries[0].archive_path == $archive and
		.entries[0].disposition == "candidate" and
		.entries[0].expected_allocated_bytes > 0 and
		(.entries[0].identity.identity_digest | startswith("sha256:")) and
		(.entries[0].identity.index_digest | startswith("sha256:"))
	' "$output_path" >/dev/null || rc=1
	[[ "$(jq -cS '.entries' "$output_path")" == "$(jq -cS '.entries' "$second_output_path")" ]] || rc=1
	[[ "$(jq -r '.plan_id' "$output_path")" == "$(jq -r '.plan_id' "$second_output_path")" ]] || rc=1
	print_result "exact_plan_writes_candidate_without_mutation" "$rc" \
		"Expected one identity-bound candidate and unchanged recovery evidence"
	return 0
}

test_git_state_detects_recovery_data() {
	local home_path="${TEST_DIR}/dirty-home"
	local repo_path="${TEST_DIR}/dirty-repo"
	local worktree_path="${TEST_DIR}/dirty-worktree"
	local recovery_root="${home_path}/recovery"
	local archive_path="" identity="" state=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh29388-dirty-plan") || rc=1
	identity=$(_worktree_recovery_plan_identity_json "${archive_path%/*}") || rc=1
	printf 'changed\n' >"${archive_path}/README.md" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	"$GIT_BIN" -C "$archive_path" checkout -q -- README.md || rc=1
	printf 'untracked\n' >"${archive_path}/unique.bin" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	rm -f "${archive_path}/unique.bin"
	printf '*.cache\n' >>"${repo_path}/.git/info/exclude" || rc=1
	printf 'ignored\n' >"${archive_path}/unique.cache" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	rm -f "${archive_path}/unique.cache"
	printf 'node_modules/\nprivate-artifact/\n' >>"${repo_path}/.git/info/exclude" || rc=1
	mkdir -p "${archive_path}/node_modules/package" || rc=1
	printf 'regenerable\n' >"${archive_path}/node_modules/package/cache.bin" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || rc=1
	mkdir -p "${archive_path}/private-artifact" || rc=1
	printf 'preserve\n' >"${archive_path}/private-artifact/user.bin" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	print_result "git_state_detects_recovery_data" "$rc" \
		"Expected tracked, untracked, and user ignored data to veto candidates while recognised caches remain clear"
	return 0
}

test_cache_policy_recognises_python_and_root_codegraph_only() {
	local archive_path="${TEST_DIR}/cache-status-archive"
	local status_path="${TEST_DIR}/cache-status.bin"
	local symlink_target="${TEST_DIR}/cache-status-symlink-target"
	local policy_status=0
	local rc=0

	"$GIT_BIN" init -q -b main "$archive_path" || rc=1
	mkdir -p "${archive_path}/backend/__pycache__" \
		"${archive_path}/backend/.pytest_cache" "${archive_path}/.codegraph" \
		"${archive_path}/nested/.codegraph" "$symlink_target" || rc=1
	printf '!! backend/__pycache__/module.pyc\0!! backend/.pytest_cache/state\0!! .codegraph/codegraph.db\0' \
		>"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 1 ]] || rc=1
	policy_status=0
	_worktree_recovery_cache_policy "status" "$status_path" "$archive_path" \
		"${TEST_DIR}/missing-git" || policy_status=$?
	[[ "$policy_status" -eq 2 ]] || rc=1
	printf '!! nested/.codegraph/codegraph.db\0' >"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 0 ]] || rc=1
	rm -rf "${archive_path}/.codegraph" || rc=1
	ln -s "$symlink_target" "${archive_path}/.codegraph" || rc=1
	printf '!! .codegraph/codegraph.db\0' >"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 0 ]] || rc=1
	printf '!! logs/diagnostic.log\0' >"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 0 ]] || rc=1
	print_result "cache_policy_recognises_python_and_root_codegraph_only" "$rc" \
		"Expected Python and root CodeGraph caches to be regenerable while nested CodeGraph, symlinks, and logs remain protected"
	return 0
}

test_git_state_protects_tracked_regenerable_cache_roots() {
	local cache_path="" repo_path="" identity="" state=""
	local rc=0

	for cache_path in ".codegraph" "backend/__pycache__" "backend/.pytest_cache"; do
		repo_path="${TEST_DIR}/tracked-status-${cache_path//\//-}"
		"$GIT_BIN" init -q -b main "$repo_path" || rc=1
		"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || rc=1
		"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || rc=1
		"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || rc=1
		printf '%s/\n' "$cache_path" >>"${repo_path}/.git/info/exclude" || rc=1
		mkdir -p "${repo_path}/${cache_path}" || rc=1
		printf 'tracked configuration\n' >"${repo_path}/${cache_path}/config.json" || rc=1
		"$GIT_BIN" -C "$repo_path" add -f "${cache_path}/config.json" || rc=1
		"$GIT_BIN" -C "$repo_path" commit -q -m init || rc=1
		printf 'generated cache\n' >"${repo_path}/${cache_path}/generated.bin" || rc=1
		identity=$(jq -cn --arg archive_path "$repo_path" '{archive_path:$archive_path}') || rc=1
		state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
		[[ "$state" == "dirty" ]] || rc=1
	done
	print_result "git_state_protects_tracked_regenerable_cache_roots" "$rc" \
		"Expected tracked content to keep every newly recognised cache identity protected"
	return 0
}

test_archive_prunes_only_regenerable_ignored_caches() {
	local repo_path="${TEST_DIR}/cache-policy-repo"
	local worktree_path="${TEST_DIR}/cache-policy-worktree"
	local recovery_root="${TEST_DIR}/cache-policy-recovery"
	local archive_path="" identity="" state=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	create_unarchived_fixture "$repo_path" "$worktree_path" \
		"bugfix/gh30931-cache-policy" || rc=1
	printf 'node_modules/\n__pycache__/\n.pytest_cache/\n/.codegraph/\nnested/.codegraph/\nprivate-artifact/\n' \
		>>"${repo_path}/.git/info/exclude" || rc=1
	mkdir -p "${worktree_path}/node_modules/package" \
		"${worktree_path}/backend/__pycache__" "${worktree_path}/backend/.pytest_cache" \
		"${worktree_path}/.codegraph" "${worktree_path}/nested/.codegraph" \
		"${worktree_path}/private-artifact" || rc=1
	python3 - "${worktree_path}/node_modules/package/large-cache.bin" <<'PY' || rc=1
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"x" * 2 * 1024 * 1024)
PY
	printf 'bytecode\n' >"${worktree_path}/backend/__pycache__/module.pyc" || rc=1
	printf 'pytest\n' >"${worktree_path}/backend/.pytest_cache/state" || rc=1
	printf 'graph\n' >"${worktree_path}/.codegraph/codegraph.db" || rc=1
	printf 'nested graph\n' >"${worktree_path}/nested/.codegraph/codegraph.db" || rc=1
	printf 'user-evidence\n' >"${worktree_path}/private-artifact/user.bin" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$worktree_path" "test.sh" "cache-policy" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ ! -e "${archive_path}/node_modules" ]] || rc=1
	[[ ! -e "${archive_path}/backend/__pycache__" ]] || rc=1
	[[ ! -e "${archive_path}/backend/.pytest_cache" ]] || rc=1
	[[ ! -e "${archive_path}/.codegraph" ]] || rc=1
	[[ -f "${archive_path}/nested/.codegraph/codegraph.db" ]] || rc=1
	[[ -f "${archive_path}/private-artifact/user.bin" ]] || rc=1
	identity=$(_worktree_recovery_plan_identity_json "${archive_path%/*}") || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	print_result "archive_prunes_only_regenerable_ignored_caches" "$rc" \
		"Expected large dependency caches to be omitted while ignored user evidence remains protected"
	return 0
}

test_archive_pruning_preserves_tracked_codegraph_root() {
	local source_path="${TEST_DIR}/tracked-codegraph-source"
	local archive_path="${TEST_DIR}/tracked-codegraph-archive"
	local rc=0

	"$GIT_BIN" init -q -b main "$source_path" || rc=1
	"$GIT_BIN" -C "$source_path" config user.email test@example.invalid || rc=1
	"$GIT_BIN" -C "$source_path" config user.name 'Aidevops Test' || rc=1
	"$GIT_BIN" -C "$source_path" config commit.gpgsign false || rc=1
	printf '/.codegraph/\n' >>"${source_path}/.git/info/exclude" || rc=1
	mkdir -p "${source_path}/.codegraph" || rc=1
	printf 'tracked configuration\n' >"${source_path}/.codegraph/config.json" || rc=1
	"$GIT_BIN" -C "$source_path" add -f .codegraph/config.json || rc=1
	"$GIT_BIN" -C "$source_path" commit -q -m init || rc=1
	printf 'generated graph\n' >"${source_path}/.codegraph/codegraph.db" || rc=1
	cp -R "$source_path" "$archive_path" || rc=1
	_worktree_prune_regenerable_archive_caches \
		"$source_path" "$archive_path" "$GIT_BIN" || rc=1
	[[ -f "${archive_path}/.codegraph/config.json" &&
		-f "${archive_path}/.codegraph/codegraph.db" ]] || rc=1
	print_result "archive_pruning_preserves_tracked_codegraph_root" "$rc" \
		"Expected any tracked file to veto pruning the repository-root CodeGraph cache"
	return 0
}

test_claim_state_uses_archive_repository() {
	local home_path="${TEST_DIR}/claim-home"
	local repo_path="${TEST_DIR}/claim-repo"
	local worktree_path="${TEST_DIR}/claim-worktree"
	local unrelated_repo="${TEST_DIR}/claim-unrelated-repo"
	local recovery_root="${home_path}/recovery"
	local claim_dir="${home_path}/.aidevops/.agent-workspace/interactive-claims"
	local archive_path="" identity="" unavailable_identity="" state=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" "$claim_dir" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh30902-archive-claim") || rc=1
	"$GIT_BIN" -C "$archive_path" remote add origin \
		"https://github.com/archive/repo.git" || rc=1
	identity=$(_worktree_recovery_plan_identity_json "${archive_path%/*}") || rc=1
	"$GIT_BIN" init -q -b main "$unrelated_repo" || rc=1
	"$GIT_BIN" -C "$unrelated_repo" remote add origin \
		"https://github.com/unrelated/repo.git" || rc=1
	jq -n '{issue:30902,slug:"unrelated/repo",pid:1,
		hostname:"aidevops-remote-fixture.invalid"}' \
		>"${claim_dir}/unrelated-repo-30902.json" || rc=1
	state=$(
		cd "$unrelated_repo" || exit 1
		export HOME="$home_path"
		_worktree_recovery_plan_claim_state "$identity"
	) || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || rc=1
	jq -n '{issue:30902,slug:"archive/repo",pid:1,
		hostname:"aidevops-remote-fixture.invalid"}' \
		>"${claim_dir}/archive-repo-30902.json" || rc=1
	state=$(
		cd "$unrelated_repo" || exit 1
		export HOME="$home_path"
		_worktree_recovery_plan_claim_state "$identity"
	) || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE" ]] || rc=1
	unavailable_identity=$(printf '%s\n' "$identity" | jq -c \
		--arg archive "${TEST_DIR}/missing-archive" '.archive_path = $archive') || rc=1
	state=$(_worktree_recovery_plan_claim_state "$unavailable_identity") || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_UNAVAILABLE" ]] || rc=1
	print_result "claim_state_uses_archive_repository" "$rc" \
		"Expected archive-bound claims, no unrelated CWD fallback, and unavailable invalid identity"
	return 0
}

test_detached_claim_does_not_invent_active_owner() {
	local identity='' claim='' evidence='' result=''
	local branch='' rc=0
	identity='{"archive_path":"/unused-fixture","source_removal_outcome":"removed","branch":"detached"}'
	claim=$(_worktree_recovery_plan_claim_state "$identity") || rc=1
	[[ "$claim" == 'not-applicable' ]] || rc=1
	evidence=$(_worktree_recovery_plan_partial_evidence_json clear clear clear "$claim") || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == protected ]] || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.reasons[0]')" == detached-or-unresolved-branch ]] || rc=1
	# Even a hypothetical all-clear claim cannot turn detached identity into a
	# deletion candidate. Exact commit/task evidence never overrides this gate.
	evidence='{"git":"clear","worktree":"clear","registry":"clear","claim":"clear","process":"clear","external":{"commit":"merged","open_pr":"clear","task":"closed"}}'
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == protected ]] || rc=1
	for branch in '' unknown refs/tags/v1; do
		identity=$(jq -cn --arg branch "$branch" '{archive_path:"/unused-fixture",branch:$branch}') || rc=1
		claim=$(_worktree_recovery_plan_claim_state "$identity") || rc=1
		[[ "$claim" == "$WORKTREE_RECOVERY_UNAVAILABLE" ]] || rc=1
	done
	print_result "detached_claim_does_not_invent_active_owner" "$rc" \
		"Expected truthful detached claim evidence while retaining deletion protection and unknown-identity failure"
	return 0
}

assert_profile_unavailable_process_reason() {
	local identity="$1"
	local evidence_path="${TEST_DIR}/profile-evidence.json"
	local evidence=""
	local result=""

	(
		_worktree_recovery_plan_git_state() { printf 'clear\n'; }
		_worktree_recovery_plan_worktree_reference_state() { printf 'clear\n'; }
		_worktree_recovery_plan_registry_state() { printf 'clear\n'; }
		_worktree_recovery_plan_claim_state() { printf 'not-applicable\n'; }
		_worktree_recovery_plan_process_state() { printf 'unavailable\n'; }
		_worktree_recovery_plan_external_evidence_json() { return 99; }
		_worktree_recovery_plan_evidence_json "$identity" >"$evidence_path"
	) || return 1
	evidence=$(<"$evidence_path") || return 1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || return 1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition + ":" + .reasons[0]')" == 'unknown:process-evidence-unavailable' ]] || return 1
	result=$(_worktree_recovery_plan_classification_json \
		"$(printf '%s\n' "$identity" | jq -c '.producer_context = "legacy"')" \
		"$evidence" true) || return 1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition + ":" + .reasons[0]')" == 'protected:detached-or-unresolved-branch' ]]
	return $?
}

test_profile_publication_detached_evidence_is_exact_and_fail_closed() {
	local identity='' evidence='' result='' disposition='' reason='' mode=''
	local evidence_path="${TEST_DIR}/profile-evidence.json"
	local rc=0
	identity=$(jq -cn \
		'{format:"aidevops-worktree-recovery-v2",archive_path:"/recovery/profile",source_path:"/worktrees/profile-readme",head:"abc123",branch:"detached",producer:"profile-readme-helper.sh",producer_context:"recovery_path=profile-publication-archive profile_scratch=true",source_removal_outcome:"removed"}') || rc=1

	for mode in published unpublished unavailable; do
		if ! (
			_worktree_recovery_plan_repo_slug() {
				printf '%s\n' 'example/profile'
				return 0
			}
			command() {
				[[ "$1" == '-v' && "$2" == 'gh' ]]
			}
			gh() {
				[[ "$mode" != 'unavailable' ]] || return 1
				case "$2" in
				'repos/example/profile')
					printf '%s\n' 'main'
					;;
				'repos/example/profile/compare/abc123...main')
					if [[ "$mode" == 'published' ]]; then
						printf 'ahead\tabc123\n'
					else
						printf 'diverged\tdef456\n'
					fi
					;;
				*) return 1 ;;
				esac
				return 0
			}
			_worktree_recovery_plan_profile_publication_evidence_json "$identity" >"$evidence_path"
		); then
			rc=1
		fi
		evidence=$(<"$evidence_path") || rc=1
		case "$mode" in
		published)
			printf '%s\n' "$evidence" | jq -e \
				'.commit == "published" and .open_pr == "clear" and .task == "not-applicable" and .provenance == "profile-publication"' \
				>/dev/null || rc=1
			;;
		unpublished)
			[[ "$(printf '%s\n' "$evidence" | jq -r '.commit')" == 'unproven' ]] || rc=1
			;;
		unavailable)
			[[ "$(printf '%s\n' "$evidence" | jq -r '.commit')" == "$WORKTREE_RECOVERY_UNAVAILABLE" ]] || rc=1
			;;
		esac
		result=$(_worktree_recovery_plan_classification_json "$identity" \
			"$(jq -cn --argjson external "$evidence" '{git:"clear",worktree:"clear",registry:"clear",claim:"not-applicable",process:"clear",external:$external}')" true) || rc=1
		disposition=$(printf '%s\n' "$result" | jq -r '.disposition') || rc=1
		reason=$(printf '%s\n' "$result" | jq -r '.reasons[0]') || rc=1
		case "$mode" in
		published) [[ "$disposition:$reason" == 'candidate:producer-published-detached-evidence-clear' ]] || rc=1 ;;
		unpublished) [[ "$disposition:$reason" == 'protected:exact-commit-not-published' ]] || rc=1 ;;
		unavailable) [[ "$disposition:$reason" == 'unknown:commit-evidence-unavailable' ]] || rc=1 ;;
		esac
	done
	evidence='{"commit":"published","open_pr":"clear","task":"not-applicable","issue_number":null,"repo":"example/profile","provenance":"profile-publication"}'
	result=$(_worktree_recovery_plan_classification_json \
		"$(printf '%s\n' "$identity" | jq -c '.producer_context = "malformed"')" \
		"$(jq -cn --argjson external "$evidence" '{git:"clear",worktree:"clear",registry:"clear",claim:"not-applicable",process:"clear",external:$external}')" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.reasons[0]')" == 'detached-or-unresolved-branch' ]] || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" \
		"$(jq -cn --argjson external "$evidence" '{git:"clear",worktree:"clear",registry:"clear",claim:"not-applicable",process:"active",external:$external}')" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.reasons[0]')" == 'active-process-reference' ]] || rc=1
	if ! (
		_worktree_recovery_plan_git_state() { printf 'clear\n'; }
		_worktree_recovery_plan_worktree_reference_state() { printf 'clear\n'; }
		_worktree_recovery_plan_registry_state() { printf 'clear\n'; }
		_worktree_recovery_plan_claim_state() { printf 'not-applicable\n'; }
		_worktree_recovery_plan_process_state() { printf 'clear\n'; }
		_worktree_recovery_plan_external_evidence_json() {
			printf '%s\n' '{"commit":"published","open_pr":"clear","task":"not-applicable","issue_number":null,"repo":"example/profile","provenance":"profile-publication"}'
		}
		_worktree_recovery_plan_evidence_json "$identity" >"$evidence_path"
	); then
		rc=1
	fi
	evidence=$(<"$evidence_path") || rc=1
	[[ "$(printf '%s\n' "$evidence" | jq -r '.claim')" == 'not-applicable' ]] || rc=1
	[[ "$(printf '%s\n' "$evidence" | jq -r '.external.commit')" == 'published' ]] || rc=1
	assert_profile_unavailable_process_reason "$identity" || rc=1
	print_result "profile_publication_detached_evidence_is_exact_and_fail_closed" "$rc" \
		"Expected identity-aware unavailable reasons while malformed, live, unavailable, or unpublished archives remain preserved"
	return 0
}

test_profile_publication_detached_archive_plans_without_apply() {
	local home_path="${TEST_DIR}/profile-plan-home"
	local repo_path="${TEST_DIR}/profile-plan-repo"
	local worktree_path="${TEST_DIR}/profile-plan-worktree"
	local dirty_worktree_path="${TEST_DIR}/profile-plan-dirty-worktree"
	local recovery_root="${home_path}/recovery"
	local plan_path="${TEST_DIR}/profile-plan.json"
	local archive_path='' dirty_archive_path='' rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	"$GIT_BIN" init -q -b main "$repo_path" || rc=1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || rc=1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || rc=1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || rc=1
	printf 'profile\n' >"${repo_path}/README.md" || rc=1
	"$GIT_BIN" -C "$repo_path" add README.md || rc=1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || rc=1
	"$GIT_BIN" -C "$repo_path" remote add origin 'https://github.com/example/profile.git' || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q --detach "$worktree_path" HEAD || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$worktree_path" 'profile-readme-helper.sh' \
		'recovery_path=profile-publication-archive profile_scratch=true' || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$worktree_path" "$archive_path" 'profile-readme-helper.sh' 'profile-publication' \
		'recovery_path=profile-publication-archive profile_scratch=true' 'true' 'true' || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q --detach "$dirty_worktree_path" HEAD || rc=1
	printf 'unique unpublished data\n' >"${dirty_worktree_path}/unique.bin" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$dirty_worktree_path" 'profile-readme-helper.sh' \
		'recovery_path=profile-publication-archive profile_scratch=true' || rc=1
	dirty_archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$dirty_worktree_path" "$dirty_archive_path" 'profile-readme-helper.sh' 'profile-publication' \
		'recovery_path=profile-publication-archive profile_scratch=true' 'true' 'true' || rc=1
	if ! (
		_worktree_recovery_plan_worktree_reference_state() { printf 'clear\n'; }
		_worktree_recovery_plan_registry_state() { printf 'clear\n'; }
		_worktree_recovery_plan_process_state() { printf 'clear\n'; }
		_worktree_recovery_plan_external_evidence_json() {
			printf '%s\n' '{"commit":"published","open_pr":"clear","task":"not-applicable","issue_number":null,"repo":"example/profile","provenance":"profile-publication"}'
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
			cmd_recovery plan --output "$plan_path" >/dev/null
	); then
		rc=1
	fi
	jq -e --arg archive "$archive_path" --arg dirty_archive "$dirty_archive_path" '
		.candidate_count == 1 and .protected_count == 1 and .unknown_count == 0 and
		(.entries[] | select(.archive_path == $archive) |
			.identity.producer == "profile-readme-helper.sh" and
			.identity.producer_context == "recovery_path=profile-publication-archive profile_scratch=true" and
			.evidence.claim == "not-applicable" and
			.reasons == ["producer-published-detached-evidence-clear"]) and
		(.entries[] | select(.archive_path == $dirty_archive) |
			.disposition == "protected" and .reasons == ["archive-worktree-dirty"])
	' "$plan_path" >/dev/null || rc=1
	[[ -d "$archive_path" && -d "$dirty_archive_path" &&
		! -e "$worktree_path" && ! -e "$dirty_worktree_path" ]] || rc=1
	print_result "profile_publication_detached_archive_plans_without_apply" "$rc" \
		"Expected only the clean published archive to become a read-only candidate while unique unpublished data remains protected"
	return 0
}

generic_detached_classification() {
	local identity="$1"
	local evidence_path="$2"
	local result=""

	result=$(_worktree_recovery_plan_classification_json "$identity" "$(<"$evidence_path")" true) || return 1
	printf '%s\n' "$result" | jq -r '.disposition + ":" + .reasons[0]'
	return $?
}

# Runs the real evidence pipeline for a generic detached identity with local
# probes stubbed. Modes: age (elapsed|young|invalid), git, process, compare.
generic_detached_evidence() {
	local identity="$1"
	local evidence_path="$2"
	local age_mode="$3"
	local git_mode="$4"
	local process_mode="$5"
	local compare_mode="$6"
	local probe_marker="$7"

	(
		_worktree_recovery_plan_git_state() { printf '%s\n' "$git_mode"; }
		_worktree_recovery_plan_worktree_reference_state() { printf 'clear\n'; }
		_worktree_recovery_plan_registry_state() { printf 'clear\n'; }
		_worktree_recovery_plan_claim_state() { printf 'not-applicable\n'; }
		_worktree_recovery_plan_process_state() {
			printf 'process\n' >>"$probe_marker"
			printf '%s\n' "$process_mode"
		}
		_worktree_recovery_plan_external_evidence_json() {
			_worktree_recovery_plan_detached_retention_evidence_json "$1"
		}
		_worktree_recovery_plan_created_age_seconds() {
			case "$age_mode" in
			elapsed) printf '%s\n' 864000 ;;
			young) printf '%s\n' 60 ;;
			*) return 1 ;;
			esac
			return 0
		}
		_worktree_recovery_plan_repo_slug() { printf '%s\n' 'example/detached'; }
		gh() {
			printf 'remote\n' >>"$probe_marker"
			case "$2" in
			'repos/example/detached') printf '%s\n' 'main' ;;
			'repos/example/detached/compare/abc123...main')
				case "$compare_mode" in
				published) printf 'ahead\tabc123\n' ;;
				unpublished) printf 'diverged\tdef456\n' ;;
				*) return 1 ;;
				esac
				;;
			*) return 1 ;;
			esac
			return 0
		}
		AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS=7 \
			_worktree_recovery_plan_evidence_json "$identity" >"$evidence_path"
	)
	return $?
}

test_generic_detached_retention_publication_is_fail_closed() {
	local identity='' outcome='' mode='' rc=0
	local evidence_path="${TEST_DIR}/generic-detached-evidence.json"
	local probe_marker="${TEST_DIR}/generic-detached-probes"

	identity=$(jq -cn \
		'{format:"aidevops-worktree-recovery-v2",archive_path:"/recovery/generic",source_path:"/worktrees/generic",head:"abc123",branch:"detached",created_at:"2026-01-01T00:00:00Z",producer:"worktree-helper.sh",producer_context:"recovery_path=test",source_removal_outcome:"removed"}') || rc=1
	for mode in \
		'elapsed clear clear published candidate:detached-head-published-retention-elapsed' \
		'elapsed clear clear unpublished protected:exact-commit-not-published' \
		'elapsed clear clear unavailable unknown:commit-evidence-unavailable' \
		'elapsed clear unavailable published unknown:process-evidence-unavailable' \
		'elapsed clear active published protected:active-process-reference' \
		'elapsed dirty clear published protected:archive-worktree-dirty' \
		'young clear clear published protected:detached-within-retention' \
		'invalid clear clear published unknown:retention-evidence-unavailable'; do
		# shellcheck disable=SC2086 # intentional word splitting of fixed case rows
		set -- $mode
		: >"$probe_marker"
		generic_detached_evidence "$identity" "$evidence_path" "$1" "$2" "$3" "$4" "$probe_marker" || rc=1
		outcome=$(generic_detached_classification "$identity" "$evidence_path") || rc=1
		[[ "$outcome" == "$5" ]] || {
			printf '  generic detached %s: got %s\n' "$mode" "$outcome"
			rc=1
		}
		# Young or undatable archives are retained before process or remote probes.
		if [[ "$1" != elapsed ]] && [[ -s "$probe_marker" ]]; then rc=1; fi
	done
	generic_detached_evidence "$identity" "$evidence_path" elapsed clear clear published "$probe_marker" || rc=1
	# Legacy detached identity without creation evidence keeps the old protection.
	outcome=$(generic_detached_classification \
		"$(printf '%s\n' "$identity" | jq -c 'del(.created_at)')" "$evidence_path") || rc=1
	[[ "$outcome" == 'protected:detached-or-unresolved-branch' ]] || rc=1
	outcome=$(generic_detached_classification \
		"$(printf '%s\n' "$identity" | jq -c '.source_removal_outcome = "pending"')" "$evidence_path") || rc=1
	[[ "$outcome" == 'protected:source-removal-not-complete' ]] || rc=1
	# Evidence from another provenance can never satisfy the generic contract.
	jq -c '.external.provenance = "profile-publication"' "$evidence_path" >"${evidence_path}.tmp" || rc=1
	outcome=$(generic_detached_classification "$identity" "${evidence_path}.tmp") || rc=1
	[[ "$outcome" == 'unknown:unrecognised-evidence-state' ]] || rc=1
	print_result "generic_detached_retention_publication_is_fail_closed" "$rc" \
		"Expected only aged, clean, clear, published detached archives to become candidates"
	return 0
}

# Plans and applies with local probes stubbed clear and a GitHub stub that
# reports only the given HEAD as published on the default branch.
run_generic_detached_plan_apply() {
	local home_path="$1"
	local recovery_root="$2"
	local plan_path="$3"
	local receipt_path="$4"
	local published_head="$5"

	(
		_worktree_recovery_plan_git_state() { printf 'clear\n'; }
		_worktree_recovery_plan_worktree_reference_state() { printf 'clear\n'; }
		_worktree_recovery_plan_registry_state() { printf 'clear\n'; }
		_worktree_recovery_plan_claim_state() { printf 'not-applicable\n'; }
		_worktree_recovery_plan_process_state() { printf 'clear\n'; }
		_worktree_recovery_plan_external_evidence_json() {
			_worktree_recovery_plan_detached_retention_evidence_json "$1"
		}
		_worktree_recovery_plan_created_age_seconds() { printf '%s\n' 864000; }
		_worktree_recovery_plan_repo_slug() { printf '%s\n' 'example/detached'; }
		gh() {
			local compare_head=''
			case "$2" in
			'repos/example/detached') printf '%s\n' 'main' ;;
			repos/example/detached/compare/*)
				compare_head="${2#repos/example/detached/compare/}"
				compare_head="${compare_head%...main}"
				if [[ "$compare_head" == "$published_head" ]]; then
					printf 'ahead\t%s\n' "$published_head"
				else
					printf 'diverged\t%s\n' "$published_head"
				fi
				;;
			*) return 1 ;;
			esac
			return 0
		}
		local confirmation=''
		HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
			cmd_recovery plan --output "$plan_path" >/dev/null || exit 1
		confirmation=$(jq -r '.confirmation_token' "$plan_path") || exit 1
		HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
			cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" \
			--confirm "$confirmation" >/dev/null || exit 1
	)
	return $?
}

test_generic_detached_archive_plans_and_applies() {
	local home_path="${TEST_DIR}/generic-detached-home"
	local repo_path="${TEST_DIR}/generic-detached-repo"
	local worktree_path="${TEST_DIR}/generic-detached-worktree"
	local unpublished_path="${TEST_DIR}/generic-detached-unpublished"
	local recovery_root="${home_path}/recovery"
	local plan_path="${TEST_DIR}/generic-detached-plan.json"
	local receipt_path="${TEST_DIR}/generic-detached-receipt.json"
	local archive_path='' unpublished_archive='' published_head=''
	local path=''
	local rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	"$GIT_BIN" init -q -b main "$repo_path" || rc=1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || rc=1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || rc=1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || rc=1
	printf 'detached\n' >"${repo_path}/README.md" || rc=1
	"$GIT_BIN" -C "$repo_path" add README.md || rc=1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || rc=1
	"$GIT_BIN" -C "$repo_path" remote add origin 'https://github.com/example/detached.git' || rc=1
	published_head=$("$GIT_BIN" -C "$repo_path" rev-parse HEAD) || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q --detach "$worktree_path" HEAD || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q --detach "$unpublished_path" HEAD || rc=1
	printf 'local only\n' >"${unpublished_path}/local.txt" || rc=1
	"$GIT_BIN" -C "$unpublished_path" add local.txt || rc=1
	"$GIT_BIN" -C "$unpublished_path" commit -q -m 'unpublished detached work' || rc=1
	for path in "$worktree_path" "$unpublished_path"; do
		AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
			archive_worktree_path_recoverably "$path" 'worktree-helper.sh' \
			'recovery_path=test-detached' || rc=1
		if [[ "$path" == "$worktree_path" ]]; then
			archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
		else
			unpublished_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
		fi
		AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
			"$path" "$WORKTREE_RECOVERABLE_ARCHIVE_PATH" 'worktree-helper.sh' 'test-cleanup' \
			'recovery_path=test-detached' 'true' 'true' || rc=1
	done
	run_generic_detached_plan_apply "$home_path" "$recovery_root" "$plan_path" \
		"$receipt_path" "$published_head" || rc=1
	jq -e --arg archive "$archive_path" --arg unpublished "$unpublished_archive" '
		.candidate_count == 1 and .protected_count == 1 and
		(.entries[] | select(.archive_path == $archive) |
			.disposition == "candidate" and
			.evidence.external.provenance == "published-detached-head" and
			.evidence.external.retention == "elapsed" and
			.reasons == ["detached-head-published-retention-elapsed"]) and
		(.entries[] | select(.archive_path == $unpublished) |
			.disposition == "protected" and .reasons == ["exact-commit-not-published"])
	' "$plan_path" >/dev/null || rc=1
	jq -e '.complete == true and .candidate_count == 1 and .entries[0].outcome == "removed"' \
		"$receipt_path" >/dev/null 2>&1 || rc=1
	[[ ! -e "$archive_path" && -d "$unpublished_archive" ]] || rc=1
	print_result "generic_detached_archive_plans_and_applies" "$rc" \
		"Expected an aged published detached archive to be applied while unpublished detached work is preserved"
	return 0
}

test_plan_output_refuses_unsafe_targets() {
	local existing_path="${TEST_DIR}/existing-plan.json"
	local symlink_path="${TEST_DIR}/symlink-plan.json"
	local target_path="${TEST_DIR}/symlink-target.json"
	local home_path="${TEST_DIR}/unsafe-home"
	local recovery_root="${home_path}/recovery"
	local unwritable_dir="${TEST_DIR}/unwritable"
	local unwritable_path="${unwritable_dir}/plan.json"
	local rc=0

	mkdir -p "$recovery_root" "$unwritable_dir" || rc=1
	printf '{}\n' >"$existing_path" || rc=1
	printf '{}\n' >"$target_path" || rc=1
	ln -s "$target_path" "$symlink_path" || rc=1
	if worktree_recovery_plan_write "$existing_path" >/dev/null 2>&1; then rc=1; fi
	if worktree_recovery_plan_write "$symlink_path" >/dev/null 2>&1; then rc=1; fi
	if worktree_recovery_plan_write "relative-plan.json" >/dev/null 2>&1; then rc=1; fi
	chmod 500 "$unwritable_dir" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_plan_write "$unwritable_path" >/dev/null 2>&1; then rc=1; fi
	chmod 700 "$unwritable_dir" || rc=1
	[[ "$(<"$existing_path")" == '{}' && -L "$symlink_path" ]] || rc=1
	[[ ! -e "$unwritable_path" && ! -L "$unwritable_path" ]] || rc=1
	print_result "plan_output_refuses_unsafe_targets" "$rc" \
		"Expected existing, symlinked, and relative outputs to fail without mutation"
	return 0
}

test_classification_fails_closed() {
	local identity='{"source_removal_outcome":"removed","branch":"refs/heads/bugfix/gh29388-plan"}'
	local clear_external='{"commit":"merged","open_pr":"clear","task":"closed"}'
	local evidence="" result=""
	local protected_case=""
	local rc=0

	evidence=$(jq -cn --argjson external "$clear_external" \
		'{git:"dirty",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external}') || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	evidence=$(jq -cn --argjson external "$clear_external" \
		'{git:"clear",worktree:"clear",registry:"clear",claim:"unavailable",process:"clear",external:$external}') || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "unknown" ]] || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" false) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.reasons[0]')" == "identity-or-size-changed" ]] || rc=1
	for protected_case in worktree registry claim process; do
		evidence=$(jq -cn --arg field "$protected_case" --argjson external "$clear_external" \
			'{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external} | .[$field]="active"') || rc=1
		result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
		[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	done
	for clear_external in \
		'{"commit":"unproven","open_pr":"clear","task":"closed"}' \
		'{"commit":"merged","open_pr":"active","task":"closed"}' \
		'{"commit":"merged","open_pr":"clear","task":"open"}'; do
		evidence=$(jq -cn --argjson external "$clear_external" \
			'{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external}') || rc=1
		result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
		[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	done
	clear_external='{"commit":"unavailable","open_pr":"unavailable","task":"unavailable"}'
	evidence=$(jq -cn --argjson external "$clear_external" \
		'{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external}') || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "unknown" ]] || rc=1
	identity='{"source_removal_outcome":"removed","branch":"detached"}'
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	print_result "classification_fails_closed" "$rc" \
		"Expected dirty evidence to protect and unavailable or changed evidence to remain unknown"
	return 0
}

test_recovery_issue_attribution_uses_archived_source_path() {
	local issue="" status=0
	local rc=0

	issue=$(_worktree_recovery_plan_identity_issue_number \
		"refs/heads/feature/auto-20260830-155046" \
		"/worktrees/project-pr2641-review-feature-auto-20260830-155046") || rc=1
	[[ "$issue" == "2641" ]] || rc=1
	issue=$(_worktree_recovery_plan_identity_issue_number \
		"refs/heads/feature/auto-20260830-155046-gh2641" \
		"/worktrees/project-pr2641-review") || rc=1
	[[ "$issue" == "2641" ]] || rc=1
	status=0
	_worktree_recovery_plan_identity_issue_number \
		"refs/heads/feature/auto-20260830-155046-gh2641" \
		"/worktrees/project-pr2642-review" >/dev/null 2>&1 || status=$?
	[[ "$status" -eq 2 ]] || rc=1
	print_result "recovery_issue_attribution_uses_archived_source_path" "$rc" \
		"Expected archived PR worktree names to supply missing task identity while conflicts fail closed"
	return 0
}

test_unlinked_merged_pr_is_terminal_task_evidence() {
	local identity="" evidence=""
	local rc=0

	identity=$(jq -cn \
		'{archive_path:"/recovery/archive",source_path:"/worktrees/project-auto-20260830",
		branch:"refs/heads/feature/auto-20260830",head:"abc123"}') || rc=1
	evidence=$(
		_worktree_recovery_plan_repo_slug() {
			local ignored_archive="$1"
			: "$ignored_archive"
			printf '%s\n' "example/repo"
			return 0
		}
		gh() {
			local resource="$1"
			if [[ "$resource" == "pr" ]]; then
				printf '%s\n' '[{"state":"MERGED","mergedAt":"2026-09-01T00:00:00Z","headRefOid":"abc123"}]'
				return 0
			fi
			return 1
		}
		_worktree_recovery_plan_external_evidence_json "$identity"
	) || rc=1
	printf '%s\n' "$evidence" | jq -e \
		'.commit == "merged" and .open_pr == "clear" and .task == "closed" and .issue_number == null' \
		>/dev/null || rc=1
	print_result "unlinked_merged_pr_is_terminal_task_evidence" "$rc" \
		"Expected an exact merged PR to provide terminal task evidence without a branch-encoded issue"
	return 0
}

test_dirty_recovery_short_circuits_expensive_probes() {
	local bucket_path="${TEST_DIR}/dirty-short-circuit"
	local probe_path="${TEST_DIR}/dirty-short-circuit-probe"
	local entry=""
	local rc=0

	mkdir -p "$bucket_path" || rc=1
	entry=$(
		_worktree_recovery_plan_identity_json() {
			local ignored_bucket="$1"
			: "$ignored_bucket"
			jq -cn --arg bucket "$bucket_path" \
				'{bucket_path:$bucket,archive_path:($bucket + "/archive"),source_path:"/worktrees/source",
				source_removal_outcome:"removed",branch:"refs/heads/feature/auto-20260830",head:"abc123"}'
			return $?
		}
		_worktree_recovery_plan_git_state() {
			local ignored_identity="$1"
			: "$ignored_identity"
			printf '%s\n' "dirty"
			return 0
		}
		_worktree_recovery_plan_worktree_reference_state() {
			local ignored_identity="$1"
			: "$ignored_identity"
			printf 'called\n' >"$probe_path"
			return 1
		}
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			: "$ignored_path"
			printf 'called\n' >"$probe_path"
			return 1
		}
		_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" 1024
	) || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.disposition')" == "protected" ]] || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.reasons[0]')" == "archive-worktree-dirty" ]] || rc=1
	[[ ! -e "$probe_path" ]] || rc=1
	print_result "dirty_recovery_short_circuits_expensive_probes" "$rc" \
		"Expected dirty archives to remain protected without unrelated local, remote, or size probes"
	return 0
}

test_active_claim_short_circuits_later_probes() {
	local bucket_path="${TEST_DIR}/active-claim-short-circuit"
	local probe_path="${TEST_DIR}/active-claim-short-circuit-probe"
	local entry=""
	local rc=0

	mkdir -p "$bucket_path" || rc=1
	entry=$(
		_worktree_recovery_plan_identity_json() {
			local ignored_bucket="$1"
			: "$ignored_bucket"
			jq -cn --arg bucket "$bucket_path" \
				'{bucket_path:$bucket,archive_path:($bucket + "/archive"),source_path:"/worktrees/source",
				source_removal_outcome:"removed",branch:"refs/heads/feature/auto-20260830",head:"abc123"}'
			return $?
		}
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
			printf 'active\n'
			return 0
		}
		_worktree_recovery_plan_process_state() {
			printf 'called\n' >"$probe_path"
			return 1
		}
		_worktree_recovery_plan_external_evidence_json() {
			printf 'called\n' >"$probe_path"
			return 1
		}
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			: "$ignored_path"
			printf 'called\n' >"$probe_path"
			return 1
		}
		_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" 1024
	) || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.disposition')" == "protected" ]] || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.reasons[0]')" == "active-session-claim" ]] || rc=1
	[[ ! -e "$probe_path" ]] || rc=1
	print_result "active_claim_short_circuits_later_probes" "$rc" \
		"Expected an active claim to protect its archive without process, remote, or size probes"
	return 0
}

test_plan_records_malformed_bucket_unknown() {
	local home_path="${TEST_DIR}/malformed-home"
	local recovery_root="${home_path}/recovery"
	local malformed_bucket="${recovery_root}/aidevops-worktree-cleanup-malformed"
	local output_path="${TEST_DIR}/malformed-plan.json"
	local rc=0

	mkdir -p "${malformed_bucket}/${_WT_RECOVERY_DIR_NAME}" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V2" > \
		"${malformed_bucket}/${_WT_RECOVERY_DIR_NAME}/format" || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_plan_write "$output_path" >/dev/null || rc=1
	jq -e '.candidate_count == 0 and .unknown_count == 1 and
		.entries[0].reasons == ["archive-unrecognised-or-incomplete"]' \
		"$output_path" >/dev/null || rc=1
	print_result "plan_records_malformed_bucket_unknown" "$rc" \
		"Expected malformed archives to remain visible but never become candidates"
	return 0
}

test_size_drift_downgrades_only_entry() {
	local home_path="${TEST_DIR}/drift-home"
	local repo_path="${TEST_DIR}/drift-repo"
	local worktree_path="${TEST_DIR}/drift-worktree"
	local recovery_root="${home_path}/recovery"
	local archive_path="" bucket_path="" measured="" expected_bytes="" entry=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh29388-drift-plan") || rc=1
	bucket_path="${archive_path%/*}"
	measured=$(_worktree_recovery_measure_path "$bucket_path") || rc=1
	IFS='|' read -r expected_bytes _ _ <<<"$measured"
	entry=$(
		install_clear_evidence_stubs
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			: "$ignored_path"
			printf '%s|exact|' "$((expected_bytes + 1024))"
			return 0
		}
		_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" "$expected_bytes"
	) || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.disposition')" == "unknown" ]] || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.reasons[0]')" == "identity-or-size-changed" ]] || rc=1
	print_result "size_drift_downgrades_only_entry" "$rc" \
		"Expected a late byte change to downgrade the affected entry"
	return 0
}

test_attributed_remeasurement_uses_explicit_budget() {
	local bucket_path="${TEST_DIR}/remeasure-budget-bucket"
	local du_script="${TEST_DIR}/remeasure-budget-du.sh"
	local reasons_path="${TEST_DIR}/remeasure-budget-reasons"
	local entry="" timed_out="" counts=""
	local rc=0

	mkdir -p "$bucket_path" || rc=1
	cat >"$du_script" <<'SH'
#!/usr/bin/env bash
sleep 0.3
printf '1\t%s\n' "$2"
SH
	chmod 700 "$du_script" || rc=1
	entry=$(
		_worktree_recovery_plan_identity_json() {
			jq -cn --arg bucket "$bucket_path" \
				'{bucket_path:$bucket,archive_path:($bucket + "/archive"),
				source_removal_outcome:"removed",branch:"refs/heads/bugfix/gh31009"}'
			return $?
		}
		_worktree_recovery_plan_evidence_json() {
			jq -cn '{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",
				external:{commit:"merged",open_pr:"clear",task:"closed"}}'
			return $?
		}
		AIDEVOPS_WORKTREE_RECOVERY_DU_COMMAND="$du_script" \
			AIDEVOPS_WORKTREE_RECOVERY_SIZE_TIMEOUT_TENTHS=2 \
			_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" 1024 10
	) || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.disposition')" == "candidate" ]] || rc=1
	timed_out=$(
		_worktree_recovery_plan_identity_json() {
			jq -cn --arg bucket "$bucket_path" \
				'{bucket_path:$bucket,archive_path:($bucket + "/archive"),
				source_removal_outcome:"removed",branch:"refs/heads/bugfix/gh31009"}'
			return $?
		}
		_worktree_recovery_plan_evidence_json() {
			jq -cn '{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",
				external:{commit:"merged",open_pr:"clear",task:"closed"}}'
			return $?
		}
		AIDEVOPS_WORKTREE_RECOVERY_DU_COMMAND="$du_script" \
			AIDEVOPS_WORKTREE_RECOVERY_SIZE_TIMEOUT_TENTHS=2 \
			_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" 1024
	) || rc=1
	[[ "$(printf '%s\n' "$timed_out" | jq -r '.reasons[0]')" == "sizing-timeout" ]] || rc=1
	: >"$reasons_path" || rc=1
	_worktree_recovery_maintenance_record_reason "$reasons_path" \
		"$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" "sizing-timeout" || rc=1
	counts=$(_worktree_recovery_maintenance_reason_counts_json "$reasons_path") || rc=1
	printf '%s\n' "$counts" | jq -e \
		'.sizing_timeout == 1 and .sizing_unavailable == 0 and .classification_unavailable == 0' \
		>/dev/null || rc=1
	print_result "attributed_remeasurement_uses_explicit_budget" "$rc" \
		"Expected a slow exact remeasurement to use its supplied budget and distinguish timeout from overall deadline exhaustion"
	return 0
}

test_global_inventory_failure_is_explicit() {
	local plan=""
	local rc=0

	plan=$(
		worktree_recovery_inventory() {
			return 1
		}
		worktree_recovery_plan_json "Linux"
	) || rc=1
	printf '%s\n' "$plan" | jq -e '
		.inventory_complete == false and
		.inventory_error == "classification-unavailable" and
		.candidate_count == 0 and .entry_count == 0
	' >/dev/null || rc=1
	print_result "global_inventory_failure_is_explicit" "$rc" \
		"Expected a failed global scan to produce no candidates and an explicit error"
	return 0
}

test_entry_sizing_failure_is_localized() {
	local plan=""
	local rc=0

	plan=$(
		worktree_recovery_lifecycle_json() {
			printf '%s\n' '{"error":null,"sizing_error":"sizing-timeout","buckets":[
			{"role":"current","state":"attributed","path":"/recovery/exact","bytes":1024,"sizing_confidence":"exact"},
			{"role":"current","state":"attributed","path":"/recovery/slow","bytes":null,"sizing_confidence":"unavailable"}]}'
			return 0
		}
		_worktree_recovery_plan_attributed_entry_json() {
			local role="$1"
			local bucket_path="$2"
			local ignored_bytes="$3"
			local bytes=1024
			: "$ignored_bytes"
			if [[ "$bucket_path" == "/recovery/slow" ]]; then
				_worktree_recovery_plan_unknown_entry_json \
					"$role" "$bucket_path" null "sizing-unavailable"
				return $?
			fi
			jq -cn --arg role "$role" --arg path "$bucket_path" --argjson bytes "$bytes" \
				'{role:$role,path:$path,archive_path:($path + "/archive"),expected_allocated_bytes:$bytes,
				identity:{identity_digest:"sha256:fixture"},evidence:{},disposition:"candidate",
				reasons:["all-required-evidence-clear"]}'
			return $?
		}
		worktree_recovery_plan_json "Linux"
	) || rc=1
	printf '%s\n' "$plan" | jq -e '
		.inventory_complete == true and .inventory_error == null and
		.classification_complete == true and .classified_entry_count == 2 and
		.candidate_count == 1 and .unknown_count == 1 and
		([.entries[] | select(.path == "/recovery/slow")][0].reasons == ["sizing-unavailable"])
	' >/dev/null || rc=1
	print_result "entry_sizing_failure_is_localized" "$rc" \
		"Expected one slow size probe to remain unknown without blocking an exact peer candidate"
	return 0
}

test_manual_plan_classification_is_bounded_and_resumable() {
	local first_output="${TEST_DIR}/bounded-plan-first.json"
	local second_output="${TEST_DIR}/bounded-plan-second.json"
	local rc=0

	(
		worktree_recovery_lifecycle_json() {
			printf '%s\n' '{"error":null,"sizing_error":null,"buckets":[
			{"role":"current","state":"unknown","path":"/recovery/bucket-0","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-1","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-2","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-3","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-4","bytes":null,"sizing_confidence":"unavailable"}]}'
			return 0
		}
		cmd_recovery plan --max-classify 2 --offset 0 --output "$first_output" >/dev/null || return 1
		cmd_recovery plan --output "$second_output" --offset 2 --max-classify 2 >/dev/null || return 1
	) || rc=1
	jq -e '
		.classification_complete == false and .classified_entry_count == 2 and
		.deferred_entry_count == 3 and .classification_offset == 0 and
		.next_classification_offset == 2 and
		([.entries[] | select(.reasons == ["classification-deferred"]) | .path] ==
		 ["/recovery/bucket-2","/recovery/bucket-3","/recovery/bucket-4"])
	' "$first_output" >/dev/null || rc=1
	jq -e '
		.classification_complete == false and .classified_entry_count == 2 and
		.deferred_entry_count == 3 and .classification_offset == 2 and
		.next_classification_offset == 4 and
		([.entries[] | select(.reasons == ["classification-deferred"]) | .path] ==
		 ["/recovery/bucket-0","/recovery/bucket-1","/recovery/bucket-4"])
	' "$second_output" >/dev/null || rc=1
	[[ "$(jq -r '.plan_id' "$first_output")" != "$(jq -r '.plan_id' "$second_output")" ]] || rc=1
	print_result "manual_plan_classification_is_bounded_and_resumable" "$rc" \
		"Expected bounded plan windows to expose a deterministic continuation offset"
	return 0
}

test_manual_plan_deadline_emits_continuation() {
	local output_path="${TEST_DIR}/deadline-plan.json"
	local clock_path="${TEST_DIR}/deadline-clock"
	local rc=0

	printf '0\n' >"$clock_path" || rc=1
	(
		worktree_recovery_lifecycle_json() {
			printf '%s\n' '{"error":null,"sizing_error":null,"buckets":[
			{"role":"current","state":"unknown","path":"/recovery/deadline-0","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/deadline-1","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/deadline-2","bytes":null,"sizing_confidence":"unavailable"}]}'
			return 0
		}
		date() {
			local call_count=0
			if [[ "${1:-}" == "+%s" ]]; then
				IFS= read -r call_count <"$clock_path" || return 1
				call_count=$((call_count + 1))
				printf '%s\n' "$call_count" >"$clock_path" || return 1
				if [[ "$call_count" -le 2 ]]; then printf '100\n'; else printf '102\n'; fi
				return 0
			fi
			command date "$@"
			return $?
		}
		cmd_recovery plan --output "$output_path" --max-classify 3 \
			--deadline-seconds 1 >/dev/null || return 1
	) || rc=1
	jq -e '
		.classification_complete == false and .classified_entry_count == 1 and
		.deferred_entry_count == 2 and .classification_deadline_seconds == 1 and
		.classification_deadline_exhausted == true and .next_classification_offset == 1 and
		([.entries[] | select(.reasons == ["classification-deadline-exhausted"]) | .path] ==
		 ["/recovery/deadline-1","/recovery/deadline-2"])
	' "$output_path" >/dev/null || rc=1
	print_result "manual_plan_deadline_emits_continuation" "$rc" \
		"Expected deadline exhaustion to stop new classification and preserve a continuation offset"
	return 0
}
