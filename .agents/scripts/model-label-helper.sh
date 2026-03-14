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
readonly VALID_MODELS="local haiku flash sonnet pro opus"

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
    local, haiku, flash, sonnet, pro, opus (or concrete model names like claude-sonnet-4-6)

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
#   $1 - Model name (e.g., claude-sonnet-4-6, sonnet, gpt-4)
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
	claude-haiku-4* | claude-3-haiku* | claude-3-5-haiku*)
		echo "haiku"
		;;
	gemini-*-flash*)
		echo "flash"
		;;
	claude-sonnet-4* | claude-3-sonnet* | claude-3-5-sonnet*)
		echo "sonnet"
		;;
	gemini-*-pro*)
		echo "pro"
		;;
	claude-opus-4* | claude-3-opus* | o3 | o1*)
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
# Shared: validate action is in VALID_ACTIONS
#######################################
_validate_action() {
	local action="$1"
	if ! echo "$VALID_ACTIONS" | grep -qw "$action"; then
		echo "[ERROR] Invalid action '$action'. Valid: $VALID_ACTIONS" >&2
		return 1
	fi
	return 0
}

#######################################
# Shared: require gh CLI
#######################################
_require_gh() {
	if ! command -v gh &>/dev/null; then
		echo "[ERROR] gh CLI not found" >&2
		return 1
	fi
	return 0
}

#######################################
# Shared: resolve repo name from path
# Sets REPLY to the repo slug (owner/repo)
#######################################
_resolve_repo() {
	local repo_path="$1"
	REPLY=$(cd "$repo_path" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')
	if [[ -z "$REPLY" ]]; then
		echo "[ERROR] Could not determine repository name" >&2
		return 1
	fi
	return 0
}

#######################################
# Shared: parse trailing --repo flag from args
# Sets REPLY to the repo path (default: ".")
#######################################
_parse_repo_flag() {
	REPLY="."
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			if [[ $# -lt 2 || -z "${2:-}" ]]; then
				echo "[ERROR] Missing value for --repo" >&2
				return 1
			fi
			REPLY="$2"
			shift 2
			;;
		*)
			echo "[ERROR] Unknown option: $1" >&2
			return 1
			;;
		esac
	done
	return 0
}

#######################################
# Add model usage label to GitHub issue
#######################################
cmd_add() {
	local task_id="$1"
	local action="$2"
	local model="$3"
	local repo_path="${4:-.}"

	_validate_action "$action" || return 1
	_require_gh || return 1

	local model_tier
	model_tier=$(normalize_model "$model")

	local issue_num
	if ! issue_num=$(get_issue_number "$task_id" "$repo_path"); then
		echo "[WARN] Cannot add label - no GitHub issue reference found" >&2
		return 1
	fi

	local label="${action}:${model_tier}"
	local repo_name
	_resolve_repo "$repo_path" || return 1
	repo_name="$REPLY"

	echo "[INFO] Adding label '$label' to issue #$issue_num for task $task_id"
	if gh issue edit "$issue_num" --add-label "$label" --repo "$repo_name" 2>/dev/null; then
		echo "[OK] Label added successfully"
		return 0
	else
		echo "[ERROR] Failed to add label - check gh auth and repo access" >&2
		return 1
	fi
}

#######################################
# Query tasks with specific action:model label
#######################################
cmd_query() {
	local action="$1"
	local model="$2"
	local repo_path="${3:-.}"

	_validate_action "$action" || return 1
	_require_gh || return 1

	local model_tier
	model_tier=$(normalize_model "$model")
	local label="${action}:${model_tier}"

	local repo_name
	_resolve_repo "$repo_path" || return 1
	repo_name="$REPLY"

	echo "[INFO] Querying issues with label '$label'..."
	gh issue list --label "$label" --repo "$repo_name" --limit 100 --json number,title,labels --jq '.[] | "#\(.number): \(.title) [\(.labels | map(.name) | join(", "))]"'

	return 0
}

#######################################
# Show model usage statistics
# Uses a single API call to fetch all labels instead of 40 separate gh calls
#######################################
cmd_stats() {
	local repo_path="${1:-.}"

	_require_gh || return 1

	local repo_name
	_resolve_repo "$repo_path" || return 1
	repo_name="$REPLY"

	echo "Model Usage Statistics for $repo_name"
	echo "========================================"
	echo ""

	# Single API call: fetch all repo labels with issue counts
	# This replaces 40 separate gh issue list calls (8 actions * 5 models)
	local all_labels
	all_labels=$(gh label list --repo "$repo_name" --limit 200 --json name --jq '.[].name' 2>/dev/null || echo '')

	for action in $VALID_ACTIONS; do
		local has_data=false
		local section=""
		for model in $VALID_MODELS; do
			local label="${action}:${model}"
			if echo "$all_labels" | grep -qx "$label"; then
				local count
				count=$(gh issue list --label "$label" --repo "$repo_name" --limit 1000 --json number --jq 'length' 2>/dev/null || echo "0")
				if [[ "$count" -gt 0 ]]; then
					if [[ "$has_data" == false ]]; then
						section="[$action]"$'\n'
						has_data=true
					fi
					section+=$(printf "  %-10s: %d\n" "$model" "$count")$'\n'
				fi
			fi
		done
		if [[ "$has_data" == true ]]; then
			printf '%s\n' "$section"
		fi
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
		_parse_repo_flag "$@" || return 1
		cmd_add "$task_id" "$action" "$model" "$REPLY"
		;;
	query)
		if [[ $# -lt 2 ]]; then
			echo "[ERROR] Usage: model-label-helper.sh query <action> <model> [--repo PATH]" >&2
			return 1
		fi
		local action="$1"
		local model="$2"
		shift 2
		_parse_repo_flag "$@" || return 1
		cmd_query "$action" "$model" "$REPLY"
		;;
	stats)
		_parse_repo_flag "$@" || return 1
		cmd_stats "$REPLY"
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
