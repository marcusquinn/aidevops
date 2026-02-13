#!/usr/bin/env bash
# model-label-helper.sh - Track model usage per task via GitHub issue labels
# Part of t1025: Model usage tracking for data-driven model selection
#
# Usage:
#   model-label-helper.sh add <task-id> <action> <model> [--repo PATH]
#   model-label-helper.sh query <action> <model> [--repo PATH]
#   model-label-helper.sh stats [--repo PATH]
#   model-label-helper.sh help
#
# Actions: planned, researched, implemented, reviewed, verified, documented, failed, retried
# Models: haiku, flash, sonnet, pro, opus (or concrete model names)
#
# Labels are append-only (history, not state). Examples:
#   implemented:sonnet - Task was implemented using sonnet tier
#   failed:sonnet - Task failed when using sonnet tier
#   retried:opus - Task was retried with opus tier after failure
#
# Integration points:
#   - supervisor dispatch: adds implemented:{model}
#   - supervisor evaluate: adds failed:{model} or retried:{model}
#   - interactive sessions: adds planned:{model} on task creation
#   - pattern-tracker: queries labels for success rate analysis

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Valid actions (lifecycle stages)
readonly VALID_ACTIONS="planned researched implemented reviewed verified documented failed retried"

# Valid model tiers (matches model-routing.md and pattern-tracker)
readonly VALID_MODELS="haiku flash sonnet pro opus"

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
model-label-helper.sh - Track model usage per task via GitHub issue labels

USAGE:
    model-label-helper.sh add <task-id> <action> <model> [--repo PATH]
    model-label-helper.sh query <action> <model> [--repo PATH]
    model-label-helper.sh stats [--repo PATH]
    model-label-helper.sh help

COMMANDS:
    add         Add a model usage label to a task's GitHub issue
    query       Find tasks with specific action:model combination
    stats       Show model usage statistics across all tasks
    help        Show this help message

ACTIONS:
    planned, researched, implemented, reviewed, verified, documented, failed, retried

MODELS:
    haiku, flash, sonnet, pro, opus (or concrete model names like claude-sonnet-4-5)

EXAMPLES:
    # Add label when dispatching a task
    model-label-helper.sh add t1025 implemented sonnet

    # Add label when task fails
    model-label-helper.sh add t1025 failed sonnet

    # Add label when retrying with higher tier
    model-label-helper.sh add t1025 retried opus

    # Query tasks that failed with sonnet
    model-label-helper.sh query failed sonnet

    # Show overall model usage stats
    model-label-helper.sh stats

INTEGRATION:
    - Supervisor dispatch: Automatically adds implemented:{model} label
    - Supervisor evaluate: Adds failed:{model} or retried:{model} on outcomes
    - Interactive sessions: Adds planned:{model} when creating tasks
    - Pattern tracker: Queries labels for success rate analysis

NOTES:
    - Labels are append-only (history, not state)
    - Requires gh CLI and ref:GH# in TODO.md task line
    - Labels are created on-demand (no pre-creation needed)
    - Concrete model names are normalized to tiers for consistency
EOF
	return 0
}

#######################################
# Normalize model name to tier
# Arguments:
#   $1 - Model name (e.g., claude-sonnet-4-5, sonnet, gpt-4)
# Returns:
#   Normalized tier name (haiku, flash, sonnet, pro, opus)
#######################################
normalize_model() {
	local model="$1"

	# Already a tier name
	if echo "$VALID_MODELS" | grep -qw "$model"; then
		echo "$model"
		return 0
	fi

	# Normalize concrete model names to tiers
	# Specific patterns first, then wildcards
	case "$model" in
	claude-3-haiku* | claude-3-5-haiku*)
		echo "haiku"
		;;
	gemini-*-flash*)
		echo "flash"
		;;
	claude-3-sonnet* | claude-3-5-sonnet* | claude-sonnet-4*)
		echo "sonnet"
		;;
	gemini-*-pro*)
		echo "pro"
		;;
	claude-3-opus* | claude-opus-4* | o3 | o1*)
		echo "opus"
		;;
	*haiku*)
		echo "haiku"
		;;
	*flash*)
		echo "flash"
		;;
	*sonnet*)
		echo "sonnet"
		;;
	*pro*)
		echo "pro"
		;;
	*opus*)
		echo "opus"
		;;
	*)
		# Unknown model - use as-is but warn
		echo "[WARN] Unknown model '$model' - using as-is" >&2
		echo "$model"
		;;
	esac

	return 0
}

#######################################
# Extract GitHub issue number from TODO.md task line
# Arguments:
#   $1 - Task ID (e.g., t1025)
#   $2 - Repository path
# Returns:
#   Issue number (without # prefix) or empty string
#######################################
get_issue_number() {
	local task_id="$1"
	local repo_path="$2"
	local todo_file="${repo_path}/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		echo "[ERROR] TODO.md not found at $todo_file" >&2
		return 1
	fi

	# Extract ref:GH#NNN from task line
	local issue_ref
	issue_ref=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" 2>/dev/null | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || true)

	if [[ -z "$issue_ref" ]]; then
		echo "[WARN] No ref:GH# found for task $task_id in TODO.md" >&2
		return 1
	fi

	echo "$issue_ref"
	return 0
}

#######################################
# Add model usage label to GitHub issue
# Arguments:
#   $1 - Task ID
#   $2 - Action (planned, implemented, failed, etc.)
#   $3 - Model tier/name
#   $4 - Repository path (optional, defaults to current dir)
#######################################
cmd_add() {
	local task_id="$1"
	local action="$2"
	local model="$3"
	local repo_path="${4:-.}"

	# Validate action
	if ! echo "$VALID_ACTIONS" | grep -qw "$action"; then
		echo "[ERROR] Invalid action '$action'. Valid: $VALID_ACTIONS" >&2
		return 1
	fi

	# Normalize model to tier
	local model_tier
	model_tier=$(normalize_model "$model")

	# Get issue number from TODO.md
	local issue_num
	if ! issue_num=$(get_issue_number "$task_id" "$repo_path"); then
		echo "[WARN] Cannot add label - no GitHub issue reference found" >&2
		return 1
	fi

	# Construct label name
	local label="${action}:${model_tier}"

	# Check if gh CLI is available
	if ! command -v gh &>/dev/null; then
		echo "[ERROR] gh CLI not found - cannot add label" >&2
		return 1
	fi

	# Add label (creates label if it doesn't exist)
	echo "[INFO] Adding label '$label' to issue #$issue_num for task $task_id"
	if gh issue edit "$issue_num" --add-label "$label" --repo "$(cd "$repo_path" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')" 2>/dev/null; then
		echo "[OK] Label added successfully"
		return 0
	else
		echo "[ERROR] Failed to add label - check gh auth and repo access" >&2
		return 1
	fi
}

#######################################
# Query tasks with specific action:model label
# Arguments:
#   $1 - Action
#   $2 - Model tier/name
#   $3 - Repository path (optional)
#######################################
cmd_query() {
	local action="$1"
	local model="$2"
	local repo_path="${3:-.}"

	# Validate action
	if ! echo "$VALID_ACTIONS" | grep -qw "$action"; then
		echo "[ERROR] Invalid action '$action'. Valid: $VALID_ACTIONS" >&2
		return 1
	fi

	# Normalize model
	local model_tier
	model_tier=$(normalize_model "$model")

	local label="${action}:${model_tier}"

	# Check gh CLI
	if ! command -v gh &>/dev/null; then
		echo "[ERROR] gh CLI not found" >&2
		return 1
	fi

	# Query issues with label
	echo "[INFO] Querying issues with label '$label'..."
	local repo_name
	repo_name=$(cd "$repo_path" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')

	if [[ -z "$repo_name" ]]; then
		echo "[ERROR] Could not determine repository name" >&2
		return 1
	fi

	gh issue list --label "$label" --repo "$repo_name" --limit 100 --json number,title,labels --jq '.[] | "#\(.number): \(.title) [\(.labels | map(.name) | join(", "))]"'

	return 0
}

#######################################
# Show model usage statistics
# Arguments:
#   $1 - Repository path (optional)
#######################################
cmd_stats() {
	local repo_path="${1:-.}"

	if ! command -v gh &>/dev/null; then
		echo "[ERROR] gh CLI not found" >&2
		return 1
	fi

	local repo_name
	repo_name=$(cd "$repo_path" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')

	if [[ -z "$repo_name" ]]; then
		echo "[ERROR] Could not determine repository name" >&2
		return 1
	fi

	echo "Model Usage Statistics for $repo_name"
	echo "========================================"
	echo ""

	# Count labels by action and model
	for action in $VALID_ACTIONS; do
		echo "[$action]"
		for model in $VALID_MODELS; do
			local label="${action}:${model}"
			local count
			count=$(gh issue list --label "$label" --repo "$repo_name" --limit 1000 --json number 2>/dev/null | jq '. | length' || echo "0")
			if [[ "$count" -gt 0 ]]; then
				printf "  %-10s: %d\n" "$model" "$count"
			fi
		done
		echo ""
	done

	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	add)
		if [[ $# -lt 3 ]]; then
			echo "[ERROR] Usage: model-label-helper.sh add <task-id> <action> <model> [--repo PATH]" >&2
			return 1
		fi

		local task_id="$1"
		local action="$2"
		local model="$3"
		shift 3

		local repo_path="."
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--repo)
				repo_path="$2"
				shift 2
				;;
			*)
				echo "[ERROR] Unknown option: $1" >&2
				return 1
				;;
			esac
		done

		cmd_add "$task_id" "$action" "$model" "$repo_path"
		;;
	query)
		if [[ $# -lt 2 ]]; then
			echo "[ERROR] Usage: model-label-helper.sh query <action> <model> [--repo PATH]" >&2
			return 1
		fi

		local action="$1"
		local model="$2"
		shift 2

		local repo_path="."
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--repo)
				repo_path="$2"
				shift 2
				;;
			*)
				echo "[ERROR] Unknown option: $1" >&2
				return 1
				;;
			esac
		done

		cmd_query "$action" "$model" "$repo_path"
		;;
	stats)
		local repo_path="."
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--repo)
				repo_path="$2"
				shift 2
				;;
			*)
				echo "[ERROR] Unknown option: $1" >&2
				return 1
				;;
			esac
		done

		cmd_stats "$repo_path"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo "[ERROR] Unknown command: $cmd" >&2
		cmd_help
		return 1
		;;
	esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
