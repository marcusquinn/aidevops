#!/usr/bin/env bash
# task-complete-helper.sh - Interactive task completion with proof-log enforcement
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   task-complete-helper.sh <task-id> [options]
#
# Options:
#   --pr <number>              PR number (e.g., 123)
#   --verified <date>          Verified date (YYYY-MM-DD, defaults to today)
#   --repo-path <path>         Path to git repository (default: current directory)
#   --no-push                  Mark complete but don't push (for testing)
#   --help                     Show this help message
#
# Examples:
#   task-complete-helper.sh t123 --pr 456
#   task-complete-helper.sh t124 --verified 2026-02-12
#   task-complete-helper.sh t125 --verified  # Uses today's date
#
# Exit codes:
#   0 - Success (task marked complete, committed, and pushed)
#   1 - Error (missing arguments, task not found, git error, etc.)
#
# This script enforces the proof-log requirement for task completion:
#   - Requires either --pr or --verified argument
#   - Marks task [x] in TODO.md
#   - Adds pr:#NNN or verified:YYYY-MM-DD to the task line
#   - Adds completed:YYYY-MM-DD timestamp
#   - Commits and pushes the change
#
# This closes the interactive AI enforcement gap (t317).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
TASK_ID=""
PR_NUMBER=""
VERIFIED_DATE=""
REPO_PATH="$PWD"
NO_PUSH=false

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Show help
show_help() {
	grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
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
	TASK_ID="$1"
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			PR_NUMBER="$2"
			shift 2
			;;
		--verified)
			if [[ -n "${2:-}" && "$2" != --* ]]; then
				VERIFIED_DATE="$2"
				shift 2
			else
				VERIFIED_DATE=$(date +%Y-%m-%d)
				shift
			fi
			;;
		--repo-path)
			REPO_PATH="$2"
			shift 2
			;;
		--no-push)
			NO_PUSH=true
			shift
			;;
		--help)
			show_help
			exit 0
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

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

	local today
	today=$(date +%Y-%m-%d)

	# Create backup
	cp "$todo_file" "${todo_file}.bak"

	# Mark as complete: [ ] -> [x], append proof-log and completed:date
	# Use sed to match the line and transform it
	local sed_pattern="s/^([[:space:]]*- )\[ \] (${task_id} .*)$/\1[x] \2 ${proof_log} completed:${today}/"

	if [[ "$OSTYPE" == "darwin"* ]]; then
		sed -i '' -E "$sed_pattern" "$todo_file"
	else
		sed -i -E "$sed_pattern" "$todo_file"
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

	rm -f "${todo_file}.bak"
	log_success "Marked $task_id complete with proof-log: $proof_log"
	return 0
}

# Commit and push TODO.md
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

	# Build proof-log string
	local proof_log=""
	if [[ -n "$PR_NUMBER" ]]; then
		proof_log="pr:#${PR_NUMBER}"
		log_info "Proof-log: PR #${PR_NUMBER}"
	else
		proof_log="verified:${VERIFIED_DATE}"
		log_info "Proof-log: verified ${VERIFIED_DATE}"
	fi

	# Mark task complete
	if ! complete_task "$TASK_ID" "$proof_log" "$REPO_PATH"; then
		return 1
	fi

	# Commit and push
	if ! commit_and_push "$TASK_ID" "$proof_log" "$REPO_PATH" "$NO_PUSH"; then
		return 1
	fi

	log_success "Task $TASK_ID completed successfully"
	return 0
}

main "$@"
