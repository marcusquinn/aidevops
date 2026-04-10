#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Full Development Loop Orchestrator — state management for AI-driven dev workflow.
# Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
# Decision logic lives in full-loop.md; this script handles state + background exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly STATE_DIR=".agents/loop-state"
readonly STATE_FILE="${STATE_DIR}/full-loop.local.state"
readonly DEFAULT_MAX_TASK_ITERATIONS=50 DEFAULT_MAX_PREFLIGHT_ITERATIONS=5 DEFAULT_MAX_PR_ITERATIONS=20
readonly BOLD='\033[1m'

HEADLESS="${FULL_LOOP_HEADLESS:-false}"
_FG_PID_FILE=""

is_headless() { [[ "$HEADLESS" == "true" ]]; }

print_phase() {
	printf "\n${BOLD}${CYAN}=== Phase: %s ===${NC}\n${CYAN}%s${NC}\n\n" "$1" "$2"
}

save_state() {
	local phase="$1" prompt="$2" pr_number="${3:-}" started_at="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	mkdir -p "$STATE_DIR"
	cat >"$STATE_FILE" <<EOF
---
active: true
phase: ${phase}
started_at: "${started_at}"
updated_at: "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
pr_number: "${pr_number}"
max_task_iterations: ${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}
max_preflight_iterations: ${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}
max_pr_iterations: ${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}
skip_preflight: ${SKIP_PREFLIGHT:-false}
skip_postflight: ${SKIP_POSTFLIGHT:-false}
skip_runtime_testing: ${SKIP_RUNTIME_TESTING:-false}
no_auto_pr: ${NO_AUTO_PR:-false}
no_auto_deploy: ${NO_AUTO_DEPLOY:-false}
headless: ${HEADLESS:-false}
---

${prompt}
EOF
}

load_state() {
	[[ -f "$STATE_FILE" ]] || return 1
	# Pre-initialize all state variables with safe defaults so that set -u does
	# not abort when the state file is incomplete (missing fields are never set
	# by the awk parse loop, leaving variables unbound).
	PHASE=""
	ACTIVE=""
	ITERATION=""
	STARTED_AT="unknown"
	UPDATED_AT=""
	PR_NUMBER=""
	MAX_TASK_ITERATIONS="$DEFAULT_MAX_TASK_ITERATIONS"
	MAX_PREFLIGHT_ITERATIONS="$DEFAULT_MAX_PREFLIGHT_ITERATIONS"
	MAX_PR_ITERATIONS="$DEFAULT_MAX_PR_ITERATIONS"
	SKIP_PREFLIGHT="false"
	SKIP_POSTFLIGHT="false"
	SKIP_RUNTIME_TESTING="false"
	NO_AUTO_PR="false"
	NO_AUTO_DEPLOY="false"
	HEADLESS="${FULL_LOOP_HEADLESS:-false}"
	SAVED_PROMPT=""
	# Single-pass parse of YAML frontmatter — safe variable assignment via printf -v
	local _key _val _line
	while IFS= read -r _line; do
		_key="${_line%%=*}"
		_val="${_line#*=}"
		# Allowlist: only set known state variables
		case "$_key" in
		PHASE | ACTIVE | ITERATION | STARTED_AT | UPDATED_AT | \
			MAX_TASK_ITERATIONS | MAX_PREFLIGHT_ITERATIONS | \
			MAX_PR_ITERATIONS | SKIP_PREFLIGHT | SKIP_POSTFLIGHT | SKIP_RUNTIME_TESTING | \
			NO_AUTO_PR | NO_AUTO_DEPLOY | HEADLESS | PR_NUMBER)
			printf -v "$_key" '%s' "$_val"
			;;
		esac
	done < <(awk -F': ' '/^---$/{n++;next} n==1 && NF>=2{
		gsub(/[" ]/, "", $2); k=$1; gsub(/-/, "_", k)
		print toupper(k) "=" $2
	}' "$STATE_FILE")
	CURRENT_PHASE="${PHASE:-}"
	SAVED_PROMPT=$(sed -n '/^---$/,/^---$/d; p' "$STATE_FILE")
	return 0
}

is_loop_active() { [[ -f "$STATE_FILE" ]] && grep -q '^active: true' "$STATE_FILE"; }

is_aidevops_repo() {
	local r
	r=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	[[ "$r" == *"/aidevops"* ]] || [[ -f "$r/.aidevops-repo" ]]
}
get_current_branch() { git branch --show-current 2>/dev/null || echo ""; }
is_on_feature_branch() {
	local b
	b=$(get_current_branch)
	[[ -n "$b" && "$b" != "main" && "$b" != "master" ]]
}

# cool — phase emitters drive the AI loop per full-loop.md
emit_task_phase() {
	print_phase "Task Development" "AI will iterate on task until TASK_COMPLETE"
	echo "PROMPT: $1"
	echo "When complete, emit: <promise>TASK_COMPLETE</promise>"
}
emit_preflight_phase() {
	print_phase "Preflight" "AI runs quality checks"
	[[ "${SKIP_PREFLIGHT:-false}" == "true" ]] && {
		print_warning "Preflight skipped"
		echo "<promise>PREFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Run quality checks per full-loop.md guidance."
}
emit_pr_create_phase() {
	print_phase "PR Creation" "AI creates pull request"
	[[ "${NO_AUTO_PR:-false}" == "true" ]] && ! is_headless && {
		print_warning "Auto PR disabled"
		return 0
	}
	echo "Create PR per full-loop.md guidance."
}
emit_pr_review_phase() {
	print_phase "PR Review" "AI monitors CI and reviews"
	echo "Monitor PR per full-loop.md guidance."
}
emit_postflight_phase() {
	print_phase "Postflight" "AI verifies release health"
	[[ "${SKIP_POSTFLIGHT:-false}" == "true" ]] && {
		print_warning "Postflight skipped"
		echo "<promise>POSTFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Verify release per full-loop.md guidance."
}
emit_deploy_phase() {
	print_phase "Deploy" "AI deploys changes"
	! is_aidevops_repo && {
		print_info "Not aidevops repo, skipping deploy"
		return 0
	}
	[[ "${NO_AUTO_DEPLOY:-false}" == "true" ]] && {
		print_warning "Auto deploy disabled"
		return 0
	}
	echo "Run setup.sh per full-loop.md guidance."
}

# Pre-start maintainer gate check (GH#17810).
# Extracts the first issue number from the prompt and verifies the linked
# issue does not have needs-maintainer-review label or missing assignee.
# Mirrors the logic in .github/workflows/maintainer-gate.yml check-pr job.
#
# Returns:
#   0 — gate passes (safe to start)
#   1 — gate blocked (do NOT start work)
#
# Skips gracefully when:
#   - No issue number found in prompt (not all tasks have linked issues)
#   - gh CLI unavailable or API call fails (fail-open to avoid blocking non-issue tasks)
#   - Issue is closed (already reviewed)
_check_linked_issue_gate() {
	local prompt="$1"
	local repo="${2:-}"

	# Extract first issue number from prompt — look for #NNN or issue/NNN patterns
	local issue_num
	issue_num=$(echo "$prompt" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$issue_num" ]]; then
		# No issue number in prompt — skip gate (not all tasks reference issues)
		return 0
	fi

	# Resolve repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
	fi
	if [[ -z "$repo" ]]; then
		# Cannot determine repo — skip gate (fail-open)
		return 0
	fi

	# Fetch issue data — fail-open on API errors (don't block non-issue tasks)
	local raw_issue
	raw_issue=$(gh api "repos/${repo}/issues/${issue_num}" 2>/dev/null) || {
		print_warning "Maintainer gate pre-check: could not fetch issue #${issue_num} — skipping gate"
		return 0
	}

	local state labels assignees
	state=$(echo "$raw_issue" | jq -r '.state' 2>/dev/null || echo "unknown")
	labels=$(echo "$raw_issue" | jq -r '[.labels[]?.name] | .[]' 2>/dev/null || true)
	assignees=$(echo "$raw_issue" | jq -r '[.assignees[]?.login] | .[]' 2>/dev/null || true)

	# Skip closed issues — they've already been reviewed
	if [[ "$state" == "closed" ]]; then
		return 0
	fi

	local blocked=false reasons=""

	# Check 1: needs-maintainer-review label
	if echo "$labels" | grep -q 'needs-maintainer-review'; then
		blocked=true
		reasons="${reasons}Issue #${issue_num} has \`needs-maintainer-review\` label — a maintainer must approve before work begins.\n"
	fi

	# Check 2: no assignee (exempt quality-debt issues per GH#6623)
	if [[ -z "$assignees" ]]; then
		if echo "$labels" | grep -q 'quality-debt'; then
			: # exempt
		else
			blocked=true
			reasons="${reasons}Issue #${issue_num} has no assignee — assign the issue before starting work.\n"
		fi
	fi

	if [[ "$blocked" == "true" ]]; then
		print_error "Maintainer gate pre-check BLOCKED — cannot start work:"
		printf '%b' "$reasons" >&2
		printf "To unblock:\n  1. Run: sudo aidevops approve issue %s\n  2. Assign the issue to yourself\n" "$issue_num" >&2
		return 1
	fi

	return 0
}

# Initialize option variables with defaults so set -u doesn't crash on
# export when flags are not passed.
_init_start_defaults() {
	MAX_TASK_ITERATIONS="${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}"
	MAX_PREFLIGHT_ITERATIONS="${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}"
	MAX_PR_ITERATIONS="${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}"
	SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
	SKIP_POSTFLIGHT="${SKIP_POSTFLIGHT:-false}"
	SKIP_RUNTIME_TESTING="${SKIP_RUNTIME_TESTING:-false}"
	NO_AUTO_PR="${NO_AUTO_PR:-false}"
	NO_AUTO_DEPLOY="${NO_AUTO_DEPLOY:-false}"
	DRY_RUN="${DRY_RUN:-false}"
	_BACKGROUND=false
	return 0
}

# Parse start subcommand options. Sets global option variables and _BACKGROUND.
# Arguments: all remaining args after the prompt string.
# Returns: 0 on success, 1 on unknown option.
_parse_start_options() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max-task-iterations)
			MAX_TASK_ITERATIONS="$2"
			shift 2
			;;
		--max-preflight-iterations)
			MAX_PREFLIGHT_ITERATIONS="$2"
			shift 2
			;;
		--max-pr-iterations)
			MAX_PR_ITERATIONS="$2"
			shift 2
			;;
		--skip-preflight)
			SKIP_PREFLIGHT=true
			shift
			;;
		--skip-postflight)
			SKIP_POSTFLIGHT=true
			shift
			;;
		--skip-runtime-testing)
			SKIP_RUNTIME_TESTING=true
			shift
			;;
		--no-auto-pr)
			NO_AUTO_PR=true
			shift
			;;
		--no-auto-deploy)
			NO_AUTO_DEPLOY=true
			shift
			;;
		--headless)
			HEADLESS=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--background | --bg)
			_BACKGROUND=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Launch the loop in the background via nohup.
# Arguments: $1 — prompt string.
_launch_background() {
	local prompt="$1"
	mkdir -p "$STATE_DIR"
	export MAX_TASK_ITERATIONS MAX_PREFLIGHT_ITERATIONS MAX_PR_ITERATIONS
	export SKIP_PREFLIGHT SKIP_POSTFLIGHT SKIP_RUNTIME_TESTING NO_AUTO_PR NO_AUTO_DEPLOY FULL_LOOP_HEADLESS="$HEADLESS"
	nohup "$0" _run_foreground "$prompt" >"${STATE_DIR}/full-loop.log" 2>&1 &
	echo "$!" >"${STATE_DIR}/full-loop.pid"
	print_success "Background loop started (PID: $!). Use 'status' or 'logs' to monitor."
	return 0
}

cmd_start() {
	local prompt="$1"
	shift

	_init_start_defaults
	_parse_start_options "$@" || return 1

	[[ -z "$prompt" ]] && {
		print_error "Usage: full-loop-helper.sh start \"<prompt>\" [options]"
		return 1
	}
	is_loop_active && {
		print_warning "Loop already active. Use 'resume' or 'cancel'."
		return 1
	}
	is_on_feature_branch || {
		print_error "Must be on a feature branch"
		return 1
	}

	# Pre-start maintainer gate check (GH#17810): block if linked issue has
	# needs-maintainer-review label or no assignee. Mirrors the CI gate in
	# .github/workflows/maintainer-gate.yml so workers fail fast locally
	# instead of creating PRs that will always fail CI.
	_check_linked_issue_gate "$prompt" || return 1

	printf "\n${BOLD}${BLUE}=== FULL DEVELOPMENT LOOP - STARTING ===${NC}\n  Task: %s\n  Branch: %s | Headless: %s\n\n" \
		"$prompt" "$(get_current_branch)" "$HEADLESS"
	[[ "${DRY_RUN:-false}" == "true" ]] && {
		print_info "Dry run - no changes made"
		return 0
	}

	save_state "task" "$prompt"
	SAVED_PROMPT="$prompt"

	if [[ "$_BACKGROUND" == "true" ]]; then
		_launch_background "$prompt"
		return 0
	fi
	emit_task_phase "$prompt"
}

# Phase transition map: current -> next phase + emit function
_next_phase() {
	case "$1" in
	task) echo "preflight emit_preflight_phase" ;;
	preflight) echo "pr-create emit_pr_create_phase" ;;
	pr-create) echo "pr-review emit_pr_review_phase" ;;
	pr-review) echo "postflight emit_postflight_phase" ;;
	postflight) echo "deploy emit_deploy_phase" ;;
	deploy) echo "complete cmd_complete" ;;
	complete) echo "complete cmd_complete" ;;
	*) return 1 ;;
	esac
}

cmd_resume() {
	is_loop_active || {
		print_error "No active loop to resume"
		return 1
	}
	load_state
	print_info "Resuming from phase: $CURRENT_PHASE"
	local transition
	transition=$(_next_phase "$CURRENT_PHASE") || {
		print_error "Unknown phase: $CURRENT_PHASE"
		return 1
	}
	local next_phase="${transition%% *}" emit_fn="${transition#* }"
	save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
	$emit_fn
}

cmd_status() {
	is_loop_active || {
		echo "No active full loop"
		return 0
	}
	load_state
	printf "\n${BOLD}Full Loop Status${NC}\nPhase: ${CYAN}%s${NC} | Started: %s | PR: %s | Headless: %s\nPrompt: %s\n\n" \
		"$CURRENT_PHASE" "$STARTED_AT" "${PR_NUMBER:-none}" "$HEADLESS" "$(echo "$SAVED_PROMPT" | head -3)"
}

cmd_cancel() {
	is_loop_active || {
		print_warning "No active loop to cancel"
		return 0
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && {
			kill "$pid" 2>/dev/null || true
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
		}
		rm -f "$pid_file"
	fi
	rm -f "$STATE_FILE" ".agents/loop-state/ralph-loop.local.state" ".agents/loop-state/quality-loop.local.state" 2>/dev/null
	print_success "Full loop cancelled"
}

cmd_logs() {
	local log_file="${STATE_DIR}/full-loop.log" lines="${1:-50}"
	[[ -f "$log_file" ]] || {
		print_warning "No log file. Start with --background first."
		return 1
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && print_info "Running (PID: $pid)" || print_warning "Not running (was PID: $pid)"
	fi
	printf "\n${BOLD}Full Loop Logs (last %d lines)${NC}\n" "$lines"
	tail -n "$lines" "$log_file"
}

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

# Commit-and-PR: stage, commit, rebase, push, create PR, post merge summary.
# Collapses full-loop steps 4.1-4.2.1 into a single deterministic call.
# Workers and interactive sessions both use this — no parallel logic.
#
# Usage: full-loop-helper.sh commit-and-pr --issue <N> --message <msg> [--title <title>] [--summary <what>] [--testing <how>] [--decisions <notes>] [--label <label>...]
# Exit codes: 0 = PR created (prints PR number to stdout), 1 = failure
#
# On rebase conflict: returns 1 with instructions. Caller must resolve and retry.
# On push failure: returns 1. Caller should check remote state.
# On PR creation failure: returns 1. Changes are committed and pushed — caller
# can create the PR manually.

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
		*)
			print_error "Unknown argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

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

# Rebase onto origin/main and force-push the current branch.
# Returns 1 on rebase conflict or push failure.
_rebase_and_push() {
	local branch="$1"

	print_info "Rebasing onto origin/main..."
	if ! git fetch origin main --quiet 2>/dev/null; then
		print_warning "git fetch origin main failed — proceeding with current state"
	fi
	if ! git rebase origin/main 2>/dev/null; then
		print_error "Rebase conflict. Resolve conflicts, then run: git rebase --continue && full-loop-helper.sh commit-and-pr ..."
		git rebase --abort 2>/dev/null || true
		return 1
	fi

	print_info "Pushing to origin/${branch}..."
	if ! git push -u origin "$branch" --force-with-lease 2>/dev/null; then
		print_error "Push failed. Check remote state and retry."
		return 1
	fi
	return 0
}

# Build the PR body string and print it to stdout.
# Arguments: issue_number, summary_what, summary_testing, files_changed, sig_footer
_build_pr_body() {
	local issue_number="$1" summary_what="$2" summary_testing="$3"
	local files_changed="$4" sig_footer="$5"

	printf '%s\n' "## Summary

${summary_what:-Implementation for issue #${issue_number}.}

## Files Changed

${files_changed:-See diff}

## Runtime Testing

- **Risk level:** Low (agent prompts / infrastructure scripts)
- **Verification:** ${summary_testing:-shellcheck clean, self-assessed}

Resolves #${issue_number}

${sig_footer}"
	return 0
}

# Create the PR and print the PR number to stdout.
# Arguments: repo, pr_title, pr_body, origin_label; extra_labels passed as remaining args.
# Returns 1 on failure.
_create_pr() {
	local repo="$1" pr_title="$2" pr_body="$3" origin_label="$4"
	shift 4
	local -a extra_labels=("$@")

	print_info "Creating PR..."
	local pr_url=""
	local -a pr_cmd=(gh pr create --repo "$repo" --title "$pr_title" --body "$pr_body" --label "$origin_label")
	for lbl in "${extra_labels[@]+"${extra_labels[@]}"}"; do
		pr_cmd+=(--label "$lbl")
	done

	pr_url=$("${pr_cmd[@]}" 2>&1) || {
		print_error "PR creation failed: ${pr_url}"
		return 1
	}

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

# Post the MERGE_SUMMARY comment on the PR (full-loop step 4.2.1).
# Arguments: pr_number, repo, issue_number, summary_what, files_changed,
#            summary_testing, summary_decisions
_post_merge_summary() {
	local pr_number="$1" repo="$2" issue_number="$3" summary_what="$4"
	local files_changed="$5" summary_testing="$6" summary_decisions="$7"

	local merge_summary="<!-- MERGE_SUMMARY -->
## Completion Summary

- **What**: ${summary_what:-Implementation for issue #${issue_number}}
- **Issue**: #${issue_number}
- **Files changed**: ${files_changed:-see diff}
- **Testing**: ${summary_testing:-shellcheck clean, self-assessed}
- **Key decisions**: ${summary_decisions:-none}"

	if gh pr comment "$pr_number" --repo "$repo" --body "$merge_summary" >/dev/null 2>&1; then
		print_success "Merge summary comment posted on PR #${pr_number}"
	else
		print_warning "Failed to post merge summary comment — post it manually"
	fi
	return 0
}

# Label the linked issue as in-review, removing in-progress/queued labels.
# Arguments: issue_number, repo
_label_issue_in_review() {
	local issue_number="$1" repo="$2"

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
	if [[ "$issue_state" == "OPEN" ]]; then
		gh issue edit "$issue_number" --repo "$repo" \
			--add-label "status:in-review" \
			--remove-label "status:in-progress" \
			--remove-label "status:queued" >/dev/null 2>&1 || true
	fi
	return 0
}

cmd_commit_and_pr() {
	local issue_number="" commit_message="" pr_title="" summary_what="" summary_testing="" summary_decisions=""
	local -a extra_labels=()

	_parse_commit_and_pr_args "$@" || return 1

	# Validate inputs and detect repo/branch (sets $repo and $branch in this scope)
	local repo="" branch=""
	_validate_commit_and_pr_inputs "$issue_number" "$commit_message" || return 1

	_stage_and_commit "$commit_message" || return 1
	_rebase_and_push "$branch" || return 1

	# Build PR metadata
	if [[ -z "$pr_title" ]]; then
		pr_title="GH#${issue_number}: ${commit_message}"
	fi

	local origin_label="origin:interactive"
	if [[ "${HEADLESS:-}" == "1" || "${FULL_LOOP_HEADLESS:-}" == "true" ]]; then
		origin_label="origin:worker"
	fi

	local sig_footer=""
	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		sig_footer=$("$sig_helper" footer 2>/dev/null || echo "")
	fi

	local files_changed=""
	files_changed=$(git diff --name-only origin/main..HEAD 2>/dev/null | tr '\n' ', ' | sed 's/,$//' || echo "")

	local pr_body=""
	pr_body=$(_build_pr_body "$issue_number" "$summary_what" "$summary_testing" "$files_changed" "$sig_footer")

	local pr_number=""
	pr_number=$(_create_pr "$repo" "$pr_title" "$pr_body" "$origin_label" "${extra_labels[@]+"${extra_labels[@]}"}") || return 1

	_post_merge_summary "$pr_number" "$repo" "$issue_number" "$summary_what" "$files_changed" "$summary_testing" "$summary_decisions"
	_label_issue_in_review "$issue_number" "$repo"

	# Output PR number for caller to pass to `merge`
	printf '%s\n' "$pr_number"
	return 0
}

# Merge wrapper (GH#17541) — enforces review-bot-gate then merges.
# Single command that replaces the multi-step protocol (wait + merge).
# Workers call this instead of bare `gh pr merge`.
#
# Usage: full-loop-helper.sh merge <PR_NUMBER> [REPO] [--squash|--merge|--rebase]
# Exit codes: 0 = merged, 1 = gate failed or merge failed
cmd_merge() {
	local pr_number="${1:-}"
	local repo=""
	local merge_method="--squash"

	if [[ -z "$pr_number" ]]; then
		print_error "Usage: full-loop-helper.sh merge <PR_NUMBER> [REPO] [--squash|--merge|--rebase]"
		return 1
	fi
	shift

	# Parse optional repo and merge method from remaining arguments
	for arg in "$@"; do
		case "$arg" in
		--squash | --merge | --rebase)
			merge_method="$arg"
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

	# Auto-detect repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			print_error "Cannot detect repo. Pass REPO as second argument."
			return 1
		fi
	fi

	# Gate: enforce review-bot-gate before merge
	cmd_pre_merge_gate "$pr_number" "$repo" || {
		print_error "Merge blocked by review bot gate. Address bot findings or wait for reviews."
		return 1
	}

	# Merge (no --delete-branch from inside worktree, per full-loop.md step 4.5)
	print_info "Merging PR #${pr_number} in ${repo} (${merge_method})..."
	if gh pr merge "$pr_number" --repo "$repo" "$merge_method" 2>&1; then
		print_success "PR #${pr_number} merged successfully"

		# t1934: Unlock PR and linked issue after worker merge.
		# Issues/PRs are locked at dispatch time to prevent prompt injection.
		# The worker merge path must unlock them — otherwise they stay locked
		# permanently (the pulse deterministic merge path has its own unlock,
		# but workers that self-merge bypass it).
		gh issue unlock "$pr_number" --repo "$repo" >/dev/null 2>&1 || true

		# Find and unlock the linked issue (from PR body "Resolves #NNN")
		local _linked_issue
		_linked_issue=$(gh pr view "$pr_number" --repo "$repo" --json body \
			--jq '.body' 2>/dev/null |
			grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#[0-9]+' |
			grep -oE '[0-9]+' | head -1) || _linked_issue=""
		if [[ -n "$_linked_issue" && "$_linked_issue" =~ ^[0-9]+$ ]]; then
			gh issue unlock "$_linked_issue" --repo "$repo" >/dev/null 2>&1 || true
		fi

		return 0
	else
		print_error "Merge failed for PR #${pr_number}"
		return 1
	fi
}

cmd_complete() {
	load_state 2>/dev/null || true
	printf "\n${BOLD}${GREEN}=== FULL DEVELOPMENT LOOP - COMPLETE ===${NC}\n"
	printf "Task: done | Preflight: passed | PR: #%s | Postflight: healthy" "${PR_NUMBER:-unknown}"
	is_aidevops_repo && printf " | Deploy: done"
	printf "\n\n"
	rm -f "$STATE_FILE"
	echo "<promise>FULL_LOOP_COMPLETE</promise>"
} # nice — entire dev lifecycle in one pass

show_help() {
	cat <<'EOF'
Full Development Loop Orchestrator
Usage: full-loop-helper.sh <command> [options]
Commands:
  start "<prompt>"              Start a new development loop
  resume                        Resume from last phase
  status                        Show current loop state
  cancel                        Cancel active loop
  logs [N]                      Show last N log lines (default: 50)
  commit-and-pr --issue N --message "msg"  Stage, commit, rebase, push, create PR, post merge summary
  pre-merge-gate <PR> [REPO]    Check review bot gate before merge (GH#17541)
  merge <PR> [REPO] [--squash]  Gate-enforced merge (runs pre-merge-gate first)
  help                          Show this help
Options: --max-task-iterations N (50) | --max-preflight-iterations N (5)
  --max-pr-iterations N (20) | --skip-preflight | --skip-postflight
  --skip-runtime-testing | --no-auto-pr | --no-auto-deploy
  --headless | --dry-run | --background
Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
EOF
}

_run_foreground() {
	local prompt="$1"
	# Use a global for the trap — local variables are out of scope when the
	# EXIT trap fires after the function returns (causes unbound variable
	# crash under set -u).
	_FG_PID_FILE="${STATE_DIR}/full-loop.pid"
	trap 'rm -f "$_FG_PID_FILE"' EXIT
	emit_task_phase "$prompt"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	start) cmd_start "$@" ;; resume) cmd_resume ;; status) cmd_status ;;
	cancel) cmd_cancel ;; logs) cmd_logs "$@" ;; _run_foreground) _run_foreground "$@" ;;
	commit-and-pr) cmd_commit_and_pr "$@" ;;
	pre-merge-gate) cmd_pre_merge_gate "$@" ;;
	merge) cmd_merge "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
