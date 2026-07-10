#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Merge -- merge execution, admin fallback, resource unlocking
# =============================================================================
# Sub-library for full-loop-helper.sh orchestrator. Contains merge repo
# resolution, admin-merge fallback signaling, merge execution, resource
# unlocking (PR/issue), stacked PR retargeting, and the cmd_merge command.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-merge.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     gh_pr_comment, release_interactive_claim_on_merge)
#   - shared-claim-lifecycle.sh (release_interactive_claim_on_merge)
#   - shared-phase-filing.sh (auto_file_next_phase)
#   - full-loop-helper-commit.sh (cmd_pre_merge_gate)
#   - Globals: SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_MERGE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_MERGE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Sequential phase auto-filing parity with pulse-merge.sh (t2740/GH#22629).
# shellcheck source=./shared-phase-filing.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/shared-phase-filing.sh"

# Targeted remediation for stale GitHub CLI HTTP cache entries that can make
# `gh pr merge` return a cached 401 even after live gh auth succeeds (GH#24656).
# shellcheck source=./gh-merge-cache-remediation-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/gh-merge-cache-remediation-lib.sh"

# --- Repo Resolution ---

# _merge_resolve_repo — resolve repo slug from argument or auto-detect from git remote.
# Echoes the resolved repo slug. Returns 1 when detection fails.
_merge_resolve_repo() {
	local repo_arg="${1:-}"
	if [[ -n "$repo_arg" ]]; then
		printf '%s\n' "$repo_arg"
		return 0
	fi
	local detected=""
	detected=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
	if [[ -z "$detected" ]]; then
		print_error "Cannot detect repo. Pass REPO as second argument."
		return 1
	fi
	printf '%s\n' "$detected"
	return 0
}

# --- Admin Merge Fallback Signaling ---

# _signal_admin_merge_fallback — post PR comment, audit log, and label after --admin fallback merge.
#
# t2247: When `_merge_execute` falls back to `--admin` because branch protection
# blocked a plain merge, this function records three signaling artifacts so the
# fallback is visible at PR level (not just in session logs).
#
# Args: pr_number repo merge_method original_error_output
# Returns: 0 always (signaling failures are non-fatal — the merge already succeeded)
_signal_admin_merge_fallback() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local original_error="$4"

	# (a) PR comment with error context, ops markers, and remediation
	local _sig_footer=""
	_sig_footer=$(gh-signature-helper.sh footer --model "${AIDEVOPS_MODEL:-unknown}" 2>/dev/null) || _sig_footer=""

	local _admin_comment="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
## Admin Merge Fallback (t2247)

Branch protection blocked the plain \`gh pr merge\` for PR #${pr_number}. The merge succeeded using \`--admin\` fallback (per GH#18538 — workers share the maintainer's \`gh auth\`).

**Merge method:** \`${merge_method}\`

<details>
<summary>Original branch-protection error</summary>

\`\`\`text
${original_error}
\`\`\`

</details>

**Remediation:** If this bypass was unintended, revert with \`gh pr revert ${pr_number} --repo ${repo}\` and investigate why review bots did not approve.
<!-- ops:end -->
${_sig_footer}"

	if gh_pr_comment "$pr_number" --repo "$repo" --body "$_admin_comment" >/dev/null 2>&1; then
		print_info "Admin-merge fallback comment posted on PR #${pr_number}"
	else
		print_warning "Failed to post admin-merge fallback comment on PR #${pr_number}"
	fi

	# (b) Audit log entry
	if command -v audit-log-helper.sh >/dev/null 2>&1; then
		audit-log-helper.sh log merge-admin-fallback \
			"PR #${pr_number} in ${repo} — ${merge_method} — branch protection blocked plain merge" \
			2>/dev/null || true
	fi

	# (c) admin-merge label for cross-PR filtering
	gh pr edit "$pr_number" --repo "$repo" --add-label "admin-merge" 2>/dev/null || true

	return 0
}

# --- Merge Execution ---

# _merge_output_is_graphql_rate_limit — classify GitHub CLI GraphQL quota failures.
#
# Args: merge_output
# Returns: 0 when the failure is specifically a GraphQL rate-limit/transport
# exhaustion class; 1 for policy, checks, conflict, and generic merge errors.
_merge_output_is_graphql_rate_limit() {
	local merge_output="$1"

	printf '%s' "$merge_output" | grep -qiE 'GraphQL:.*API rate limit|GraphQL.*rate limit|rateLimitExceeded'
	return $?
}

_merge_output_is_review_policy_block() {
	local merge_output="$1"

	printf '%s' "$merge_output" | grep -qiE 'At least [0-9]+ approving review|approving review is required|review required|cannot approve your own pull request|can not approve your own pull request|self-approval'
	return $?
}

_merge_is_headless_session() {
	case "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${Claude_HEADLESS:-}${GITHUB_ACTIONS:-}" in
	*true* | *1*) return 0 ;;
	*) return 1 ;;
	esac
}

_merge_pr_ready_for_interactive_admin_bypass() {
	local pr_number="$1"
	local repo="$2"
	local pr_json="${3:-}"

	if [[ -z "$pr_json" ]]; then
		pr_json=$(gh pr view "$pr_number" --repo "$repo" \
			--json isDraft,reviewDecision,statusCheckRollup 2>/dev/null) || return 1
	fi

	printf '%s' "$pr_json" | jq -e '
		def up(v): (v // "" | ascii_upcase);
		def passish: (up(.conclusion) == "SUCCESS" or up(.conclusion) == "NEUTRAL" or up(.conclusion) == "SKIPPED" or up(.state) == "SUCCESS");
		(.isDraft != true)
		and ((.reviewDecision // "") != "CHANGES_REQUESTED")
		and ([.statusCheckRollup[]? | select(passish | not)] | length) == 0
	' >/dev/null
	return $?
}

_merge_try_interactive_admin_auto_fallback() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local merge_output="$4"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo" ]] || return 1
	! _merge_is_headless_session || return 1
	_merge_output_is_review_policy_block "$merge_output" || return 1
	_merge_pr_ready_for_interactive_admin_bypass "$pr_number" "$repo" || return 1

	#aidevops:trust-boundary -- interactive admin fallback still enforces linked NMR crypto gate before bypassing review-count protection.
	_merge_guard_admin_merge_maintainer_review "$pr_number" "$repo" || return 2
	print_info "Auto-merge is blocked only by review-required branch policy/self-approval; interactive maintainer session is using --admin merge after gates passed."
	if gh pr merge "$pr_number" --repo "$repo" "$merge_method" --admin 2>&1; then
		print_success "PR #${pr_number} merged with interactive --admin fallback"
		_signal_admin_merge_fallback "$pr_number" "$repo" "$merge_method" "$merge_output"
		return 0
	fi

	print_error "Merge failed for PR #${pr_number} (even with --admin — maintainer gate or admin rights missing)"
	return 2
}

_merge_linked_issue_numbers() {
	local pr_number="$1"
	local repo="$2"
	local pr_json="${3:-}"
	local issue_numbers=""

	if [[ -z "$pr_json" ]]; then
		pr_json=$(gh pr view "$pr_number" --repo "$repo" \
			--json closingIssuesReferences,body 2>/dev/null) || return 1
	fi

	issue_numbers=$(printf '%s' "$pr_json" | jq -r '.closingIssuesReferences[]?.number // empty') || return 1

	if [[ -z "$issue_numbers" ]]; then
		issue_numbers=$(printf '%s' "$pr_json" | jq -r '.body // ""' |
			grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#[0-9]+' |
			grep -oE '[0-9]+' || true)
	fi

	printf '%s\n' "$issue_numbers" | grep -E '^[0-9]+$' | sort -u || true
	return 0
}

_merge_issue_requires_maintainer_review() {
	local issue_number="$1"
	local repo="$2"
	local labels_csv=""

	labels_csv=$(gh issue view "$issue_number" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 2
	if [[ ",${labels_csv}," == *",needs-maintainer-review,"* ]]; then
		return 0
	fi
	return 1
}

_merge_guard_admin_merge_maintainer_review() {
	local pr_number="$1"
	local repo="$2"
	local issue_numbers=""
	local issue_number=""
	local blocked_issues=""
	local verify_rc=0

	issue_numbers=$(_merge_linked_issue_numbers "$pr_number" "$repo") || {
		print_error "Admin merge blocked: unable to verify linked issues for PR #${pr_number}; refusing to override branch protection"
		return 1
	}

	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		verify_rc=0
		_merge_issue_requires_maintainer_review "$issue_number" "$repo" || verify_rc=$?
		if [[ "$verify_rc" -eq 0 ]]; then
			blocked_issues+=" #${issue_number}"
		elif [[ "$verify_rc" -ne 1 ]]; then
			print_error "Admin merge blocked: unable to verify maintainer-review labels on issue #${issue_number}"
			return 1
		fi
	done <<<"$issue_numbers"

	#aidevops:trust-boundary -- admin merge must not bypass signed/maintainer issue approval.
	if [[ -n "$blocked_issues" ]]; then
		print_error "Admin merge blocked: linked issue(s)${blocked_issues} still require maintainer review"
		print_info "Required action: run 'sudo aidevops approve issue <issue_number> ${repo}' or record an equivalent maintainer decision before merging."
		return 1
	fi

	return 0
}

_merge_fetch_head_sha_rest() {
	local pr_number="$1"
	local repo="$2"
	local head_sha=""
	head_sha=$(gh api "repos/${repo}/pulls/${pr_number}" --jq '.head.sha // empty' 2>/dev/null || true)
	if [[ -z "$head_sha" ]]; then
		return 1
	fi
	printf '%s\n' "$head_sha"
	return 0
}

# _merge_rest_fallback — squash/merge/rebase a PR via the REST pull merge endpoint.
#
# This is a transport fallback only. It is called after review-bot-gate has
# passed and only when `gh pr merge` failed because its GraphQL path was rate
# limited. The REST endpoint still enforces branch protection and mergeability;
# failures remain failures.
#
# Args: pr_number repo merge_method expected_head_sha
# Returns: 0 = merged, 1 = REST merge failed
_merge_rest_fallback() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local expected_head_sha="$4"
	local rest_method="${merge_method#--}"
	local rest_out="" rest_rc=0

	if [[ -z "$expected_head_sha" ]]; then
		print_error "REST merge fallback unavailable: PR head SHA was not verified before merge"
		return 1
	fi

	case "$rest_method" in
	squash | merge | rebase) ;;
	*)
		print_error "Unsupported merge method for REST fallback: ${merge_method}"
		return 1
		;;
	esac

	print_info "GraphQL rate limit blocked gh pr merge; retrying via REST pull merge endpoint with verified head SHA ${expected_head_sha}..."
	if rest_out=$(gh api -X PUT "repos/${repo}/pulls/${pr_number}/merge" \
		-f "sha=${expected_head_sha}" \
		-f "merge_method=${rest_method}" 2>&1); then
		rest_rc=0
	else
		rest_rc=$?
	fi

	printf '%s\n' "$rest_out"
	if [[ $rest_rc -eq 0 ]]; then
		print_success "PR #${pr_number} merged via REST fallback (${rest_method})"
		return 0
	fi

	print_error "REST merge fallback failed for PR #${pr_number}"
	return 1
}

# _merge_execute — attempt `gh pr merge` with optional --admin fallback on branch-protection errors.
#
# GH#18538: branch protection that requires an approving review rejects plain
# `gh pr merge`. Workers share the owner's gh auth, so --admin works when the
# authed user has admin rights. We only fall back to --admin when the caller
# did not explicitly pass --admin or --auto (explicit intent is never overridden).
#
# GH#18731: --admin / --auto are explicit caller intents; when present, the
# error-retry path is skipped entirely.
#
# Bash 3.2 note: `"${arr[@]}"` raises "unbound variable" under set -u when the
# array is empty. The `${arr[@]+"${arr[@]}"}` form expands to zero words safely.
#
# Args: pr_number repo merge_method has_admin has_auto
# Returns: 0 = merged or queued, 1 = failed
_merge_execute() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local has_admin="$4"
	local has_auto="$5"

	# Reconstruct flags array from boolean sentinels (avoids passing arrays across function calls).
	local merge_flags=()
	[[ "$has_admin" -eq 1 ]] && merge_flags+=("--admin")
	[[ "$has_auto" -eq 1 ]] && merge_flags+=("--auto")
	if [[ "$has_admin" -eq 1 ]]; then
		_merge_guard_admin_merge_maintainer_review "$pr_number" "$repo" || return 1
	fi

	local merge_desc="$merge_method"
	[[ ${#merge_flags[@]} -gt 0 ]] && merge_desc+=" ${merge_flags[*]}"
	print_info "Merging PR #${pr_number} in ${repo} (${merge_desc})..."

	local pre_merge_head_sha=""
	if [[ "$has_auto" -eq 0 ]]; then
		pre_merge_head_sha=$(_merge_fetch_head_sha_rest "$pr_number" "$repo" || true)
		if [[ -z "$pre_merge_head_sha" ]]; then
			print_warning "Could not verify PR head SHA before merge; REST rate-limit fallback will be unavailable"
		fi
	fi

	# Capture output AND exit code under set -e. A bare assignment `out=$(cmd)`
	# triggers errexit before `rc=$?` is reached; the if-form keeps both available.
	# (GH#18538 follow-up to PR #18748 — the bare-assignment form shipped as a bug.)
	local _merge_out="" _merge_rc=0
	if _merge_out=$(gh pr merge "$pr_number" --repo "$repo" "$merge_method" ${merge_flags[@]+"${merge_flags[@]}"} 2>&1); then
		_merge_rc=0
	else
		_merge_rc=$?
	fi
	if [[ $_merge_rc -ne 0 ]] && gh_merge_remediate_stale_auth_cache "$_merge_out" "full-loop PR #${pr_number} in ${repo}" ""; then
		local _merge_retry_out="" _merge_original_out="$_merge_out"
		print_info "gh pr merge returned 401 while live gh auth succeeds; quarantined stale gh cache entries and retrying once..."
		if _merge_retry_out=$(gh pr merge "$pr_number" --repo "$repo" "$merge_method" ${merge_flags[@]+"${merge_flags[@]}"} 2>&1); then
			_merge_out="$_merge_retry_out"
			_merge_rc=0
		else
			_merge_rc=$?
			_merge_out="${_merge_original_out}

[retry after stale gh cache remediation]
${_merge_retry_out}"
		fi
	fi

	if [[ $_merge_rc -ne 0 ]]; then
		printf '%s\n' "$_merge_out"
		# Only use REST fallback for GraphQL quota transport failures after the
		# caller reached the merge execution stage (cmd_merge runs review-bot-gate
		# first). Do not turn --auto into an immediate REST merge.
		if [[ $has_auto -eq 0 ]] && _merge_output_is_graphql_rate_limit "$_merge_out"; then
			_merge_rest_fallback "$pr_number" "$repo" "$merge_method" "$pre_merge_head_sha" && return 0
			return 1
		elif [[ $has_admin -eq 0 && $has_auto -eq 1 ]]; then
			local auto_admin_rc=0
			_merge_try_interactive_admin_auto_fallback "$pr_number" "$repo" "$merge_method" "$_merge_out" || auto_admin_rc=$?
			[[ "$auto_admin_rc" -eq 0 ]] && return 0
			[[ "$auto_admin_rc" -eq 2 ]] && return 1
			print_error "Merge failed for PR #${pr_number}"
			return 1
		# Only fall back to --admin when caller passed neither --admin nor --auto.
		elif [[ $has_admin -eq 0 && $has_auto -eq 0 ]] &&
			printf '%s' "$_merge_out" | grep -qE 'base branch policy prohibits|Required status checks? (is|are) expected|At least [0-9]+ approving review'; then
			_merge_guard_admin_merge_maintainer_review "$pr_number" "$repo" || return 1
			print_info "Branch protection blocked plain merge; retrying with --admin (workers share the maintainer's gh auth per GH#18538)..."
			if gh pr merge "$pr_number" --repo "$repo" "$merge_method" --admin 2>&1; then
				print_success "PR #${pr_number} merged with --admin fallback"
				# t2247: Signal that admin-merge fallback was used — three artifacts:
				# (a) PR comment with error context + remediation
				# (b) Audit log entry
				# (c) admin-merge label for cross-PR filtering
				_signal_admin_merge_fallback "$pr_number" "$repo" "$merge_method" "$_merge_out"
				return 0
			else
				print_error "Merge failed for PR #${pr_number} (even with --admin — maintainer gate or admin rights missing)"
				return 1
			fi
		else
			print_error "Merge failed for PR #${pr_number}"
			return 1
		fi
	fi

	printf '%s\n' "$_merge_out"
	if [[ $has_auto -eq 1 ]]; then
		print_success "PR #${pr_number} queued for auto-merge"
	else
		print_success "PR #${pr_number} merged successfully"
	fi
	return 0
}

# --- Resource Unlocking ---

# _merge_unlock_resources — unlock PR and linked issue after worker self-merge.
#
# t1934: Issues/PRs are locked at dispatch time to prevent prompt injection.
# The worker merge path must unlock them — the pulse deterministic merge path
# has its own unlock, but workers that self-merge bypass it.
#
# Args: pr_number repo
_merge_unlock_resources() {
	local pr_number="$1"
	local repo="$2"

	gh issue unlock "$pr_number" --repo "$repo" >/dev/null 2>&1 || true

	# Find and unlock the issue linked via "Resolves/Closes/Fixes #NNN" in the PR body.
	local _linked_issue=""
	_linked_issue=$(gh pr view "$pr_number" --repo "$repo" --json body \
		--jq '.body' 2>/dev/null |
		grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#[0-9]+' |
		grep -oE '[0-9]+' | head -1) || _linked_issue=""
	if [[ -n "$_linked_issue" && "$_linked_issue" =~ ^[0-9]+$ ]]; then
		gh issue unlock "$_linked_issue" --repo "$repo" >/dev/null 2>&1 || true
	fi

	return 0
}

# --- Stacked PR Retargeting ---

# _retarget_stacked_children_interactive — retarget open PRs stacked on the
# head branch of the PR that is about to be merged. GitHub auto-closes stacked
# children when their base branch disappears after the delete-on-merge step.
# This runs before every interactive merge (cmd_merge). The pulse equivalent
# is _retarget_stacked_children in pulse-merge.sh. (t2412 / GH#20005)
#
# Limitation: only direct children are retargeted; grandchildren are handled
# when their own parent merges and fires this function in turn.
#
# Args: pr_number repo
_retarget_stacked_children_interactive() {
	local pr_number="$1"
	local repo="$2"
	local parent_head_ref
	parent_head_ref=$(gh pr view "$pr_number" --repo "$repo" --json headRefName -q '.headRefName' 2>/dev/null) || parent_head_ref=""
	if [[ -z "$parent_head_ref" ]]; then
		return 0
	fi

	local children
	children=$(gh pr list --repo "$repo" --base "$parent_head_ref" --state open --json number -q '.[].number' 2>/dev/null) || children=""
	if [[ -z "$children" ]]; then
		return 0
	fi

	local default_branch
	default_branch=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
	default_branch="${default_branch:-main}"

	local child
	while IFS= read -r child; do
		[[ -z "$child" ]] && continue
		print_info "Retargeting stacked PR #${child} from '${parent_head_ref}' to '${default_branch}' before merging PR #${pr_number} (t2412)"
		gh pr edit "$child" --repo "$repo" --base "$default_branch" 2>&1 || true
	done <<<"$children"
	return 0
}

# --- Post-Merge Worktree Cleanup ---

_merge_current_worktree_cleanup_plan() {
	local pr_head_ref="$1"
	[[ -n "$pr_head_ref" ]] || return 1

	local current_branch=""
	current_branch=$(git branch --show-current 2>/dev/null || true)
	[[ -n "$current_branch" && "$current_branch" == "$pr_head_ref" ]] || return 1

	local current_root=""
	current_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	[[ -n "$current_root" ]] || return 1

	local porcelain=""
	porcelain=$(git worktree list --porcelain 2>/dev/null || true)
	[[ -n "$porcelain" ]] || return 1

	local canonical_dir=""
	canonical_dir="${porcelain%%$'\n'*}"
	canonical_dir="${canonical_dir#worktree }"
	[[ -n "$canonical_dir" && "$canonical_dir" != "$current_root" ]] || return 1

	printf '%s\t%s\t%s\n' "$current_root" "$current_branch" "$canonical_dir"
	return 0
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

_merge_refresh_canonical_for_cleanup() {
	local canonical_dir="$1"
	local default_branch="$2"
	[[ -d "$canonical_dir" && -n "$default_branch" ]] || return 1

	local current_canonical_branch=""
	current_canonical_branch=$(git -C "$canonical_dir" branch --show-current 2>/dev/null || true)

	# Pull only when the canonical worktree is already on the default branch. If a
	# user has another active branch checked out there, update the local default
	# branch ref via fetch instead so cleanup never merges default into that branch.
	if [[ "$current_canonical_branch" == "$default_branch" ]]; then
		if git -C "$canonical_dir" pull --ff-only origin "$default_branch" >/dev/null 2>&1; then
			return 0
		fi
	elif git -C "$canonical_dir" fetch origin "$default_branch:$default_branch" >/dev/null 2>&1; then
		return 0
	fi
	print_warning "Post-merge worktree cleanup: canonical pull/fetch skipped/failed for ${canonical_dir}; continuing cleanup"
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

	local worktree_path="" branch_name="" canonical_dir=""
	IFS=$'\t' read -r worktree_path branch_name canonical_dir <<<"$cleanup_plan"
	[[ -n "$worktree_path" && -n "$branch_name" && -n "$canonical_dir" ]] || return 0
	[[ -d "$canonical_dir" ]] || return 0

	print_info "Post-merge worktree cleanup: removing linked worktree ${worktree_path} for ${branch_name} in ${repo}"
	local default_branch=""
	default_branch=$(_merge_default_branch_for_cleanup "$canonical_dir")
	_merge_refresh_canonical_for_cleanup "$canonical_dir" "$default_branch"

	if ! cd "$canonical_dir" 2>/dev/null; then
		print_warning "Post-merge worktree cleanup: could not cd to canonical repo ${canonical_dir}"
		return 0
	fi

	if _merge_remove_worktree_for_cleanup "$branch_name"; then
		git push origin --delete "$branch_name" >/dev/null 2>&1 || true
		git branch -D "$branch_name" >/dev/null 2>&1 || true
		print_success "Post-merge worktree cleanup complete for ${branch_name}"
		return 0
	fi

	print_warning "Post-merge worktree cleanup did not remove ${worktree_path}; safety-net cleanup will retry later"
	return 0
}

# --- Merge Command ---

# Merge wrapper (GH#17541) — enforces review-bot-gate then merges.
# Single command that replaces the multi-step protocol (wait + merge).
# Workers call this instead of bare `gh pr merge`.
#
# Usage: full-loop-helper.sh merge <PR_NUMBER> [REPO] [--squash|--merge|--rebase] [--admin] [--auto]
#   --admin  pass --admin to gh pr merge (GH#18731 — owner-only bypass of
#            branch protection for self-authored PRs on personal-account
#            repos; skips the error-retry path since intent is explicit)
#   --auto   pass --auto to gh pr merge (GH#18731 — queues auto-merge to
#            run when required checks pass, rather than merging now)
# Note: --admin and --auto are mutually exclusive at the gh CLI level
# (GH#19310 / t2141). When both are passed, --admin wins (it already implies
# "merge now", so --auto adds no value); --auto is dropped silently with an
# informational message rather than failing the merge.
# Exit codes: 0 = merged (or queued, with --auto), 1 = gate failed or merge failed
cmd_merge() {
	local pr_number="${1:-}"
	local repo=""
	local merge_method="--squash"
	local has_admin=0
	local has_auto=0

	if [[ -z "$pr_number" ]]; then
		print_error "Usage: full-loop-helper.sh merge <PR_NUMBER> [REPO] [--squash|--merge|--rebase] [--admin] [--auto]"
		return 1
	fi
	shift

	# Parse optional repo, merge method, and gh pass-through flags.
	# --admin / --auto (GH#18731) pass straight through to `gh pr merge`.
	for arg in "$@"; do
		case "$arg" in
		--squash | --merge | --rebase)
			merge_method="$arg"
			;;
		--admin)
			has_admin=1
			;;
		--auto)
			has_auto=1
			;;
		*)
			if [[ -z "$repo" ]]; then
				repo="$arg"
			else
				print_error "Unknown argument: $arg"
				return 1
			fi
			;;
		esac
	done

	# GH#19310 (t2141): `gh pr merge` rejects --admin and --auto together with:
	#   "specify only one of `--auto`, `--disable-auto`, or `--admin`"
	# Resolve in favour of --admin: it already implies "merge now via owner
	# override", so --auto (queue and wait) is functionally redundant when
	# --admin is set. Silent resolution (with info message) is friendlier than
	# erroring on an obvious-feeling combination of flags.
	if [[ "$has_admin" -eq 1 && "$has_auto" -eq 1 ]]; then
		print_info "Both --admin and --auto were specified; gh pr merge rejects this combination."
		print_info "Resolving in favour of --admin (overrides branch protection now); dropping --auto."
		has_auto=0
	fi

	repo=$(_merge_resolve_repo "$repo") || return 1

	local _cleanup_plan=""
	if [[ "$has_auto" -eq 0 ]]; then
		local _pr_head_ref=""
		_pr_head_ref=$(gh pr view "$pr_number" --repo "$repo" --json headRefName --jq '.headRefName // empty' 2>/dev/null || true)
		_cleanup_plan=$(_merge_current_worktree_cleanup_plan "$_pr_head_ref" 2>/dev/null || true)
	fi

	# Gate: enforce review-bot-gate before merge.
	cmd_pre_merge_gate "$pr_number" "$repo" || {
		print_error "Merge blocked by review bot gate. Address bot findings or wait for reviews."
		return 1
	}

	# Retarget any open PRs stacked on this branch before the head branch is
	# deleted post-merge. GitHub auto-closes stacked children when their base
	# branch disappears; retargeting to the default branch prevents this.
	# (t2412 / GH#20005)
	_retarget_stacked_children_interactive "$pr_number" "$repo"

	_merge_execute "$pr_number" "$repo" "$merge_method" "$has_admin" "$has_auto" || return 1

	# t2429 (GH#20067): Auto-release interactive claim on merge — parity with
	# pulse-merge.sh. Extract the linked issue from the PR body (same pattern as
	# _merge_unlock_resources) and call the shared release helper. Best-effort;
	# failures are logged but never block the merge completion path.
	local _linked_issue_for_release=""
	_linked_issue_for_release=$(gh pr view "$pr_number" --repo "$repo" --json body \
		--jq '.body' 2>/dev/null |
		grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#[0-9]+' |
		grep -oE '[0-9]+' | head -1) || _linked_issue_for_release=""
	if [[ -n "$_linked_issue_for_release" ]]; then
		release_interactive_claim_on_merge "$pr_number" "$repo" "$_linked_issue_for_release" || true
	fi

	# Sequential phase auto-filing parity with pulse-merge.sh. Worker self-merge
	# bypasses the deterministic pulse post-merge hook, so trigger the shared
	# best-effort phase filer here after any immediate merge path succeeds,
	# including the REST merge fallback used when GraphQL quota is exhausted.
	# Do not fire for --auto: the PR is only queued, not merged yet.
	if [[ "$has_auto" -eq 0 && -n "$_linked_issue_for_release" ]]; then
		auto_file_next_phase "$_linked_issue_for_release" "$repo" || true
	fi

	_merge_unlock_resources "$pr_number" "$repo"
	if [[ "$has_auto" -eq 0 && -n "$_cleanup_plan" ]]; then
		_merge_cleanup_linked_worktree "$_cleanup_plan" "$repo" || true
	fi

	return 0
}
