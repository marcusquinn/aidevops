#!/usr/bin/env bash
# =============================================================================
# Pre-Edit Git Branch Check
# =============================================================================
# Run this BEFORE any file edit to enforce the git workflow.
# Returns exit code 1 if on main/master branch (should create branch first).
#
# Usage:
#   ~/.aidevops/agents/scripts/pre-edit-check.sh
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "description"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --check-command "git push --force origin main"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --verify-op "git push --force origin main"
#
# Exit codes:
#   0 - OK to proceed (on feature branch in worktree, or docs-only on main)
#   1 - STOP (on protected branch main/master, interactive mode)
#   2 - Create worktree (loop mode detected code task on main)
#   3 - WARNING (on feature branch in main repo - should use worktree instead)
#
# High-stakes detection (--check-command):
#   When --check-command is passed, the script checks the command against
#   verification trigger patterns from configs/verification-triggers.json.
#   If matched, outputs REQUIRES_VERIFICATION=1 with category and risk level.
#   See reference/high-stakes-operations.md for the full taxonomy.
#
# Operation verification (--verify-op, t1364.3):
#   When --verify-op is passed, the script invokes verify-operation-helper.sh
#   to classify the operation risk and optionally invoke cross-provider
#   verification for high-stakes operations.
#
# AI assistants should call this before any Edit/Write tool and:
# - Exit 1: STOP and present branch creation options
# - Exit 3: Present options to user (continue, create worktree, or switch main back)
# - Exit 0: Proceed with edits
# =============================================================================

set -euo pipefail

# =============================================================================
# Loop Mode Support
# =============================================================================
# When --loop-mode is passed, the script auto-decides based on task description:
# - Docs-only tasks (README, CHANGELOG, docs/) -> stay on main (exit 0)
# - Code tasks (feature, fix, implement, etc.) -> signal worktree needed (exit 2)

LOOP_MODE=false
TASK_DESC=""
CHECK_COMMAND=""
VERIFY_OP=""

while [[ $# -gt 0 ]]; do
	case $1 in
	--loop-mode)
		LOOP_MODE=true
		shift
		;;
	--task)
		TASK_DESC="$2"
		shift 2
		;;
	--check-command)
		CHECK_COMMAND="$2"
		shift 2
		;;
	--verify-op)
		VERIFY_OP="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

# Function to detect if task is docs-only
is_docs_only() {
	local task="$1"
	# Use tr for lowercase (portable across bash versions including macOS default bash 3.x)
	local task_lower
	task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

	# Code change indicators (negative match - if present, NOT docs-only)
	# These take precedence over docs patterns
	local code_patterns="feature|fix|bug|implement|refactor|add.*function|update.*code|create.*script|modify.*config|change.*logic|new.*api|endpoint|enhance|port|ssl|helper"

	# Docs-only indicators (positive match)
	# Includes planning files (TODO.md, todo/) which can be edited on main
	local docs_patterns="^readme|^changelog|^documentation|docs/|typo|spelling|comment only|license only|^update readme|^update changelog|^update docs|^todo|todo\.md|plans\.md|planning|^add task|^update task|backlog"

	# Check for code patterns first (takes precedence)
	if echo "$task_lower" | grep -qE "$code_patterns"; then
		return 1 # Not docs-only
	fi

	# Check for docs patterns
	if echo "$task_lower" | grep -qE "$docs_patterns"; then
		return 0 # Is docs-only
	fi

	# Default: not docs-only (safer to create branch)
	return 1
}

# =============================================================================
# High-Stakes Operation Detection
# =============================================================================
# Checks a command string against verification trigger patterns defined in
# configs/verification-triggers.json. Outputs structured key=value pairs
# for the calling agent to parse.
#
# Uses grep -qiE for pattern matching — patterns from the JSON are treated
# as extended regexes matched case-insensitively against the command string.

# Resolve the path to verification-triggers.json relative to this script.
# Works in both deployed (~/.aidevops/agents/scripts/) and dev (.agents/scripts/) contexts.
_resolve_triggers_config() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# Dev repo layout: .agents/scripts/ -> .agents/configs/
	local dev_path="${script_dir}/../configs/verification-triggers.json"
	if [[ -f "$dev_path" ]]; then
		echo "$dev_path"
		return 0
	fi

	# Deployed layout: ~/.aidevops/agents/scripts/ -> ~/.aidevops/agents/configs/
	local deployed_path="${script_dir}/../configs/verification-triggers.json"
	if [[ -f "$deployed_path" ]]; then
		echo "$deployed_path"
		return 0
	fi

	# Fallback: search from repo root
	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
	if [[ -n "$repo_root" && -f "$repo_root/.agents/configs/verification-triggers.json" ]]; then
		echo "$repo_root/.agents/configs/verification-triggers.json"
		return 0
	fi

	return 1
}

# Check a command against high-stakes trigger patterns.
# Arguments:
#   $1 - command string to check
# Output (on match):
#   REQUIRES_VERIFICATION=1
#   VERIFICATION_CATEGORY=<category>
#   VERIFICATION_RISK_LEVEL=<critical|high|medium>
#   VERIFICATION_GATE=<block|warn|log>
# Returns: 0 if high-stakes match found, 1 if no match
check_high_stakes() {
	local cmd="$1"

	if [[ -z "$cmd" ]]; then
		return 1
	fi

	local triggers_file
	triggers_file="$(_resolve_triggers_config)" || return 1

	# Requires jq for JSON parsing
	if ! command -v jq &>/dev/null; then
		echo "VERIFICATION_ERROR=jq_not_found" >&2
		return 1
	fi

	local categories
	categories=$(jq -r '.categories | keys[]' "$triggers_file" 2>/dev/null) || return 1

	local category
	for category in $categories; do
		local patterns
		patterns=$(jq -r ".categories[\"$category\"].command_patterns[]" "$triggers_file" 2>/dev/null) || continue

		local pattern
		while IFS= read -r pattern; do
			[[ -z "$pattern" ]] && continue
			# Match pattern against command (case-insensitive, extended regex)
			if echo "$cmd" | grep -qiE "$pattern"; then
				local risk_level default_gate
				risk_level=$(jq -r ".categories[\"$category\"].risk_level" "$triggers_file" 2>/dev/null)
				default_gate=$(jq -r ".categories[\"$category\"].default_gate" "$triggers_file" 2>/dev/null)

				echo "REQUIRES_VERIFICATION=1"
				echo "VERIFICATION_CATEGORY=$category"
				echo "VERIFICATION_RISK_LEVEL=$risk_level"
				echo "VERIFICATION_GATE=$default_gate"
				echo "VERIFICATION_PATTERN=$pattern"
				return 0
			fi
		done <<<"$patterns"
	done

	return 1
}

# If --check-command was passed, run high-stakes detection and exit.
# This mode is independent of the branch-check logic below.
if [[ -n "$CHECK_COMMAND" ]]; then
	if check_high_stakes "$CHECK_COMMAND"; then
		exit 0
	else
		echo "REQUIRES_VERIFICATION=0"
		exit 0
	fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

# =============================================================================
# Operation Verification (t1364.3)
# =============================================================================
# When --verify-op is passed, check the operation against the risk taxonomy
# and invoke cross-provider verification for high-stakes operations.
# Uses verify-operation-helper.sh CLI (t1364.2) for classification and verification.

run_operation_verification() {
	local operation="$1"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
	local verify_helper="${script_dir}/verify-operation-helper.sh"

	if [[ ! -x "$verify_helper" ]]; then
		return 0 # Helper not installed — skip verification silently
	fi

	# Use the CLI check command to classify the operation
	local check_output
	check_output=$("$verify_helper" check --operation "$operation" 2>/dev/null) || return 0

	local risk_tier
	risk_tier=$(echo "$check_output" | grep '^risk_tier:' | awk '{print $2}') || risk_tier="standard"

	if [[ "$risk_tier" == "standard" || "$risk_tier" == "unknown" ]]; then
		return 0 # No verification needed
	fi

	# Build context from git state
	local branch repo_root
	branch=$(git branch --show-current 2>/dev/null || echo "unknown")
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")

	# Invoke full verification for critical/high operations
	local verify_result
	verify_result=$("$verify_helper" verify \
		--operation "$operation" \
		--risk-tier "$risk_tier" \
		--repo "$repo_root" \
		--branch "$branch" 2>/dev/null) || true

	case "$verify_result" in
	BLOCK*)
		echo -e "${RED}Operation blocked by verification. Aborting.${NC}"
		exit 1
		;;
	WARN*)
		if [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]]; then
			echo -e "${YELLOW}Verification raised concerns in headless mode — proceeding with caution${NC}"
		else
			echo -e "${YELLOW}Verification raised concerns. Review above and proceed with caution.${NC}"
		fi
		;;
	esac
	return 0
}

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
	echo -e "${YELLOW}Not in a git repository - no branch check needed${NC}"
	exit 0
fi

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "")

if [[ -z "$current_branch" ]]; then
	echo -e "${YELLOW}Detached HEAD state - consider creating a branch${NC}"
	exit 0
fi

# Check if on main or master
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
	# Loop mode: auto-decide based on task description
	if [[ "$LOOP_MODE" == "true" ]]; then
		if is_docs_only "$TASK_DESC"; then
			echo -e "${YELLOW}LOOP-AUTO${NC}: Docs-only task detected, staying on $current_branch"
			echo "LOOP_DECISION=stay"
			exit 0
		else
			# Auto-create worktree for code changes
			echo -e "${YELLOW}LOOP-AUTO${NC}: Code task detected, worktree required"
			echo "LOOP_DECISION=worktree"
			exit 2 # Special exit code for "create worktree"
		fi
	fi

	# Interactive mode: show warning and exit
	echo ""
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo -e "${RED}${BOLD}  STOP - ON PROTECTED BRANCH: $current_branch${NC}"
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo ""
	echo -e "${YELLOW}You must create a branch before making changes.${NC}"
	echo ""
	echo "Suggested branch names based on change type:"
	echo "  feature/description  - New functionality"
	echo "  bugfix/description   - Bug fixes"
	echo "  chore/description    - Maintenance, docs, config"
	echo "  hotfix/description   - Urgent production fixes"
	echo "  refactor/description - Code restructuring"
	echo ""
	echo -e "${BOLD}Create a worktree (keeps main repo on main):${NC}"
	echo ""
	if command -v wt &>/dev/null; then
		echo "    wt switch -c {type}/{description}"
		echo ""
		echo "    (Using Worktrunk - recommended)"
	else
		echo "    ~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{description}"
		echo "    cd ../{repo}-{type}-{description}"
		echo ""
		echo "    (Install Worktrunk for better experience: brew install max-sixty/worktrunk/wt)"
	fi
	echo ""
	echo -e "${YELLOW}Why worktrees? The main repo directory should ALWAYS stay on main.${NC}"
	echo -e "${YELLOW}Using 'git checkout -b' here leaves the repo on a feature branch,${NC}"
	echo -e "${YELLOW}which breaks parallel sessions and causes merge conflicts.${NC}"
	echo ""
	echo -e "${RED}DO NOT proceed with edits until on a feature branch.${NC}"
	echo ""
	exit 1
else
	# Check if this is the main repo directory (not a worktree) on a feature branch
	# This is a warning - the main repo should stay on main
	git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
	git_dir=$(git rev-parse --git-dir 2>/dev/null)

	# If git-dir equals git-common-dir, this is the main worktree (not a linked worktree)
	is_main_worktree=false
	if [[ "$git_dir" == "$git_common_dir" ]] || [[ "$git_dir" == ".git" ]]; then
		is_main_worktree=true
	fi

	# Sync terminal tab title with repo/branch (silent, non-blocking)
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
	source "${SCRIPT_DIR}/shared-constants.sh"

	if [[ -x "$SCRIPT_DIR/terminal-title-helper.sh" ]]; then
		"$SCRIPT_DIR/terminal-title-helper.sh" sync 2>/dev/null || true
	fi

	if [[ "$is_main_worktree" == "true" ]]; then
		# Loop mode: auto-decide for feature branch in main repo
		if [[ "$LOOP_MODE" == "true" ]]; then
			if is_docs_only "$TASK_DESC"; then
				echo -e "${YELLOW}LOOP-AUTO${NC}: Docs-only task on feature branch, continuing"
				echo "LOOP_DECISION=continue"
				exit 0
			else
				# For code tasks, warn but continue (already on feature branch)
				echo -e "${YELLOW}LOOP-AUTO${NC}: On feature branch in main repo (not ideal but continuing)"
				echo "LOOP_DECISION=continue_warning"
				exit 0
			fi
		fi

		# Interactive mode: show warning with options
		echo ""
		echo -e "${YELLOW}${BOLD}======================================================${NC}"
		echo -e "${YELLOW}${BOLD}  WARNING - MAIN REPO ON FEATURE BRANCH${NC}"
		echo -e "${YELLOW}${BOLD}======================================================${NC}"
		echo ""
		echo -e "Current branch: ${BOLD}$current_branch${NC}"
		echo ""
		echo -e "${YELLOW}The main repo directory should stay on 'main' for parallel safety.${NC}"
		echo -e "${YELLOW}Working directly here can cause issues with parallel sessions.${NC}"
		echo ""
		echo "Options:"
		echo "  1. Create worktree for this task (recommended)"
		echo "  2. Continue on current branch (not recommended for code)"
		echo "  3. Switch main repo back to main, then create worktree"
		echo ""
		echo "FEATURE_BRANCH_WARNING=$current_branch"
		exit 3
	else
		# Check if task is claimed by someone else via TODO.md assignee: field (t165)
		# Note: no 'local' — this runs at script top-level, not inside a function
		task_id_from_branch=""
		task_id_from_branch=$(echo "$current_branch" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || true)
		if [[ -n "$task_id_from_branch" ]]; then
			project_root=""
			project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
			todo_file="$project_root/TODO.md"
			if [[ -f "$todo_file" ]]; then
				task_line=""
				task_line=$(grep -E "^\- \[.\] ${task_id_from_branch} " "$todo_file" | head -1 || true)
				task_assignee=""
				task_assignee=$(echo "$task_line" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || true)
				if [[ -n "$task_assignee" ]]; then
					# Must match get_aidevops_identity() in supervisor-helper.sh
					my_identity="${AIDEVOPS_IDENTITY:-$(whoami 2>/dev/null || echo unknown)@$(hostname -s 2>/dev/null || echo local)}"
					if [[ "$task_assignee" != "$my_identity" ]]; then
						echo -e "${YELLOW}WARNING${NC}: Task $task_id_from_branch is claimed by assignee:$task_assignee"
					fi
				fi
			fi
		fi
		# Operation verification gate (t1364.3)
		if [[ -n "$VERIFY_OP" ]]; then
			run_operation_verification "$VERIFY_OP"
		fi

		echo -e "${GREEN}OK${NC} - On branch: ${BOLD}$current_branch${NC} (in worktree)"
		exit 0
	fi
fi
