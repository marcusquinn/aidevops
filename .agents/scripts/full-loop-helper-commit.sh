#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit & PR -- staging, validation, PR creation, merge summary
# =============================================================================
# Sub-library for full-loop-helper.sh orchestrator. Contains pre-merge gate,
# commit staging, project validators (node format/lint/typecheck), rebase/push,
# PR body composition, worker claim validation, PR creation, and merge summary.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     gh_create_pr, gh_pr_comment, gh_issue_comment, set_issue_status, _gh_recover_pr_if_exists)
#   - Globals: SCRIPT_DIR, HEADLESS
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_LIB_LOADED=1
_FULL_LOOP_CHECK_PENDING="pending"
_FULL_LOOP_CHECK_INDETERMINATE="indeterminate"
_FULL_LOOP_CHECK_DEFERRED="api-deferred"
_FULL_LOOP_ERROR_COOLDOWN="github-api-cooldown"
_FULL_LOOP_ERROR_READ_DEFERRED="github-api-read-deferred"
_FULL_LOOP_CHECK_TERMINAL_FAILURE="terminal-failure"
_FULL_LOOP_RETRY_DETAIL="retry-when-capacity-returns"
_FULL_LOOP_TRUE="true"

# Defensive SCRIPT_DIR fallback
_FULL_LOOP_COMMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	SCRIPT_DIR="$_FULL_LOOP_COMMIT_DIR"
fi

# Checkout-free planning publication receipts provide the only narrow exception
# to same-named local-branch head equality. The verifier revalidates all evidence.
# shellcheck source=./planning-publisher.sh
# shellcheck disable=SC1091
source "${_FULL_LOOP_COMMIT_DIR}/planning-publisher.sh"
# Reuse Pulse's authoritative classic-branch-protection and ruleset resolver.
# shellcheck source=./pulse-merge-required-checks.sh
# shellcheck disable=SC1091
source "${_FULL_LOOP_COMMIT_DIR}/pulse-merge-required-checks.sh"

# Project validator execution is isolated so this commit/PR orchestrator stays
# below the large-file gate without changing its public source contract.
# shellcheck source=./full-loop-helper-commit-validators.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via the helper directory
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-commit-validators.sh"

# Shared PR base resolution (GH#39167): configured pr_base_branch, then the
# remote default; never a hard-coded `main`.
# shellcheck source=./shared-pr-base.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via the helper directory
source "${_FULL_LOOP_COMMIT_DIR}/shared-pr-base.sh"

# Remote readiness and pre-merge gates retain the original public source contract.
# Resolve the sibling independently of caller-owned SCRIPT_DIR fixture paths.
# shellcheck source=./full-loop-helper-readiness.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via the helper directory
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-readiness.sh"

# shellcheck source=./full-loop-helper-subject.sh
# shellcheck disable=SC1091
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-subject.sh"

# Share runtime-owned paths with prospective PR risk classification.
# shellcheck source=./full-loop-helper-risk.sh
# shellcheck disable=SC1091
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-risk.sh"

# Closed-issue completion-bookkeeping (t2091) validators live in a focused
# sibling so this orchestrator stays below the large-file gate (GH#31068).
# shellcheck source=./full-loop-helper-commit-bookkeeping.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via the helper directory
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-commit-bookkeeping.sh"

# Branch-history finalization, replacement-PR ancestry and validator detection
# live in a focused sibling so this orchestrator stays below the large-file gate
# (GH#39385).
# shellcheck source=./full-loop-helper-commit-history.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via the helper directory
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-commit-history.sh"

# Pre-publication validation gates share the orchestrator's resolved helper
# directory, independently of caller-owned SCRIPT_DIR fixture paths (GH#39864).
# shellcheck source=./full-loop-helper-commit-gates.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via the helper directory
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-commit-gates.sh"

# Squash-merged continuation recovery runs from _stage_and_commit (GH#39862).
# shellcheck source=./full-loop-helper-commit-continuation.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via the helper directory
source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-commit-continuation.sh"

# --- Argument Parsing ---

# Parse commit-and-pr arguments into caller-scoped variables.
# Expects the caller to have declared: issue_number, commit_message, pr_title,
# summary_what, summary_testing, summary_decisions, summary_regression,
# runtime_risk, testing_level, completion_bookkeeping, bookkeeping_proof_pr, bookkeeping_task_id,
# skip_rebase, extra_labels (array).
# Returns 1 on unknown argument.
_parse_commit_and_pr_args() {
	local -a args=("$@")
	local index=0
	local arg=""
	local value=""
	while [[ "$index" -lt "${#args[@]}" ]]; do
		arg="${args[$index]}"
		pr_metadata_overrides="${pr_metadata_overrides:-} ${arg#--}"
		case "$arg" in
		--issue | --message | --title | --summary | --testing | --risk-level | --testing-level | --decisions | --regression-evidence | --label | --proof-pr | --task-id | --replace-pr | --replacement-reason | --base)
			if [[ $((index + 1)) -ge ${#args[@]} ]]; then
				print_error "${arg} requires a value"
				return 1
			fi
			value="${args[$((index + 1))]}"
			;;
		esac

		case "$arg" in
		--issue)
			issue_number="$value"
			index=$((index + 2))
			;;
		--message)
			commit_message="$value"
			index=$((index + 2))
			;;
		--title)
			pr_title="$value"
			index=$((index + 2))
			;;
		--summary)
			summary_what="$value"
			index=$((index + 2))
			;;
		--testing)
			summary_testing="$value"
			index=$((index + 2))
			;;
		--risk-level)
			runtime_risk="$value"
			index=$((index + 2))
			;;
		--testing-level)
			testing_level="$value"
			index=$((index + 2))
			;;
		--decisions)
			summary_decisions="$value"
			index=$((index + 2))
			;;
		--regression-evidence) summary_regression="$value"; index=$((index + 2)) ;; # GH#39136
		--label)
			extra_labels+=("$value")
			index=$((index + 2))
			;;
		--proof-pr)
			bookkeeping_proof_pr="$value"
			index=$((index + 2))
			;;
		--task-id)
			bookkeeping_task_id="$value"
			index=$((index + 2))
			;;
		--replace-pr) replacement_pr="$value"; index=$((index + 2)) ;;
		--replacement-reason) replacement_reason="$value"; index=$((index + 2)) ;;
		--base) stack_base_arg="$value"; index=$((index + 2)) ;; # stacked PR base
		--completion-bookkeeping)
			completion_bookkeeping=1
			index=$((index + 1))
			;;
		--allow-parent-close)
			allow_parent_close=1
			index=$((index + 1))
			;;
		--keep-issue-open) keep_issue_open=1; index=$((index + 1)) ;; # GH#36598
		--ready) create_ready=1; index=$((index + 1)) ;;
		--skip-hooks)
			# Pass --no-verify to git push. Use for doc-only PRs when hooks
			# have been manually verified clean. See GH#20138.
			skip_hooks=1
			index=$((index + 1))
			;;
		--no-rebase)
			# GH#26627: explicit recovery mode after a failed/aborted rebase.
			# Pushes only after clean-state and ahead-of-base checks pass.
			skip_rebase=1
			index=$((index + 1))
			;;
		*)
			print_error "Unknown argument: $arg"
			return 1
			;;
		esac
	done
	# Callers that source only this parser (partial extraction) lack the scanner.
	if declare -F _commit_and_pr_scan_text_inputs >/dev/null; then
		_commit_and_pr_scan_text_inputs || return 1
	fi
	return 0
}

# GH#36598: --keep-issue-open links a long-running issue with `For #N` so merge
# leaves it open and skips the issue status:in-review handoff. It is
# interactive-only (a worker PR that leaves its dispatched issue open would be
# redispatched) and contradicts parent-close and bookkeeping closing intent.
_validate_keep_issue_open_request() {
	[[ "$keep_issue_open" -eq 1 ]] || return 0
	if [[ "$allow_parent_close" -eq 1 || "$completion_bookkeeping" -eq 1 ]]; then
		print_error "--keep-issue-open cannot be combined with --allow-parent-close or --completion-bookkeeping"
		return 1
	fi
	if [[ "$(detect_session_origin)" != "interactive" ]]; then
		print_error "--keep-issue-open is interactive-only; worker PRs must resolve their dispatched issue"
		return 1
	fi
	return 0
}

# Resolve the remote default branch for cross-repo commit-and-pr operations.
# Returns 0 and prints the branch name, or returns 1 with remediation guidance.
_resolve_remote_default_branch() {
	local remote_name="${1:-origin}"
	local ref=""

	ref=$(git symbolic-ref --short "refs/remotes/${remote_name}/HEAD" 2>/dev/null || true)
	if [[ -n "$ref" ]]; then
		printf '%s\n' "${ref#"${remote_name}"/}"
		return 0
	fi

	print_error "Cannot determine ${remote_name} default branch from refs/remotes/${remote_name}/HEAD."
	print_error "Run: git remote set-head ${remote_name} --auto"
	print_error "Then retry: full-loop-helper.sh commit-and-pr ..."
	return 1
}

# Stacked-PR base override set by `--base <branch>` (empty = repository PR base).
FULL_LOOP_STACK_BASE=""
# Repository PR base resolved once per commit-and-pr (GH#39167).
FULL_LOOP_PR_BASE=""
FULL_LOOP_PR_BASE_SOURCE=""

# Resolve the branch a PR targets: the validated --base override, then the
# resolved repository PR base, then the remote default branch.
_resolve_pr_base_branch() {
	local remote_name="${1:-origin}"
	if [[ -n "${FULL_LOOP_STACK_BASE:-}" ]]; then
		printf '%s\n' "$FULL_LOOP_STACK_BASE"
		return 0
	fi
	if [[ -n "${FULL_LOOP_PR_BASE:-}" ]]; then
		printf '%s\n' "$FULL_LOOP_PR_BASE"
		return 0
	fi
	_resolve_remote_default_branch "$remote_name"
	return $?
}

# Ensure no rebase/merge state is active before recovery-mode push.
_ensure_no_in_progress_integration() {
	local git_dir=""
	git_dir=$(git rev-parse --git-dir 2>/dev/null) || git_dir=""
	if [[ -z "$git_dir" ]]; then
		print_error "Cannot inspect git state for rebase/merge recovery."
		return 1
	fi

	local rebase_merge="" rebase_apply="" merge_head=""
	rebase_merge=$(git rev-parse --git-path rebase-merge 2>/dev/null || printf '%s' "${git_dir}/rebase-merge")
	rebase_apply=$(git rev-parse --git-path rebase-apply 2>/dev/null || printf '%s' "${git_dir}/rebase-apply")
	merge_head=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || printf '%s' "${git_dir}/MERGE_HEAD")

	if [[ -e "$rebase_merge" || -e "$rebase_apply" || -e "$merge_head" ]]; then
		print_error "Refusing recovery push while a rebase or merge is in progress."
		print_error "Resolve/abort the operation first, then retry with --no-rebase if appropriate."
		return 1
	fi
	return 0
}

# --- Input Validation ---

# Return 0 when a commit subject is an intermediate WIP message.
# Args: $1=commit subject
_is_wip_commit_message() {
	local message="$1"
	if [[ "$message" =~ ^wip[[:space:]:\(] ]]; then
		return 0
	fi
	return 1
}

# Pure check (no API/git reads) that --issue and --message are present; runs
# before title composition so a missing input reports usage (GH#39377).
_require_commit_and_pr_inputs() {
	local issue_number="$1" commit_message="$2"
	if [[ -z "$issue_number" || -z "$commit_message" ]]; then
		print_error "Usage: full-loop-helper.sh commit-and-pr|create-pr --issue <N> --message <msg>"
		return 1
	fi
	return 0
}

# Validate commit-and-pr inputs: required fields and branch safety.
# Sets caller-scoped $repo and $branch on success.
# Returns 1 on validation failure.
_validate_commit_and_pr_inputs() {
	local issue_number="$1" commit_message="$2"

	_require_commit_and_pr_inputs "$issue_number" "$commit_message" || return 1
	if _is_wip_commit_message "$commit_message"; then
		print_error "Refusing WIP final commit message: ${commit_message}"
		print_error "Use a conventional final subject such as 'fix: describe the completed change'."
		return 1
	fi

	repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
	if [[ -z "$repo" ]]; then
		# t3050: gh repo view requires GraphQL. When GraphQL budget is
		# exhausted (rate-limit window), fall back to deriving the slug from
		# `git remote get-url origin`. This matches the framework rule
		# "No slug? Use `git -C <path> remote get-url origin`" and keeps
		# commit-and-pr working through GraphQL exhaustion. REST fallbacks
		# elsewhere in the wrapper handle the actual PR creation.
		local _origin_url=""
		_origin_url=$(git remote get-url origin 2>/dev/null || echo "")
		repo=$(printf '%s' "$_origin_url" | sed -E 's|^git@github.com:||; s|^https://github.com/||; s|\.git$||')
		if [[ -z "$repo" || "$repo" != */* ]]; then
			print_error "Cannot detect repo from git remote (gh repo view + git origin both failed)."
			return 1
		fi
		print_warning "[commit-and-pr] gh repo view failed (likely rate-limited); using git origin slug: $repo"
	fi

	branch=$(git branch --show-current 2>/dev/null || echo "")
	if [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" ]]; then
		print_error "Cannot commit-and-pr from ref '${branch:-detached}'. Must be in a safe linked worktree."
		return 1
	fi
	if [[ "${AIDEVOPS_RUNTIME_PENDING_COMPLETION:-0}" == 1 ]]; then
		branch=$(_runtime_completion_target_branch "$repo" "$branch") || return 1
	fi
	return 0
}

# --- Staging & Commit ---

# Stage product changes without relying on repository-specific ignore rules.
# Refuse pre-staged runtime changes rather than silently altering the index.
_stage_product_changes() {
	local path=""
	local -a protected_paths=() stage_paths=(":/")
	# shellcheck disable=SC2154 # initialized by full-loop-helper-risk.sh
	for path in "${_full_loop_runtime_paths[@]}"; do
		protected_paths+=(":(top,literal)${path}")
		# A singleton glob matches the exact dot while preventing Git from
		# rejecting an ignored literal exclusion as an explicitly added path.
		stage_paths+=(":(top,exclude)[.]${path#.}" ":(top,exclude)[.]${path#.}/**")
	done
	if ! git diff --cached --quiet -- "${protected_paths[@]}"; then
		print_error "Runtime state is staged, or its index check failed; unstage runtime paths before retrying."
		return 1
	fi
	if ! git add -A -- "${stage_paths[@]}"; then
		print_error "git add failed while excluding runtime state"
		return 1
	fi
	return 0
}

# Refuse references to payloads omitted by git add (GH#39939). The prospective
# PR is the index against the PR merge base, including already-committed WIP.
# FULL_LOOP_ALLOW_IGNORED_REFERENCES=1 explicitly permits intentional references;
# it never stages ignored content, which may contain credentials.
_check_ignored_source_references() (
	if [[ "${FULL_LOOP_ALLOW_IGNORED_REFERENCES:-0}" == 1 ]]; then
		print_warning "Skipping ignored-file reference check (FULL_LOOP_ALLOW_IGNORED_REFERENCES=1)."
		return 0
	fi
	local base_branch="" merge_base="" diff_text="" ignored_list="" diff_loaded=0
	ignored_list=$(mktemp) || return 1
	trap 'rm -f "$ignored_list"' EXIT
	if ! git ls-files --others --ignored --exclude-standard -z >"$ignored_list"; then
		print_error "Cannot inspect ignored worktree files."
		return 1
	fi
	local path="" runtime_path="" skip="" basename="" line="" referencing_path="" failed=0
	while IFS= read -r -d '' path; do
		case "/${path}" in
		*/__pycache__/* | */node_modules/* | */.full-loop-cleanup-deferred | */.full-loop-cleanup-deferred/*) continue ;;
		esac
		skip=0
		for runtime_path in "${_full_loop_runtime_paths[@]}"; do
			if [[ "$path" == "$runtime_path" || "$path" == "$runtime_path/"* ]]; then
				skip=1
				break
			fi
		done
		[[ "$skip" == 1 || ! -f "$path" ]] && continue
		# Avoid resolving history or building a diff for runtime-only worktrees.
		if [[ "$diff_loaded" == 0 ]]; then
			base_branch=$(_resolve_pr_base_branch origin) || return 1
			merge_base=$(git merge-base "refs/remotes/origin/$base_branch" HEAD) || return 1
			diff_text=$(git -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --unified=0 "$merge_base" --) || return 1
			diff_loaded=1
		fi
		basename="${path##*/}"
		referencing_path=""
		while IFS= read -r line; do
			case "$line" in
			'+++ b/'*) referencing_path="${line#+++ b/}" ;;
			'+++ '*) referencing_path="${line#+++ }" ;;
			+*)
				if [[ "$line" == *"$basename"* ]]; then
					print_error "Ignored worktree file '${path}' is referenced by '${referencing_path}'."
					git check-ignore -v -- "$path" >&2 || return 1
					failed=1
					break
				fi
				;;
			esac
		done <<<"$diff_text"
	done <"$ignored_list"
	if [[ "$failed" == 1 ]]; then
		print_error "Stage the intended source explicitly after checking it for secrets, or use FULL_LOOP_ALLOW_IGNORED_REFERENCES=1 for intentional untracked references."
		return 1
	fi
	return 0
)

# Stage product changes and commit with the given message.
# Skips commit if nothing staged but commits exist ahead of the remote default branch.
# Returns 1 on failure.
_stage_and_commit() {
	local commit_message="$1"

	print_info "Staging and committing changes..."
	_stage_product_changes || return 1
	_check_ignored_source_references || return 1

	if git diff --cached --quiet 2>/dev/null; then
		local base_branch="" base_ref="" ahead=""
		base_branch=$(_resolve_pr_base_branch origin) || return 1
		base_ref="origin/${base_branch}"
		ahead=$(git rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo "0")
		if [[ "$ahead" == "0" ]]; then
			print_error "No changes to commit and no commits ahead of ${base_ref}."
			return 1
		fi
		print_info "No new changes to commit, but ${ahead} commit(s) ahead of ${base_ref}. Proceeding to PR."
	else
		if ! git commit -m "$commit_message"; then
			print_error "git commit failed"
			return 1
		fi
	fi
	# GH#39862: before WIP finalization, validators, rebase or push, move a
	# continuation of a squash-merged head onto a fresh branch holding only the
	# post-merge unit. Updates the caller-scoped $branch (cmd_commit_and_pr) so
	# every later push, PR lookup and merge summary uses the new head. Explicit
	# --replace-pr and runtime-owned completion keep their audited paths.
	if [[ -n "${repo:-}" && -n "${branch:-}" && -z "${replacement_pr:-}" &&
		"${AIDEVOPS_RUNTIME_PENDING_COMPLETION:-0}" != 1 ]]; then
		_recover_squash_merged_continuation "$repo" "$branch" "${skip_rebase:-0}" || return 1
		if [[ -n "$FULL_LOOP_CONTINUATION_BRANCH" ]]; then
			branch="$FULL_LOOP_CONTINUATION_BRANCH"
			summary_decisions="${summary_decisions:+${summary_decisions}; }${FULL_LOOP_CONTINUATION_NOTE}"
		fi
	fi
	return 0
}

# --- Rebase & Push ---

# Detect a shallow git clone and optionally auto-unshallow.
# A shallow clone lacks intermediate commit objects between the clone-depth
# boundary and the remote base tip. Rebasing on a shallow clone fails with
# hundreds of 'add/add' conflicts that masquerade as a force-push to origin.
# Recovery sequence (manual): git fetch --unshallow origin
#
# Behaviour:
#   AIDEVOPS_SHALLOW_UNSHALLOW=0  → warn and return 1 (operator must fix)
#   AIDEVOPS_SHALLOW_UNSHALLOW=1  → attempt git fetch --unshallow and return 0
#   default (unset)               → auto-unshallow (same as =1)
#
# Args: none
# Returns: 0 if clone is full-depth or was successfully unshallowed
#          1 if clone is shallow and auto-unshallow is disabled or failed
_check_and_handle_shallow_clone() {
	local is_shallow=""
	is_shallow=$(git rev-parse --is-shallow-repository 2>/dev/null || echo "false")
	if [[ "$is_shallow" != "true" ]]; then
		return 0
	fi

	local opt="${AIDEVOPS_SHALLOW_UNSHALLOW:-1}"
	if [[ "$opt" == "0" ]]; then
		print_error "Local clone is shallow; rebase requires full history."
		print_error "Run: git fetch --unshallow origin"
		print_error "See .agents/reference/git-hygiene.md for recovery steps."
		return 1
	fi

	print_warning "Shallow clone detected — running git fetch --unshallow origin (set AIDEVOPS_SHALLOW_UNSHALLOW=0 to disable)..."
	if git fetch --unshallow origin 2>/dev/null; then
		print_info "Unshallow complete — proceeding with rebase."
		return 0
	else
		print_error "git fetch --unshallow failed. Rebase would produce add/add conflicts."
		print_error "Resolve manually: git fetch --unshallow origin"
		print_error "See .agents/reference/git-hygiene.md for recovery steps."
		return 1
	fi
}

# Rebase onto the detected origin default branch without mutating the remote.
# Args: $1=branch $2=skip_rebase (0|1, optional, default 0)
# Returns 1 on rebase conflict.
_rebase_for_push() {
	local branch="$1"
	local skip_rebase="${2:-0}"
	local base_branch="" base_ref=""
	base_branch=$(_resolve_pr_base_branch origin) || return 1
	base_ref="origin/${base_branch}"

	if [[ "$skip_rebase" == "1" ]]; then
		print_warning "Skipping rebase by explicit request (--no-rebase); validating clean recovery state."
		_ensure_no_in_progress_integration || return 1
		local ahead=""
		ahead=$(git rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo "0")
		if [[ "$ahead" == "0" ]]; then
			print_error "Refusing --no-rebase push: HEAD is not ahead of ${base_ref}."
			return 1
		fi
	else
		print_info "Rebasing onto ${base_ref}..."
		if ! git fetch origin "$base_branch" --quiet 2>/dev/null; then
			print_warning "git fetch origin ${base_branch} failed — proceeding with current state"
		fi
		# GH#21900: detect shallow clone before rebase to avoid add/add conflict cascade.
		_check_and_handle_shallow_clone || return 1
		if ! git rebase "$base_ref" 2>/dev/null; then
			git rebase --abort 2>/dev/null || true
			print_error "Rebase conflict/abort while rebasing onto ${base_ref}."
			print_error "After inspecting the branch and confirming a PR without rebase is safe, retry:"
			print_error "  full-loop-helper.sh commit-and-pr ... --no-rebase"
			print_error "Do not fall back to raw inline 'gh pr create --body ...'; keep the wrapper path."
			return 1
		fi
	fi

	# t2229 Layer 3: auto-reset .task-counter if rebase picked up a stale value.
	# After rebase, the branch may carry a counter lower than the base branch's
	# current value (race: base advanced between rebase-base and push).
	# Reset to the base branch value to prevent silent regression on merge.
	if [[ -f .task-counter ]]; then
		local branch_counter="" base_counter=""
		branch_counter=$(tr -d '[:space:]' <.task-counter 2>/dev/null) || true
		base_counter=$(git show "${base_ref}:.task-counter" 2>/dev/null | tr -d '[:space:]') || true
		if [[ -n "$branch_counter" && -n "$base_counter" ]] &&
			[[ "$branch_counter" =~ ^[0-9]+$ ]] &&
			[[ "$base_counter" =~ ^[0-9]+$ ]] &&
			[[ "$((10#$branch_counter))" -lt "$((10#$base_counter))" ]]; then
			print_info "Auto-resetting .task-counter: ${branch_counter} → ${base_counter} (base drifted during rebase)"
			printf '%s\n' "$base_counter" >.task-counter
			git add .task-counter
			git commit -m "chore: reset .task-counter to ${base_ref} value (t2229 race prevention)" --no-verify
		fi
	fi
	return 0
}

# GH#33381: the exact branch name the last successful _push_branch published.
# PR creation and its partial-failure recovery use this instead of inferring
# the head from ambient git/gh state, which can differ after a replacement
# branch or in a linked worktree backed by a bare common directory.
FULL_LOOP_PUSHED_BRANCH=""

# GH#33381: classify the remote ref for a branch before pushing.
# Args: $1=branch
# Output: "<state> <remote_sha>" where state is one of
#   absent       — no remote ref (remote_sha empty)
#   same         — remote already equals HEAD
#   fast-forward — remote is an ancestor of HEAD
#   own-rewrite  — remote is a previous tip of this local branch (its reflog),
#                  i.e. our own history rewritten by rebase/WIP finalization
#   foreign      — remote diverged and is not our history (e.g. a dead
#                  worker's push under the same deterministic branch name)
#   unknown      — remote could not be queried
_classify_remote_branch() {
	local branch="$1"
	local ls_output="" remote_sha="" head_sha=""
	if ! ls_output=$(git ls-remote --heads origin "refs/heads/${branch}" 2>/dev/null); then
		printf 'unknown \n'
		return 0
	fi
	remote_sha=$(printf '%s\n' "$ls_output" | awk -v ref="refs/heads/${branch}" '!found && $2 == ref { print $1; found=1 }')
	if [[ -z "$remote_sha" ]]; then
		printf 'absent \n'
		return 0
	fi
	head_sha=$(git rev-parse HEAD 2>/dev/null || true)
	if [[ "$remote_sha" == "$head_sha" ]]; then
		printf 'same %s\n' "$remote_sha"
		return 0
	fi
	if ! git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
		git fetch --quiet origin "refs/heads/${branch}" 2>/dev/null || true
	fi
	if git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
		if git merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
			printf 'fast-forward %s\n' "$remote_sha"
			return 0
		fi
		# Capture first: `grep -q` exiting early would SIGPIPE git under pipefail.
		local own_tips=""
		own_tips=$(git reflog show --format=%H "refs/heads/${branch}" 2>/dev/null || true)
		if [[ $'\n'"${own_tips}"$'\n' == *$'\n'"${remote_sha}"$'\n'* ]]; then
			printf 'own-rewrite %s\n' "$remote_sha"
			return 0
		fi
	fi
	printf 'foreign %s\n' "$remote_sha"
	return 0
}

# GH#33381: pick the first "<branch>-rN" name that exists neither locally nor
# on origin. Args: $1=branch. Output: replacement name. Returns 1 if none free.
_replacement_branch_name() {
	local branch="$1"
	local n=2 candidate="" remote_hit=""
	while [[ "$n" -le 9 ]]; do
		candidate="${branch}-r${n}"
		if ! git show-ref --verify --quiet "refs/heads/${candidate}"; then
			remote_hit=$(git ls-remote --heads origin "refs/heads/${candidate}" 2>/dev/null || printf 'error')
			if [[ -z "$remote_hit" ]]; then
				printf '%s\n' "$candidate"
				return 0
			fi
		fi
		n=$((n + 1))
	done
	return 1
}

# GH#33381: resolve the --head value for PR creation. Same-repository pushes
# use the plain branch name; a fork origin needs "<fork-owner>:<branch>".
# Args: $1=target repo slug $2=branch
_pr_head_ref_for_repo() {
	local repo="$1"
	local branch="$2"
	local origin_url="" origin_slug=""
	origin_url=$(git remote get-url origin 2>/dev/null || true)
	origin_slug=$(printf '%s\n' "$origin_url" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')
	if [[ "$origin_slug" == */* && -n "$repo" ]] &&
		[[ "$(printf '%s' "$origin_slug" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]]; then
		printf '%s:%s\n' "${origin_slug%%/*}" "$branch"
		return 0
	fi
	printf '%s\n' "$branch"
	return 0
}

# Push a branch after all final-diff metadata validation has passed.
# Args: $1=branch $2=skip_hooks (0|1, optional, default 0) $3=repo slug (optional)
#       $4=explicitly authorized --replace-pr number (optional)
# Sets FULL_LOOP_PUSHED_BRANCH to the branch actually published.
#
# GH#33381: never overwrite history that is not ours. The remote ref is
# classified first; our own (fast-forward or reflog-proven rewrite) history is
# replaced only with an explicit lease on the observed SHA. A diverged foreign
# remote branch is preserved untouched and this work is published under a
# collision-free "<branch>-rN" name instead — unless that remote branch backs
# an open PR, which must be continued or replaced explicitly.
_push_branch() {
	local branch="$1"
	local skip_hooks="${2:-0}"
	local repo="${3:-}" replacement_pr="${4:-}"
	FULL_LOOP_PUSHED_BRANCH=""

	local classification="" remote_state="" remote_sha="" lease_arg=""
	classification=$(_classify_remote_branch "$branch")
	remote_state="${classification%% *}"
	remote_sha="${classification#* }"
	[[ "${AIDEVOPS_RUNTIME_PENDING_COMPLETION:-0}" != 1 || ( "$skip_hooks" == 0 && ( "$remote_state" == same || "$remote_state" == fast-forward ) ) ]] || return 1

	case "$remote_state" in
	absent) lease_arg="--force-with-lease=${branch}:" ;;
	same | fast-forward | own-rewrite) lease_arg="--force-with-lease=${branch}:${remote_sha}" ;;
	foreign)
		local open_pr=""
		if [[ -n "$repo" ]]; then
			open_pr=$(gh pr list --repo "$repo" --head "$branch" --state open \
				--json number --jq '.[0].number // empty' 2>/dev/null || printf 'unknown')
		else
			open_pr="unknown"
		fi
		if [[ -n "$open_pr" && ( -z "$replacement_pr" || "$open_pr" != "$replacement_pr" ) ]]; then
			print_error "Remote branch '${branch}' has diverged (${remote_sha:0:12}) and backs open PR #${open_pr} (or PR state is unavailable)."
			print_error "Continue that PR's history, or replace it explicitly with --replace-pr N --replacement-reason TEXT; nothing was pushed."
			return 1
		fi
		local replacement=""
		replacement=$(_replacement_branch_name "$branch") || {
			print_error "Remote branch '${branch}' has diverged and no free '${branch}-rN' replacement name was found; nothing was pushed."
			return 1
		}
		print_warning "Remote branch '${branch}' has diverged with history that is not this branch's (${remote_sha:0:12}); preserving it untouched."
		git branch -m "$branch" "$replacement" || {
			print_error "Could not rename local branch '${branch}' to '${replacement}'; nothing was pushed."
			return 1
		}
		print_info "Publishing this work as replacement branch '${replacement}'"
		branch="$replacement"
		lease_arg="--force-with-lease=${branch}:"
		;;
	*) lease_arg="" ;;
	esac

	print_info "Pushing to origin/${branch}..."

	# GH#20138/GH#39356: push timeout to detect pre-push hook hangs. On code
	# diffs the managed pre-push hooks (privacy-guard, complexity-guard,
	# repo-verify typecheck, secretlint + SonarCloud validation) legitimately
	# take ~75s or more, so the default is 300s. Doc-only diffs exit early
	# (<1s). Override with AIDEVOPS_PUSH_TIMEOUT_S (positive integer seconds).
	local push_timeout="${AIDEVOPS_PUSH_TIMEOUT_S:-300}"
	[[ "$push_timeout" =~ ^[1-9][0-9]*$ ]] || push_timeout=300
	local _push_args=(-u origin "$branch")
	if [[ "${AIDEVOPS_RUNTIME_PENDING_COMPLETION:-0}" == 1 ]]; then
		[[ "$(_runtime_completion_target_branch "$repo" "$(git branch --show-current)")" == "$branch" ]] || return 1
		_push_args=(-u origin "$(git rev-parse HEAD):refs/heads/${branch}" "$lease_arg")
	else
		[[ -n "$lease_arg" ]] && _push_args+=("$lease_arg")
	fi
	[[ "$skip_hooks" == "1" ]] && _push_args+=(--no-verify)

	local push_rc
	push_rc=0
	if command -v timeout >/dev/null 2>&1; then
		timeout "$push_timeout" git push "${_push_args[@]}" 1>&2 || push_rc=$?
	else
		git push "${_push_args[@]}" 1>&2 || push_rc=$?
	fi

	if [[ "$push_rc" -eq 124 ]]; then
		# timeout(1) exits 124 on SIGTERM
		print_error "Push timed out after ${push_timeout}s — likely a pre-push hook stalling."
		print_error "Diagnose: PRIVACY_GUARD_DEBUG=1 COMPLEXITY_GUARD_DEBUG=1 git push ${_push_args[*]}"
		print_error "Hooks on code diffs can legitimately run long; raise the budget: AIDEVOPS_PUSH_TIMEOUT_S=<seconds>."
		print_error "Do not bypass hooks for code diffs; --skip-hooks is only for doc-only diffs."
		print_error "See reference/pre-push-guards.md for diagnosis steps."
		return 1
	elif [[ "$push_rc" -ne 0 ]]; then
		print_error "Push failed (exit ${push_rc}). Check remote state and retry."
		return 1
	fi
	FULL_LOOP_PUSHED_BRANCH="$branch"
	return 0
}

# Compatibility wrapper for callers that do not need a pre-push validation gap.
# Args: $1=branch $2=skip_hooks $3=skip_rebase $4=repo slug (optional)
_rebase_and_push() {
	local branch="$1"
	local skip_hooks="${2:-0}"
	local skip_rebase="${3:-0}"
	local repo="${4:-}"
	_rebase_for_push "$branch" "$skip_rebase" || return 1
	_push_branch "$branch" "$skip_hooks" "$repo" || return 1
	return 0
}

# --- PR Helpers ---

# t2242: Check if a given issue has the parent-task label.
# Modelled on parent-task-keyword-guard.sh:76 _is_parent_task.
# Args: $1=issue_number $2=repo_slug
# Returns: 0 if parent-task/meta label present, 1 if not, 2 on gh failure
_issue_has_parent_task_label() {
	local issue_number="$1"
	local repo_slug="$2"

	local labels_json=""
	local gh_rc=0
	labels_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels 2>/dev/null) || gh_rc=$?

	if [[ "$gh_rc" -ne 0 || -z "$labels_json" ]]; then
		# gh API failure — cannot determine. Return 2 (uncertain).
		return 2
	fi

	local hit=""
	hit=$(printf '%s' "$labels_json" |
		jq -r '(.labels // [])[].name | select(. == "parent-task" or . == "meta")' | sed -n '1p' || true)

	if [[ -n "$hit" ]]; then
		return 0
	fi
	return 1
}

# Return the safe keyword for redispatched review repairs. The issue-body
# receipt survives worker/session changes; it can only remove closure authority.
# A verified final delivery uses the existing explicit --allow-parent-close.
_review_repair_closing_keyword() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body=""
	issue_body=$(_gh_with_timeout read gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""') || return 1
	if [[ "$issue_body" == *"<!-- aidevops:review-repair:non-closing:${issue_number} -->"* ]]; then
		printf '%s' For
	else
		printf '%s' Resolves
	fi
	return 0
}

# GH#38823: fail closed when a worker summary declares the dispatched issue
# as `For`/`Ref #N` (a partial PR) while commit-and-pr would emit `Resolves #N`
# and close it, losing unmet verification criteria. Returns 1 on contradiction.
# Arguments: issue_number, then summary text fields. References to other
# issues are unaffected (GH#36864 turns them into `Ref #M` under Related).
_summary_declares_partial_self() {
	local issue_number="$1"
	shift
	local text="" reference_number=""
	local pattern='(^|[^[:alnum:]_])([Ff][Oo][Rr]|[Rr][Ee][Ff])[:[:space:]]+#([0-9]+)'
	for text in "$@"; do
		while [[ "$text" =~ $pattern ]]; do
			reference_number="${BASH_REMATCH[3]}"
			if [[ "$reference_number" == "$issue_number" ]]; then
				return 1
			fi
			text="${text/"${BASH_REMATCH[0]}"/}"
		done
	done
	return 0
}

# Build the PR body string and print it to stdout.
# Arguments: issue_number, summary_what, summary_testing, files_changed,
#            sig_footer, closing_keyword (default: Resolves), requested_risk,
#            requested_testing_level, base_ref (resolved merge base),
#            replacement_note, decisions, regression_evidence
_build_pr_body() {
	local issue_number="$1" summary_what="$2" summary_testing="$3"
	local files_changed="$4" sig_footer="$5"
	local closing_keyword="${6:-Resolves}"
	local requested_risk="${7:-}"
	local requested_testing_level="${8:-}"
	local base_ref="${9:-}"
	local replacement_note="${10:-}"
	local decisions="${11:-}"
	local regression_evidence="${12:-}"
	local runtime_risk=""
	local testing_level=""
	local related="" related_numbers=" "
	local field="" text="" reference="" reference_number="" prefix=""
	local reference_pattern='(^|[^[:alnum:]_])([Ff][Oo][Rr]|[Rr][Ee][Ff])[:[:space:]]+#([0-9]+)'

	# GH#36864: prose must not introduce a second explicit work identity.
	# Keep the dispatched declaration below authoritative, even when summaries
	# contain same-line, multiline or prose-prefixed child/umbrella references.
	for field in summary_what summary_testing replacement_note decisions regression_evidence; do
		text="${!field}"
		while [[ "$text" =~ $reference_pattern ]]; do
			reference="${BASH_REMATCH[0]}"
			prefix="${BASH_REMATCH[1]}"
			reference_number="${BASH_REMATCH[3]}"
			text="${text/"$reference"/"${prefix}issue #${reference_number}"}"
			if [[ "$reference_number" != "$issue_number" && "$related_numbers" != *" ${reference_number} "* ]]; then
				related_numbers+="${reference_number} "
				related+="Ref #${reference_number}"$'\n'
			fi
		done
		printf -v "$field" '%s' "$text"
	done

	_pr_body_inputs_reserve_runtime_section "$summary_what" "$summary_testing" \
		"$replacement_note" "$decisions" "$regression_evidence" || return 1
	runtime_risk=$(_derive_runtime_risk "$requested_risk" "$files_changed" "$summary_what" "$base_ref") || return 1
	testing_level=$(_resolve_runtime_testing_level "$runtime_risk" "$requested_testing_level" "$summary_testing") || return 1
	# GH#39558: the Runtime Testing parser ends evidence at a "- **" bullet, so
	# render bold-label bullets inside accepted evidence as plain bullets; the
	# merge recheck and continued PRs then read the evidence that was accepted.
	summary_testing=$(printf '%s' "$summary_testing" | sed -E 's/^-[[:space:]]+\*\*([^*]*)\*\*/- \1/') || return 1
	# GH#38509: risk derivation above needs every path; the body shows a
	# bounded list so large diffs stay under GitHub's body limit.
	files_changed=$(_format_files_changed_for_body "$files_changed") || return 1

	printf '%s\n' "## Summary

${summary_what:-Implementation for issue #${issue_number}.}

${replacement_note:+## Replacement Audit

${replacement_note}
}

## Files Changed

${files_changed:-See diff}

${decisions:+## Decisions

${decisions}

}## Runtime Testing

- **Risk level:** ${runtime_risk}
- **Verification:** ${testing_level} — ${summary_testing:-no additional evidence supplied}

${regression_evidence:+## Regression Evidence

${regression_evidence}

}${closing_keyword} #${issue_number}

${related:+## Related

${related}
}
${sig_footer}"
	return 0
}

# GH#39136: run the repository's own Platform Fix Regression Evidence gate on
# the final title, body and diff before any push, so a platform-fix PR is not
# published only to fail CI (a rerun replays the old body; only an edit passes).
# Applies only where the repository's CI enforces it; uses its checked-in script.
# Arguments: pr_title, pr_body, comparison_base
_commit_and_pr_platform_evidence_gate() {
	local pr_title="$1" pr_body="$2" comparison_base="$3"
	local repo_root="" gate="" temp_root="" body_file="" files_file="" rc=0
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
	gate="${repo_root}/.agents/scripts/platform-fix-regression-evidence.sh"
	[[ -f "${repo_root}/.github/workflows/platform-fix-regression-evidence.yml" && -f "$gate" ]] || return 0
	temp_root="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_root" || return 1
	body_file=$(mktemp "${temp_root}/aidevops-platform-evidence-body.XXXXXX") || return 1
	files_file=$(mktemp "${temp_root}/aidevops-platform-evidence-files.XXXXXX") || {
		rm -f "$body_file"
		return 1
	}
	printf '%s\n' "$pr_body" >"$body_file"
	if git diff --name-only "$comparison_base" HEAD >"$files_file"; then
		bash "$gate" --title "$pr_title" --body-file "$body_file" --files-file "$files_file" >&2 || rc=$?
	else
		rc=1
	fi
	rm -f "$body_file" "$files_file"
	if [[ "$rc" -ne 0 ]]; then
		print_error "Platform Fix Regression Evidence would fail in CI; add a repository test or pass --regression-evidence \"<why automated regression is not possible, plus the manual evidence>\". Nothing was pushed."
		return 1
	fi
	return 0
}

# GH#38509: GitHub rejects PR bodies and comments over 65,536 characters, and
# Linux limits one argv string to 128 KiB. Print a short changed-file list
# unchanged; summarise a long one by top-level directory within a fixed budget.
# Arguments: files_changed (comma-separated paths, as built by commit-and-pr)
_format_files_changed_for_body() {
	local files_changed="${1:-}"
	local max_files="${FULL_LOOP_BODY_MAX_FILES:-100}"
	local max_chars="${FULL_LOOP_BODY_MAX_FILE_CHARS:-20000}"
	local file_count=0
	[[ "$max_files" =~ ^[0-9]+$ ]] || max_files=100
	[[ "$max_chars" =~ ^[0-9]+$ && "$max_chars" -ge 200 ]] || max_chars=20000
	if [[ -n "$files_changed" ]]; then
		file_count=$(printf '%s\n' "$files_changed" | tr ',' '\n' |
			awk '{ gsub(/^[ \t]+|[ \t]+$/, "") } NF { n++ } END { print n + 0 }') || return 1
	fi
	if [[ "$file_count" -le "$max_files" && "${#files_changed}" -le "$max_chars" ]]; then
		printf '%s' "$files_changed"
		return 0
	fi
	printf '%s\n' "$files_changed" | tr ',' '\n' | awk -v total="$file_count" -v budget="$max_chars" '
		{
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 == "") next
			key = $0
			slash = index(key, "/")
			if (slash > 0) key = substr(key, 1, slash)
			if (!(key in count)) order[++groups] = key
			count[key]++
		}
		END {
			for (i = 2; i <= groups; i++) {
				item = order[i]
				for (j = i - 1; j >= 1 && count[order[j]] < count[item]; j--) order[j + 1] = order[j]
				order[j + 1] = item
			}
			out = total " files changed across " groups " top-level paths (full list in the PR diff):"
			for (i = 1; i <= groups; i++) {
				entry = " `" order[i] "` " count[order[i]]
				if (i < groups) entry = entry ","
				if (length(out) + length(entry) > budget - 40) {
					out = out " and " (groups - i + 1) " more"
					break
				}
				out = out entry
			}
			printf "%s", out
		}' || return 1
	return 0
}

# --- Worker Claim Validation ---

# t1955: Validate that this worker's dispatch claim is still active before
# creating a PR. Prevents orphan PRs from workers whose assignment was
# stale-recovered while they were still working.
#
# Checks:
#   1. Issue comments for a WORKER_SUPERSEDED marker naming this runner
#   2. Issue assignee — if reassigned to another runner, we've been replaced
#
# Only runs in headless mode (interactive sessions don't go through dispatch).
# Non-fatal in interactive mode — always returns 0.
# In headless mode: returns 0 if claim is valid, 1 if superseded.
#
# Arguments: $1 = issue_number, $2 = repo slug
_validate_worker_claim() {
	local issue_number="$1"
	local repo="$2"

	# Skip in interactive mode — no dispatch claim to validate
	if [[ "${HEADLESS:-false}" != "true" && "${FULL_LOOP_HEADLESS:-}" != "true" ]]; then
		return 0
	fi

	# Skip if no issue number (shouldn't happen, but defensive)
	if [[ -z "$issue_number" || ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 0
	fi

	# Determine this runner's login
	local self_login=""
	self_login=$(gh api user --jq '.login' 2>/dev/null) || self_login=""
	if [[ -z "$self_login" ]]; then
		# Can't determine identity — proceed (fail-open)
		print_warning "Cannot determine runner login for claim validation — proceeding"
		return 0
	fi

	# Check for WORKER_SUPERSEDED marker in recent comments
	local comments_json=""
	comments_json=$(gh api "repos/${repo}/issues/${issue_number}/comments" \
		--jq '[.[] | select(.body | test("WORKER_SUPERSEDED")) | {body: .body, created_at: .created_at}] | sort_by(.created_at) | reverse | first // empty' \
		2>/dev/null) || comments_json=""

	if [[ -n "$comments_json" ]]; then
		local superseded_runners=""
		superseded_runners=$(printf '%s' "$comments_json" | jq -r '.body' 2>/dev/null |
			grep -oE 'WORKER_SUPERSEDED runners=[^ ]*' |
			sed 's/WORKER_SUPERSEDED runners=//' || echo "")

		if [[ -n "$superseded_runners" && ",$superseded_runners," == *",$self_login,"* ]]; then
			# This runner was explicitly superseded — check if we've been re-assigned since
			local current_assignees=""
			current_assignees=$(gh issue view "$issue_number" --repo "$repo" \
				--json assignees --jq '[.assignees[].login] | join(",")' 2>/dev/null) || current_assignees=""

			if [[ ",$current_assignees," != *",$self_login,"* ]]; then
				print_warning "Worker claim superseded: this runner (${self_login}) was stale-recovered on #${issue_number} and not re-assigned — aborting PR creation (t1955)"
				return 1
			fi
			# Re-assigned back to us (e.g., re-dispatched) — proceed
		fi
	fi

	# Check current assignee — if assigned to someone else, we've been replaced
	local current_assignees=""
	current_assignees=$(gh issue view "$issue_number" --repo "$repo" \
		--json assignees --jq '[.assignees[].login] | join(",")' 2>/dev/null) || current_assignees=""

	if [[ -n "$current_assignees" && ",$current_assignees," != *",$self_login,"* ]]; then
		print_warning "Worker claim invalid: #${issue_number} is assigned to ${current_assignees}, not ${self_login} — aborting PR creation (t1955)"
		return 1
	fi

	return 0
}

# --- PR Title Composition ---

# _derive_pr_title_prefix: choose tNNN (preferred) or GH#NNN (fallback) for
# the auto-derived PR title, based on whether TODO.md has an entry whose
# ref:GH# tag matches the issue number.
#
# Why (t2720): issue-sync.yml's PR-merge job auto-completes TODO entries by
# extracting a task_id from the merged PR title (regex anchored on ^tNNN).
# When commit-and-pr falls back to "GH#NNN:" titles, the extractor returns
# empty and the TODO line is silently left on `[ ]` even though the PR
# merged and SYNC_PAT is present. Preferring tNNN closes that gap.
#
# Args:
#   $1 - issue_number (required; empty yields "GH#" fallback)
#   $2 - todo_file (optional; defaults to <repo-root>/TODO.md)
# Outputs:
#   tNNN     when TODO.md has a matching entry
#   GH#NNN   otherwise (missing file, no match, or unset issue number)
# Returns: 0 always (callers inline the stdout).
_derive_pr_title_prefix() {
	local issue_number="${1:-}"
	local todo_file="${2:-}"

	if [[ -z "$issue_number" ]]; then
		printf 'GH#\n'
		return 0
	fi

	if [[ -z "$todo_file" ]]; then
		local repo_root=""
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
		if [[ -n "$repo_root" ]]; then
			todo_file="${repo_root}/TODO.md"
		fi
	fi

	if [[ -z "$todo_file" || ! -f "$todo_file" ]]; then
		printf 'GH#%s\n' "$issue_number"
		return 0
	fi

	# Match "- [ ] tNNN ... ref:GH#<issue_number>" with a non-digit or EOL
	# boundary after the number so ref:GH#123 doesn't match ref:GH#12345.
	local task_id=""
	task_id=$(grep -E "^- \[[ x]\] t[0-9]+ .*ref:GH#${issue_number}([^0-9]|\$)" "$todo_file" 2>/dev/null |
		sed -n '1p' |
		grep -oE '^- \[[ x]\] t[0-9]+' |
		grep -oE 't[0-9]+$' ||
		true)

	if [[ -n "$task_id" ]]; then
		printf '%s\n' "$task_id"
	else
		printf 'GH#%s\n' "$issue_number"
	fi
	return 0
}

# _compose_pr_title: idempotently compose the auto-derived PR title.
#
# Why (t2825/RC3): when commit_message already starts with a task-ID prefix
# (tNNN: or GH#NNN:), return it verbatim instead of prepending another one.
# Canonical failure: PR #20817 was created with title
# "t2799: t2799: split RATE_LIMIT_PATTERNS..." because an interactive
# `commit-and-pr --message "t2799: ..."` call unconditionally prepended
# another tNNN: via _derive_pr_title_prefix. This guard makes the
# auto-derive path idempotent so callers can safely include a prefix in
# the commit message without producing a doubled title.
#
# Prefix validation (GH#20858): when commit_message already has a prefix,
# verify it matches the canonical prefix for issue_number. A mismatched
# prefix (e.g. "t999: ..." for issue that maps to t456) silently breaks
# TODO auto-completion (issue-sync regex anchored on ^tNNN) and attribution.
# When a mismatch is detected, the canonical prefix is substituted and a
# warning is emitted to stderr. Pass-through is preserved when issue_number
# is empty (can't validate) or when the prefix already matches.
#
# Args:
#   $1 - issue_number
#   $2 - commit_message
#   $3 - todo_file (optional; passed through to _derive_pr_title_prefix)
# Outputs:
#   commit_message (verbatim) when it already has a correct tNNN: or GH#NNN: prefix
#   <canonical_prefix>: <body> when prefix is present but mismatched
#   <derived_prefix>: <commit_message> when no prefix is present
# Returns: 0 always.
_compose_pr_title() {
	local issue_number="${1:-}"
	local commit_message="${2:-}"
	local todo_file="${3:-}"

	if [[ "$commit_message" =~ ^(t[0-9]+|GH#[0-9]+): ]]; then
		local existing_prefix="${BASH_REMATCH[1]}"
		# Skip validation when issue_number is unknown — cannot derive canonical.
		if [[ -z "$issue_number" ]]; then
			printf '%s\n' "$commit_message"
			return 0
		fi
		local canonical_prefix=""
		canonical_prefix="$(_derive_pr_title_prefix "$issue_number" "$todo_file")"
		if [[ "$existing_prefix" == "$canonical_prefix" ]]; then
			printf '%s\n' "$commit_message"
		else
			# Strip the mismatched prefix (everything up to and including the first ": ")
			# and substitute the canonical one so issue-sync auto-completion works.
			local body="${commit_message#*: }"
			print_warning "_compose_pr_title: prefix mismatch — commit has '${existing_prefix}:' but issue #${issue_number} maps to '${canonical_prefix}:'. Using canonical prefix."
			printf '%s: %s\n' "$canonical_prefix" "$body"
		fi
		return 0
	fi

	printf '%s: %s\n' "$(_derive_pr_title_prefix "$issue_number" "$todo_file")" "$commit_message"
	return 0
}

# --- PR Creation ---

# Verify that a PR has exactly one origin label and that it is the expected
# immutable session origin. REST readback is deliberate: a successful mutation
# exit code is not proof that GitHub reached the required postcondition.
# Arguments: PR number, repository slug, expected origin name (without prefix).
# Returns: 0=verified, 2=missing/wrong/dual/unavailable origin labels.
_verify_pr_origin_label() {
	local pr_number="$1"
	local repo="$2"
	local origin_name="$3"
	local origin_labels=""
	origin_labels=$(_gh_with_timeout read gh api "repos/${repo}/issues/${pr_number}" \
		--jq '[.labels[].name | select(startswith("origin:"))]' 2>/dev/null) || origin_labels="[]"
	if printf '%s' "$origin_labels" |
		jq -e --arg expected "origin:${origin_name}" \
			'length == 1 and .[0] == $expected' >/dev/null 2>&1; then
		return 0
	fi
	return 2
}

# Reconcile and verify the immutable origin postcondition while retaining a
# bounded, non-secret failure classification for operators. The caller keeps
# authority over origin_name; gh_create_pr remains the sole creation injector.
# Arguments: PR number, repository slug, expected origin name (without prefix).
_reconcile_pr_origin_label() {
	local pr_number="$1"
	local repo="$2"
	local origin_name="$3"
	local origin_error=""
	origin_error=$(mktemp) || return 1
	# set_origin_label may print the PR URL after a successful REST mutation.
	# _create_pr is a machine-output function, so keep that status off stdout.
	if ! set_origin_label "$pr_number" "$repo" "$origin_name" --pr >/dev/null 2>"$origin_error"; then
		local failure_kind="GitHub label write failed"
		if grep -qiE 'permission|forbidden|Resource not accessible|HTTP 403' "$origin_error" 2>/dev/null; then
			failure_kind="credential lacks PR label permission"
		elif grep -qiE 'rate limit|rateLimitExceeded|HTTP 429' "$origin_error" 2>/dev/null; then
			failure_kind="GitHub API rate limited the label write"
		fi
		rm -f "$origin_error"
		print_error "Could not apply origin:${origin_name} to PR #${pr_number}: ${failure_kind}; retry commit-and-pr after GitHub writes recover"
		return 1
	fi
	rm -f "$origin_error"

	local verify_rc=0
	_verify_pr_origin_label "$pr_number" "$repo" "$origin_name" || verify_rc=$?
	case "$verify_rc" in
	0) return 0 ;;
	*)
		print_error "PR #${pr_number} did not reach the exact origin:${origin_name} postcondition; retry commit-and-pr to reconcile unavailable, missing, wrong, or dual origin labels"
		return 1
		;;
	esac
}

# Create the PR and print the PR number to stdout.
# Arguments: repo, pr_title, pr_body, origin_label; extra_labels passed as remaining args.
# Returns 1 on failure.
# t2115: Uses gh_create_pr wrapper (shared-constants.sh) for origin label + signature auto-append.
# t2767: Implements partial-success recovery — when gh_create_pr exits non-zero but a PR
# already exists for the current branch (GitHub created it but a follow-up update failed),
# we recover and continue instead of bailing out.
# GH#26045: After extracting the PR number, verify/re-apply the current session
# origin label via set_origin_label so recovered partial-success PRs cannot remain
# unlabeled and unroutable by pulse CI/review repair workers.
# Align a continued PR with the intended base: an explicit --base always wins;
# otherwise a PR on a branch that is neither the PR base nor an open parent
# PR head moves to the resolved PR base (GH#39167). A stacked continuation
# without --base keeps its parent base.
# Args: $1=pr_number $2=repo slug
_retarget_continuation_pr_base() {
	local pr_number="$1"
	local repo="$2"
	local target="${FULL_LOOP_STACK_BASE:-${FULL_LOOP_PR_BASE:-}}"
	[[ -n "$target" ]] || return 0
	local current_base="" pr_endpoint="repos/${repo}/pulls/${pr_number}"
	current_base=$(_gh_with_timeout read gh api "$pr_endpoint" --jq '.base.ref') || return 1
	[[ "$current_base" == "$target" ]] && return 0
	if [[ -z "${FULL_LOOP_STACK_BASE:-}" ]]; then
		local parent_rc=2
		declare -F aidevops_pr_base_is_stacked_parent >/dev/null 2>&1 && parent_rc=0 &&
			{ aidevops_pr_base_is_stacked_parent "$repo" "$current_base" || parent_rc=$?; }
		[[ "$parent_rc" -eq 1 ]] || return 0
	fi
	print_info "Retargeting PR #${pr_number} base: ${current_base} -> ${target}"
	gh api "$pr_endpoint" --method PATCH \
		--raw-field "base=${target}" >/dev/null || {
		print_error "Failed to retarget PR #${pr_number} to base ${target}"
		return 1
	}
	return 0
}

_create_or_continue_pr() {
	local continuation_pr="$1"
	local repo="$2"
	local pr_title="$3"
	local pr_body="$4"
	local origin_label="$5"
	shift 5
	[[ "${AIDEVOPS_RUNTIME_PENDING_COMPLETION:-0}" != 1 || ( -n "$continuation_pr" && "$continuation_pr" == "${AIDEVOPS_PR_REPAIR_NUMBER:-}" ) ]] || return 1
	if [[ -n "$continuation_pr" ]]; then
		print_info "Continuing existing issue-linked PR #${continuation_pr} at the final creation boundary"
		_reconcile_pr_origin_label "$continuation_pr" "$repo" "${origin_label#origin:}" || return 1
		_reconcile_recovered_pr_metadata "$continuation_pr" "$repo" "$pr_title" "$pr_body" || return 1
		_retarget_continuation_pr_base "$continuation_pr" "$repo" || return 1
		_ready_continued_draft_pr "$continuation_pr" "$repo" "$origin_label" # GH#39842
		printf '%s\n' "$continuation_pr"
		return 0
	fi
	_create_pr "$repo" "$pr_title" "$pr_body" "$origin_label" "$@"
	return $?
}

# GH#39167: print the explicit base for PR creation and log its source; gh's
# implicit default ignored pr_base_branch and silently targeted the default.
# Returns 1 (no --base) only when no base resolves at all.
_explicit_pr_create_base() {
	local pr_base=""
	pr_base=$(_resolve_pr_base_branch origin) || return 1
	[[ -n "$pr_base" ]] || return 1
	local pr_base_source="${FULL_LOOP_PR_BASE_SOURCE:-origin-head}"
	[[ -n "${FULL_LOOP_STACK_BASE:-}" ]] && pr_base_source="--base stacked parent"
	print_info "PR base: ${pr_base} (source: ${pr_base_source})"
	printf '%s\n' "$pr_base"
	return 0
}

# GH#39210: run the PR create command; --ready scopes AIDEVOPS_PR_CREATE_READY=1
# to this single call (never exported).
_run_pr_create_cmd() {
	local ready="$1"
	shift
	if [[ "$ready" -eq 1 ]]; then
		AIDEVOPS_PR_CREATE_READY=1 "$@"
		return $?
	fi
	"$@"
	return $?
}

# Verify the final pushed head (post commit/rebase/push) before opening
# non-draft; on mismatch or lookup failure keep the draft default.
# Args: $1=requested ready (0|1) $2=head branch. Prints effective ready (0|1).
_effective_pr_ready() {
	local ready="$1"
	local head_branch="$2"
	if [[ "$ready" -eq 1 && -n "$head_branch" ]]; then
		local local_head="" remote_head=""
		local_head=$(git rev-parse HEAD 2>/dev/null || true)
		remote_head=$(git ls-remote --heads origin "refs/heads/${head_branch}" 2>/dev/null | cut -f1 | sed -n 1p || true)
		if [[ -z "$local_head" || "$local_head" != "$remote_head" ]]; then
			print_warning "Pushed head does not match local HEAD; creating PR as draft" >&2
			ready=0
		fi
	fi
	printf '%s\n' "$ready"
	return 0
}

_create_pr() {
	local repo="$1" pr_title="$2" pr_body="$3" origin_label="$4"
	shift 4
	local -a extra_labels=("$@")
	local recovered=0

	print_info "Creating PR..."
	local pr_url="" pr_error="" rc=0
	# t2115/t3088: gh_create_pr injects the origin label and signature footer;
	# passing --label "$origin_label" too applied both labels (t2200, PR #21825).
	# The label is reconciled below once the PR number is known (GH#26045).
	# GH#33381: pass the exact pushed head instead of letting gh infer it from
	# ambient checkout state (wrong after a replacement branch, or in linked
	# worktrees backed by a bare common directory).
	local head_branch="${FULL_LOOP_PUSHED_BRANCH:-}"
	[[ -n "$head_branch" ]] || head_branch=$(git branch --show-current 2>/dev/null || echo "")
	# GH#38509: pass the body through a file; an inline --body is one argv
	# string and fails with "Argument list too long" for large generated bodies.
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local body_file=""
	if ! mkdir -p "$temp_root" || ! body_file=$(mktemp "${temp_root}/aidevops-pr-create-body.XXXXXX"); then
		print_error "Could not create PR body file in ${temp_root}"
		return 1
	fi
	if ! printf '%s' "$pr_body" >"$body_file"; then
		rm -f "$body_file"
		print_error "Could not write PR body file"
		return 1
	fi
	local -a pr_cmd=(gh_create_pr --repo "$repo" --title "$pr_title" --body-file "$body_file")
	[[ -n "$head_branch" ]] && pr_cmd+=(--head "$(_pr_head_ref_for_repo "$repo" "$head_branch")")
	local pr_base=""
	pr_base=$(_explicit_pr_create_base) && pr_cmd+=(--base "$pr_base")
	for lbl in "${extra_labels[@]+"${extra_labels[@]}"}"; do
		pr_cmd+=(--label "$lbl")
	done

	pr_error=$(mktemp -t aidevops-pr-create-error.XXXXXX) || {
		rm -f "$body_file"
		return 1
	}
	pr_url=$(_run_pr_create_cmd "$(_effective_pr_ready "${create_ready:-0}" "$head_branch")" "${pr_cmd[@]}" 2>"$pr_error") || rc=$?
	rm -f "$body_file"

	if [[ $rc -ne 0 ]]; then
		# t2767: Partial-success recovery.
		# gh pr create (via gh_create_pr) can return non-zero even when GitHub already
		# created the PR — this happens when a follow-up GraphQL mutation (body update,
		# label application) succeeds on GitHub's backend but the subsequent API response
		# fails with a transient error (e.g. "Something went wrong while executing your query").
		# Before treating this as a hard failure, check whether the PR now exists.
		local recovered_url=""
		recovered_url=$(_gh_recover_pr_if_exists "$head_branch" "$repo" 2>/dev/null || echo "")
		if [[ -n "$recovered_url" ]]; then
			print_info "PR creation command returned non-zero but PR exists — recovering (t2767): ${recovered_url}"
			pr_url="$recovered_url"
			recovered=1
		else
			print_error "PR creation failed: $(<"$pr_error")"
			rm -f "$pr_error"
			return 1
		fi
	fi
	rm -f "$pr_error"

	local pr_number=""
	local pr_candidates=""
	pr_candidates=$(printf '%s\n' "$pr_url" | grep -oE 'github\.com/[^[:space:]]+/[^[:space:]]+/pull/[0-9]+' | grep -oE '[0-9]+$' || true)
	pr_number="${pr_candidates##*$'\n'}"
	if [[ -z "$pr_number" ]]; then
		pr_candidates=$(printf '%s\n' "$pr_url" | grep -oE '[0-9]+$' || true)
		pr_number="${pr_candidates##*$'\n'}"
	fi
	if [[ -z "$pr_number" ]]; then
		print_error "Could not extract PR number from: ${pr_url}"
		return 1
	fi

	local origin_name="${origin_label#origin:}"
	case "$origin_name" in
	interactive | worker | worker-takeover) ;;
	*)
		print_error "Could not normalize origin label '${origin_label}' for PR #${pr_number}"
		return 1
		;;
	esac
	_reconcile_pr_origin_label "$pr_number" "$repo" "$origin_name" || return 1
	if [[ "$recovered" -eq 1 ]]; then
		_reconcile_recovered_pr_metadata "$pr_number" "$repo" "$pr_title" "$pr_body" || return 1
	fi

	print_success "PR #${pr_number} created: ${pr_url}"
	printf '%s\n' "$pr_number"
	return 0
}

# Inherit omitted evidence before prospective risk validation, not after push.
# Explicit values remain authoritative; final-diff risk checks still run normally.
_inherit_pr_runtime_metadata() {
	local pr_number="$1"
	local repo="$2"
	local body="" metadata="" sections=""
	local override_flags=" ${pr_metadata_overrides:-} "
	local endpoint="repos/${repo}/pulls"
	endpoint+="/${pr_number}"
	body=$(_gh_with_timeout read gh api "$endpoint" --jq '.body // empty') || return 1
	metadata=$(printf '%s' "$body" | _runtime_testing_metadata_from_body) || return 1
	sections=$(printf '%s' "$metadata" | jq -r '.sections // 0')
	# GH#39558: never inherit from ambiguous (multi-section) metadata.
	if [[ ! "$sections" =~ ^[0-9]+$ ]] || ((sections > 1)); then
		if [[ "$override_flags" != *" risk-level "* || "$override_flags" != *" testing-level "* || "$override_flags" != *" testing "* ]]; then
			print_error "PR #${pr_number} has ${sections} Runtime Testing sections; pass --risk-level, --testing-level and --testing explicitly instead of inheriting them."
			return 1
		fi
	fi
	[[ "$override_flags" == *" risk-level "* ]] || runtime_risk=$(printf '%s' "$metadata" | jq -r '.risk')
	[[ "$override_flags" == *" testing-level "* ]] || testing_level=$(printf '%s' "$metadata" | jq -r '.level')
	[[ "$override_flags" == *" testing "* ]] || summary_testing=$(printf '%s' "$metadata" | jq -r '.evidence')
	return 0
}

# Keep curated sections verbatim, refreshing only derived data and explicit
# overrides. Use the live body as the base so arbitrary prose and footer survive.
_merge_existing_pr_body() {
	local current_body="$1"
	local generated_body="$2"
	local overrides="${3:-}"
	python3 - "$current_body" "$generated_body" "$overrides" <<'PY'
import re, sys
current, generated, overrides = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
if not current.strip() or not re.search(r'^## ', generated, re.M):
    print(generated)
    sys.exit(0)

def section(body, name):
    boundary = r'(?=^## |^(?:Resolves|Fixes|Closes|For|Ref) #\d+\b|^<!-- aidevops:|\Z)'
    return re.search(r'^## ' + re.escape(name) + r'\n.*?' + boundary, body, re.M | re.S)

def insert_section(body, text):
    footer = re.search(r'^(?:Resolves|Fixes|Closes|For|Ref) #\d+\b|^<!-- aidevops:', body, re.M)
    position = footer.start() if footer else len(body)
    return body[:position].rstrip('\n') + '\n\n' + text.rstrip('\n') + '\n\n' + body[position:]

for name, flag in [('Files Changed', None), ('Summary', 'summary'), ('Decisions', 'decisions'),
                   ('Regression Evidence', 'regression-evidence')]:
    old, new = section(current, name), section(generated, name)
    if old and not new and flag in overrides:
        current = current[:old.start()] + current[old.end():]
    if new and (not old or flag is None or flag in overrides):
        if old:
            current = current[:old.start()] + new[0] + current[old.end():]
        else:
            current = insert_section(current, new[0])

old, new = section(current, 'Runtime Testing'), section(generated, 'Runtime Testing')
if old and new:
    # The runtime section can also contain the closing reference and signature:
    # replace only the requested metadata lines, never that trailing content.
    text = old[0]
    for label, flags in [('Risk level', {'risk-level'}), ('Verification', {'testing', 'testing-level'})]:
        pattern = r'^- \*\*' + label + r':\*\* .*?(?=^- \*\*|\Z)'
        replacement = re.search(pattern, new[0], re.M | re.S)
        if overrides & flags and replacement:
            text = re.sub(pattern, lambda _: replacement[0], text, flags=re.M | re.S)
    current = current[:old.start()] + text + current[old.end():]
elif new:
    current = insert_section(current, new[0])

# Sections deliberately exclude the closing reference and signature. Recover
# each independently so a partial footer is completed without duplicating it.
reference = r'^(?:Resolves|Fixes|Closes|For|Ref) #\d+\b[^\n]*'
if not re.search(reference, current, re.M):
    closing = re.search(reference, generated, re.M)
    if closing:
        signature_start = re.search(r'^<!-- aidevops:', current, re.M)
        position = signature_start.start() if signature_start else len(current)
        current = current[:position].rstrip('\n') + '\n\n' + closing[0] + '\n\n' + current[position:]
if not re.search(r'^<!-- aidevops:sig -->', current, re.M):
    signature = re.search(r'^(?:<!-- aidevops:origin:[^\n]*\n)?<!-- aidevops:sig -->.*', generated, re.M | re.S)
    if signature:
        current = current.rstrip('\n') + '\n\n' + signature[0]
print(current.rstrip('\n'))
PY
	return $?
}

# Read one authoritative metadata snapshot, distinguishing a null body from a
# successful transport with no usable output. Do not retry outside transport policy.
_read_pr_metadata_json() {
	local repo="$1"
	local pr_number="$2"
	local metadata=""
	metadata=$(_gh_with_timeout read gh api "repos/${repo}/pulls/${pr_number}") || return 1
	# Slurping also rejects empty output and multiple JSON documents.
	printf '%s' "$metadata" | jq -es '
		length == 1 and (.[0] | type == "object" and
			has("title") and has("body") and (.title | type) == "string" and
			((.body | type) == "string" or .body == null))
	' >/dev/null 2>&1 || return 1
	printf '%s\n' "$metadata"
	return 0
}

# Restore generated metadata after partial PR creation recovered an existing PR.
# A retry may compute title/body details from a newer review-repair head.
# Arguments: PR number, repository slug, generated title, generated body.
_reconcile_recovered_pr_metadata() {
	local pr_number="$1"
	local repo="$2"
	local generated_title="$3"
	local generated_body="$4"
	local current_title=""
	local current_body=""
	local metadata=""

	metadata=$(_read_pr_metadata_json "$repo" "$pr_number" 2>/dev/null) || {
		print_error "Could not read recovered PR #${pr_number} title/body for metadata reconciliation"
		return 1
	}
	current_title=$(jq -r '.title' <<<"$metadata") || return 1
	current_body=$(jq -r '.body // ""' <<<"$metadata") || return 1
	generated_body=$(_merge_existing_pr_body "$current_body" "$generated_body" "${pr_metadata_overrides:-}") || return 1
	if [[ "$current_title" == "$generated_title" && "$current_body" == "$generated_body" ]]; then
		print_info "Recovered PR #${pr_number} metadata already matches the generated head"
		return 0
	fi

	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local body_file=""
	if ! mkdir -p "$temp_root" || ! body_file=$(mktemp "${temp_root}/aidevops-recovered-pr-body.XXXXXX"); then
		print_error "Could not create recovered PR metadata body file"
		return 1
	fi
	if ! printf '%s\n' "$generated_body" >"$body_file"; then
		rm -f "$body_file"
		print_error "Could not write recovered PR metadata body"
		return 1
	fi
	if ! gh_pr_edit_safe "$pr_number" --repo "$repo" --title "$generated_title" --body-file "$body_file" >/dev/null; then
		rm -f "$body_file"
		print_error "Failed to update stale metadata on recovered PR #${pr_number}"
		return 1
	fi
	rm -f "$body_file"

	metadata=$(_read_pr_metadata_json "$repo" "$pr_number" 2>/dev/null) || {
		print_error "Could not verify recovered PR #${pr_number} title/body reconciliation"
		return 1
	}
	current_title=$(jq -r '.title' <<<"$metadata") || return 1
	current_body=$(jq -r '.body // ""' <<<"$metadata") || return 1
	if [[ "$current_title" != "$generated_title" || "$current_body" != "$generated_body" ]]; then
		print_error "Recovered PR #${pr_number} metadata reconciliation did not reach the generated title/body postcondition"
		return 1
	fi
	print_success "Reconciled and verified recovered PR #${pr_number} metadata"
	return 0
}

# Verify that a worker-created leaf PR has the same-repository closing reference
# needed by GitHub's closingIssuesReferences metadata and by pulse's worker
# merge gate. A partial PR create can leave an otherwise valid PR with an empty
# body; repair that narrow condition before the issue/PR transition to review.
# Arguments: PR number, repository slug, expected issue number, generated body.
_ensure_worker_pr_linkage() {
	local pr_number="$1"
	local repo="$2"
	local issue_number="$3"
	local generated_body="$4"
	local current_body=""
	local metadata=""
	local reference_keyword="Resolves"

	if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ || "$repo" != */* || ! "$issue_number" =~ ^[1-9][0-9]*$ || -z "$generated_body" ]]; then
		print_error "Cannot validate worker PR linkage: invalid PR, repository, issue, or generated body"
		return 1
	fi

	metadata=$(_read_pr_metadata_json "$repo" "$pr_number" 2>/dev/null) || {
		print_error "Cannot validate worker PR #${pr_number} linkage before review transition"
		return 1
	}
	current_body=$(jq -r '.body // ""' <<<"$metadata") || return 1
	if printf '%s' "$generated_body" | jq -Rse --arg issue "$issue_number" \
		'test("(^|\\n)(For|Ref) #" + $issue + "\\b")' >/dev/null 2>&1; then
		reference_keyword="For"
	fi

	local closing_issues=""
	closing_issues=$(printf '%s' "$current_body" |
		grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#[0-9]+' |
		grep -oE '[0-9]+' | sort -u) || closing_issues=""
	if [[ "$closing_issues" == "$issue_number" ]]; then
		if [[ "$reference_keyword" == "For" ]]; then
			print_error "Worker PR #${pr_number} has a closing reference despite non-closing repair intent"
			return 1
		fi
		return 0
	fi

	# A qualified close reference targets another repository. Do not add a local
	# reference to an ambiguous body: pulse must remain fail-closed for cross-repo
	# or multi-issue relationships.
	if [[ -n "$closing_issues" ]] || grep -Eiq \
		'(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+[^[:space:]]+#[0-9]+' <<<"$current_body"; then
		print_error "Worker PR #${pr_number} has ambiguous or cross-repository closing references; refusing linkage repair"
		return 1
	fi
	# GH#33374: explicit checkpoint intent is not a missing closing reference.
	# Never turn a deliberate For/Ref body into a GitHub auto-closing link.
	if printf '%s' "$current_body" | jq -Rse --arg issue "$issue_number" \
		'test("\\b(for|ref)[[:space:]]+#" + $issue + "\\b"; "i")' >/dev/null 2>&1; then
		print_info "Preserving non-closing checkpoint reference on worker PR #${pr_number}"
		return 0
	fi

	local repaired_body="$generated_body"
	if [[ -n "$current_body" ]]; then
		repaired_body="${current_body}"$'\n\n'"${reference_keyword} #${issue_number}"
	fi
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local repair_body_file=""
	if ! mkdir -p "$temp_root" || ! repair_body_file=$(mktemp "${temp_root}/aidevops-worker-pr-body.XXXXXX"); then
		print_error "Could not create worker PR linkage repair body file"
		return 1
	fi
	if ! printf '%s\n' "$repaired_body" >"$repair_body_file"; then
		rm -f "$repair_body_file"
		print_error "Could not write worker PR linkage repair body"
		return 1
	fi
	if ! gh_pr_edit_safe "$pr_number" --repo "$repo" --body-file "$repair_body_file" >/dev/null; then
		rm -f "$repair_body_file"
		print_error "Failed to repair missing linked issue reference on worker PR #${pr_number}"
		return 1
	fi
	rm -f "$repair_body_file"

	metadata=$(_read_pr_metadata_json "$repo" "$pr_number" 2>/dev/null) || {
		print_error "Could not verify repaired linked issue reference on worker PR #${pr_number}"
		return 1
	}
	current_body=$(jq -r '.body // ""' <<<"$metadata") || return 1
	if [[ "$reference_keyword" == "For" ]]; then
		printf '%s' "$current_body" | jq -Rse --arg issue "$issue_number" \
			'test("(^|\\n)(For|Ref) #" + $issue + "\\b") and
			(test("\\b(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#" + $issue + "\\b"; "i") | not)' >/dev/null 2>&1 || return 1
		return 0
	fi
	closing_issues=$(printf '%s' "$current_body" |
		grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#[0-9]+' |
		grep -oE '[0-9]+' | sort -u) || closing_issues=""
	if [[ "$closing_issues" != "$issue_number" ]]; then
		print_error "Worker PR #${pr_number} linkage repair did not produce Resolves #${issue_number}"
		return 1
	fi
	print_success "Repaired and verified linked issue reference on worker PR #${pr_number}"
	return 0
}

# --- Merge Summary ---

# Reconcile the single canonical merge summary comment without creating a
# duplicate. The gh API shim signs the PATCH body before it reaches GitHub.
# Arguments: PR number, repo, comments endpoint, marker, generated body.
_reconcile_existing_merge_summary() {
	local pr_number="$1"
	local repo="$2"
	local comments_endpoint="$3"
	local merge_summary_marker="$4"
	local merge_summary_body="$5"
	local existing_summary=""
	local summary_id=""
	local existing_body=""
	local summary_id_jq="[.[] | select(.body | test(\$marker))] | first | .id"
	local summary_body_jq="[.[] | select(.body | test(\$marker))] | first | .body"

	existing_summary=$(_gh_with_timeout read gh api "$comments_endpoint" \
		2>/dev/null) || {
		print_error "Could not read the canonical merge summary comment on PR #${pr_number}"
		return 1
	}
	if ! summary_id=$(printf '%s' "$existing_summary" |
		jq -er --arg marker "$merge_summary_marker" "$summary_id_jq"); then
		print_error "Could not identify the canonical merge summary comment on PR #${pr_number}"
		return 1
	fi
	if ! existing_body=$(printf '%s' "$existing_summary" |
		jq -er --arg marker "$merge_summary_marker" "$summary_body_jq"); then
		print_error "Could not read the canonical merge summary comment body on PR #${pr_number}"
		return 1
	fi
	if [[ "$existing_body" == "$merge_summary_body"* ]]; then
		print_info "Merge summary comment already matches PR #${pr_number} — skipping duplicate (t2767)"
		return 0
	fi
	if ! gh api "repos/${repo}/issues/comments/${summary_id}" \
		--method PATCH --raw-field "body=${merge_summary_body}" >/dev/null; then
		print_error "Failed to update stale canonical merge summary comment on PR #${pr_number}"
		return 1
	fi
	existing_summary=$(_gh_with_timeout read gh api "$comments_endpoint" \
		2>/dev/null) || {
		print_error "Could not verify the updated canonical merge summary comment on PR #${pr_number}"
		return 1
	}
	if ! existing_body=$(printf '%s' "$existing_summary" |
		jq -er --arg marker "$merge_summary_marker" "$summary_body_jq"); then
		print_error "Could not read the updated canonical merge summary comment body on PR #${pr_number}"
		return 1
	fi
	if [[ "$existing_body" != "$merge_summary_body"* ]]; then
		print_error "Canonical merge summary comment on PR #${pr_number} did not reach the generated metadata postcondition"
		return 1
	fi
	print_success "Updated and verified stale canonical merge summary comment on PR #${pr_number}"
	return 0
}

# Post the MERGE_SUMMARY comment on the PR (full-loop step 4.2.1).
# Arguments: pr_number, repo, issue_number, summary_what, files_changed,
#            summary_testing, summary_decisions
# t2767: Idempotent — preserves a matching canonical MERGE_SUMMARY comment,
# while updating the one canonical comment if a retry generated newer metadata.
_post_merge_summary() {
	local pr_number="$1" repo="$2" issue_number="$3" summary_what="$4"
	local files_changed="$5" summary_testing="$6" summary_decisions="$7"
	files_changed=$(_format_files_changed_for_body "$files_changed") || return 1
	local merge_summary_marker="<!-- MERGE_SUMMARY -->"
	local comments_endpoint="repos/${repo}/issues/${pr_number}/comments"
	local summary_count_jq="[.[] | select(.body | test(\"${merge_summary_marker}\"))] | length"
	local merge_summary_body="${merge_summary_marker}
## Completion Summary

- **What**: ${summary_what:-Implementation for issue #${issue_number}}
- **Issue**: #${issue_number}
- **Files changed**: ${files_changed:-see diff}
- **Testing**: ${summary_testing:-shellcheck clean, self-assessed}
- **Key decisions**: ${summary_decisions:-none}"

	# t2767/GH#26608: Check if the canonical MERGE_SUMMARY comment already exists before posting.
	# Uses PR timeline comments endpoint (issues endpoint covers PR comments).
	# Counter safety: validate result is a number before comparing (t2763).
	local _existing_count=0
	local _tmp_count=""
	if ! _tmp_count=$(gh api "$comments_endpoint" \
		--jq "$summary_count_jq"); then
		print_error "Could not verify existing merge summary comments on PR #${pr_number}; refusing a potentially duplicate post"
		return 1
	fi
	if [[ ! "$_tmp_count" =~ ^[0-9]+$ ]]; then
		print_error "Invalid merge summary count for PR #${pr_number}: ${_tmp_count:-empty}"
		return 1
	fi
	_existing_count="$_tmp_count"
	if [[ "$_existing_count" -eq 1 ]]; then
		_reconcile_existing_merge_summary "$pr_number" "$repo" "$comments_endpoint" \
			"$merge_summary_marker" "$merge_summary_body"
		return $?
	fi
	if [[ "$_existing_count" -gt 1 ]]; then
		print_error "PR #${pr_number} has ${_existing_count} canonical merge summary comments; expected exactly one"
		return 1
	fi

	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local merge_summary_file=""
	if ! mkdir -p "$temp_root"; then
		print_error "Could not create merge summary workspace: ${temp_root}"
		return 1
	fi
	if ! merge_summary_file=$(mktemp "${temp_root}/aidevops-merge-summary.XXXXXX"); then
		print_error "Could not create merge summary body file in ${temp_root}"
		return 1
	fi
	if ! printf '%s\n' "$merge_summary_body" >"$merge_summary_file"; then
		print_error "Could not write merge summary body file for PR #${pr_number}"
		rm -f "$merge_summary_file"
		return 1
	fi

	# gh_pr_comment signs a private copy of --body-file before posting. Keep
	# stderr visible so policy or GitHub failures retain actionable diagnostics.
	if ! gh_pr_comment "$pr_number" --repo "$repo" --body-file "$merge_summary_file" >/dev/null; then
		print_error "Failed to post signed merge summary comment on PR #${pr_number}"
		rm -f "$merge_summary_file"
		return 1
	fi
	rm -f "$merge_summary_file"

	_tmp_count=$(gh api "$comments_endpoint" \
		--jq "$summary_count_jq") || {
		print_error "Merge summary posted on PR #${pr_number}, but verification failed"
		return 1
	}
	if [[ "$_tmp_count" != "1" ]]; then
		print_error "Merge summary postcondition failed on PR #${pr_number}: expected 1 canonical comment, found ${_tmp_count:-unknown}"
		return 1
	fi
	print_success "Signed merge summary comment posted and verified on PR #${pr_number}"
	return 0
}

# --- Issue Labeling ---

# Label the linked issue as in-review + self-assign, removing all sibling
# status labels (t2033). Defence-in-depth for t2056/t2110: even if the
# interactive-session-helper.sh claim was skipped or failed, the PR-open
# path ensures the assignee is set — preventing the status:in-review +
# zero-assignees degraded state that breaks dispatch dedup.
# Arguments: issue_number, repo
_label_issue_in_review() {
	local issue_number="$1" repo="$2"
	local review_status="in-review"

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
	if [[ "$issue_state" == "OPEN" ]]; then
		# Resolve the current gh user for self-assignment (best-effort)
		local current_user=""
		current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
		if [[ -n "$current_user" && "$current_user" != "null" ]]; then
			set_issue_status "$issue_number" "$repo" "$review_status" \
				--add-assignee "$current_user" >/dev/null 2>&1 || true
		else
			set_issue_status "$issue_number" "$repo" "$review_status" >/dev/null 2>&1 || true
		fi
	fi
	return 0
}

# Label the newly opened PR as in-review, removing stale status:available that
# can be inherited from issue-style label operations on PR issues.
# Arguments: pr_number, repo
_label_pr_in_review() {
	local pr_number="$1" repo="$2"
	local review_status="in-review"

	if [[ -z "$pr_number" || -z "$repo" ]]; then
		return 0
	fi
	set_issue_status "$pr_number" "$repo" "$review_status" >/dev/null 2>&1 || true
	return 0
}
