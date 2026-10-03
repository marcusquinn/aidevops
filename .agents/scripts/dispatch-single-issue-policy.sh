#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Issue metadata, trust gates, and signed permission resume for manual dispatch.
# Source through dispatch-single-issue-helper.sh; it owns dependencies and state.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_DSI_POLICY_LOADED:-}" ]] && return 0
_DSI_POLICY_LOADED=1

if [[ -z "${_DSI_SCRIPT_DIR:-}" ]]; then
	_dsi_policy_path="${BASH_SOURCE[0]%/*}"
	[[ "$_dsi_policy_path" == "${BASH_SOURCE[0]}" ]] && _dsi_policy_path="."
	_DSI_SCRIPT_DIR="$(cd "$_dsi_policy_path" && pwd)"
	unset _dsi_policy_path
fi

#######################################
# Validate issue exists, is OPEN, and emit metadata via stdout (single jq call).
# Sets _DSI_ISSUE_TITLE, _DSI_ISSUE_LABELS, _DSI_ISSUE_URL, _DSI_ISSUE_ASSIGNEES.
# Args:
#   $1 - issue number
#   $2 - owner/repo slug
# Returns: 0 ok, 1 not found / closed / API error
#######################################
_dsi_load_issue_meta() {
	local issue_number="$1"
	local repo_slug="$2"
	local meta_json

	meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees,url 2>/dev/null) || meta_json=""

	if [[ -z "$meta_json" ]]; then
		_dsi_err "Cannot fetch issue #${issue_number} from ${repo_slug} (not found, no permission, or network error)"
		return 1
	fi

	local state state_normalized
	state=$(printf '%s' "$meta_json" | jq -r '.state // "UNKNOWN"')
	state_normalized=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
	if [[ "$state_normalized" != "OPEN" ]]; then
		_dsi_err "Issue #${issue_number} is ${state} (must be OPEN for dispatch)"
		return 1
	fi

	_DSI_ISSUE_META_JSON="$meta_json"
	_DSI_ISSUE_TITLE=$(printf '%s' "$meta_json" | jq -r '.title // ""')
	_DSI_ISSUE_URL=$(printf '%s' "$meta_json" | jq -r '.url // ""')
	_DSI_ISSUE_LABELS=$(printf '%s' "$meta_json" | jq -r '[.labels[].name] | join(",")')
	_DSI_ISSUE_ASSIGNEES=$(printf '%s' "$meta_json" | jq -r '[.assignees[].login] | join(",")')
	return 0
}

#######################################
# Determine whether the target number is a pull request, not a plain Issue.
#
# Manual dispatch can be pointed at an arbitrary number, and `gh issue view`
# accepts PR numbers through the issue facade. Use the REST issue object's
# `pull_request` marker as a trust-boundary guard before any ceremony writes.
#
# Args:
#   $1 - issue number
#   $2 - owner/repo slug
# Returns:
#   0 target is a PR, 1 target is a plain Issue, 2 unable to verify
#######################################
_dsi_target_is_pull_request() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_json="" has_pull_request=""

	_DSI_TARGET_JSON=""
	target_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 2
	_DSI_TARGET_JSON="$target_json"
	has_pull_request=$(printf '%s' "$target_json" | jq -r 'has("pull_request")' 2>/dev/null) || return 2
	if [[ "$has_pull_request" == "$_DSI_JSON_TRUE" ]]; then
		return 0
	fi
	if [[ "$has_pull_request" == "false" ]]; then
		return 1
	fi
	return 2
}

#######################################
# Block manual dispatch when live interactive/review hold labels are present.
# Args: $1 - labels CSV
# Returns: 0 when safe, 1 when held
#######################################
_dsi_guard_no_interactive_hold() {
	local labels_csv="$1"
	local labels_with_commas=""
	labels_with_commas=$(printf ',%s,' "$labels_csv")
	if [[ "$labels_with_commas" == *",status:in-review,"* && "$labels_with_commas" != *",auto-dispatch,"* ]]; then
		_dsi_err "Target carries an interactive review hold label; refusing worker dispatch (GH#22948)"
		return 1
	fi
	if [[ "$labels_with_commas" == *",origin:interactive,"* && "$labels_with_commas" != *",auto-dispatch,"* ]]; then
		_dsi_err "Target carries an interactive review hold label; refusing worker dispatch (GH#22948)"
		return 1
	fi
	return 0
}

#######################################
# Independently verify issue-author authority before a manual worker launch.
# This closes the gap where creation-time NMR labeling failed and the manual
# dispatcher previously treated the missing label as approval.
# Args: $1 - issue number, $2 - owner/repo slug
# Returns: 0 when trusted/approved, 1 when dispatch must remain blocked
#######################################
_dsi_guard_issue_author_trust() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_json="${_DSI_TARGET_JSON:-}"
	local author_meta="" author_association="NONE" author_type="" author_login="" external_source="false"

	if [[ -z "$issue_json" ]]; then
		issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || issue_json=""
	fi
	if [[ -n "$issue_json" ]]; then
		author_meta=$(printf '%s' "$issue_json" | jq -r \
			'[.author_association // "NONE", .user.type // "", .user.login // "", (([.labels[]?.name] | index("external-contributor") != null) | tostring)] | join("|")' 2>/dev/null) || author_meta=""
	fi
	if [[ -n "$author_meta" ]]; then
		IFS='|' read -r author_association author_type author_login external_source <<<"$author_meta"
	fi
	[[ -n "$author_association" ]] || author_association="NONE"
	if [[ "$author_type" == "Bot" && "$external_source" != "$_DSI_JSON_TRUE" ]]; then
		return 0
	fi

	local authority_rc=1
	if [[ "$external_source" != "$_DSI_JSON_TRUE" ]] && declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1; then
		authority_rc=0
		_gh_actor_has_repo_write_authority "$repo_slug" "$author_login" "$author_association" || authority_rc=$?
	elif [[ "$external_source" != "$_DSI_JSON_TRUE" ]]; then
		authority_rc=2
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 0
	fi

	if [[ ! -x "$_DSI_APPROVAL_HELPER" ]]; then
		_dsi_err "Issue-author approval verifier is unavailable; refusing manual worker dispatch"
		return 1
	fi
	local verification=""
	verification=$("$_DSI_APPROVAL_HELPER" verify "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ "$verification" == "$_DSI_VERIFIED" ]]; then
		return 0
	fi
	if [[ -n "$verification" && "$verification" != "NO_APPROVAL" ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} has an unverifiable approval marker (${verification}); refusing manual worker dispatch"
		return 1
	fi

	#aidevops:trust-boundary -- label mutation is containment, never the authority source.
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$issue_number" --repo "$repo_slug" \
			--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
	else
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
	fi
	_dsi_err "Issue #${issue_number} in ${repo_slug} has untrusted, external-source, or unknown author authority (${author_association}; external_source=${external_source}; ${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}) and no verified approval; refusing manual worker dispatch"
	return 1
}

#######################################
# Block manual worker dispatch until maintainer-review trust gates are cleared.
# Args: $1 - labels CSV, $2 - issue number, $3 - owner/repo slug
# Returns: 0 when safe, 1 when maintainer review is still required
#######################################
_dsi_guard_no_maintainer_review_required() {
	local labels_csv="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local labels_with_commas=""
	labels_with_commas=$(printf ',%s,' "$labels_csv")

	#aidevops:trust-boundary -- manual dispatch must not bypass signed/maintainer issue approval.
	if [[ "$labels_with_commas" == *",needs-maintainer-review,"* ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} still requires maintainer review; refusing manual worker dispatch"
		_dsi_info "  Required action: run 'sudo aidevops approve issue ${issue_number} ${repo_slug}' or record an equivalent maintainer decision before dispatch."
		return 1
	fi

	return 0
}

_dsi_guard_no_maintainer_permission_required() {
	local labels_csv="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local labels_with_commas=""
	labels_with_commas=$(printf ',%s,' "$labels_csv")
	if [[ "$labels_with_commas" == *",needs-maintainer-permissions,"* ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} is waiting for a scoped maintainer permission grant; refusing manual worker dispatch"
		_dsi_info "  Run the request-specific 'sudo aidevops approve permissions ... --request perm-...' command from the issue comment."
		return 1
	fi
	return 0
}

_dsi_guard_permission_history_verified() {
	local issue_number="$1"
	local repo_slug="$2"
	local events_json labeled_count verification
	events_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/events?per_page=100" --paginate --slurp 2>/dev/null) || {
		_dsi_err "Unable to inspect permission-request history for issue #${issue_number} in ${repo_slug}; refusing manual worker dispatch"
		return 1
	}
	labeled_count=$(jq '[.[][]? | select(.event == "labeled" and .label.name == "needs-maintainer-permissions")] | length' <<<"$events_json" 2>/dev/null) || {
		_dsi_err "Permission-request history for issue #${issue_number} in ${repo_slug} is malformed; refusing manual worker dispatch"
		return 1
	}
	[[ "$labeled_count" -gt 0 ]] || return 0
	[[ -x "$_DSI_APPROVAL_HELPER" ]] || {
		_dsi_err "Permission verification helper is unavailable; refusing manual worker dispatch"
		return 1
	}
	verification=$("$_DSI_APPROVAL_HELPER" verify-permissions issue "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ "$verification" == "NO_REQUEST" || "$verification" == "WITHDRAWN" ]]; then
		return 0
	fi
	if [[ "$verification" == "$_DSI_VERIFIED" ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} has a signed grant bound to its original worker session and worktree; a new manual worker cannot consume it"
		_dsi_info "  Run 'dispatch-single-issue-helper.sh resume ${issue_number} ${repo_slug}' to reuse the verified original binding."
		return 1
	fi
	_dsi_err "Issue #${issue_number} in ${repo_slug} has permission-request history without a current matching signed grant (${verification:-NO_APPROVAL}); refusing manual worker dispatch"
	return 1
}

# Discover only registered linked worktrees of this repository. The marker is a
# candidate, never authority: verify its complete signed binding before accepting
# it. Missing or ambiguous candidates fail closed.
_dsi_resolve_permission_resume() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="" line="" worktree="" git_dir="" marker=""
	local request="" session="" branch="" digest="" verification="" matches=0
	local matched_worktree="" matched_branch="" matched_session="" matched_request=""
	repo_path=$(_dsi_repo_path_for_slug "$repo_slug") || return 1
	[[ -d "$repo_path" && -x "$_DSI_APPROVAL_HELPER" ]] || return 1
	while IFS= read -r line; do
		[[ "$line" == "worktree "* ]] || continue
		worktree="${line#worktree }"
		[[ -f "$worktree/.git" ]] || continue
		[[ "$(_dsi_repo_slug_for_worktree "$worktree")" == "$repo_slug" ]] || continue
		git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || continue
		marker="${git_dir}/aidevops-permission-pending"
		[[ -f "$marker" ]] || continue
		request=$(jq -er --arg issue "$issue_number" '
			select(.issue == ($issue | tonumber)) | .request_id
			| select(type == "string" and test("^perm-[a-f0-9]{16}$"))
		' "$marker" 2>/dev/null) || continue
		session=$(jq -er --arg prefix "manual-cli-${issue_number}-" '
			.session | select(type == "string" and startswith($prefix))
			| select(test("^manual-cli-[0-9]+-[0-9]+$"))
		' "$marker" 2>/dev/null) || continue
		branch=$(git -C "$worktree" branch --show-current) || continue
		[[ -n "$branch" ]] || continue
		digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$worktree") || return 1
		verification=$("$_DSI_APPROVAL_HELPER" verify-permissions issue "$issue_number" "$repo_slug" \
			"$request" "$session" "$branch" "$digest" 2>/dev/null) || continue
		[[ "$verification" == "$_DSI_VERIFIED" ]] || continue
		matches=$((matches + 1))
		matched_worktree="$worktree"
		matched_branch="$branch"
		matched_session="$session"
		matched_request="$request"
	done < <(git -C "$repo_path" worktree list --porcelain)
	if [[ "$matches" -ne 1 ]]; then
		_dsi_err "Resume requires exactly one preserved manual worktree with a current signed binding (found ${matches})"
		return 1
	fi
	_DSI_WORKTREE_PATH="$matched_worktree"
	_DSI_WORKTREE_BRANCH="$matched_branch"
	_DSI_RESUME_SESSION="$matched_session"
	_DSI_RESUME_REQUEST="$matched_request"
	_DSI_DISPATCH_BASE_BRANCH=$(_dsi_dispatch_base_branch "$repo_slug" "$repo_path")
	return 0
}

cmd_resume() {
	local rc=0
	_DSI_RESUME_MODE=1
	cmd_dispatch "$@" || rc=$?
	_DSI_RESUME_MODE=0
	return "$rc"
}

#######################################
# Check parent-task gate. parent-task is always a hard block (never single-dispatch).
# Args: $1 - labels CSV (from _dsi_load_issue_meta)
# Returns: 0 not parent-task, 1 IS parent-task (block)
#######################################
_dsi_check_parent_task() {
	local labels_csv="$1"
	local needle=",${labels_csv},"
	if [[ "$needle" == *",parent-task,"* ]]; then
		_dsi_err "Issue is labeled parent-task — these are decomposition trackers and cannot be single-dispatched"
		return 1
	fi
	return 0
}
