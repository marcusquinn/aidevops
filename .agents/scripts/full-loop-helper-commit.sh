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

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Pre-Merge Gate ---

# Pre-merge gate (GH#17541) — deterministic enforcement of review-bot-gate
# before any PR merge. Workers MUST call this before `gh pr merge`.
# Models the pulse-wrapper.sh pattern (line 8243-8262) for the worker merge path.
#
# Usage: full-loop-helper.sh pre-merge-gate <PR_NUMBER> [REPO]
# Exit codes: 0 = safe to merge, 1 = gate failed (do NOT merge)
cmd_pre_merge_gate() {
	local pr_number="${1:-}"
	local repo="${2:-}"

	if [[ -z "$pr_number" ]]; then
		print_error "Usage: full-loop-helper.sh pre-merge-gate <PR_NUMBER> [REPO]"
		return 1
	fi

	# Auto-detect repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			print_error "Cannot detect repo. Pass REPO as second argument."
			return 1
		fi
	fi

	local rbg_helper="${SCRIPT_DIR}/review-bot-gate-helper.sh"
	if [[ ! -f "$rbg_helper" ]]; then
		# Fallback to deployed location
		rbg_helper="${HOME}/.aidevops/agents/scripts/review-bot-gate-helper.sh"
	fi

	if [[ ! -f "$rbg_helper" ]]; then
		print_warning "review-bot-gate-helper.sh not found — skipping gate (degraded mode)"
		return 0
	fi

	print_info "Running review bot gate for PR #${pr_number} in ${repo}..."

	# Use 'wait' mode (polls up to 600s) — same as full-loop.md step 4.4 instructs,
	# but now enforced in code rather than relying on prompt compliance.
	local rbg_result=""
	rbg_result=$(bash "$rbg_helper" wait "$pr_number" "$repo" 2>&1) || true

	local rbg_status=""
	rbg_status=$(printf '%s' "$rbg_result" | grep -oE '(PASS|SKIP|WAITING|PASS_RATE_LIMITED)' | tail -1)

	case "$rbg_status" in
	PASS | SKIP | PASS_RATE_LIMITED)
		print_success "Review bot gate: ${rbg_status} — safe to merge PR #${pr_number}"
		return 0
		;;
	*)
		print_error "Review bot gate: ${rbg_status:-FAILED} — do NOT merge PR #${pr_number}"
		printf '%s\n' "$rbg_result" | tail -5
		return 1
		;;
	esac
}

# --- Argument Parsing ---

# Parse commit-and-pr arguments into caller-scoped variables.
# Expects the caller to have declared: issue_number, commit_message, pr_title,
# summary_what, summary_testing, summary_decisions, extra_labels (array).
# Returns 1 on unknown argument.
_parse_commit_and_pr_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--issue)
			issue_number="$2"
			shift 2
			;;
		--message)
			commit_message="$2"
			shift 2
			;;
		--title)
			pr_title="$2"
			shift 2
			;;
		--summary)
			summary_what="$2"
			shift 2
			;;
		--testing)
			summary_testing="$2"
			shift 2
			;;
		--decisions)
			summary_decisions="$2"
			shift 2
			;;
		--label)
			extra_labels+=("$2")
			shift 2
			;;
		--allow-parent-close)
			allow_parent_close=1
			shift
			;;
		--skip-hooks)
			# Pass --no-verify to git push. Use for doc-only PRs when hooks
			# have been manually verified clean. See GH#20138.
			skip_hooks=1
			shift
			;;
		*)
			print_error "Unknown argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

# --- Input Validation ---

# Validate commit-and-pr inputs: required fields and branch safety.
# Sets caller-scoped $repo and $branch on success.
# Returns 1 on validation failure.
_validate_commit_and_pr_inputs() {
	local issue_number="$1" commit_message="$2"

	if [[ -z "$issue_number" || -z "$commit_message" ]]; then
		print_error "Usage: full-loop-helper.sh commit-and-pr --issue <N> --message <msg>"
		return 1
	fi

	repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
	if [[ -z "$repo" ]]; then
		print_error "Cannot detect repo from git remote."
		return 1
	fi

	branch=$(git branch --show-current 2>/dev/null || echo "")
	if [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" ]]; then
		print_error "Cannot commit-and-pr from branch '${branch:-detached}'. Must be on a feature branch."
		return 1
	fi
	return 0
}

# --- Staging & Commit ---

# Stage all changes and commit with the given message.
# Skips commit if nothing staged but commits exist ahead of main.
# Returns 1 on failure.
_stage_and_commit() {
	local commit_message="$1"

	print_info "Staging and committing changes..."
	if ! git add -A; then
		print_error "git add failed"
		return 1
	fi

	if git diff --cached --quiet 2>/dev/null; then
		local ahead=""
		ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
		if [[ "$ahead" == "0" ]]; then
			print_error "No changes to commit and no commits ahead of main."
			return 1
		fi
		print_info "No new changes to commit, but ${ahead} commit(s) ahead of main. Proceeding to PR."
	else
		if ! git commit -m "$commit_message"; then
			print_error "git commit failed"
			return 1
		fi
	fi
	return 0
}

# --- Project Validators (t2842) ---
# Closes the worker-CI-failure gap where workers ship code that fails
# project CI checks (Format/Lint/Typecheck) because no pre-push
# validation runs at commit time.
# Decomposed into 5 helpers to stay under the function-complexity gate:
#   _run_project_validators       — orchestrator
#   _validators_should_run        — bypass-path check
#   _detect_node_project          — node-project detection (returns pm)
#   _run_node_auto_fix            — format/lint auto-fix + amend
#   _run_node_typecheck           — typecheck check-only

# Returns 0 if validators should run, 1 if any bypass condition applies.
# Prints the bypass reason on info as appropriate.
# Args: $1=skip_hooks (0|1)
_validators_should_run() {
	local skip_hooks="${1:-0}"
	if [[ "$skip_hooks" == "1" ]]; then
		return 1
	fi
	if [[ "${AIDEVOPS_SKIP_PROJECT_VALIDATORS:-0}" == "1" ]]; then
		print_info "[validators] AIDEVOPS_SKIP_PROJECT_VALIDATORS=1, skipping"
		return 1
	fi
	local last_msg
	last_msg=$(git log -1 --format=%s 2>/dev/null || echo "")
	if [[ "$last_msg" =~ ^wip[[:space:]:\(] ]]; then
		print_info "[validators] wip commit (\"${last_msg}\"), skipping"
		return 1
	fi
	local non_docs_count
	non_docs_count=$(git show --name-only --format='' HEAD 2>/dev/null |
		grep -cvE '\.(md|txt|rst)$|^LICENSE|^COPYING|^\.gitignore$|^$' || true)
	# safe_grep_count guard (t2763): zero-match path may emit "0\n0"
	[[ "$non_docs_count" =~ ^[0-9]+$ ]] || non_docs_count=0
	if [[ "$non_docs_count" == "0" ]]; then
		print_info "[validators] docs-only change, skipping"
		return 1
	fi
	return 0
}

# Detect node project type and chosen package manager.
# Sets caller-scope `pm` variable (npm/pnpm/yarn) on success.
# Returns 0 if a node project with relevant scripts is detected, 1 otherwise.
_detect_node_project() {
	if [[ ! -f package.json ]]; then
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "[validators] jq not available, cannot inspect package.json — skipping"
		return 1
	fi
	local has_relevant_scripts
	# Only include scripts that are actually executed by the runner.
	# "format" and "lint" (without :fix suffix) are omitted because the runner
	# only attempts format:fix/format:write/prettier:fix and lint:fix — detecting
	# on bare format/lint causes false positives where validators report "passed"
	# without actually running anything (Augment review, PR #20898).
	has_relevant_scripts=$(jq -r '
		.scripts // {} |
		[has("format:fix"),has("format:write"),has("prettier:fix"),
		 has("lint:fix"),
		 has("typecheck"),has("check:types"),has("tsc")] |
		any
	' package.json 2>/dev/null || echo "false")
	if [[ "$has_relevant_scripts" != "true" ]]; then
		return 1
	fi
	pm="npm"
	if [[ -f pnpm-lock.yaml ]]; then
		pm="pnpm"
	elif [[ -f yarn.lock ]]; then
		pm="yarn"
	fi
	if ! command -v "$pm" >/dev/null 2>&1; then
		print_warning "[validators] $pm not available on PATH — skipping (set AIDEVOPS_SKIP_PROJECT_VALIDATORS=1 to silence)"
		return 1
	fi
	return 0
}

# Run auto-fix passes (format then lint). Continue past failures —
# fix scripts may legitimately exit non-zero on un-auto-fixable issues.
# If auto-fix produced changes, amend the HEAD commit.
# Sets caller-scope `fix_changes` to 1 if amend happened, 0 otherwise.
# Args: $1=pm (npm|pnpm|yarn) $2=timeout_secs $3=timeout_available (0|1)
# Returns 0 on success, 1 if amend failed.
_run_node_auto_fix() {
	local pm="$1"
	local t="$2"
	local timeout_available="${3:-0}"
	# Build a timeout prefix array; empty when timeout(1) is not available.
	local -a timeout_prefix=()
	[[ "$timeout_available" == "1" ]] && timeout_prefix=("timeout" "$t")
	fix_changes=0
	local script_name
	for script_name in format:fix format:write prettier:fix; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			print_info "[validators] $pm run $script_name (auto-fix)"
			"${timeout_prefix[@]}" "$pm" run "$script_name" >/dev/null 2>&1 || true
			break
		fi
	done
	# Lint auto-fix loop pattern matches format for parallel extension.
	# shellcheck disable=SC2043
	for script_name in lint:fix; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			print_info "[validators] $pm run $script_name (auto-fix)"
			"${timeout_prefix[@]}" "$pm" run "$script_name" >/dev/null 2>&1 || true
			break
		fi
	done
	if git diff --quiet 2>/dev/null; then
		return 0
	fi
	print_info "[validators] auto-fix produced changes, amending commit"
	# Use git add -u (tracked files only) to avoid staging untracked artifacts
	# that format/lint runners may create (e.g. caches, generated files).
	git add -u
	# --no-verify on amend: avoid recursing into pre-commit territory.
	if ! git commit --amend --no-edit --no-verify >/dev/null 2>&1; then
		print_error "[validators] failed to amend commit with auto-fix changes"
		git status -s 2>&1 | head -10 >&2
		return 1
	fi
	fix_changes=1
	return 0
}

# Run check-only typecheck. Picks first existing script in preference order.
# Captures output for failure diagnosis. Mentor error on failure.
# Args: $1=pm $2=timeout_secs $3=timeout_available (0|1)
# Returns 0 on pass/no-script, 1 on failure.
_run_node_typecheck() {
	local pm="$1"
	local t="$2"
	local timeout_available="${3:-0}"
	# Build a timeout prefix array; empty when timeout(1) is not available.
	local -a timeout_prefix=()
	[[ "$timeout_available" == "1" ]] && timeout_prefix=("timeout" "$t")
	local typecheck_script
	typecheck_script=""
	local script_name
	for script_name in typecheck check:types tsc; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			typecheck_script="$script_name"
			break
		fi
	done
	if [[ -z "$typecheck_script" ]]; then
		return 0
	fi
	print_info "[validators] $pm run $typecheck_script (check-only)"
	# Separate declaration from mktemp assignment: local masks the exit code of
	# command substitutions, so declare first then assign (Gemini review PR #20898).
	# mktemp without -t: more portable (GNU and BSD mktemp differ on -t semantics).
	local tc_log
	tc_log="$(mktemp)"
	local tc_rc=0
	"${timeout_prefix[@]}" "$pm" run "$typecheck_script" >"$tc_log" 2>&1 || tc_rc=$?
	if [[ "$tc_rc" -eq 0 ]]; then
		rm -f "$tc_log"
		return 0
	fi
	print_error "[validators] $typecheck_script FAILED — code has type errors"
	print_error "  last 20 lines:"
	tail -20 "$tc_log" >&2
	rm -f "$tc_log"
	print_error ""
	print_error "  diagnose:    $pm run $typecheck_script"
	print_error "  fix errors, commit, then re-run: full-loop-helper.sh commit-and-pr ..."
	print_error "  bypass:      full-loop-helper.sh commit-and-pr ... --skip-hooks"
	print_error "               (or AIDEVOPS_SKIP_PROJECT_VALIDATORS=1 env)"
	return 1
}

# Orchestrator. Args: $1=skip_hooks (0|1). Returns 0 on pass/skip, 1 on fail.
_run_project_validators() {
	local skip_hooks="${1:-0}"
	# _validators_should_run returns 0 when validators should run, 1 otherwise.
	if ! _validators_should_run "$skip_hooks"; then
		return 0
	fi
	local pm=""
	if ! _detect_node_project; then
		# Silent skip when no project detected (non-node project = most aidevops paths).
		return 0
	fi
	print_info "[validators] running node project validators ($pm)..."
	local validator_timeout
	validator_timeout="${AIDEVOPS_VALIDATOR_TIMEOUT:-300}"
	# Detect timeout(1) availability once here; sub-functions receive a flag so
	# they don't each re-check (portability: macOS may lack timeout without
	# GNU coreutils; pattern mirrors _rebase_and_push:L941).
	local timeout_available=0
	command -v timeout >/dev/null 2>&1 && timeout_available=1
	local fix_changes=0
	_run_node_auto_fix "$pm" "$validator_timeout" "$timeout_available" || return 1
	_run_node_typecheck "$pm" "$validator_timeout" "$timeout_available" || return 1
	if [[ "$fix_changes" == "1" ]]; then
		print_info "[validators] passed (auto-fix amended into commit)"
	else
		print_info "[validators] passed"
	fi
	return 0
}

# --- Rebase & Push ---

# Rebase onto origin/main and force-push the current branch.
# Args: $1=branch $2=skip_hooks (0|1, optional, default 0)
# Returns 1 on rebase conflict or push failure.
_rebase_and_push() {
	local branch="$1"
	local skip_hooks="${2:-0}"

	print_info "Rebasing onto origin/main..."
	if ! git fetch origin main --quiet 2>/dev/null; then
		print_warning "git fetch origin main failed — proceeding with current state"
	fi
	if ! git rebase origin/main 2>/dev/null; then
		print_error "Rebase conflict. Resolve conflicts, then run: git rebase --continue && full-loop-helper.sh commit-and-pr ..."
		git rebase --abort 2>/dev/null || true
		return 1
	fi

	# t2229 Layer 3: auto-reset .task-counter if rebase picked up a stale value.
	# After rebase, the branch may carry a counter lower than origin/main's
	# current value (race: main advanced between rebase-base and push).
	# Reset to origin/main's value to prevent silent regression on merge.
	if [[ -f .task-counter ]]; then
		local branch_counter="" base_counter=""
		branch_counter=$(cat .task-counter 2>/dev/null | tr -d '[:space:]') || true
		base_counter=$(git show origin/main:.task-counter 2>/dev/null | tr -d '[:space:]') || true
		if [[ -n "$branch_counter" && -n "$base_counter" ]] \
			&& [[ "$branch_counter" =~ ^[0-9]+$ ]] \
			&& [[ "$base_counter" =~ ^[0-9]+$ ]] \
			&& [[ "$((10#$branch_counter))" -lt "$((10#$base_counter))" ]]; then
			print_info "Auto-resetting .task-counter: ${branch_counter} → ${base_counter} (base drifted during rebase)"
			echo "$base_counter" > .task-counter
			git add .task-counter
			git commit -m "chore: reset .task-counter to origin/main value (t2229 race prevention)" --no-verify
		fi
	fi

	print_info "Pushing to origin/${branch}..."

	# GH#20138: 60s push timeout to detect pre-push hook hangs. Pre-push hooks
	# (privacy-guard, complexity-regression) can stall on network I/O or when
	# scanning large repos. If push exceeds 60s, print an actionable advisory
	# and return 1 so the caller can retry with --skip-hooks.
	# Fast-path: both hooks now exit early on doc-only diffs (<1s), so the
	# 60s timeout is a safety net for edge cases, not a normal code path.
	local push_timeout=60
	local _push_args=(-u origin "$branch" --force-with-lease)
	[[ "$skip_hooks" == "1" ]] && _push_args+=(--no-verify)

	local push_rc
	push_rc=0
	if command -v timeout >/dev/null 2>&1; then
		timeout "$push_timeout" git push "${_push_args[@]}" || push_rc=$?
	else
		git push "${_push_args[@]}" || push_rc=$?
	fi

	if [[ "$push_rc" -eq 124 ]]; then
		# timeout(1) exits 124 on SIGTERM
		print_error "Push timed out after ${push_timeout}s — likely a pre-push hook stalling."
		print_error "Diagnose: PRIVACY_GUARD_DEBUG=1 COMPLEXITY_GUARD_DEBUG=1 git push ${_push_args[*]}"
		print_error "Bypass (doc-only diff, no secrets): git push ${_push_args[*]} --no-verify"
		print_error "  or rerun: full-loop-helper.sh commit-and-pr ... --skip-hooks"
		print_error "See reference/pre-push-guards.md for diagnosis steps."
		return 1
	elif [[ "$push_rc" -ne 0 ]]; then
		print_error "Push failed (exit ${push_rc}). Check remote state and retry."
		return 1
	fi
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
		jq -r '(.labels // [])[].name | select(. == "parent-task" or . == "meta")' | head -n 1 || true)

	if [[ -n "$hit" ]]; then
		return 0
	fi
	return 1
}

# Build the PR body string and print it to stdout.
# Arguments: issue_number, summary_what, summary_testing, files_changed,
#            sig_footer, closing_keyword (default: Resolves)
_build_pr_body() {
	local issue_number="$1" summary_what="$2" summary_testing="$3"
	local files_changed="$4" sig_footer="$5"
	local closing_keyword="${6:-Resolves}"

	printf '%s\n' "## Summary

${summary_what:-Implementation for issue #${issue_number}.}

## Files Changed

${files_changed:-See diff}

## Runtime Testing

- **Risk level:** Low (agent prompts / infrastructure scripts)
- **Verification:** ${summary_testing:-shellcheck clean, self-assessed}

${closing_keyword} #${issue_number}

${sig_footer}"
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
	task_id=$(grep -E "^- \[[ x]\] t[0-9]+ .*ref:GH#${issue_number}([^0-9]|\$)" "$todo_file" 2>/dev/null \
		| head -1 \
		| grep -oE '^- \[[ x]\] t[0-9]+' \
		| grep -oE 't[0-9]+$' \
		|| true)

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

# Create the PR and print the PR number to stdout.
# Arguments: repo, pr_title, pr_body, origin_label; extra_labels passed as remaining args.
# Returns 1 on failure.
# t2115: Uses gh_create_pr wrapper (shared-constants.sh) for origin label + signature auto-append.
# t2767: Implements partial-success recovery — when gh_create_pr exits non-zero but a PR
# already exists for the current branch (GitHub created it but a follow-up update failed),
# we recover and continue instead of bailing out.
_create_pr() {
	local repo="$1" pr_title="$2" pr_body="$3" origin_label="$4"
	shift 4
	local -a extra_labels=("$@")

	print_info "Creating PR..."
	local pr_url="" rc=0
	# t2115: gh_create_pr auto-appends origin label and signature footer.
	# The explicit --label "$origin_label" is kept for backward compat (GitHub deduplicates).
	local -a pr_cmd=(gh_create_pr --repo "$repo" --title "$pr_title" --body "$pr_body" --label "$origin_label")
	for lbl in "${extra_labels[@]+"${extra_labels[@]}"}"; do
		pr_cmd+=(--label "$lbl")
	done

	pr_url=$("${pr_cmd[@]}" 2>&1) || rc=$?

	if [[ $rc -ne 0 ]]; then
		# t2767: Partial-success recovery.
		# gh pr create (via gh_create_pr) can return non-zero even when GitHub already
		# created the PR — this happens when a follow-up GraphQL mutation (body update,
		# label application) succeeds on GitHub's backend but the subsequent API response
		# fails with a transient error (e.g. "Something went wrong while executing your query").
		# Before treating this as a hard failure, check whether the PR now exists.
		local current_branch="" recovered_url=""
		current_branch=$(git branch --show-current 2>/dev/null || echo "")
		recovered_url=$(_gh_recover_pr_if_exists "$current_branch" "$repo" 2>/dev/null || echo "")
		if [[ -n "$recovered_url" ]]; then
			print_info "PR creation command returned non-zero but PR exists — recovering (t2767): ${recovered_url}"
			pr_url="$recovered_url"
		else
			print_error "PR creation failed: ${pr_url}"
			return 1
		fi
	fi

	local pr_number=""
	pr_number=$(printf '%s' "$pr_url" | grep -oE '[0-9]+$' || echo "")
	if [[ -z "$pr_number" ]]; then
		print_error "Could not extract PR number from: ${pr_url}"
		return 1
	fi

	print_success "PR #${pr_number} created: ${pr_url}"
	printf '%s\n' "$pr_number"
	return 0
}

# --- Merge Summary ---

# Post the MERGE_SUMMARY comment on the PR (full-loop step 4.2.1).
# Arguments: pr_number, repo, issue_number, summary_what, files_changed,
#            summary_testing, summary_decisions
# t2767: Idempotent — skips posting if MERGE_SUMMARY comment already exists.
# This handles the partial-success recovery case where commit-and-pr was
# interrupted after posting the comment but before returning the PR number.
_post_merge_summary() {
	local pr_number="$1" repo="$2" issue_number="$3" summary_what="$4"
	local files_changed="$5" summary_testing="$6" summary_decisions="$7"

	# t2767: Check if MERGE_SUMMARY comment already exists before posting.
	# Uses PR timeline comments endpoint (issues endpoint covers PR comments).
	# Counter safety: validate result is a number before comparing (t2763).
	local _existing_count=0
	local _tmp_count=""
	_tmp_count=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("MERGE_SUMMARY"))] | length' 2>/dev/null || true)
	[[ "$_tmp_count" =~ ^[0-9]+$ ]] && _existing_count="$_tmp_count"
	if [[ "$_existing_count" -gt 0 ]]; then
		print_info "Merge summary comment already exists on PR #${pr_number} — skipping duplicate (t2767)"
		return 0
	fi

	local merge_summary="<!-- MERGE_SUMMARY -->
## Completion Summary

- **What**: ${summary_what:-Implementation for issue #${issue_number}}
- **Issue**: #${issue_number}
- **Files changed**: ${files_changed:-see diff}
- **Testing**: ${summary_testing:-shellcheck clean, self-assessed}
- **Key decisions**: ${summary_decisions:-none}"

	if gh_pr_comment "$pr_number" --repo "$repo" --body "$merge_summary" >/dev/null 2>&1; then
		print_success "Merge summary comment posted on PR #${pr_number}"
	else
		print_warning "Failed to post merge summary comment — post it manually"
	fi
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

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
	if [[ "$issue_state" == "OPEN" ]]; then
		# Resolve the current gh user for self-assignment (best-effort)
		local current_user=""
		current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
		if [[ -n "$current_user" && "$current_user" != "null" ]]; then
			set_issue_status "$issue_number" "$repo" "in-review" \
				--add-assignee "$current_user" >/dev/null 2>&1 || true
		else
			set_issue_status "$issue_number" "$repo" "in-review" >/dev/null 2>&1 || true
		fi
	fi
	return 0
}
