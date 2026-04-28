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

	local merge_desc="$merge_method"
	[[ ${#merge_flags[@]} -gt 0 ]] && merge_desc+=" ${merge_flags[*]}"
	print_info "Merging PR #${pr_number} in ${repo} (${merge_desc})..."

	# Capture output AND exit code under set -e. A bare assignment `out=$(cmd)`
	# triggers errexit before `rc=$?` is reached; the if-form keeps both available.
	# (GH#18538 follow-up to PR #18748 — the bare-assignment form shipped as a bug.)
	local _merge_out="" _merge_rc=0
	if _merge_out=$(gh pr merge "$pr_number" --repo "$repo" "$merge_method" ${merge_flags[@]+"${merge_flags[@]}"} 2>&1); then
		_merge_rc=0
	else
		_merge_rc=$?
	fi

	if [[ $_merge_rc -ne 0 ]]; then
		printf '%s\n' "$_merge_out"
		# Only fall back to --admin when caller passed neither --admin nor --auto.
		if [[ $has_admin -eq 0 && $has_auto -eq 0 ]] &&
			printf '%s' "$_merge_out" | grep -qE 'base branch policy prohibits|Required status checks? (is|are) expected|At least [0-9]+ approving review'; then
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

	_merge_unlock_resources "$pr_number" "$repo"

	return 0
}
