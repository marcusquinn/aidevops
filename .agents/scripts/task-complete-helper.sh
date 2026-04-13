#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# task-complete-helper.sh - Interactive task completion with proof-log enforcement
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   task-complete-helper.sh <task-id> [options]
#
# Options:
#   --pr <number>              PR number (e.g., 123)
#   --verified <date>          Verified date (YYYY-MM-DD, defaults to today)
#   --testing-level <level>    Testing level: runtime-verified | self-assessed | untested
#   --verify                   Run verify-brief.sh on task brief before completing
#   --repo-path <path>         Path to git repository (default: current directory)
#   --gh-repo <owner/repo>     GitHub repo slug for PR lookup (default: auto-detect from git remote)
#   --skip-merge-check         Skip PR merge verification (use only in tests or CI environments)
#   --no-push                  Mark complete but don't push (for testing)
#   --help                     Show this help message
#
# Examples:
#   task-complete-helper.sh t123 --pr 456
#   task-complete-helper.sh t124 --verified 2026-02-12
#   task-complete-helper.sh t125 --verified  # Uses today's date
#   task-complete-helper.sh t126 --pr 789 --verify  # Verify brief before completing
#   task-complete-helper.sh t127 --pr 101 --gh-repo owner/repo  # Cross-repo PR lookup
#   task-complete-helper.sh t128 --pr 102 --testing-level runtime-verified
#   task-complete-helper.sh t129 --verified --testing-level self-assessed
#   task-complete-helper.sh t130 --verified --testing-level untested
#
# Testing levels:
#   runtime-verified  Dev environment started, Playwright/smoke tests ran and passed
#   self-assessed     Code reviewed by AI, no runtime execution (default for most tasks)
#   untested          No testing performed (docs, config, or blocked by environment)
#
# Exit codes:
#   0 - Success (task marked complete, committed, and pushed)
#   1 - Error (missing arguments, task not found, git error, PR not merged, etc.)
#
# This script enforces the proof-log requirement for task completion:
#   - Requires either --pr or --verified argument
#   - When --pr is given, verifies the PR is actually MERGED before proceeding
#   - Marks task [x] in TODO.md
#   - Adds pr:#NNN or verified:YYYY-MM-DD to the task line
#   - Adds testing:LEVEL to the task line when --testing-level is specified
#   - Adds completed:YYYY-MM-DD timestamp
#   - Commits and pushes the change
#
# This closes the interactive AI enforcement gap (t317).
# PR merge verification closes the premature-completion bug (GH#466 on Ultimate-Multisite/ai-agent).
# Testing level recording closes the observability gap (t1660.5).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
TASK_ID=""
PR_NUMBER=""
VERIFIED_DATE=""
TESTING_LEVEL=""
REPO_PATH="$PWD"
GH_REPO=""
NO_PUSH=false
VERIFY_BRIEF=false
SKIP_MERGE_CHECK=false

# Valid testing levels (t1660.5)
VALID_TESTING_LEVELS="runtime-verified self-assessed untested"

# Logging: uses shared log_* from shared-constants.sh

# Show help
show_help() {
	grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
	return 0
}

# Validate parsed arguments (task ID format, proof-log presence, field formats).
# Called by parse_args() after the flag loop completes.
_validate_args() {
	# Validate task ID format
	if ! echo "$TASK_ID" | grep -qE '^t[0-9]+(\.[0-9]+)*$'; then
		log_error "Invalid task ID format: $TASK_ID (expected: tNNN or tNNN.N)"
		return 1
	fi

	# Require either --pr or --verified
	if [[ -z "$PR_NUMBER" && -z "$VERIFIED_DATE" ]]; then
		log_error "Missing required proof-log: specify either --pr <number> or --verified [date]"
		show_help
		return 1
	fi

	# Validate PR number if provided
	if [[ -n "$PR_NUMBER" ]] && ! echo "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
		log_error "Invalid PR number: $PR_NUMBER (expected: numeric)"
		return 1
	fi

	# Validate verified date if provided
	if [[ -n "$VERIFIED_DATE" ]] && ! echo "$VERIFIED_DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
		log_error "Invalid verified date: $VERIFIED_DATE (expected: YYYY-MM-DD)"
		return 1
	fi

	# Validate testing level if provided (t1660.5)
	if [[ -n "$TESTING_LEVEL" ]]; then
		local valid_level=""
		local level=""
		for level in $VALID_TESTING_LEVELS; do
			if [[ "$TESTING_LEVEL" == "$level" ]]; then
				valid_level="$level"
				break
			fi
		done
		if [[ -z "$valid_level" ]]; then
			log_error "Invalid testing level: $TESTING_LEVEL"
			log_error "Valid values: $VALID_TESTING_LEVELS"
			return 1
		fi
	fi

	return 0
}

# Parse arguments
parse_args() {
	if [[ $# -eq 0 ]]; then
		log_error "Missing required argument: task-id"
		show_help
		return 1
	fi

	# First positional argument is task ID
	local first_arg="$1"
	TASK_ID="$first_arg"
	shift

	local arg=""
	local val=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--pr)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --pr requires a PR number" >&2
				exit 1
			fi
			PR_NUMBER="$val"
			shift 2
			;;
		--verified)
			val="${2:-}"
			if [[ -n "$val" && "$val" != --* ]]; then
				VERIFIED_DATE="$val"
				shift 2
			else
				VERIFIED_DATE=$(date +%Y-%m-%d)
				shift
			fi
			;;
		--repo-path)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --repo-path requires a path" >&2
				exit 1
			fi
			REPO_PATH="$val"
			shift 2
			;;
		--gh-repo)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --gh-repo requires an owner/repo slug" >&2
				exit 1
			fi
			GH_REPO="$val"
			shift 2
			;;
		--testing-level)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --testing-level requires a value (runtime-verified|self-assessed|untested)" >&2
				exit 1
			fi
			TESTING_LEVEL="$val"
			shift 2
			;;
		--skip-merge-check)
			SKIP_MERGE_CHECK=true
			shift
			;;
		--no-push)
			NO_PUSH=true
			shift
			;;
		--verify)
			VERIFY_BRIEF=true
			shift
			;;
		--help)
			show_help
			exit 0
			;;
		*)
			log_error "Unknown option: $arg"
			return 1
			;;
		esac
	done

	_validate_args
	return $?
}

# Verify a PR is actually merged before allowing task completion.
# This prevents the premature-completion bug where a worker calls this script
# with --pr NNN immediately after creating the PR (before it is merged).
#
# Arguments:
#   $1 - PR number
#   $2 - GitHub repo slug (owner/repo), or empty to auto-detect from git remote
#   $3 - Repository path (used for git context when gh_repo is empty)
#
# Returns:
#   0 - PR is merged
#   1 - PR is not merged, or lookup failed
verify_pr_merged() {
	local pr_number="$1"
	local gh_repo="${2:-}"
	local repo_path="${3:-}"

	log_info "Verifying PR #${pr_number} is merged${gh_repo:+ (repo: $gh_repo)}..."

	# Use gh's built-in --jq to extract both fields in a single API call,
	# avoiding external jq dependency. When --gh-repo is not provided, run gh
	# from the repo directory so it picks up the correct git remote context.
	local pr_output pr_state pr_merged_at
	local gh_view_args=("pr" "view" "$pr_number" "--json" "state,mergedAt" "--jq" '[.state, (.mergedAt // "")] | join("\t")')
	if [[ -n "$gh_repo" ]]; then
		gh_view_args+=("--repo" "$gh_repo")
	fi

	if [[ -z "$gh_repo" ]] && [[ -n "$repo_path" ]]; then
		if ! pr_output=$(cd "$repo_path" && gh "${gh_view_args[@]}" 2>&1); then
			log_error "Failed to fetch PR #${pr_number}: ${pr_output}"
			log_error "Check that the PR exists and gh CLI is authenticated."
			return 1
		fi
	else
		if ! pr_output=$(gh "${gh_view_args[@]}" 2>&1); then
			log_error "Failed to fetch PR #${pr_number}: ${pr_output}"
			log_error "Check that the PR exists and gh CLI is authenticated."
			return 1
		fi
	fi

	# Parse tab-separated output: state\tmergedAt
	pr_state="${pr_output%%$'\t'*}"
	pr_merged_at="${pr_output#*$'\t'}"

	if [[ "$pr_state" != "MERGED" ]] || [[ -z "$pr_merged_at" ]]; then
		log_error "PR #${pr_number} is not merged (state: ${pr_state:-unknown})"
		log_error "Task completion is only allowed after the PR is merged."
		local rerun_cmd="task-complete-helper.sh $TASK_ID --pr $pr_number"
		[[ -n "$gh_repo" ]] && rerun_cmd+=" --gh-repo $gh_repo"
		log_error "Wait for the PR to merge, then re-run: $rerun_cmd"
		return 1
	fi

	# good stuff — PR is confirmed merged, safe to mark the task done
	log_success "PR #${pr_number} is merged (mergedAt: ${pr_merged_at})"
	return 0
}

# Mark task complete in TODO.md
complete_task() {
	local task_id="$1"
	local proof_log="$2"
	local repo_path="$3"

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		log_error "TODO.md not found at $todo_file"
		return 1
	fi

	# Check if task exists and is open
	if ! grep -qE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file"; then
		if grep -qE "^[[:space:]]*- \[x\] ${task_id}( |$)" "$todo_file"; then
			log_warn "Task $task_id is already marked complete"
			return 0
		else
			log_error "Task $task_id not found in $todo_file"
			return 1
		fi
	fi

	# t1003: Guard against marking parent tasks complete when subtasks are still open
	# Check for explicit subtask IDs (e.g., t123.1, t123.2 are children of t123)
	local explicit_subtasks
	explicit_subtasks=$(grep -E "^[[:space:]]*- \[ \] ${task_id}\.[0-9]+( |$)" "$todo_file" || true)

	if [[ -n "$explicit_subtasks" ]]; then
		local open_count
		open_count=$(echo "$explicit_subtasks" | wc -l | tr -d ' ')
		log_error "Task $task_id has $open_count open subtask(s) by ID — cannot mark complete"
		log_error "  Complete all subtasks first: $(echo "$explicit_subtasks" | grep -oE "t[0-9]+\.[0-9]+" | tr '\n' ' ')"
		return 1
	fi

	# Check for indentation-based subtasks
	local task_line
	task_line=$(grep -E "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1)
	local task_indent
	task_indent=$(echo "$task_line" | sed -E 's/^([[:space:]]*).*/\1/' | wc -c)
	task_indent=$((task_indent - 1)) # wc -c counts newline

	local open_subtasks
	open_subtasks=$(awk -v tid="$task_id" -v tindent="$task_indent" '
		BEGIN { found=0 }
		/- \[ \] '"$task_id"'( |$)/ { found=1; next }
		found && /^[[:space:]]*- \[/ {
			match($0, /^[[:space:]]*/);
			line_indent = RLENGTH;
			if (line_indent > tindent) {
				if ($0 ~ /- \[ \]/) { print $0 }
			} else { found=0 }
		}
		found && /^[[:space:]]*$/ { next }
		found && !/^[[:space:]]*- / && !/^[[:space:]]*$/ { found=0 }
	' "$todo_file")

	if [[ -n "$open_subtasks" ]]; then
		local open_count
		open_count=$(echo "$open_subtasks" | wc -l | tr -d ' ')
		log_error "Task $task_id has $open_count open subtask(s) by indentation — cannot mark complete"
		log_error "  Complete all indented subtasks first"
		return 1
	fi

	local today
	today=$(date +%Y-%m-%d)

	# Verify ## Done section exists before modifying the file
	if ! grep -q "^## Done$" "$todo_file"; then
		log_error "## Done section not found in $todo_file — cannot move task"
		return 1
	fi

	# Create backup
	cp "$todo_file" "${todo_file}.bak"

	local tmp_block
	tmp_block=$(mktemp)
	local tmp_result
	tmp_result=$(mktemp)

	# Pass 1: Extract the task block (parent + indented children) into a temp
	# file, transform the parent line ([ ] -> [x], append proof_log +
	# completed:today), and output the file with the block removed.
	#
	# Block boundary: the matching "- [ ] TASKID" line plus any immediately-
	# following lines indented with 2+ spaces.  Ends at the first blank line,
	# next top-level "- [" entry, or EOF.
	awk -v tid="$task_id" -v proof="$proof_log" -v tday="$today" -v bfile="$tmp_block" '
	BEGIN { capturing=0; pat="^[[:space:]]*- \\[ \\] " tid "( |$)" }
	!capturing {
		if ($0 ~ pat) {
			capturing=1
			sub(/\[ \]/, "[x]")
			print $0 " " proof " completed:" tday > bfile
			next
		}
		print
		next
	}
	/^[[:space:]]*$/ { capturing=0; print; next }
	/^- \[/ { capturing=0; print; next }
	/^  / { print > bfile; next }
	{ capturing=0; print }
	' "$todo_file" >"$tmp_result"

	# Pass 2: Insert the extracted block at the top of the ## Done section
	# (immediately after the blank line that follows the ## Done header).
	local pass2_rc=0
	awk -v bfile="$tmp_block" '
	BEGIN { done_found=0 }
	/^## Done$/ {
		done_found=1
		print
		if ((getline nl) > 0) {
			if (nl == "") {
				print nl
				while ((getline bl < bfile) > 0) { print bl }
				print ""
				close(bfile)
			} else {
				while ((getline bl < bfile) > 0) { print bl }
				print ""
				print nl
				close(bfile)
			}
		} else {
			while ((getline bl < bfile) > 0) { print bl }
			close(bfile)
		}
		next
	}
	{ print }
	END {
		if (!done_found) {
			print "ERROR: ## Done section not found" > "/dev/stderr"
			exit 1
		}
	}
	' "$tmp_result" >"$todo_file" || pass2_rc=$?

	rm -f "$tmp_result" "$tmp_block"

	if [[ "$pass2_rc" -ne 0 ]]; then
		log_error "Failed to insert block into ## Done section"
		mv "${todo_file}.bak" "$todo_file"
		return 1
	fi

	# Verify the change was made
	if ! grep -qE "^[[:space:]]*- \[x\] ${task_id} " "$todo_file"; then
		log_error "Failed to update TODO.md for $task_id"
		mv "${todo_file}.bak" "$todo_file"
		return 1
	fi

	# Verify proof-log was added
	if ! grep -E "^[[:space:]]*- \[x\] ${task_id} " "$todo_file" | grep -qE "(pr:#[0-9]+|verified:[0-9]{4}-[0-9]{2}-[0-9]{2})"; then
		log_error "Failed to add proof-log to $task_id"
		mv "${todo_file}.bak" "$todo_file"
		return 1
	fi

	# Verify the task is now in the ## Done section
	if ! awk '/^## Done$/{f=1; next} /^## /{f=0} f' "$todo_file" | grep -qE "^[[:space:]]*- \[x\] ${task_id}( |$)"; then
		log_error "Task $task_id not found in ## Done section after move"
		mv "${todo_file}.bak" "$todo_file"
		return 1
	fi

	rm -f "${todo_file}.bak"
	log_success "Marked $task_id complete and moved to ## Done: $proof_log"
	return 0
}

# Check whether all task IDs listed in a plan's TODO line are complete in TODO.md.
# Arguments:
#   $1 - space-separated list of task IDs extracted from the plan's TODO line
#   $2 - path to TODO.md
# Returns:
#   0 - all tasks are complete (or list is empty)
#   1 - at least one task is still open
_check_plan_tasks_complete() {
	local plan_tasks="$1"
	local todo_file="$2"

	local ptask=""
	for ptask in $plan_tasks; do
		if grep -qE "^[[:space:]]*- \[ \] ${ptask}( |$)" "$todo_file"; then
			log_info "Task $ptask is still open — plan not complete"
			return 1
		fi
	done
	return 0
}

# Find the line number of the **Status:** field for the plan that owns the given
# TODO line in PLANS.md. Walks backward from todo_line to find the ### header,
# then forward to find **Status:** within that header-to-TODO range.
# (GH#5392 — robust against extra metadata fields between Status and TODO lines)
# Arguments:
#   $1 - line number of the plan's **TODO:** line in PLANS.md
#   $2 - path to PLANS.md
# Outputs (stdout):
#   The line number of the **Status:** line, or empty string if not found
_find_plan_status_line() {
	local todo_line="$1"
	local plans_file="$2"

	# Walk backward to find the enclosing ### [ header
	local header_line=""
	local search_line=$((todo_line - 1))
	while [[ "$search_line" -ge 1 ]]; do
		local line_content
		line_content=$(sed -n "${search_line}p" "$plans_file")
		if echo "$line_content" | grep -q '^### \['; then
			header_line="$search_line"
			break
		fi
		search_line=$((search_line - 1))
	done

	if [[ -z "$header_line" ]]; then
		echo ""
		return 0
	fi

	# Scan forward from header to todo_line for **Status:**
	local scan_line=$((header_line + 1))
	while [[ "$scan_line" -lt "$todo_line" ]]; do
		local line_content
		line_content=$(sed -n "${scan_line}p" "$plans_file")
		if echo "$line_content" | grep -q '^\*\*Status:\*\*'; then
			echo "$scan_line"
			return 0
		fi
		scan_line=$((scan_line + 1))
	done

	echo ""
	return 0
}

# Sync PLANS.md status when a task is completed.
# If all tasks referenced by a plan are now [x] in TODO.md,
# update the plan's Status to Completed. Plans stay in PLANS.md
# as institutional memory — never removed.
sync_plans_status() {
	local task_id="$1"
	local proof_log="$2"
	local repo_path="$3"

	local plans_file="$repo_path/todo/PLANS.md"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$plans_file" ]]; then
		return 0
	fi

	# Find plans that reference this task ID
	local plan_lines
	plan_lines=$(grep -n "^\*\*TODO:\*\*.*${task_id}" "$plans_file" 2>/dev/null | cut -d: -f1 || true)

	if [[ -z "$plan_lines" ]]; then
		return 0
	fi

	log_info "Task $task_id found in PLANS.md — checking plan completion"

	local plans_changed=false
	local todo_line=""

	for todo_line in $plan_lines; do
		# Extract all task IDs from this plan's TODO line
		local todo_content
		todo_content=$(sed -n "${todo_line}p" "$plans_file")
		local plan_tasks
		plan_tasks=$(echo "$todo_content" | grep -oE 't[0-9]+(\.[0-9]+)*' | sort -u)

		if [[ -z "$plan_tasks" ]]; then
			continue
		fi

		# Check if ALL tasks in this plan are complete in TODO.md
		if ! _check_plan_tasks_complete "$plan_tasks" "$todo_file"; then
			continue
		fi

		# Find the plan's Status line
		local status_line
		status_line=$(_find_plan_status_line "$todo_line" "$plans_file")

		if [[ -z "$status_line" ]]; then
			continue
		fi

		local current_status
		current_status=$(sed -n "${status_line}p" "$plans_file")

		# Skip if already completed
		if echo "$current_status" | grep -qi 'Completed'; then
			continue
		fi

		# Update status to Completed
		if [[ "$OSTYPE" == "darwin"* ]]; then
			sed -i '' "${status_line}s/\*\*Status:\*\*.*/\*\*Status:\*\* Completed/" "$plans_file"
		else
			sed -i "${status_line}s/\*\*Status:\*\*.*/\*\*Status:\*\* Completed/" "$plans_file"
		fi

		plans_changed=true
		log_success "Updated plan status to Completed (PLANS.md line $status_line)"
	done

	if [[ "$plans_changed" == "true" ]]; then
		log_info "PLANS.md updated — will be included in commit"
	fi

	return 0
}

# Commit and push TODO.md (and PLANS.md if changed)
commit_and_push() {
	local task_id="$1"
	local proof_log="$2"
	local repo_path="$3"
	local no_push="$4"

	cd "$repo_path" || {
		log_error "Failed to cd to $repo_path"
		return 1
	}

	# Stage TODO.md
	if ! git add TODO.md; then
		log_error "Failed to stage TODO.md"
		return 1
	fi

	# Stage PLANS.md if it was modified by sync_plans_status
	if [[ -f "todo/PLANS.md" ]] && ! git diff --quiet todo/PLANS.md 2>/dev/null; then
		git add todo/PLANS.md
		log_info "Staged PLANS.md (plan status updated)"
	fi

	# Commit
	local commit_msg="chore: mark $task_id complete ($proof_log)"
	if ! git commit -m "$commit_msg"; then
		log_error "Failed to commit TODO.md"
		return 1
	fi

	log_success "Committed: $commit_msg"

	# Push (unless --no-push)
	if [[ "$no_push" == "false" ]]; then
		if ! git push; then
			log_error "Failed to push to remote"
			log_info "Run 'git push' manually to sync the change"
			return 1
		fi
		log_success "Pushed to remote"
	else
		log_info "Skipped push (--no-push flag)"
	fi

	return 0
}

# Main
main() {
	if ! parse_args "$@"; then
		return 1
	fi

	log_info "Completing task: $TASK_ID"

	# Run brief verification if --verify flag is set
	if [[ "$VERIFY_BRIEF" == "true" ]]; then
		local brief_file="${REPO_PATH}/todo/tasks/${TASK_ID}-brief.md"
		if [[ ! -f "$brief_file" ]]; then
			log_error "Brief file not found: $brief_file — cannot verify"
			log_info "Remove --verify flag if this task has no brief"
			return 1
		else
			local verify_script="${SCRIPT_DIR}/verify-brief.sh"
			if [[ ! -x "$verify_script" ]]; then
				log_error "verify-brief.sh not found or not executable: $verify_script"
				return 1
			fi
			log_info "Running brief verification: $brief_file"
			if ! "$verify_script" "$brief_file" --repo-path "$REPO_PATH"; then
				log_error "Brief verification failed — task cannot be marked complete"
				log_info "Fix failing criteria or remove --verify flag to skip verification"
				return 1
			fi
			log_success "Brief verification passed"
		fi
	fi

	# Build proof-log string
	local proof_log=""
	if [[ -n "$PR_NUMBER" ]]; then
		proof_log="pr:#${PR_NUMBER}"
		log_info "Proof-log: PR #${PR_NUMBER}"

		# Verify the PR is actually merged before marking the task complete.
		# This prevents the premature-completion bug (GH#466) where a worker
		# calls this script right after opening a PR, before it is merged.
		if [[ "$SKIP_MERGE_CHECK" == "true" ]]; then
			log_warn "Skipping PR merge check (--skip-merge-check). Use only in tests."
		else
			if ! verify_pr_merged "$PR_NUMBER" "$GH_REPO" "$REPO_PATH"; then
				return 1
			fi
		fi
	else
		proof_log="verified:${VERIFIED_DATE}"
		log_info "Proof-log: verified ${VERIFIED_DATE}"
	fi

	# Append testing level to proof-log when provided (t1660.5)
	if [[ -n "$TESTING_LEVEL" ]]; then
		proof_log="${proof_log} testing:${TESTING_LEVEL}"
		log_info "Testing level: ${TESTING_LEVEL}"
	fi

	# Mark task complete
	if ! complete_task "$TASK_ID" "$proof_log" "$REPO_PATH"; then
		return 1
	fi

	# Sync PLANS.md status (non-fatal — plans sync is best-effort)
	sync_plans_status "$TASK_ID" "$proof_log" "$REPO_PATH" || true

	# Commit and push (includes PLANS.md if modified)
	if ! commit_and_push "$TASK_ID" "$proof_log" "$REPO_PATH" "$NO_PUSH"; then
		return 1
	fi

	log_success "Task $TASK_ID completed successfully" # nice
	return 0
}

main "$@"
