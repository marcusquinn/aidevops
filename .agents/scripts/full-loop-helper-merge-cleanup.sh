#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Merge Cleanup -- canonical sync and post-merge worktree cleanup
# =============================================================================
# Extracted verbatim from full-loop-helper-merge.sh (GH#30748). Resolves the
# canonical checkout for a merged PR, reconciles planning publication,
# fast-forwards the canonical base through canonical-recovery-helper.sh,
# reports sync state, removes linked worktrees, and records the deferred
# cleanup owner receipt (_merge_record_deferred_cleanup_owner).
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-merge-cleanup.sh"
#        (sourced by full-loop-helper-merge.sh; do not execute directly)
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - full-loop-helper-merge-worktree.sh (worktree identity/cleanup targets)
#   - full-loop-cleanup-receipt.sh (full_loop_write_cleanup_deferred)
#   - canonical-recovery-helper.sh, worktree-helper.sh (resolved at call time)
#   - Globals: SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_MERGE_CLEANUP_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_MERGE_CLEANUP_LIB_LOADED=1

# --- Post-Merge Worktree Cleanup ---

_merge_current_canonical_dir_for_cleanup() {
	local current_root="$1"
	local porcelain=""
	local canonical_dir=""

	[[ -n "$current_root" ]] || return 1
	porcelain=$(git worktree list --porcelain 2>/dev/null || true)
	[[ -n "$porcelain" ]] || return 1
	canonical_dir="${porcelain%%$'\n'*}"
	canonical_dir="${canonical_dir#worktree }"
	[[ -n "$canonical_dir" && "$canonical_dir" != "$current_root" && -d "$canonical_dir" ]] || return 1
	printf '%s\n' "$canonical_dir"
	return 0
}

_merge_canonical_dir_for_sync() {
	local porcelain=""
	local canonical_dir=""
	porcelain=$(git worktree list --porcelain 2>/dev/null) || return 1
	canonical_dir="${porcelain%%$'\n'*}"
	[[ "$canonical_dir" == worktree\ * ]] || return 1
	canonical_dir="${canonical_dir#worktree }"
	[[ -d "$canonical_dir" ]] || return 1
	printf '%s\n' "$canonical_dir"
	return 0
}

# Resolve a managed repository's canonical path from its registered slug, not
# the current worktree. `full-loop-helper.sh merge PR owner/repo` is allowed
# to run from another repository.
_merge_repo_path_for_slug() {
	local repo_slug="$1"
	local repos_json="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local repo_path=""
	[[ -n "$repo_slug" && -f "$repos_json" ]] || return 1
	repo_path=$(jq -r --arg slug "$repo_slug" '
		.initialized_repos[]?
		| select(((.slug // "") | ascii_downcase) == ($slug | ascii_downcase))
		| .path // empty
	' "$repos_json" 2>/dev/null | sed -n '1p') || repo_path=""
	[[ -n "$repo_path" ]] || return 1
	repo_path="${repo_path/#\~/$HOME}"
	[[ -d "$repo_path" ]] || return 1
	printf '%s\n' "$repo_path"
	return 0
}

_merge_reconcile_planning_publication() {
	local pr_number="$1"
	local repo="$2"
	local merge_sha="$3"
	local canonical_synced="${4:-1}"
	local repo_path=""
	local changed_files=""
	local reconciler="${SCRIPT_DIR}/planning-publication-reconcile.sh"

	[[ -x "$reconciler" && "$merge_sha" =~ ^[0-9a-f]{40}$ ]] || return 0
	changed_files=$(gh api --paginate "repos/${repo}/pulls/${pr_number}/files" --jq '.[].filename' 2>/dev/null || true)
	if ! printf '%s\n' "$changed_files" | grep -qE '^(TODO\.md|todo/tasks/)'; then
		return 0
	fi
	if [[ "$canonical_synced" != "1" ]]; then
		print_warning "Planning publication reconcile deferred for merged PR #${pr_number}: canonical sync pending or no canonical working tree"
		printf 'PLANNING_RECONCILE_NEXT=planning-publication-reconcile.sh reconcile --repo %q --sha %q\n' "$repo" "$merge_sha"
		return 0
	fi
	repo_path=$(_merge_repo_path_for_slug "$repo" 2>/dev/null || true)
	if [[ -z "$repo_path" ]]; then
		print_warning "Planning publication reconcile skipped: canonical path for ${repo} is not registered"
		return 0
	fi
	if (cd "$repo_path" && "$reconciler" reconcile --repo "$repo" --sha "$merge_sha"); then
		print_success "Planning publication reconciled for merged PR #${pr_number}"
	else
		print_warning "Planning publication reconcile deferred for merged PR #${pr_number}"
		printf 'PLANNING_RECONCILE_NEXT=planning-publication-reconcile.sh reconcile --repo %q --sha %q\n' "$repo" "$merge_sha"
	fi
	return 0
}

_merge_current_worktree_cleanup_plan() {
	local pr_head_ref="$1"
	local pr_head_oid="$2"
	local pr_head_repo="$3"
	local repo="$4"
	local cleanup_target=""
	local worktree_path=""
	local branch_name=""
	local delete_remote_branch=""
	local canonical_dir=""

	cleanup_target=$(_merge_current_worktree_cleanup_target "$pr_head_ref" "$pr_head_oid" "$pr_head_repo" "$repo") || return 1
	IFS=$'\t' read -r worktree_path branch_name delete_remote_branch <<<"$cleanup_target"
	canonical_dir=$(_merge_current_canonical_dir_for_cleanup "$worktree_path") || return 1
	printf '%s\t%s\t%s\t%s\n' "$worktree_path" "$branch_name" "$canonical_dir" "$delete_remote_branch"
	return 0
}

_merge_fresh_worktree_cleanup_target() {
	local pr_number="$1"
	local repo="$2"
	local pr_json=""
	pr_json=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo" \
		--json headRefName,headRefOid,headRepository,isCrossRepository 2>/dev/null) || return 1
	printf '%s' "$pr_json" | jq -e --arg string_type "string" '
		(.headRefName | type == $string_type and length > 0)
		and (.headRefOid | type == $string_type and length > 0)
		and (.headRepository.nameWithOwner | type == $string_type and length > 0)
		and (.isCrossRepository | type == "boolean")' >/dev/null 2>&1 || return 1

	local pr_head_ref=""
	local pr_head_oid=""
	local pr_head_repo=""
	local is_cross_repository=""
	IFS=$'\t' read -r pr_head_ref pr_head_oid pr_head_repo is_cross_repository < <(
		printf '%s' "$pr_json" | jq -r '[.headRefName, .headRefOid, .headRepository.nameWithOwner, .isCrossRepository] | @tsv'
	)
	: "$is_cross_repository"
	_merge_current_worktree_cleanup_target "$pr_head_ref" "$pr_head_oid" "$pr_head_repo" "$repo" || return 1
	return 0
}

_merge_fresh_worktree_cleanup_plan() {
	local pr_number="$1"
	local repo="$2"
	local cleanup_target=""
	local worktree_path=""
	local branch_name=""
	local delete_remote_branch=""
	local canonical_dir=""

	cleanup_target=$(_merge_fresh_worktree_cleanup_target "$pr_number" "$repo") || return 1
	IFS=$'\t' read -r worktree_path branch_name delete_remote_branch <<<"$cleanup_target"
	canonical_dir=$(_merge_current_canonical_dir_for_cleanup "$worktree_path") || return 1
	printf '%s\t%s\t%s\t%s\n' "$worktree_path" "$branch_name" "$canonical_dir" "$delete_remote_branch"
	return 0
}

# Resolve the current linked worktree as the cleanup target of a merged PR from
# fresh GitHub evidence. Returns 2 when metadata cannot be queried, 3 when it is
# incomplete, and 1 when the local worktree is not this PR's target.
#   mode "adopt"  (GH#28915): the local branch must equal the PR head ref.
#   mode "retire" (GH#33890): also accepts the same-repository alias that merge
#     cleanup records with delete_remote_branch=0. Alias acceptance is already
#     proven by the exact head OID, registered worktree record and repository
#     identity; marker retirement then requires the finalized receipt to
#     record this exact worktree and branch.
_merge_fresh_merged_worktree_cleanup_target() {
	local pr_number="$1"
	local repo="$2"
	local mode="$3"
	local pr_json=""
	local pr_head_ref=""
	local pr_head_oid=""
	local pr_head_repo=""
	local cleanup_target=""
	local worktree_path=""
	local branch_name=""
	local delete_remote_branch=""
	local current_repo=""

	[[ "$mode" == "adopt" || "$mode" == "retire" ]] || return 1
	pr_json=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo" \
		--json state,mergedAt,mergeCommit,headRefName,headRefOid,headRepository,isCrossRepository 2>/dev/null) || return 2
	printf '%s' "$pr_json" | jq -e '
		.state == "MERGED"
		and (.mergedAt | strings | length > 0)
		and (.mergeCommit.oid | strings | length > 0)
		and (.headRefName | strings | length > 0)
		and (.headRefOid | strings | length > 0)
		and (.headRepository.nameWithOwner | strings | length > 0)
		and (.isCrossRepository == true or .isCrossRepository == false)
	' >/dev/null 2>&1 || return 3
	IFS=$'\t' read -r pr_head_ref pr_head_oid pr_head_repo < <(
		printf '%s' "$pr_json" | jq -r '[.headRefName, .headRefOid, .headRepository.nameWithOwner] | @tsv'
	)
	cleanup_target=$(_merge_current_worktree_cleanup_target "$pr_head_ref" "$pr_head_oid" "$pr_head_repo" "$repo") || return 1
	IFS=$'\t' read -r worktree_path branch_name delete_remote_branch <<<"$cleanup_target"
	if [[ "$branch_name" != "$pr_head_ref" ]]; then
		[[ "$mode" == "retire" && "$delete_remote_branch" == "0" ]] || return 1
	fi
	current_repo=$(_merge_current_github_repo_identity "$worktree_path" 2>/dev/null || true)
	[[ -n "$current_repo" && "$current_repo" == "$repo" ]] || return 1
	printf '%s\n' "$cleanup_target"
	return 0
}

# Strict adoption resolver (GH#28915): renamed local branches are never adopted.
_merge_fresh_adopted_worktree_cleanup_target() {
	local pr_number="$1"
	local repo="$2"
	local rc=0
	_merge_fresh_merged_worktree_cleanup_target "$pr_number" "$repo" adopt || rc=$?
	return "$rc"
}

# Marker retirement resolver (GH#33890): accepts every target merge cleanup can
# record, including the same-repository alias.
_merge_fresh_retirement_worktree_cleanup_target() {
	local pr_number="$1"
	local repo="$2"
	local rc=0
	_merge_fresh_merged_worktree_cleanup_target "$pr_number" "$repo" retire || rc=$?
	return "$rc"
}

_merge_default_branch_for_cleanup() {
	local canonical_dir="$1"
	local default_ref=""
	default_ref=$(git -C "$canonical_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
	default_ref="${default_ref#refs/remotes/origin/}"
	if [[ -n "$default_ref" && "$default_ref" != refs/* ]]; then
		printf '%s\n' "$default_ref"
		return 0
	fi
	printf '%s\n' "main"
	return 0
}

# Remote default-branch tip observed by the last canonical refresh (read-only
# `git ls-remote`; canonical refs are never fetched outside the audited helper).
FULL_LOOP_CANONICAL_REMOTE_HEAD=""

# Query the remote default-branch tip without mutating canonical. A direct
# `git fetch` in canonical is denied by the canonical Git guard (GH#33013), so
# only read-only ls-remote runs here; canonical-recovery-helper.sh owns fetches.
_merge_canonical_remote_head() {
	local canonical_dir="$1"
	local default_branch="$2"
	local ls_output=""
	local remote_head=""
	if ! ls_output=$(git -C "$canonical_dir" ls-remote origin "refs/heads/${default_branch}" 2>&1); then
		if [[ "$ls_output" == *"canonical Git guard"* ]]; then
			print_warning "CANONICAL_SYNC_PENDING=true reason=canonical_guard_denied"
		else
			print_warning "CANONICAL_SYNC_PENDING=true reason=origin_query_failed"
		fi
		return 1
	fi
	remote_head=$(printf '%s\n' "$ls_output" | awk -v ref="refs/heads/${default_branch}" '$2 == ref { print $1; exit }')
	if [[ ! "$remote_head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
		print_warning "CANONICAL_SYNC_PENDING=true reason=origin_query_failed"
		return 1
	fi
	printf '%s\n' "$remote_head"
	return 0
}

_merge_canonical_fast_forward_enabled() {
	[[ "${AIDEVOPS_MERGE_CANONICAL_FAST_FORWARD:-1}" != "0" ]] || return 1
	! _merge_is_headless_session || return 1
	return 0
}

_merge_resolve_canonical_recovery_helper() {
	local candidate=""
	for candidate in "${SCRIPT_DIR}/canonical-recovery-helper.sh" \
		"${HOME:-}/.aidevops/agents/scripts/canonical-recovery-helper.sh"; do
		if [[ -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

# Fast-forward a clean interactive canonical default branch to the merged tip
# through the audited recovery helper. Returns 2 when preconditions exclude the
# attempt (no mutation), 1 when the helper refused, and 0 after a fast-forward.
_merge_fast_forward_canonical() {
	local canonical_dir="$1"
	local default_branch="$2"
	local merge_sha="$3"
	local issue_number="$4"
	local current_branch=""
	local status_output=""
	local canonical_head=""
	local helper=""
	local helper_output=""
	local refusal=""

	_merge_canonical_fast_forward_enabled || return 2
	[[ "$merge_sha" =~ ^[0-9a-f]{40}$ && "$issue_number" =~ ^[0-9]+$ ]] || return 2
	current_branch=$(git -C "$canonical_dir" branch --show-current 2>/dev/null || true)
	[[ -n "$current_branch" && "$current_branch" == "$default_branch" ]] || return 2
	status_output=$(git -C "$canonical_dir" status --porcelain 2>/dev/null) || return 2
	[[ -z "$status_output" ]] || return 2
	canonical_head=$(git -C "$canonical_dir" rev-parse HEAD 2>/dev/null || true)
	[[ -n "$canonical_head" ]] || return 2
	# When the merge commit is already local, prove ancestry before mutating.
	# Otherwise the helper fetches the tip and refuses any non-fast-forward.
	if git -C "$canonical_dir" cat-file -e "${merge_sha}^{commit}" 2>/dev/null &&
		! git -C "$canonical_dir" merge-base --is-ancestor "$canonical_head" "$merge_sha" 2>/dev/null; then
		return 2
	fi
	helper=$(_merge_resolve_canonical_recovery_helper) || {
		print_warning "CANONICAL_SYNC_PENDING=true reason=fast_forward_refused detail=recovery_helper_unavailable"
		return 1
	}
	if helper_output=$(AIDEVOPS_REAL_GIT_BIN="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}" bash "$helper" \
		fast-forward-current --repo "$canonical_dir" --branch "$default_branch" \
		--issue "$issue_number" --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
		print_info "Canonical ${default_branch} fast-forwarded through canonical-recovery-helper.sh"
		# Surface safe outcome records; never forward command output or local paths.
		printf '%s\n' "$helper_output" | grep '^POST_SYNC outcome=' || true
		return 0
	fi
	refusal=$(printf '%s\n' "$helper_output" | grep -m1 'BLOCKED' || true)
	print_warning "CANONICAL_SYNC_PENDING=true reason=fast_forward_refused${refusal:+ detail=${refusal}}"
	return 1
}

# Args: canonical_dir default_branch [merge_sha issue_number]
# Without a merge SHA this is read-only. With one, interactive sessions may
# fast-forward a clean default-branch canonical via the audited helper.
_merge_refresh_canonical_for_cleanup() {
	local canonical_dir="$1"
	local default_branch="$2"
	local merge_sha="${3:-}"
	local issue_number="${4:-}"
	[[ -d "$canonical_dir" && -n "$default_branch" ]] || return 1

	FULL_LOOP_CANONICAL_REMOTE_HEAD=""
	local remote_head=""
	remote_head=$(_merge_canonical_remote_head "$canonical_dir" "$default_branch") || return 1
	FULL_LOOP_CANONICAL_REMOTE_HEAD="$remote_head"
	local current_canonical_branch=""
	current_canonical_branch=$(git -C "$canonical_dir" branch --show-current 2>/dev/null || true)
	local canonical_head=""
	canonical_head=$(git -C "$canonical_dir" rev-parse HEAD 2>/dev/null || true)
	if [[ "$current_canonical_branch" == "$default_branch" && "$canonical_head" == "$remote_head" ]]; then
		print_success "LIFECYCLE_STATE=CANONICAL_SYNCED sha=${remote_head}"
		return 0
	fi
	if [[ -n "$merge_sha" ]]; then
		local ff_rc=0
		_merge_fast_forward_canonical "$canonical_dir" "$default_branch" "$merge_sha" "$issue_number" || ff_rc=$?
		if [[ "$ff_rc" -eq 0 ]]; then
			canonical_head=$(git -C "$canonical_dir" rev-parse HEAD 2>/dev/null || true)
			if [[ -n "$canonical_head" && "$canonical_head" == "$remote_head" ]]; then
				print_success "LIFECYCLE_STATE=CANONICAL_SYNCED sha=${remote_head}"
				return 0
			fi
			if [[ -n "$canonical_head" ]] &&
				git -C "$canonical_dir" merge-base --is-ancestor "$merge_sha" "$canonical_head" 2>/dev/null; then
				FULL_LOOP_CANONICAL_REMOTE_HEAD="$canonical_head"
				print_success "LIFECYCLE_STATE=CANONICAL_SYNCED sha=${canonical_head}"
				return 0
			fi
		fi
	fi
	print_warning "CANONICAL_SYNC_PENDING=true canonical=${canonical_dir} branch=${current_canonical_branch:-detached}"
	return 1
}

_merge_report_canonical_sync_state() {
	local canonical_dir="$1"
	local issue_number="${2:-}"
	local merge_sha="${3:-}"
	if [[ -z "$canonical_dir" ]]; then
		print_warning "CANONICAL_SYNC_PENDING=true reason=canonical_path_unavailable"
		return 1
	fi
	# GH#33381: linked worktrees may share a bare common Git directory. There
	# is no canonical working tree to preserve or fast-forward, so this layout
	# is valid, not a canonical-layout failure; the PR lifecycle completes and
	# only working-tree-dependent follow-ups (planning reconcile) are deferred.
	if [[ "$(git -C "$canonical_dir" rev-parse --is-bare-repository 2>/dev/null || true)" == "true" ]]; then
		print_info "LIFECYCLE_STATE=CANONICAL_SYNC_NOT_APPLICABLE reason=bare_common_dir canonical=${canonical_dir}"
		return 1
	fi
	local default_branch
	default_branch=$(_merge_default_branch_for_cleanup "$canonical_dir")
	if _merge_refresh_canonical_for_cleanup "$canonical_dir" "$default_branch" "$merge_sha" "$issue_number"; then
		return 0
	fi
	local current_branch=""
	local clean=""
	local local_head=""
	local remote_head="$FULL_LOOP_CANONICAL_REMOTE_HEAD"
	local fast_forward_candidate=0
	current_branch=$(git -C "$canonical_dir" branch --show-current 2>/dev/null || true)
	clean=$(git -C "$canonical_dir" status --porcelain 2>/dev/null || true)
	local_head=$(git -C "$canonical_dir" rev-parse HEAD 2>/dev/null || true)
	[[ -n "$remote_head" ]] || remote_head=$(git -C "$canonical_dir" rev-parse "origin/${default_branch}" 2>/dev/null || true)
	if [[ "$current_branch" == "$default_branch" && -z "$clean" && -n "$local_head" && -n "$remote_head" ]]; then
		# An unfetched remote tip cannot be proven locally; the audited
		# fast-forward helper fetches it and refuses any divergence.
		if ! git -C "$canonical_dir" cat-file -e "${remote_head}^{commit}" 2>/dev/null ||
			git -C "$canonical_dir" merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null; then
			fast_forward_candidate=1
		fi
	fi
	if [[ "$fast_forward_candidate" -eq 1 ]]; then
		printf 'CANONICAL_SYNC_NEXT=canonical-recovery-helper.sh fast-forward-current --repo %q --branch %q --issue %q --confirm FAST_FORWARD_CANONICAL_BRANCH\n' "$canonical_dir" "$default_branch" "$issue_number"
	else
		printf 'CANONICAL_SYNC_NEXT=canonical-recovery-helper.sh sync-mirror --repo %q --issue %q --confirm SYNCHRONIZE_CANONICAL_MIRROR\n' "$canonical_dir" "$issue_number"
	fi
	return 1
}

# Sync canonical first (audited fast-forward when eligible) so planning
# reconcile sees the exact merged snapshot (GH#33013).
_merge_sync_canonical_then_reconcile() {
	local pr_number="$1"
	local repo="$2"
	local canonical_dir="${3:-}"
	local canonical_synced=0
	canonical_dir=$(_merge_repo_path_for_slug "$repo" 2>/dev/null || printf '%s' "$canonical_dir")
	_merge_report_canonical_sync_state "$canonical_dir" "${WORKER_ISSUE_NUMBER:-$pr_number}" \
		"${FULL_LOOP_MERGE_SHA:-}" && canonical_synced=1
	_merge_reconcile_planning_publication "$pr_number" "$repo" "${FULL_LOOP_MERGE_SHA:-}" "$canonical_synced"
	return 0
}

_merge_resolve_worktree_helper() {
	if [[ -x "${SCRIPT_DIR}/worktree-helper.sh" ]]; then
		printf '%s\n' "${SCRIPT_DIR}/worktree-helper.sh"
		return 0
	fi
	if [[ -n "${HOME:-}" && -x "${HOME}/.aidevops/agents/scripts/worktree-helper.sh" ]]; then
		printf '%s\n' "${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
		return 0
	fi
	return 1
}

_merge_remove_worktree_for_cleanup() {
	local branch_name="$1"
	local helper_path=""

	helper_path=$(_merge_resolve_worktree_helper 2>/dev/null || true)
	if [[ -n "$helper_path" ]]; then
		WORKTREE_FORCE_REMOVE=1 "$helper_path" remove "$branch_name" --force >/dev/null 2>&1 && return 0
		print_warning "Post-merge worktree cleanup: guarded helper deferred removal for ${branch_name}"
		return 1
	fi

	print_warning "Post-merge worktree cleanup: guarded worktree helper unavailable for ${branch_name}"
	return 1
}
_merge_cleanup_linked_worktree() {
	local cleanup_plan="$1"
	local repo="$2"
	[[ -n "$cleanup_plan" ]] || return 0

	local worktree_path branch_name canonical_dir delete_remote_branch
	IFS=$'\t' read -r worktree_path branch_name canonical_dir delete_remote_branch <<<"$cleanup_plan"
	[[ -n "$worktree_path" && -n "$branch_name" && -n "$canonical_dir" ]] || return 0
	[[ -d "$canonical_dir" ]] || return 0
	print_info "Post-merge worktree cleanup: removing linked worktree ${worktree_path} for ${branch_name} in ${repo}"
	local default_branch=""
	default_branch=$(_merge_default_branch_for_cleanup "$canonical_dir")
	_merge_refresh_canonical_for_cleanup "$canonical_dir" "$default_branch" || true

	if ! cd "$canonical_dir" 2>/dev/null; then
		print_warning "Post-merge worktree cleanup: could not cd to canonical repo ${canonical_dir}"
		return 0
	fi

	if _merge_remove_worktree_for_cleanup "$branch_name"; then
		if [[ "$delete_remote_branch" == "1" ]]; then
			git push origin --delete "$branch_name" >/dev/null 2>&1 || true
		fi
		git branch -D "$branch_name" >/dev/null 2>&1 || true
		print_success "Post-merge worktree cleanup complete for ${branch_name}"
		return 0
	fi

	print_warning "Post-merge worktree cleanup did not remove ${worktree_path}; safety-net cleanup will retry later"
	return 0
}

_merge_record_deferred_cleanup_owner() {
	local pr_number="$1"
	local repo="$2"
	local cleanup_target="$3"
	local release_status="${4:-pending}"
	local executor_completion_state="${5:-FINALIZATION_PENDING}"
	local worktree_path="" branch_name="" delete_remote_branch=""
	IFS=$'\t' read -r worktree_path branch_name delete_remote_branch <<<"$cleanup_target"
	: "$delete_remote_branch"
	[[ -n "$worktree_path" && -n "$branch_name" ]] || return 1
	[[ -d "$worktree_path" ]] || return 1

	local owner_pid=""
	if declare -F _resolve_worktree_owner_pid >/dev/null 2>&1; then
		owner_pid=$(_resolve_worktree_owner_pid "" 2>/dev/null || true)
	fi
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || owner_pid="$PPID"
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1

	local owner_session="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$_FULL_LOOP_OWNER_SESSION_FALLBACK}}}"
	if ! declare -F full_loop_write_cleanup_deferred >/dev/null 2>&1; then
		return 1
	fi
	full_loop_write_cleanup_deferred "$repo" "$pr_number" "$worktree_path" "$branch_name" \
		"$owner_pid" "$owner_session" "$release_status" "$executor_completion_state" >/dev/null || return 1

	local marker_dir="${worktree_path}/.agents"
	local marker_path="${marker_dir}/.full-loop-cleanup-deferred"
	mkdir -p "$marker_dir" || return 1
	# Keep the legacy marker during rollout so an older deployed cleanup
	# supervisor still preserves the live owner. The external receipt above is
	# the durable source of lifecycle truth and survives worktree removal.
	printf '%s\n' "$owner_pid" >"${marker_path}.tmp.$$" || return 1
	mv "${marker_path}.tmp.$$" "$marker_path" || return 1

	if declare -F claim_worktree_ownership >/dev/null 2>&1; then
		claim_worktree_ownership "$worktree_path" "$branch_name" \
			--owner-pid "$owner_pid" \
			--session "$owner_session" \
			--task "post-merge-cleanup" >/dev/null 2>&1 || true
	fi
	return 0
}

