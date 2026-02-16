#!/usr/bin/env bash
# Backfill blocked comments on GitHub issues (t1070)
#
# Posts explanatory comments on all GitHub issues with status:blocked label
# that don't already have a blocked comment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source required modules
source "$SCRIPT_DIR/issue-sync.sh"
source "$SCRIPT_DIR/../database.sh" 2>/dev/null || source "$SCRIPT_DIR/../../supervisor-helper.sh"

main() {
	local repo_path="${1:-$REPO_ROOT}"
	local dry_run="${2:-false}"
	
	echo "Backfilling blocked comments for repo: $repo_path"
	
	# Check if gh CLI is available
	if ! command -v gh &>/dev/null; then
		echo "Error: gh CLI not available"
		exit 1
	fi
	
	# Check gh auth
	if ! gh auth status &>/dev/null; then
		echo "Error: gh CLI not authenticated"
		exit 1
	fi
	
	# Detect repo slug
	local repo_slug
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		echo "Error: Could not detect repo slug"
		exit 1
	fi
	
	echo "Repo slug: $repo_slug"
	
	# Find all open issues with status:blocked label
	local issues
	issues=$(gh issue list --repo "$repo_slug" --label "status:blocked" --state open --json number,title --jq '.[] | "\(.number)|\(.title)"' 2>/dev/null || echo "")
	
	if [[ -z "$issues" ]]; then
		echo "No blocked issues found"
		return 0
	fi
	
	local count=0
	while IFS='|' read -r issue_number issue_title; do
		# Extract task ID from title (format: "tXXX: description")
		local task_id
		task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+' || echo "")
		
		if [[ -z "$task_id" ]]; then
			echo "Skipping issue #$issue_number (no task ID in title)"
			continue
		fi
		
		# Check if issue already has a blocked comment
		local has_blocked_comment
		has_blocked_comment=$(gh issue view "$issue_number" --repo "$repo_slug" --json comments --jq '.comments[] | select(.body | contains("Worker Blocked")) | .body' 2>/dev/null || echo "")
		
		if [[ -n "$has_blocked_comment" ]]; then
			echo "Issue #$issue_number ($task_id) already has blocked comment, skipping"
			continue
		fi
		
		# Read error from supervisor DB
		local blocked_error=""
		if [[ -f "$SUPERVISOR_DB" ]]; then
			blocked_error=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id='$(sql_escape "$task_id")';" 2>/dev/null || echo "")
		fi
		
		if [[ -z "$blocked_error" || "$blocked_error" == "null" ]]; then
			blocked_error="Task blocked — reason not specified in supervisor DB"
		fi
		
		echo "Processing issue #$issue_number ($task_id): $blocked_error"
		
		if [[ "$dry_run" == "true" ]]; then
			echo "  [DRY RUN] Would post blocked comment"
		else
			post_blocked_comment_to_github "$task_id" "$blocked_error" "$repo_path"
			((count++))
		fi
	done <<< "$issues"
	
	echo ""
	echo "Backfill complete: $count comments posted"
}

# Show usage
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat << 'USAGE'
Usage: backfill-blocked-comments.sh [REPO_PATH] [--dry-run]

Backfills blocked comments on GitHub issues with status:blocked label.

Arguments:
  REPO_PATH   Path to repository (default: current repo)
  --dry-run   Show what would be done without posting comments

Examples:
  backfill-blocked-comments.sh
  backfill-blocked-comments.sh ~/Git/aidevops
  backfill-blocked-comments.sh ~/Git/aidevops --dry-run
USAGE
	exit 0
fi

# Parse args
REPO_PATH="${1:-$REPO_ROOT}"
DRY_RUN="false"
if [[ "${2:-}" == "--dry-run" ]]; then
	DRY_RUN="true"
fi

main "$REPO_PATH" "$DRY_RUN"
