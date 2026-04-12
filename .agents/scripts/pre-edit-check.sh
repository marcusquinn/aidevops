#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pre-Edit Git Worktree Check
# =============================================================================
# Run this BEFORE any file edit to enforce the canonical-repo-on-main + linked-worktree workflow.
# Returns exit code 1 if on main/master (should create a dedicated worktree first).
#
# Usage:
#   ~/.aidevops/agents/scripts/pre-edit-check.sh
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --file "path/to/file"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "description"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --check-command "git push --force origin main"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --verify-op "git push --force origin main"
#
# Main-branch write protection (t1712):
#   Pass --file <path> for path-based enforcement (preferred).
#   Allowlisted paths (writable on main without a worktree): README.md, TODO.md, todo/**
#   All other paths require a linked worktree.
#   --task description heuristics are a fallback when --file is not provided.
#
# Exit codes:
#   0 - OK to proceed (in a linked worktree, or allowlisted path on main)
#   1 - STOP (on protected main/master, interactive mode)
#   2 - Create worktree (loop mode detected non-allowlisted path on main)
#   3 - WARNING (canonical repo directory is not on main - move it back and continue from a linked worktree)
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
# - Exit 1: STOP and present worktree creation instructions
# - Exit 3: Warn that the canonical repo directory is off main and move work to a linked worktree path
# - Exit 0: Proceed with edits
# =============================================================================

set -euo pipefail

# =============================================================================
# Fast-path for headless workers with pre-created worktrees
# =============================================================================
# When the dispatcher pre-creates a worktree and passes WORKER_WORKTREE_PATH,
# the worker is already in a safe feature branch. Skip all detection logic.
if [[ -n "${WORKER_WORKTREE_PATH:-}" && -d "${WORKER_WORKTREE_PATH:-}" ]]; then
	# Verify we're actually in the worktree (or the worker's --dir points here)
	_current_dir="$(pwd -P 2>/dev/null || pwd)"
	_wt_real="$(cd "$WORKER_WORKTREE_PATH" 2>/dev/null && pwd -P)"
	if [[ "$_current_dir" == "$_wt_real"* ]]; then
		echo "OK - Pre-created worktree: ${WORKER_WORKTREE_BRANCH:-unknown branch}"
		exit 0
	fi
fi

# =============================================================================
# Loop Mode Support
# =============================================================================
# When --loop-mode is passed, the script auto-decides based on file path or task description:
# - Allowlisted paths (README.md, TODO.md, todo/**) -> stay on main (exit 0)
# - All other paths -> signal worktree needed (exit 2)
#
# Pass --file <path> for path-based enforcement (preferred, harder to bypass).
# Fall back to --task description heuristics only when no --file is provided.

LOOP_MODE=false
TASK_DESC=""
CHECK_COMMAND=""
VERIFY_OP=""
TARGET_FILE=""

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
	--file)
		TARGET_FILE="$2"
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

# =============================================================================
# Main-branch file allowlist (t1712)
# =============================================================================
# Canonical list of paths writable on main/master without a linked worktree.
# All other paths require a worktree.
#
# Allowlisted paths:
#   README.md          — top-level readme
#   TODO.md            — task backlog
#   todo/**            — plans, briefs, task files
#
# Usage: _canonicalize_repo_relative_path <file_path> <repo_root>
# Returns: canonical repo-relative path on stdout, or "OUTSIDE_REPO" if path escapes root
# Resolves ./ and ../ segments without requiring the path to exist on disk.
_canonicalize_repo_relative_path() {
	local file_path="$1"
	local repo_root="$2"

	# Resolve to absolute path (relative paths are resolved from repo_root)
	local abs_path
	if [[ "$file_path" == /* ]]; then
		abs_path="$file_path"
	else
		abs_path="${repo_root}/${file_path}"
	fi

	# Use python3 for portable normpath (resolves ./ and ../ without filesystem access)
	if command -v python3 &>/dev/null; then
		python3 - "$abs_path" "$repo_root" <<'PYEOF'
import os, sys
abs_path = sys.argv[1]
repo_root = sys.argv[2]
canonical = os.path.normpath(abs_path)
if canonical.startswith(repo_root + os.sep) or canonical == repo_root:
    print(os.path.relpath(canonical, repo_root))
else:
    print("OUTSIDE_REPO")
PYEOF
		return 0
	fi

	# Fallback: pure bash normalization (handles common cases without python3)
	# Remove double slashes
	abs_path="${abs_path//\/\//\/}"
	# Resolve embedded ./ segments
	while [[ "$abs_path" == *"/./"* ]]; do
		abs_path="${abs_path//\/.\//\/}"
	done
	# Resolve ../ segments iteratively
	while [[ "$abs_path" == *"/../"* ]]; do
		abs_path=$(echo "$abs_path" | sed 's|[^/]*/\.\./||')
	done
	# Check if within repo root
	if [[ "$abs_path" == "${repo_root}/"* ]] || [[ "$abs_path" == "$repo_root" ]]; then
		echo "${abs_path#"${repo_root}/"}"
	else
		echo "OUTSIDE_REPO"
	fi
	return 0
}

# Usage: is_main_allowlisted_path <file_path>
# Returns: 0 if path is allowlisted, 1 if not
# Canonicalizes the path to a repo-relative form before evaluating the allowlist,
# preventing path traversal bypasses (e.g. todo/../secret.py).
#
# t1990: Interactive sessions have NO main-branch planning exception — every
# edit on main (including TODO.md, todo/**, README.md) requires a linked
# worktree. Headless sessions (pulse, CI workers, routines) keep the
# allowlist so they can continue to write routine state and dispatch
# bookkeeping directly on main without PR ceremony.
#
# Session-origin detection is inlined here (rather than calling
# detect_session_origin from shared-constants.sh) to avoid any source-order
# dependency — this function may be called before shared-constants.sh is
# sourced in the execution flow.
is_main_allowlisted_path() {
	local file_path="$1"

	# t1990: short-circuit FALSE for interactive sessions. A session is
	# interactive unless one of the known headless env vars is set. This
	# mirrors detect_session_origin() in shared-constants.sh — keep in sync.
	if [[ "${FULL_LOOP_HEADLESS:-}" != "true" ]] &&
		[[ "${AIDEVOPS_HEADLESS:-}" != "true" ]] &&
		[[ "${OPENCODE_HEADLESS:-}" != "true" ]] &&
		[[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
		# Interactive session: no allowlist, always require a worktree.
		return 1
	fi

	# Resolve repo root for canonicalization
	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

	local normalised
	if [[ -n "$repo_root" ]]; then
		# Canonicalize: resolve ./ and ../ segments, reject paths outside repo root
		normalised="$(_canonicalize_repo_relative_path "$file_path" "$repo_root")"
		# Reject paths that escape the repo root
		if [[ "$normalised" == "OUTSIDE_REPO" ]]; then
			return 1
		fi
	else
		# No git repo context: fall back to simple normalization
		# Strip leading ./ to get a repo-relative path
		normalised=$(echo "$file_path" | sed 's|^\./||')

		# Reject path traversal: any path containing .. segments is not allowlisted.
		case "$normalised" in
		*..*)
			return 1
			;;
		esac

		# Reject absolute paths
		case "$normalised" in
		/*)
			return 1
			;;
		esac
	fi

	# Exact matches
	case "$normalised" in
	README.md | TODO.md)
		return 0
		;;
	esac

	# Prefix matches (todo/ subtree)
	case "$normalised" in
	todo/*)
		return 0
		;;
	esac

	return 1
}

# Function to detect if task is docs-only (fallback when --file is not provided)
# Deprecated: prefer --file for path-based enforcement. Kept for backward compatibility
# with callers that only pass --task descriptions.
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

	# yeah, default to requiring a worktree — safer that way
	return 1
}

# Unified main-branch write check: path-based when --file provided, else task heuristic.
# Returns: 0 if write is allowed on main, 1 if worktree required
is_main_write_allowed() {
	if [[ -n "$TARGET_FILE" ]]; then
		is_main_allowlisted_path "$TARGET_FILE"
		return $?
	fi
	# Fallback: task-description heuristic (backward compat)
	is_docs_only "$TASK_DESC"
	return $?
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

# =============================================================================
# Extracted handler functions (GH#17644: reduce nesting depth from 14 to ≤8)
# =============================================================================

# Handle loop-mode decision on a protected (main/master) branch.
# Outputs LOOP_DECISION and exits 0 (stay) or 2 (worktree needed).
_handle_loop_mode_on_protected() {
	local branch="$1"

	if is_main_write_allowed; then
		if [[ -n "$TARGET_FILE" ]]; then
			echo -e "${YELLOW}LOOP-AUTO${NC}: Allowlisted path '$TARGET_FILE', staying on $branch"
		else
			echo -e "${YELLOW}LOOP-AUTO${NC}: Docs-only task detected, staying on $branch"
		fi
		echo "LOOP_DECISION=stay"
		exit 0
	fi

	# Auto-create worktree for non-allowlisted paths / code changes.
	# Previously this just signalled "worktree required" (exit 2) and left
	# creation to the LLM. Many models (gpt-5.4, haiku) didn't know how to
	# interpret exit 2 and stopped dead. Now we create the worktree
	# deterministically and return the path so the model can continue.
	if [[ -n "$TARGET_FILE" ]]; then
		echo -e "${YELLOW}LOOP-AUTO${NC}: Non-allowlisted path '$TARGET_FILE', worktree required"
	else
		echo -e "${YELLOW}LOOP-AUTO${NC}: Code task detected, worktree required"
	fi

	# Derive branch name from --task description or fall back to generic
	local _wt_branch_name=""
	local _wt_task_desc="${TASK_DESCRIPTION:-}"
	if [[ -n "$_wt_task_desc" ]]; then
		# Extract issue number if present (e.g., "Implement issue #17642")
		local _wt_issue_num=""
		_wt_issue_num=$(printf '%s' "$_wt_task_desc" | grep -oE '#[0-9]+|issue[/ ]*([0-9]+)' | grep -oE '[0-9]+' | head -1) || _wt_issue_num=""
		if [[ -n "$_wt_issue_num" ]]; then
			# Slugify the task title for the branch name
			local _wt_slug=""
			_wt_slug=$(printf '%s' "$_wt_task_desc" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40) || _wt_slug="task"
			_wt_branch_name="bugfix/gh${_wt_issue_num}-${_wt_slug}"
		fi
	fi
	# Fallback: timestamp-based branch name
	if [[ -z "$_wt_branch_name" ]]; then
		_wt_branch_name="feature/auto-$(date +%Y%m%d-%H%M%S)"
	fi

	# Try to create the worktree using the helper
	local _wt_helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/worktree-helper.sh"
	local _wt_path=""
	if [[ -x "$_wt_helper" ]]; then
		local _wt_output=""
		_wt_output=$("$_wt_helper" add "$_wt_branch_name" 2>&1) || true
		# Extract the worktree path from helper output
		_wt_path=$(printf '%s' "$_wt_output" | grep -oE '/[^ ]*Git/[^ ]*' | head -1) || _wt_path=""
		if [[ -z "$_wt_path" ]]; then
			# Fallback: construct expected path from repo name + branch
			local _wt_repo_name=""
			_wt_repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
			local _wt_safe_branch=""
			_wt_safe_branch=$(printf '%s' "$_wt_branch_name" | tr '/' '-')
			_wt_path="$(dirname "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")/${_wt_repo_name}-${_wt_safe_branch}"
		fi
	fi

	if [[ -n "$_wt_path" && -d "$_wt_path" ]]; then
		echo "LOOP_DECISION=worktree_created"
		echo "WORKTREE_PATH=$_wt_path"
		echo "WORKTREE_BRANCH=$_wt_branch_name"
		echo -e "${GREEN}LOOP-AUTO${NC}: Worktree created at $_wt_path"
		echo ""
		echo "NEXT_STEP: cd to the worktree path and continue implementation there."
		echo "All file reads and edits must use the worktree path, not the main repo."
		exit 0
	else
		# Worktree creation failed — fall back to signalling exit 2
		echo -e "${RED}LOOP-AUTO${NC}: Failed to auto-create worktree '$_wt_branch_name'"
		echo "LOOP_DECISION=worktree"
		echo "WORKTREE_BRANCH=$_wt_branch_name"
		echo "NEXT_STEP: Run worktree-helper.sh add '$_wt_branch_name' manually, then cd to the new path."
		exit 2 # Special exit code for "create worktree"
	fi
}

# Show interactive warning when on a protected branch (main/master).
# Exits 1 (stop).
_show_protected_branch_warning() {
	local branch="$1"

	echo ""
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo -e "${RED}${BOLD}  STOP - ON PROTECTED MAIN WORKTREE: $branch${NC}"
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo ""
	echo -e "${YELLOW}Leave the canonical repo on 'main' and create a linked worktree before making code changes here.${NC}"
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
	echo -e "${RED}DO NOT proceed with edits until you are inside a linked worktree.${NC}"
	echo ""
	exit 1
}

# Handle worktree ownership conflict (GH#14413 hardening).
# Arguments: $1=worktree_path, $2=owner_pid, $3=owner_session, $4=owner_created
# Exits 2 (headless/loop) or 1 (interactive).
_handle_ownership_conflict() {
	local wt_path="$1"
	local o_pid="$2"
	local o_session="$3"
	local o_created="$4"

	if [[ ! -t 0 ]] || [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]] || [[ "$LOOP_MODE" == "true" ]]; then
		echo -e "${RED}BLOCKED${NC}: linked worktree is owned by another active session/process"
		echo "WORKTREE_OWNERSHIP_CONFLICT=true"
		echo "ACTION_REQUIRED=create_worktree"
		echo "WORKTREE_PATH=$wt_path"
		echo "WORKTREE_OWNER_PID=$o_pid"
		[[ -n "$o_session" ]] && echo "WORKTREE_OWNER_SESSION=$o_session"
		[[ -n "$o_created" ]] && echo "WORKTREE_OWNER_SINCE=$o_created"
		echo "HINT: create a dedicated worktree for this session/task and retry"
		exit 2
	fi

	echo ""
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo -e "${RED}${BOLD}  STOP - WORKTREE OWNED BY ANOTHER ACTIVE SESSION${NC}"
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo ""
	echo "Worktree: $wt_path"
	echo "Owner PID: $o_pid"
	[[ -n "$o_session" ]] && echo "Owner session: $o_session"
	[[ -n "$o_created" ]] && echo "Owned since: $o_created"
	echo ""
	echo -e "${YELLOW}Use a dedicated linked worktree for this session/task to avoid cross-session edits.${NC}"
	echo ""
	exit 1
}

# Handle the canonical repo directory being off main (on a feature branch).
# Arguments: $1=current_branch
# Exits 0 (loop mode) or 3 (interactive warning).
_handle_main_repo_off_main() {
	local branch="$1"

	# Loop mode: auto-decide for canonical repo directory off main
	if [[ "$LOOP_MODE" == "true" ]]; then
		if is_main_write_allowed; then
			if [[ -n "$TARGET_FILE" ]]; then
				echo -e "${YELLOW}LOOP-AUTO${NC}: Allowlisted path '$TARGET_FILE' in main repo directory, continuing"
			else
				echo -e "${YELLOW}LOOP-AUTO${NC}: Docs-only task in main repo directory, continuing"
			fi
			echo "LOOP_DECISION=continue"
			exit 0
		fi
		# For non-allowlisted paths / code tasks, warn but continue so the caller can relocate into a worktree.
		echo -e "${YELLOW}LOOP-AUTO${NC}: Main repo directory is off main (not ideal - relocate to a linked worktree)"
		echo "LOOP_DECISION=continue_warning"
		exit 0
	fi

	# Interactive mode: show warning with options
	echo ""
	echo -e "${YELLOW}${BOLD}======================================================${NC}"
	echo -e "${YELLOW}${BOLD}  WARNING - MAIN REPO DIRECTORY IS OFF MAIN${NC}"
	echo -e "${YELLOW}${BOLD}======================================================${NC}"
	echo ""
	echo -e "Current ref: ${BOLD}$branch${NC}"
	echo ""
	echo -e "${YELLOW}The canonical repo directory should stay on 'main' for parallel safety.${NC}"
	echo -e "${YELLOW}Move code work into a linked worktree path, not this canonical repo directory.${NC}"
	echo ""
	echo "Options:"
	echo "  1. Create worktree for this task (recommended)"
	echo "  2. Switch the canonical repo directory back to main"
	echo "  3. Continue here temporarily (not recommended for code)"
	echo ""
	echo "MAIN_REPO_OFF_MAIN_WARNING=$branch"
	exit 3
}

# Check if task is claimed by someone else via TODO.md assignee: field (t165).
# Arguments: $1=current_branch
# Outputs a warning if claimed by another identity.
_check_task_assignee() {
	local branch="$1"

	local task_id_from_branch
	task_id_from_branch=$(echo "$branch" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || true)
	[[ -z "$task_id_from_branch" ]] && return 0

	local project_root
	project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
	local todo_file="$project_root/TODO.md"
	[[ ! -f "$todo_file" ]] && return 0

	local task_line
	task_line=$(grep -E "^\- \[.\] ${task_id_from_branch} " "$todo_file" | head -1 || true)
	local task_assignee
	task_assignee=$(echo "$task_line" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || true)
	[[ -z "$task_assignee" ]] && return 0

	# Must match get_aidevops_identity() in pulse-session-helper.sh
	local my_identity
	my_identity="${AIDEVOPS_IDENTITY:-$(whoami 2>/dev/null || echo unknown)@$(hostname -s 2>/dev/null || echo local)}"
	if [[ "$task_assignee" != "$my_identity" ]]; then
		echo -e "${YELLOW}WARNING${NC}: Task $task_id_from_branch is claimed by assignee:$task_assignee"
	fi
	return 0
}

# =============================================================================
# Main branch-check logic
# =============================================================================

# Guard: not in a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
	echo -e "${YELLOW}Not in a git repository - no worktree check needed${NC}"
	exit 0
fi

# Guard: detached HEAD
current_branch=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "$current_branch" ]]; then
	echo -e "${YELLOW}Detached HEAD state - prefer creating a dedicated worktree before editing${NC}"
	exit 0
fi

# --- Protected branch (main/master) ---
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
	# Loop mode: auto-decide based on file path (preferred) or task description
	[[ "$LOOP_MODE" == "true" ]] && _handle_loop_mode_on_protected "$current_branch"

	# Short-circuit: explicit --file on an allowlisted path is always allowed,
	# regardless of loop-mode or headless state (t1712).
	if [[ -n "$TARGET_FILE" ]] && is_main_allowlisted_path "$TARGET_FILE"; then
		echo -e "${GREEN}OK${NC} - Allowlisted path '$TARGET_FILE' on $current_branch"
		echo "MAIN_ALLOWLISTED=true"
		exit 0
	fi

	# Detect headless mode (GH#4400): workers dispatched without --loop-mode
	# get the interactive prompt and loop forever trying to edit. Detect
	# headless by checking if stdin is not a terminal (no TTY = headless).
	# In headless mode, output a concise machine-readable error and exit 2
	# (worktree needed) instead of the verbose interactive prompt.
	if [[ ! -t 0 ]] || [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]]; then
		echo -e "${RED}BLOCKED${NC}: Canonical repo directory is on protected '$current_branch'; move code edits into a linked worktree."
		echo "HEADLESS_BLOCKED=true"
		echo "ACTION_REQUIRED=create_worktree"
		echo "HINT: Use --loop-mode --file 'path' or --loop-mode --task 'description' to auto-create a worktree,"
		echo "or dispatch with --dir pointing to an existing worktree, not the main repo."
		exit 2
	fi

	# Interactive mode: show warning and exit
	_show_protected_branch_warning "$current_branch"
fi

# --- Feature branch (not main/master) ---

# Determine if this is the main worktree (canonical repo directory) or a linked worktree
git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
git_dir=$(git rev-parse --git-dir 2>/dev/null)

is_main_worktree=false
if [[ "$git_dir" == "$git_common_dir" ]] || [[ "$git_dir" == ".git" ]]; then
	is_main_worktree=true
fi

# Sync terminal tab title with repo/branch (silent, non-blocking)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

if [[ -x "$SCRIPT_DIR/terminal-title-helper.sh" ]]; then
	"$SCRIPT_DIR/terminal-title-helper.sh" sync 2>/dev/null || true
fi

# Sync OpenCode session title with current branch (silent, non-blocking).
# Only runs inside OpenCode sessions; helper resolves target session by cwd.
if [[ "${OPENCODE:-}" == "1" ]] && [[ -x "$SCRIPT_DIR/session-rename-helper.sh" ]]; then
	"$SCRIPT_DIR/session-rename-helper.sh" sync-branch >/dev/null 2>&1 || true
fi

# Linked worktree ownership gate (GH#14413 hardening):
# exactly one active session/process may hold a writable worktree at a time.
worktree_path=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
worktree_owner_pid="${OPENCODE_PID:-${PRE_EDIT_OWNER_PID:-${PPID:-$$}}}"
worktree_owner_session="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

if declare -f claim_worktree_ownership >/dev/null 2>&1; then
	if ! claim_worktree_ownership "$worktree_path" "$current_branch" --owner-pid "$worktree_owner_pid" --session "$worktree_owner_session"; then
		owner_info=$(check_worktree_owner "$worktree_path" 2>/dev/null || true)
		owner_pid="unknown"
		owner_session=""
		owner_created=""
		if [[ -n "$owner_info" ]]; then
			IFS='|' read -r owner_pid owner_session _ _ owner_created <<<"$owner_info"
		fi
		_handle_ownership_conflict "$worktree_path" "$owner_pid" "$owner_session" "$owner_created"
	fi
fi

# Canonical repo directory on a feature branch — warn and offer options
if [[ "$is_main_worktree" == "true" ]]; then
	_handle_main_repo_off_main "$current_branch"
fi

# --- Linked worktree (correct working context) ---

_check_task_assignee "$current_branch"

# Operation verification gate (t1364.3)
if [[ -n "$VERIFY_OP" ]]; then
	run_operation_verification "$VERIFY_OP"
fi

# Session count warning (t1398.4) — non-blocking, informational only
if [[ -x "$SCRIPT_DIR/session-count-helper.sh" ]]; then
	session_warning=$("$SCRIPT_DIR/session-count-helper.sh" check || true)
	if [[ -n "$session_warning" ]]; then
		echo -e "${YELLOW}${session_warning}${NC}"
	fi
fi

# go for it — linked worktree is the correct working context
echo -e "${GREEN}OK${NC} - In linked worktree on ref: ${BOLD}$current_branch${NC}"
exit 0
