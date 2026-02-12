#!/usr/bin/env bash
# shellcheck disable=SC2310
# =============================================================================
# Planning File Auto-Commit Helper
# =============================================================================
# Commits and pushes changes to TODO.md and todo/ without branch ceremony.
# Called automatically by Plan+ agent after planning file modifications.
#
# Usage:
#   planning-commit-helper.sh "plan: add new task"
#   planning-commit-helper.sh --check  # Just check if changes exist
#   planning-commit-helper.sh --status # Show planning file status
#
# Exit codes:
#   0 - Success (or no changes to commit)
#   1 - Error (not in git repo, etc.)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Planning file patterns
readonly PLANNING_PATTERNS="^TODO\.md$|^todo/"

log_info() {
	echo -e "${BLUE}[plan]${NC} $1"
}

log_success() {
	echo -e "${GREEN}[plan]${NC} $1"
}

log_warning() {
	echo -e "${YELLOW}[plan]${NC} $1"
}

log_error() {
	echo -e "${RED}[plan]${NC} $1" >&2
}

# Check if we're in a git repository
check_git_repo() {
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		log_error "Not in a git repository"
		return 1
	fi
	return 0
}

# Check if there are planning file changes
has_planning_changes() {
	# Check both staged and unstaged changes
	if git diff --name-only HEAD 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
		return 0
	fi
	if git diff --name-only --cached 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
		return 0
	fi
	# Also check untracked files in todo/
	if git ls-files --others --exclude-standard 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
		return 0
	fi
	return 1
}

# List planning file changes
list_planning_changes() {
	local changes=""

	# Staged changes
	local staged
	staged=$(git diff --name-only --cached 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)

	# Unstaged changes
	local unstaged
	unstaged=$(git diff --name-only 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)

	# Untracked
	local untracked
	untracked=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)

	# Combine unique
	changes=$(echo -e "${staged}\n${unstaged}\n${untracked}" | sort -u | grep -v '^$' || true)
	echo "$changes"
}

# Show status of planning files
show_status() {
	check_git_repo || return 1

	echo "Planning file status:"
	echo "====================="

	if has_planning_changes; then
		echo -e "${YELLOW}Modified planning files:${NC}"
		list_planning_changes | while read -r file; do
			[[ -n "$file" ]] && echo "  - $file"
		done
	else
		echo -e "${GREEN}No planning file changes${NC}"
	fi

	return 0
}

# Complete a task by marking it done with proof-log
# Usage: complete_task <task_id> --pr <pr_number> | --verified
complete_task() {
	local task_id=""
	local pr_number=""
	local verified_mode=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			pr_number="$2"
			shift 2
			;;
		--verified)
			verified_mode=true
			shift
			;;
		*)
			if [[ -z "$task_id" ]]; then
				task_id="$1"
			else
				log_error "Unknown argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	# Validate arguments
	if [[ -z "$task_id" ]]; then
		log_error "Task ID is required"
		echo "Usage: complete_task <task_id> --pr <pr_number> | --verified"
		return 1
	fi

	if [[ -z "$pr_number" ]] && [[ "$verified_mode" != true ]]; then
		log_error "Either --pr <number> or --verified is required"
		return 1
	fi

	if [[ -n "$pr_number" ]] && [[ "$verified_mode" == true ]]; then
		log_error "Cannot use both --pr and --verified"
		return 1
	fi

	check_git_repo || return 1

	local repo_root
	repo_root=$(git rev-parse --show-toplevel)
	local todo_file="${repo_root}/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_error "TODO.md not found at $todo_file"
		return 1
	fi

	# Validate PR is merged if --pr is used
	if [[ -n "$pr_number" ]]; then
		log_info "Validating PR #${pr_number} is merged..."
		if ! gh pr view "$pr_number" --json state,mergedAt --jq '.state,.mergedAt' &>/dev/null; then
			log_error "Failed to fetch PR #${pr_number}. Check that it exists and gh CLI is authenticated."
			return 1
		fi

		local pr_state
		local pr_merged_at
		pr_state=$(gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null)
		pr_merged_at=$(gh pr view "$pr_number" --json mergedAt --jq '.mergedAt' 2>/dev/null)

		if [[ "$pr_state" != "MERGED" ]] || [[ -z "$pr_merged_at" ]] || [[ "$pr_merged_at" == "null" ]]; then
			log_error "PR #${pr_number} is not merged (state: ${pr_state})"
			return 1
		fi

		log_success "PR #${pr_number} is merged"
	fi

	# Require explicit confirmation for --verified
	if [[ "$verified_mode" == true ]]; then
		log_warning "Using --verified mode (no PR proof)"
		echo -n "Are you sure this task is complete and verified? [y/N] "
		read -r confirmation
		if [[ "$confirmation" != "y" ]] && [[ "$confirmation" != "Y" ]]; then
			log_info "Cancelled"
			return 0
		fi
	fi

	# Find the task line
	local task_line_num
	task_line_num=$(grep -n "^\s*- \[ \] ${task_id} " "$todo_file" | head -1 | cut -d: -f1)

	if [[ -z "$task_line_num" ]]; then
		log_error "Task ${task_id} not found or already completed in TODO.md"
		return 1
	fi

	# Get the current task line
	local task_line
	task_line=$(sed -n "${task_line_num}p" "$todo_file")

	# Mark as complete
	local updated_line
	updated_line=$(echo "$task_line" | sed 's/- \[ \]/- [x]/')

	# Add proof-log field
	local today
	today=$(date +%Y-%m-%d)

	if [[ -n "$pr_number" ]]; then
		# Check if pr: field already exists
		if echo "$updated_line" | grep -q "pr:#"; then
			log_warning "Task already has pr: field, skipping"
		else
			updated_line="${updated_line} pr:#${pr_number}"
		fi
	else
		# Add verified: field
		if echo "$updated_line" | grep -q "verified:"; then
			log_warning "Task already has verified: field, skipping"
		else
			updated_line="${updated_line} verified:${today}"
		fi
	fi

	# Add completed: field if missing
	if ! echo "$updated_line" | grep -q "completed:"; then
		updated_line="${updated_line} completed:${today}"
	fi

	# Update the file
	local temp_file
	temp_file=$(mktemp)
	awk -v line_num="$task_line_num" -v new_line="$updated_line" \
		'NR == line_num {print new_line; next} {print}' \
		"$todo_file" >"$temp_file"

	if ! mv "$temp_file" "$todo_file"; then
		log_error "Failed to update TODO.md"
		rm -f "$temp_file"
		return 1
	fi

	log_success "Marked ${task_id} as complete"

	# Commit and push
	local commit_msg
	if [[ -n "$pr_number" ]]; then
		commit_msg="plan: complete ${task_id} (pr:#${pr_number})"
	else
		commit_msg="plan: complete ${task_id} (verified:${today})"
	fi

	log_info "Committing: $commit_msg"
	if todo_commit_push "$repo_root" "$commit_msg" "TODO.md todo/"; then
		log_success "Task completion committed and pushed"
	else
		log_warning "Committed locally (push failed after retries - will retry later)"
	fi

	return 0
}

# Allocate the next task ID via claim-task-id.sh
# Wrapper that calls claim-task-id.sh, parses its output, and returns
# machine-readable variables for use in TODO.md entries.
#
# Usage:
#   next_task_id --title "Task description"
#   next_task_id --title "Task description" --labels "bug,priority"
#   next_task_id --title "Task description" --offline
#   next_task_id --title "Task description" --dry-run
#
# Output (stdout, machine-readable):
#   TASK_ID=tNNN
#   TASK_REF=GH#NNN        (or GL#NNN, or offline)
#   TASK_ISSUE_URL=https://...  (empty if offline)
#   TASK_OFFLINE=false      (true if offline fallback was used)
#
# Exit codes:
#   0 - Success (online allocation)
#   2 - Success with offline fallback
#   1 - Error
next_task_id() {
	local title=""
	local labels=""
	local description=""
	local offline_flag=""
	local dry_run_flag=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			title="$2"
			shift 2
			;;
		--labels)
			labels="$2"
			shift 2
			;;
		--description)
			description="$2"
			shift 2
			;;
		--offline)
			offline_flag="--offline"
			shift
			;;
		--dry-run)
			dry_run_flag="--dry-run"
			shift
			;;
		*)
			log_error "next_task_id: unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$title" ]]; then
		log_error "next_task_id: --title is required"
		echo "Usage: next_task_id --title \"Task description\" [--labels \"l1,l2\"] [--offline] [--dry-run]"
		return 1
	fi

	# Locate claim-task-id.sh relative to this script
	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
	if [[ ! -x "$claim_script" ]]; then
		log_error "claim-task-id.sh not found at: $claim_script"
		return 1
	fi

	# Determine repo path (use git root of current directory)
	local repo_path
	repo_path=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")

	# Build claim-task-id.sh arguments
	local -a claim_args=(--title "$title" --repo-path "$repo_path")
	[[ -n "$labels" ]] && claim_args+=(--labels "$labels")
	[[ -n "$description" ]] && claim_args+=(--description "$description")
	[[ -n "$offline_flag" ]] && claim_args+=("$offline_flag")
	[[ -n "$dry_run_flag" ]] && claim_args+=("$dry_run_flag")

	# Run claim-task-id.sh and capture output + exit code
	local claim_output
	local claim_rc=0
	claim_output=$("$claim_script" "${claim_args[@]}" 2>/dev/null) || claim_rc=$?

	# Exit code 1 = hard error
	if [[ $claim_rc -eq 1 ]]; then
		log_error "claim-task-id.sh failed"
		# Re-run with stderr visible for diagnostics
		"$claim_script" "${claim_args[@]}" >/dev/null || true
		return 1
	fi

	# Parse output lines: task_id=tNNN, ref=GH#NNN, issue_url=..., reconcile=true
	local task_id="" task_ref="" issue_url="" is_offline="false"

	while IFS= read -r line; do
		case "$line" in
		task_id=*)
			task_id="${line#task_id=}"
			;;
		ref=*)
			task_ref="${line#ref=}"
			;;
		issue_url=*)
			issue_url="${line#issue_url=}"
			;;
		reconcile=*)
			# Offline mode indicator
			;;
		esac
	done <<<"$claim_output"

	# Determine if offline fallback was used
	if [[ $claim_rc -eq 2 ]] || [[ "$task_ref" == "offline" ]]; then
		is_offline="true"
	fi

	# Validate we got a task ID
	if [[ -z "$task_id" ]]; then
		log_error "claim-task-id.sh returned no task_id"
		return 1
	fi

	# Output machine-readable variables
	echo "TASK_ID=${task_id}"
	echo "TASK_REF=${task_ref}"
	echo "TASK_ISSUE_URL=${issue_url}"
	echo "TASK_OFFLINE=${is_offline}"

	# Log summary to stderr for human visibility
	if [[ "$is_offline" == "true" ]]; then
		log_warning "Allocated ${task_id} (offline — reconcile when back online)"
	else
		log_success "Allocated ${task_id} (${task_ref})"
	fi

	return "$claim_rc"
}

# Main commit function
# Uses todo_commit_push() from shared-constants.sh for serialized locking
# to prevent race conditions when multiple actors push to TODO.md on main.
commit_planning_files() {
	local commit_msg="${1:-plan: update planning files}"

	check_git_repo || return 1

	# Check for changes
	if ! has_planning_changes; then
		log_info "No planning file changes to commit"
		return 0
	fi

	# Show what we're committing
	log_info "Planning files to commit:"
	list_planning_changes | while read -r file; do
		[[ -n "$file" ]] && echo "  - $file"
	done

	local repo_root
	repo_root=$(git rev-parse --show-toplevel)

	# Use serialized commit+push (flock + pull-rebase-retry)
	log_info "Committing: $commit_msg"
	if todo_commit_push "$repo_root" "$commit_msg" "TODO.md todo/"; then
		log_success "Planning files committed and pushed"
	else
		log_warning "Committed locally (push failed after retries - will retry later)"
	fi

	return 0
}

# Main
main() {
	case "${1:-}" in
	next-id)
		shift
		next_task_id "$@"
		exit $?
		;;
	complete)
		shift
		complete_task "$@"
		exit $?
		;;
	--check)
		check_git_repo || exit 1
		if has_planning_changes; then
			echo "PLANNING_CHANGES=true"
			exit 0
		else
			echo "PLANNING_CHANGES=false"
			exit 0
		fi
		;;
	--status)
		show_status
		exit $?
		;;
	--help | -h)
		echo "Usage: planning-commit-helper.sh [OPTIONS] [COMMIT_MESSAGE]"
		echo ""
		echo "Commands:"
		echo "  next-id --title \"...\"              Allocate next task ID (via claim-task-id.sh)"
		echo "  complete <task_id> --pr <number>   Mark task complete with PR proof"
		echo "  complete <task_id> --verified      Mark task complete with manual verification"
		echo ""
		echo "Options:"
		echo "  --check                            Check if planning files have changes"
		echo "  --status                           Show planning file status"
		echo "  --help                             Show this help"
		echo ""
		echo "next-id options:"
		echo "  --title \"Task title\"               Task title (required)"
		echo "  --labels \"label1,label2\"           Comma-separated labels"
		echo "  --description \"Details\"            Task description"
		echo "  --offline                          Force offline mode"
		echo "  --dry-run                          Preview without creating issue"
		echo ""
		echo "Examples:"
		echo "  planning-commit-helper.sh next-id --title \"Add CSV export\""
		echo "  planning-commit-helper.sh next-id --title \"Fix bug\" --labels \"bug\""
		echo "  planning-commit-helper.sh 'plan: add new task'"
		echo "  planning-commit-helper.sh complete t123 --pr 456"
		echo "  planning-commit-helper.sh complete t123 --verified"
		echo "  planning-commit-helper.sh --check"
		exit 0
		;;
	*)
		commit_planning_files "$@"
		exit $?
		;;
	esac
}

main "$@"
