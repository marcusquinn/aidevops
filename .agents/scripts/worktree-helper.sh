#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155

# =============================================================================
# Git Worktree Helper Script
# =============================================================================
# Manage multiple working directories for parallel branch work.
# Each worktree is an independent directory on a different branch,
# sharing the same git database.
#
# Usage:
#   worktree-helper.sh <command> [options]
#
# Commands:
#   add <branch> [path] [--issue NNN] [--base REF]  Create worktree for branch (auto-names path)
#   list                   List all worktrees with status
#   remove <path|branch>   Remove a worktree
#   status                 Show current worktree info
#   switch <branch>        Open/create worktree for branch (prints path)
#   clean [--auto] [--force-merged]  Remove worktrees for merged branches
#   help                   Show this help
#
# Examples:
#   worktree-helper.sh add feature/auth
#   worktree-helper.sh switch bugfix/login
#   worktree-helper.sh list
#   worktree-helper.sh remove feature/auth
#   worktree-helper.sh clean
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# t2559: canonical-guard-helper.sh provides is_registered_canonical,
# assert_git_available, assert_main_worktree_sane. Sourced after
# shared-constants.sh so its fallback colour vars are available if this
# module is loaded standalone. Guarded in case older deployments lack
# the helper — sourcing errors fail open (guards become no-ops).
if [[ -f "${SCRIPT_DIR}/canonical-guard-helper.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/canonical-guard-helper.sh"
fi

# t2976: canonical audit logger for worktree-removal events (removed / skipped).
# Fallback definitions guard against set -u failures when the helper is absent
# (e.g. older deployments). The source block below overrides these when the file exists.
# The stub uses command -v so it is only defined when the real function is not yet
# loaded — prevents unconditional overwrite when audit-worktree-removal-helper.sh was
# already sourced by a caller (e.g. pulse-cleanup.sh) before worktree-helper.sh is
# re-sourced; the double-source guard in that helper would otherwise prevent restore.
_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
command -v log_worktree_removal_event >/dev/null 2>&1 || log_worktree_removal_event() { :; }
if [[ -f "${SCRIPT_DIR}/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
fi
# Caller ID used in every log_worktree_removal_event call below (avoids repeated literals).
_WTAR_WH_CALLER="worktree-helper.sh"

set -euo pipefail

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# nice — ownership registry functions are centralised in shared-constants.sh (t189):
#   register_worktree, unregister_worktree, check_worktree_owner,
#   is_worktree_owned_by_others, prune_worktree_registry

# =============================================================================
# Localdev Integration (t1224.8)
# =============================================================================
# When a worktree is created for a localdev-registered project, auto-create
# a branch subdomain route (e.g., feature-xyz.myapp.local) and output the URL.
# When a worktree is removed, auto-clean the corresponding branch route.

readonly LOCALDEV_PORTS_FILE="$HOME/.local-dev-proxy/ports.json"
readonly LOCALDEV_HELPER="${SCRIPT_DIR}/localdev-helper.sh"

# =============================================================================
# Preview Proxy Integration (GH#21560)
# =============================================================================
# Per-worktree preview subdomains via local proxy. On worktree add, allocate a
# port + register a proxy route. On remove, free the port + deregister. Both
# best-effort, non-fatal — missing helper or config → silent skip.
readonly PREVIEW_PROXY_HELPER="${SCRIPT_DIR}/preview-proxy-helper.sh"

# Detect if the current repo is registered as a localdev project.
# Matches repo directory name against registered app names in ports.json.
# Outputs the app name if found, empty string otherwise.
detect_localdev_project() {
	local repo_root="${1:-}"
	[[ -z "$repo_root" ]] && repo_root="$(get_repo_root)"
	[[ -z "$repo_root" ]] && return 1

	# ports.json must exist
	[[ ! -f "$LOCALDEV_PORTS_FILE" ]] && return 1

	# localdev-helper.sh must exist
	[[ ! -x "$LOCALDEV_HELPER" ]] && return 1

	local repo_name
	repo_name="$(basename "$repo_root")"

	# Strip worktree suffix to get the base repo name
	# Worktree paths: ~/Git/{repo}-{branch-slug} → extract {repo}
	# Main repo paths: ~/Git/{repo} → use as-is
	local base_name="$repo_name"
	# If this is a worktree (has .git file, not directory), find the main repo name
	if [[ -f "$repo_root/.git" ]]; then
		local main_worktree
		main_worktree="$(git -C "$repo_root" worktree list --porcelain | head -1 | cut -d' ' -f2-)"
		if [[ -n "$main_worktree" ]]; then
			base_name="$(basename "$main_worktree")"
		fi
	fi

	# Check if this repo name is registered in ports.json
	if command -v jq >/dev/null 2>&1; then
		local match
		match="$(jq -r --arg n "$base_name" '.apps[$n] // empty | .domain // empty' "$LOCALDEV_PORTS_FILE" 2>/dev/null)"
		if [[ -n "$match" ]]; then
			echo "$base_name"
			return 0
		fi
	else
		# Fallback: grep-based check
		if grep -qF "\"$base_name\"" "$LOCALDEV_PORTS_FILE" 2>/dev/null; then
			echo "$base_name"
			return 0
		fi
	fi

	return 1
}

# Auto-create localdev branch route after worktree creation.
# Called from cmd_add after successful worktree creation.
# If the project is not registered, auto-registers it first (t1424.1).
localdev_auto_branch() {
	local branch="$1"
	local project

	# Check if localdev-helper.sh exists
	[[ ! -x "$LOCALDEV_HELPER" ]] && return 0

	if ! project="$(detect_localdev_project)" || [[ -z "$project" ]]; then
		# Project not registered — try to auto-register (t1424.1)
		# Delegate name inference to localdev-helper.sh to avoid logic duplication
		local inferred_name=""
		inferred_name="$("$LOCALDEV_HELPER" infer-name "$(get_repo_root)" 2>/dev/null)" || true
		[[ -z "$inferred_name" ]] && return 0

		echo ""
		echo -e "${BLUE}Localdev integration: auto-registering project '$inferred_name'...${NC}"
		if "$LOCALDEV_HELPER" add "$inferred_name" 2>&1; then
			project="$inferred_name"
		else
			echo -e "${YELLOW}Localdev auto-registration failed (non-fatal)${NC}"
			return 0
		fi
	fi

	echo ""
	echo -e "${BLUE}Localdev integration: creating branch route for $project...${NC}"
	if "$LOCALDEV_HELPER" branch "$project" "$branch" 2>&1; then
		return 0
	else
		echo -e "${YELLOW}Localdev branch route creation failed (non-fatal)${NC}"
		return 0
	fi
}

# Auto-remove localdev branch route when worktree is removed.
# Called from cmd_remove after successful worktree removal.
localdev_auto_branch_rm() {
	local branch="$1"
	local project
	project="$(detect_localdev_project)" || return 0

	echo ""
	echo -e "${BLUE}Localdev integration: removing branch route for $project/$branch...${NC}"
	"$LOCALDEV_HELPER" branch rm "$project" "$branch" 2>&1 ||
		echo -e "${YELLOW}Localdev branch route removal failed (non-fatal)${NC}"
	return 0
}

# =============================================================================
# Preview Proxy Integration Functions (GH#21560)
# =============================================================================

# Auto-allocate a preview port + register proxy route after worktree creation.
# Called from cmd_add. Non-fatal — missing helper → silent skip.
preview_proxy_auto_allocate() {
	local branch="$1"
	[[ ! -x "$PREVIEW_PROXY_HELPER" ]] && return 0

	# Determine repo slug from git remote
	local repo_slug=""
	repo_slug="$(git remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')" || repo_slug=""
	[[ -z "$repo_slug" ]] && return 0

	local alloc_json=""
	alloc_json="$("$PREVIEW_PROXY_HELPER" allocate "$repo_slug" "$branch" 2>/dev/null)" || {
		# Non-fatal: allocation failed (no jq, no free ports, etc.)
		return 0
	}

	if [[ -n "$alloc_json" ]] && command -v jq >/dev/null 2>&1; then
		local port url hint
		port="$(echo "$alloc_json" | jq -r '.port // empty' 2>/dev/null)" || port=""
		url="$(echo "$alloc_json" | jq -r '.url // empty' 2>/dev/null)" || url=""
		hint="$(echo "$alloc_json" | jq -r '.start_hint // empty' 2>/dev/null)" || hint=""

		if [[ -n "$port" ]]; then
			echo ""
			echo -e "${BLUE}Preview proxy: port ${port} allocated${NC}"
			[[ -n "$url" ]] && echo -e "  Preview:  ${BOLD}${url}${NC}"
			[[ -n "$hint" ]] && echo -e "  Start:    ${hint}"
		fi
	fi
	return 0
}

# Auto-free a preview port + deregister proxy route on worktree removal.
# Called from _remove_cleanup_and_execute. Non-fatal — missing helper → silent skip.
preview_proxy_auto_free() {
	local branch="$1"
	[[ ! -x "$PREVIEW_PROXY_HELPER" ]] && return 0

	local repo_slug=""
	repo_slug="$(git remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')" || repo_slug=""
	[[ -z "$repo_slug" ]] && return 0

	"$PREVIEW_PROXY_HELPER" free "$repo_slug" "$branch" 2>/dev/null || true
	return 0
}

# Get repo info
get_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
}

# Get the repository name (basename of the repo root directory).
get_repo_name() {
	local root
	root=$(get_repo_root)
	if [[ -n "$root" ]]; then
		basename "$root"
	fi
}

# Get the current branch name, or empty string if detached/unavailable.
get_current_branch() {
	git branch --show-current 2>/dev/null || echo ""
}

# Get the default branch (main or master) (GH#3797)
# Checks all remotes for HEAD, preferring origin first.
get_default_branch() {
	# Try origin first, then any other remote HEAD
	local default_branch=""
	local remote
	default_branch=$(git symbolic-ref "refs/remotes/origin/HEAD" 2>/dev/null | sed 's@^refs/remotes/origin/@@')
	if [[ -n "$default_branch" ]]; then
		echo "$default_branch"
		return 0
	fi
	for remote in $(git remote 2>/dev/null); do
		[[ "$remote" == "origin" ]] && continue
		default_branch=$(git symbolic-ref "refs/remotes/${remote}/HEAD" 2>/dev/null | sed "s@^refs/remotes/${remote}/@@")
		if [[ -n "$default_branch" ]]; then
			echo "$default_branch"
			return 0
		fi
	done

	# Fallback: check if main or master exists
	if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
		echo "main"
	elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
		echo "master"
	else
		# Last resort default
		echo "main"
	fi
}

# Check if the current directory is the main (non-linked) worktree.
# Returns 0 if main worktree, 1 if linked worktree.
is_main_worktree() {
	local git_dir
	git_dir=$(git rev-parse --git-dir 2>/dev/null)
	# Main worktree has .git as a directory, linked worktrees have .git as a file
	[[ -d "$git_dir" ]] && [[ "$git_dir" == ".git" || "$git_dir" == "$(get_repo_root)/.git" ]]
}

# Get the remote name for a branch (from git config or remote-tracking refs).
# Outputs the remote name (e.g., "origin", "upstream") or empty string if none.
# Prefers the configured upstream remote; falls back to scanning all remotes.
_get_branch_remote() {
	local branch="$1"
	# Prefer configured upstream
	local configured_remote
	configured_remote=$(git config "branch.$branch.remote" 2>/dev/null || echo "")
	if [[ -n "$configured_remote" ]]; then
		echo "$configured_remote"
		return 0
	fi
	# Fallback: prefer origin before checking other remotes for predictability
	local ref
	ref=$(git for-each-ref --format='%(refname)' "refs/remotes/origin/$branch" 2>/dev/null)
	if [[ -z "$ref" ]]; then
		ref=$(git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | head -1)
	fi
	if [[ -n "$ref" ]]; then
		# Extract remote name from refs/remotes/<remote>/<branch>
		local remote_name
		remote_name="${ref#refs/remotes/}"
		remote_name="${remote_name%%/*}"
		echo "$remote_name"
		return 0
	fi
	return 1
}

# Check if a branch exists on any remote.
# Returns 0 (true) if refs/remotes/<any>/<branch> exists, 1 otherwise.
_branch_exists_on_any_remote() {
	local branch="$1"
	git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | grep -q .
}

# Check if a branch was ever pushed to remote
# Returns 0 (true) if branch has upstream or remote tracking
# Returns 1 (false) if branch was never pushed
branch_was_pushed() {
	local branch="$1"
	# Has upstream configured
	if git config "branch.$branch.remote" &>/dev/null; then
		return 0
	fi
	# Has remote tracking branch on any remote (not just origin)
	if git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | grep -q .; then
		return 0
	fi
	return 1
}

# Check if a stale remote branch exists for a branch name (t1060, GH#3797)
# A "stale remote" means refs/remotes/<remote>/$branch exists but no local branch does.
# This typically happens when a branch was merged via PR (remote deleted) but the
# local remote-tracking ref wasn't pruned, or when re-using a branch name.
# Checks all remotes, not just origin.
# Returns 0 if stale remote exists, 1 otherwise.
# Outputs: "<remote>|merged" or "<remote>|unmerged".
check_stale_remote_branch() {
	local branch="$1"

	# Only relevant if no local branch exists but remote ref does
	if branch_exists "$branch"; then
		return 1
	fi

	# Find the remote that has this branch (check all remotes, not just origin)
	local ref
	ref=$(git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | head -1)
	if [[ -z "$ref" ]]; then
		return 1
	fi

	# Extract remote name from refs/remotes/<remote>/<branch>
	local stale_remote
	stale_remote="${ref#refs/remotes/}"
	stale_remote="${stale_remote%%/*}"

	# Remote ref exists without a local branch — check if it's merged
	local default_branch
	default_branch=$(get_default_branch)
	if git branch -r --merged "$default_branch" 2>/dev/null | grep -q "${stale_remote}/$branch$"; then
		echo "${stale_remote}|merged"
	else
		echo "${stale_remote}|unmerged"
	fi
	return 0
}

# Delete a stale remote ref and prune local tracking ref (GH#3797)
# Internal helper to avoid repeating the same 3-line pattern
# Args: $1=branch, $2=message, $3=remote (defaults to "origin")
_delete_stale_remote_ref() {
	local branch="$1"
	local message="$2"
	local remote="${3:-origin}"

	echo -e "${BLUE}${message}${NC}"
	git push "$remote" --delete "$branch" 2>/dev/null || true
	git fetch --prune "$remote" 2>/dev/null || true
	echo -e "${GREEN}Deleted ${remote}/$branch${NC}"
}

# Handle a merged stale remote branch (interactive or headless).
# Args: $1=branch, $2=stale_remote, $3=remote_commit
# Returns 0 to proceed, 1 to abort.
_handle_stale_merged() {
	local branch="$1"
	local stale_remote="$2"
	local remote_commit="$3"

	echo -e "${YELLOW}Stale remote branch detected: ${stale_remote}/$branch (already merged)${NC}"
	echo -e "  Last commit: $remote_commit"

	if [[ -t 0 ]]; then
		echo ""
		echo -e "Options:"
		echo -e "  1) Delete stale remote ref and continue (recommended)"
		echo -e "  2) Continue without deleting"
		echo -e "  3) Abort"
		read -rp "Choice [1]: " choice
		choice="${choice:-1}"
		case "$choice" in
		1) _delete_stale_remote_ref "$branch" "Deleting stale remote ref..." "$stale_remote" ;;
		2) echo -e "${YELLOW}Proceeding without deleting stale remote${NC}" ;;
		3)
			echo -e "${RED}Aborted${NC}"
			return 1
			;;
		*)
			echo -e "${RED}Invalid choice, aborting${NC}"
			return 1
			;;
		esac
	else
		# go for it — headless mode can safely auto-delete merged stale refs
		_delete_stale_remote_ref "$branch" "Headless mode: auto-deleting merged stale remote ref..." "$stale_remote"
	fi

	return 0
}

# Handle an unmerged stale remote branch (interactive or headless).
# Args: $1=branch, $2=stale_remote, $3=remote_commit
# Returns 0 to proceed, 1 to abort.
_handle_stale_unmerged() {
	local branch="$1"
	local stale_remote="$2"
	local remote_commit="$3"

	echo -e "${RED}Stale remote branch detected: ${stale_remote}/$branch (NOT merged)${NC}"
	echo -e "  Last commit: $remote_commit"

	if [[ -t 0 ]]; then
		echo ""
		echo -e "Options:"
		echo -e "  1) Delete stale remote ref and continue (${RED}unmerged changes will be lost on remote${NC})"
		echo -e "  2) Continue without deleting (new branch will diverge from stale remote)"
		echo -e "  3) Abort"
		read -rp "Choice [3]: " choice
		choice="${choice:-3}"
		case "$choice" in
		1) _delete_stale_remote_ref "$branch" "Deleting stale remote ref..." "$stale_remote" ;;
		2) echo -e "${YELLOW}Proceeding without deleting stale remote${NC}" ;;
		3)
			echo -e "${RED}Aborted${NC}"
			return 1
			;;
		*)
			echo -e "${RED}Invalid choice, aborting${NC}"
			return 1
			;;
		esac
	else
		# Headless: warn but proceed — don't delete unmerged work
		echo -e "${YELLOW}Headless mode: proceeding without deleting (unmerged remote preserved)${NC}"
		echo -e "${YELLOW}New local branch will diverge from stale remote ref${NC}"
	fi

	return 0
}

# Handle stale remote branch before creating a new local branch (t1060)
# In interactive mode: warns user and offers to delete.
# In headless mode (no tty): auto-deletes if merged, warns and proceeds if unmerged.
# Returns 0 to proceed with branch creation, 1 to abort.
handle_stale_remote_branch() {
	local branch="$1"
	local stale_result

	stale_result=$(check_stale_remote_branch "$branch") || return 0

	# Parse "remote|status" from check_stale_remote_branch
	local stale_remote="${stale_result%%|*}"
	local stale_status="${stale_result##*|}"

	local remote_commit
	remote_commit=$(git rev-parse --short "refs/remotes/${stale_remote}/$branch" 2>/dev/null || echo "unknown")

	if [[ "$stale_status" == "merged" ]]; then
		_handle_stale_merged "$branch" "$stale_remote" "$remote_commit" || return 1
	else
		_handle_stale_unmerged "$branch" "$stale_remote" "$remote_commit" || return 1
	fi

	return 0
}

# Check if worktree has uncommitted changes (GH#3797)
# Excludes aidevops runtime directories that are safe to discard.
# Returns 0 (true) if changes exist OR if git status fails (safety-first:
# treat unknown state as "has changes" to prevent data loss on cleanup).
worktree_has_changes() {
	local worktree_path="$1"
	if [[ -d "$worktree_path" ]]; then
		local status_output
		# Capture git status; if it fails, treat as "has changes" (safety-first)
		if ! status_output=$(git -C "$worktree_path" status --porcelain 2>&1); then
			return 0
		fi
		local changes
		# Exclude aidevops runtime files: .agents/loop-state/, .agents/tmp/, .DS_Store
		# Use literal '??' (not '\?\?') to match git status untracked prefix.
		# Append '|| true' so the pipeline doesn't fail under pipefail when all lines are filtered.
		changes=$(echo "$status_output" |
			grep -v '^?? \.agents/loop-state/' |
			grep -v '^?? \.agents/tmp/' |
			grep -v '^?? \.agents/$' |
			grep -v '^?? \.DS_Store' |
			head -1 || true)
		[[ -n "$changes" ]]
	else
		return 1
	fi
}

# Move a path to the system trash instead of permanently deleting it.
# Prefers: trash (CLI utility, e.g. installed via Homebrew), gio trash (Linux), rm -rf fallback.
# Args: $1=path to trash
# Returns 0 on success, 1 on failure.
#
# t2559 Layer 2: refuses to trash a path registered as a canonical
# repository in ~/.config/aidevops/repos.json. This is the last-line
# defence against the 2026-04-20 incident where an empty main_worktree_path
# derivation caused cmd_clean to sweep canonical alongside orphan worktrees.
trash_path() {
	local target="$1"
	[[ -z "$target" ]] && return 1
	[[ ! -e "$target" ]] && return 0 # Already gone — not an error

	# t2559: never trash a registered canonical repository, no matter how
	# we got here. Fail-safe: on ambiguity (unresolvable path, malformed
	# repos.json, jq missing) the helper returns 0 for empty candidates
	# and 1 for most other "cannot confirm" cases; only a positive match
	# blocks. See canonical-guard-helper.sh for the full semantics.
	if command -v is_registered_canonical >/dev/null 2>&1; then
		if is_registered_canonical "$target"; then
			echo -e "${RED}REFUSED: '$target' is a registered canonical repository — will not trash${NC}" >&2
			return 1
		fi
	fi

	if command -v trash >/dev/null 2>&1; then
		trash "$target" 2>/dev/null && return 0
	fi
	if command -v gio >/dev/null 2>&1; then
		gio trash "$target" 2>/dev/null && return 0
	fi
	# Fallback: permanent delete
	rm -rf "$target" 2>/dev/null && return 0
	return 1
}

# Generate worktree path from branch name
# Pattern: ~/Git/{repo}-{branch-slug}
generate_worktree_path() {
	local branch="$1"
	local repo_name
	repo_name=$(get_repo_name)

	# Convert branch to slug: feature/auth-system -> feature-auth-system
	local slug
	slug=$(echo "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

	# Get parent directory of main repo
	local parent_dir
	parent_dir=$(dirname "$(get_repo_root)")

	echo "${parent_dir}/${repo_name}-${slug}"
}

# Check if branch exists
branch_exists() {
	local branch="$1"
	git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null
}

# Check if worktree exists for branch
worktree_exists_for_branch() {
	local branch="$1"
	git worktree list --porcelain | grep -q "branch refs/heads/$branch$"
}

# Get worktree path for branch
get_worktree_path_for_branch() {
	local branch="$1"
	git worktree list --porcelain | grep -B2 "branch refs/heads/$branch$" | grep "^worktree " | cut -d' ' -f2-
}

# =============================================================================
# COMMANDS
# =============================================================================

# Resolve a remove target (path or branch name) to an absolute worktree path.
# Prints the resolved path on success. Returns 1 with an error message on failure.
_remove_resolve_path() {
	local target="$1"

	if [[ -d "$target" ]]; then
		echo "$target"
		return 0
	fi

	if worktree_exists_for_branch "$target"; then
		get_worktree_path_for_branch "$target"
		return 0
	fi

	echo -e "${RED}Error: No worktree found for '$target'${NC}" >&2
	return 1
}

# Print the ownership error block for cmd_remove when another session owns the worktree.
# Args: $1=path_to_remove
_remove_show_owner_error() {
	local path_to_remove="$1"
	local owner_info
	owner_info=$(check_worktree_owner "$path_to_remove")
	local owner_pid owner_session owner_batch owner_task _
	IFS='|' read -r owner_pid owner_session owner_batch owner_task _ <<<"$owner_info"
	echo -e "${RED}Error: Worktree is owned by another active session${NC}"
	echo -e "  Owner PID:     $owner_pid"
	[[ -n "$owner_session" ]] && echo -e "  Session:       $owner_session"
	[[ -n "$owner_batch" ]] && echo -e "  Batch:         $owner_batch"
	[[ -n "$owner_task" ]] && echo -e "  Task:          $owner_task"
	echo ""
	echo "Use --force to override, or wait for the owning session to finish."
	return 0
}

# t2057 — interactive issue auto-claim from branch name.
# When cmd_add creates a worktree whose branch encodes an issue number AND
# the session is interactive, call interactive-session-helper.sh claim to
# apply status:in-review + self-assign. The label blocks the pulse's
# dispatch-dedup guard so no parallel worker can be dispatched on the same
# issue while the interactive session owns it.
#
# Branch name patterns accepted:
#   <prefix>/gh<NNN>-<rest>       e.g., bugfix/gh18700-foo
#   <prefix>/t<NNN>-<rest>        e.g., feature/t2057-phase2-wire
#   <prefix>/gh<NNN>_<rest>       (underscore separator)
#   <prefix>/t<NNN>_<rest>
#   <prefix>/auto-*-gh<NNN>       e.g., feature/auto-20260419-061301-gh19803
#
# Issue resolution priority (t2260):
#   1. Explicit --issue NNN arg (highest precedence, unambiguous)
#   2. gh<NNN> from branch name (unambiguous)
#   3. t<NNN> from branch name → ref:GH#NNN in TODO.md entry (structured field)
#
# t2260: brief-body scanning REMOVED — greedy #NNN regex on free-form text
# grabbed historical issue references (e.g. #15114 in a Context section)
# instead of the task's intended issue. Only structured sources are used now.
#
# All failure modes are non-blocking — worktree creation proceeds regardless.
_interactive_session_auto_claim() {
	local branch="$1"
	local worktree_path="$2"
	local explicit_issue="${3:-}"  # t2260: --issue NNN takes highest precedence

	# Only engage for interactive sessions — workers handle their own
	# claim flow via dispatch-dedup-helper.sh at dispatch time.
	if [[ -n "${FULL_LOOP_HEADLESS:-}" ]] || [[ -n "${AIDEVOPS_HEADLESS:-}" ]] ||
		[[ -n "${Claude_HEADLESS:-}" ]] || [[ -n "${OPENCODE_HEADLESS:-}" ]] ||
		[[ -n "${GITHUB_ACTIONS:-}" ]]; then
		return 0
	fi
	if [[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "worker" ]]; then
		return 0
	fi
	# Opt-out for scripted bulk worktree operations
	if [[ -n "${AIDEVOPS_SKIP_AUTO_CLAIM:-}" ]]; then
		print_info "AIDEVOPS_SKIP_AUTO_CLAIM set — skipping worktree auto-claim (GH#20146 audit)"
		return 0
	fi

	local issue_num=""

	# t2260: Priority 1 — explicit --issue arg (unambiguous, highest precedence)
	if [[ -n "$explicit_issue" ]]; then
		issue_num="$explicit_issue"
	fi

	# Priority 2 — gh<NNN> from branch name (unambiguous)
	if [[ -z "$issue_num" ]]; then
		if [[ "$branch" =~ /gh([0-9]+)[-_] ]]; then
			issue_num="${BASH_REMATCH[1]}"
		# t2260: also match auto-dispatch branch pattern: auto-*-gh<NNN>
		elif [[ "$branch" =~ -gh([0-9]+)$ ]]; then
			issue_num="${BASH_REMATCH[1]}"
		fi
	fi

	# Priority 3 — t<NNN> from branch → structured ref:GH#NNN in TODO.md
	# t2260: ONLY reads the structured ref:GH#NNN field from the task's own
	# TODO.md line. Does NOT scan brief bodies (too weak — free-form text
	# contains historical issue references that produce false matches).
	if [[ -z "$issue_num" ]]; then
		local task_id=""
		if [[ "$branch" =~ /(t[0-9]+)[-_] ]]; then
			task_id="${BASH_REMATCH[1]}"
		fi
		if [[ -n "$task_id" ]]; then
			local repo_root=""
			repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
			if [[ -n "$repo_root" && -f "$repo_root/TODO.md" ]]; then
				# Match ONLY the structured ref:GH#NNN field on the task's TODO line
				issue_num=$(grep -E "^- \[.\] ${task_id}\b" "$repo_root/TODO.md" \
					| grep -oE 'ref:GH#[0-9]+' \
					| grep -oE '[0-9]+' \
					| head -1 || true)
			fi
		fi
	fi

	if [[ -z "$issue_num" ]]; then
		return 0
	fi

	# Resolve the repo slug from the git remote
	local slug=""
	slug=$(git -C "$worktree_path" remote get-url origin 2>/dev/null |
		sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	if [[ -z "$slug" ]]; then
		return 0
	fi

	# Locate the helper. Prefer the deployed copy (runtime source of truth);
	# fall back to the in-repo copy when running from the canonical repo
	# before deploy. Silent on missing helper — the Phase 1 AI rule handles
	# the agent-driven path.
	local helper=""
	if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
	elif [[ -x "${SCRIPT_DIR}/interactive-session-helper.sh" ]]; then
		helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	fi

	if [[ -z "$helper" ]]; then
		return 0
	fi

	echo -e "${BLUE}Auto-claiming issue #${issue_num} for interactive session...${NC}"
	"$helper" claim "$issue_num" "$slug" --worktree "$worktree_path" >/dev/null 2>&1 || true
	return 0
}

# Restore gitignored node_modules from the canonical repo into a new worktree.
# Git worktrees only contain tracked files — dirs in .gitignore are missing.
# If .opencode/tool/*.ts imports from node_modules the runtime crashes on
# startup. See pulse-dispatch-worker-launch.sh _dlw_restore_worktree_deps.
_restore_worktree_node_modules() {
	local wt_path="$1"
	local repo_root="$2"

	[[ -n "$repo_root" && -d "$wt_path" ]] || return 0

	local _pkg_file=""
	while IFS= read -r _pkg_file; do
		local _pdir="" _rel=""
		_pdir=$(dirname "$_pkg_file") || continue
		_rel="${_pdir#"$wt_path"}"
		local _src="${repo_root}${_rel}/node_modules"
		local _dst="${wt_path}${_rel}/node_modules"
		if [[ -d "$_src" && ! -d "$_dst" ]]; then
			# t2889: fast_cp uses APFS clonefile / btrfs reflink CoW where
			# available — sub-second copy on macOS, near-zero disk delta.
			fast_cp "$_src" "$_dst" 2>/dev/null || true
		fi
	done < <(find "$wt_path" -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null)
	return 0
}

# t2885: exclude a fresh worktree from macOS Spotlight + Time Machine.
# Backed by .agents/scripts/worktree-exclusions-helper.sh. Best-effort —
# never blocks worktree creation. Silent on missing helper or non-macOS.
_apply_worktree_exclusions() {
	local wt_path="$1"
	[[ -n "$wt_path" && -d "$wt_path" ]] || return 0

	# Prefer deployed copy (runtime source of truth); fall back to in-repo
	# copy when running pre-deploy.
	local helper=""
	if [[ -x "${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh"
	elif [[ -x "${SCRIPT_DIR}/worktree-exclusions-helper.sh" ]]; then
		helper="${SCRIPT_DIR}/worktree-exclusions-helper.sh"
	fi
	[[ -n "$helper" ]] || return 0

	"$helper" apply "$wt_path" >/dev/null 2>&1 || true
	return 0
}

# Print the success banner and editor hints after a worktree is created.
_print_worktree_add_success() {
	local wt_path="$1"
	local branch="$2"

	echo ""
	echo -e "${GREEN}Worktree created successfully!${NC}"
	echo ""
	echo -e "Path: ${BOLD}$wt_path${NC}"
	echo -e "Branch: ${BOLD}$branch${NC}"
	echo ""
	echo "To start working:"
	echo "  cd $wt_path" || exit
	echo ""
	echo "Or open in a new terminal/editor:"
	echo "  code $wt_path        # VS Code"
	echo "  cursor $wt_path      # Cursor"
	echo "  opencode $wt_path    # OpenCode"
	return 0
}

# t2701: Resolve a path to absolute canonical form (resolves symlinks in parent
# via `pwd -P`, handles relative and missing leaf components).
# Prints absolute path on stdout. Always returns 0 — best-effort.
_worktree_resolve_abs_path() {
	local input="$1"
	local parent base abs_parent
	parent="$(dirname -- "$input")"
	base="$(basename -- "$input")"
	if abs_parent="$(cd "$parent" 2>/dev/null && pwd -P)"; then
		if [[ "$base" = "." ]]; then
			printf '%s\n' "$abs_parent"
		else
			printf '%s/%s\n' "${abs_parent%/}" "$base"
		fi
	else
		# Parent does not exist — naive join (best-effort absolute form)
		case "$input" in
			/*) printf '%s\n' "$input" ;;
			*)  printf '%s/%s\n' "$(pwd -P)" "$input" ;;
		esac
	fi
	return 0
}

# t2701: Assert that the requested worktree path is not inside the canonical
# repo working tree. Aborts with a mentoring error on containment.
#
# The helper's `add <branch> [path]` signature does not mirror git's own
# `git worktree add -b <branch> <path> [<base>]` — our second positional is a
# filesystem PATH, not a base branch. Users passing `main` thinking it's a
# base branch silently create a worktree at $CWD/main, nested inside the
# canonical repo (state confusion, cleanup-script blast radius, pull/merge
# inconsistency). This guard rejects that input with a mentoring error.
#
# Env override: AIDEVOPS_WORKTREE_ALLOW_NESTED=1 bypasses the check for rare
# legitimate cases (test fixtures, documented intent).
_cmd_add_assert_path_outside_repo() {
	local path="$1"
	local branch="$2"

	if [[ "${AIDEVOPS_WORKTREE_ALLOW_NESTED:-0}" = "1" ]]; then
		return 0
	fi

	local abs_path abs_repo repo_root
	abs_path="$(_worktree_resolve_abs_path "$path")"
	repo_root="$(get_repo_root)"
	if [[ -z "$repo_root" ]]; then
		# Not in a repo — cmd_add has its own "not in a git repo" check; defer.
		return 0
	fi
	abs_repo="$(cd "$repo_root" && pwd -P)"

	# Containment: abs_path equals repo root OR starts with "$abs_repo/".
	# The trailing '/' on abs_path handles the "equals" case cleanly.
	case "$abs_path/" in
		"$abs_repo"/*) : ;;  # nested
		*)             return 0 ;;  # outside repo, allowed
	esac

	# Mentoring error to stderr
	local parent_dir repo_name slug suggested_path
	parent_dir="$(dirname -- "$abs_repo")"
	repo_name="$(basename -- "$abs_repo")"
	slug="$(echo "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
	suggested_path="${parent_dir}/${repo_name}-${slug}"

	{
		echo -e "${RED}Error: Worktree path '$path' resolves to '$abs_path',${NC}"
		echo -e "${RED}which is inside the canonical repo working tree ('$abs_repo').${NC}"
		echo ""
		echo "Worktrees must live outside the canonical repo to prevent git state"
		echo "confusion (cleanup scripts, git status ambiguity, pull/merge blast radius)."
		echo ""
		echo "If you meant to branch off 'main' (or another base branch), note that"
		echo "the 'path' argument is a FILESYSTEM PATH, not a base branch. Options:"
		echo ""
		echo "  - Omit [path] for auto-generated sibling path:"
		echo "      worktree-helper.sh add $branch"
		echo ""
		echo "  - Pass an explicit path OUTSIDE the repo:"
		echo "      worktree-helper.sh add $branch $suggested_path"
		echo ""
		echo "The created worktree branches from HEAD automatically; you do not"
		echo "need to specify a base branch."
		echo ""
		echo "(Override: AIDEVOPS_WORKTREE_ALLOW_NESTED=1 — use only with a documented"
		echo "reason for a nested worktree.)"
	} >&2
	return 1
}

# Parse cmd_add arguments: positional (branch, path) + optional flags.
# Sets global _ADD_BRANCH, _ADD_PATH, _ADD_ISSUE, _ADD_BASE. Returns 1 on parse error.
# Extracted from cmd_add (t2260) to keep function bodies under 100 lines.
# --base <ref> (t2802): explicit base for new branch creation. Default is
# origin/<default_branch> — prevents scope-leak PRs when canonical HEAD is stale.
_parse_cmd_add_args() {
	_ADD_BRANCH=""
	_ADD_PATH=""
	_ADD_ISSUE=""
	_ADD_BASE=""
	local _arg=""
	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
			--issue)
				local _next="${2:-}"
				if [[ -z "$_next" ]]; then
					echo -e "${RED}Error: --issue requires a number${NC}"
					return 1
				fi
				_ADD_ISSUE="$_next"
				shift 2
				;;
			--issue=*)
				_ADD_ISSUE="${_arg#--issue=}"
				shift
				;;
			--base)
				local _next_base="${2:-}"
				if [[ -z "$_next_base" ]]; then
					echo -e "${RED}Error: --base requires a ref (e.g. origin/main, develop, <sha>)${NC}"
					return 1
				fi
				_ADD_BASE="$_next_base"
				shift 2
				;;
			--base=*)
				_ADD_BASE="${_arg#--base=}"
				shift
				;;
			-*)
				echo -e "${RED}Error: Unknown option: $_arg${NC}"
				echo "Usage: worktree-helper.sh add <branch> [path] [--issue NNN] [--base REF]"
				return 1
				;;
			*)
				if [[ -z "$_ADD_BRANCH" ]]; then
					_ADD_BRANCH="$_arg"
				elif [[ -z "$_ADD_PATH" ]]; then
					_ADD_PATH="$_arg"
				fi
				shift
				;;
		esac
	done
	if [[ -z "$_ADD_BRANCH" ]]; then
		echo -e "${RED}Error: Branch name required${NC}"
		echo "Usage: worktree-helper.sh add <branch> [path] [--issue NNN] [--base REF]"
		return 1
	fi
	return 0
}

# Resolve the base ref for a new worktree branch (t2802).
# Precedence:
#   1. Explicit --base <ref> (or AIDEVOPS_WORKTREE_BASE env var) — caller intent wins.
#   2. origin/<default_branch> — safe, matches what the server will merge into.
#   3. Local <default_branch> — fallback when remote-tracking ref missing.
#   4. Empty string — fall through to git's default (HEAD). Caller logs a warning.
#
# Rationale: the pulse calls `worktree-helper.sh add <branch>` from the canonical
# repo's cwd. If the canonical's HEAD is stale (long-lived feature branch,
# unsynced main, post-checkout leftover), `git worktree add -b` inherits that
# state and the resulting PR shows a diff proportional to the canonical's drift.
# Canonical failure: awardsapp#2716 (PR #2733, 100 files for a 2-line fix)
# caused by canonical being on stale `main` while PR target was `develop`.
#
# Args:
#   $1 - explicit_base: value of --base (may be empty)
# Outputs:
#   Resolved ref on stdout, empty string if no safe base could be resolved.
# Returns: always 0.
_resolve_worktree_base_ref() {
	local explicit_base="$1"
	local env_base="${AIDEVOPS_WORKTREE_BASE:-}"

	# 1. Explicit override (flag preferred, env as fallback).
	if [[ -n "$explicit_base" ]]; then
		printf '%s' "$explicit_base"
		return 0
	fi
	if [[ -n "$env_base" ]]; then
		printf '%s' "$env_base"
		return 0
	fi

	# 2. origin/<default>
	local default_branch
	default_branch=$(get_default_branch 2>/dev/null) || default_branch=""
	if [[ -n "$default_branch" ]]; then
		if git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
			printf 'origin/%s' "$default_branch"
			return 0
		fi
		# 3. Local default (no origin tracking — e.g. first push pending, local-only repo).
		if git rev-parse --verify --quiet "refs/heads/${default_branch}" >/dev/null 2>&1; then
			printf '%s' "$default_branch"
			return 0
		fi
	fi

	# 4. No safe base resolved — caller falls back to HEAD and warns.
	printf ''
	return 0
}

# Create the underlying git worktree for cmd_add (extracted t2802 to keep
# cmd_add under 100 lines per the function-complexity gate). Handles both
# existing-branch checkout and new-branch creation with explicit base ref.
#
# Args:
#   $1 - branch name
#   $2 - worktree path (already resolved + validated by caller)
#   $3 - explicit base ref for new-branch path (may be empty)
# Returns: 0 on success, 1 on handle_stale_remote_branch rejection.
_cmd_add_create_worktree() {
	local _branch="$1"
	local _path="$2"
	local _explicit_base="$3"

	if branch_exists "$_branch"; then
		echo -e "${BLUE}Creating worktree for existing branch '$_branch'...${NC}"
		git worktree add "$_path" "$_branch"
		return 0
	fi

	# Branch doesn't exist locally — check for stale remote ref (t1060)
	handle_stale_remote_branch "$_branch" || return 1

	# t2802: explicitly base new branches on origin/<default> (or --base REF)
	# to prevent scope-leak PRs when canonical HEAD is stale. Canonical
	# failure: awardsapp#2716 (PR #2733, 100-file diff for a 2-line fix).
	local _base_ref
	_base_ref=$(_resolve_worktree_base_ref "$_explicit_base")
	if [[ -n "$_base_ref" ]]; then
		echo -e "${BLUE}Creating worktree with new branch '$_branch' based on '$_base_ref'...${NC}"
		git worktree add -b "$_branch" "$_path" "$_base_ref"
		return 0
	fi

	# No remote default and no local default resolved. Surface the
	# degradation loudly — the resulting branch will be based on the
	# canonical's current HEAD which may be stale or unrelated.
	echo -e "${YELLOW}Warning: could not resolve origin/<default> or a local default branch.${NC}" >&2
	echo -e "${YELLOW}  Falling back to canonical HEAD. If this creates an oversized PR,${NC}" >&2
	echo -e "${YELLOW}  re-create the worktree with '--base <ref>' or set AIDEVOPS_WORKTREE_BASE.${NC}" >&2
	echo -e "${BLUE}Creating worktree with new branch '$_branch' (base: HEAD)...${NC}"
	git worktree add -b "$_branch" "$_path"
	return 0
}

cmd_add() {
	_parse_cmd_add_args "$@" || return 1
	local branch="$_ADD_BRANCH"
	local path="$_ADD_PATH"
	local explicit_issue="$_ADD_ISSUE"  # t2260: --issue NNN for unambiguous claim
	local explicit_base="$_ADD_BASE"    # t2802: --base REF for explicit base

	# t2235: Detect self-invented task ID variants (e.g. t2213b, t2213-2, t2213.fix)
	# Task IDs come ONLY from claim-task-id.sh. For follow-ups, claim a fresh ID.
	if [[ "$branch" =~ t[0-9]+[a-z]($|[-_/]) ]] || [[ "$branch" =~ t[0-9]+[-._][0-9]+($|[-_/]) ]]; then
		print_warning "Branch name contains a non-claimed task ID variant ($branch)."
		print_warning "Task IDs come ONLY from claim-task-id.sh. For follow-ups, claim a fresh ID."
		if [[ -t 0 ]]; then # interactive
			read -rp "Continue with this branch name anyway? [y/N] " confirm
			[[ "$confirm" =~ ^[Yy]$ ]] || return 1
		fi
		# headless: warn only, don't block (could be legitimate in rare cases)
	fi

	# Check if we're in a git repo
	if [[ -z "$(get_repo_root)" ]]; then
		echo -e "${RED}Error: Not in a git repository${NC}"
		return 1
	fi

	# Check if worktree already exists for this branch
	if worktree_exists_for_branch "$branch"; then
		local existing_path
		existing_path=$(get_worktree_path_for_branch "$branch")
		echo -e "${YELLOW}Worktree already exists for branch '$branch'${NC}"
		echo -e "Path: ${BOLD}$existing_path${NC}"
		echo ""
		echo "To use it:"
		echo "  cd $existing_path" || exit
		return 0
	fi

	# Generate path if not provided
	if [[ -z "$path" ]]; then
		path=$(generate_worktree_path "$branch")
	fi

	# t2701: Reject user-supplied paths that resolve inside the canonical repo.
	# Catches the common footgun of passing a base-branch name as the path arg
	# (e.g. `add feature/foo main` creating $CWD/main nested inside the repo).
	# Auto-generated paths are siblings of the repo, so this is a no-op for them.
	_cmd_add_assert_path_outside_repo "$path" "$branch" || return 1

	# Check if path already exists
	if [[ -d "$path" ]]; then
		echo -e "${RED}Error: Path already exists: $path${NC}"
		return 1
	fi

	# Create worktree (existing branch → simple checkout; new branch → base-ref dance).
	_cmd_add_create_worktree "$branch" "$path" "$explicit_base" || return 1

	# Register ownership (t189)
	register_worktree "$path" "$branch"

	# Restore gitignored dependencies (node_modules) from canonical repo.
	local _repo_root=""
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || _repo_root=""
	_restore_worktree_node_modules "$path" "$_repo_root"

	# t2885: exclude the new worktree from macOS Spotlight + Time Machine.
	# Worktrees are ephemeral — persistent state lives on the git remote.
	# Best-effort, never fails worktree creation.
	_apply_worktree_exclusions "$path"

	# t2057: interactive issue auto-claim. When the branch name encodes an
	# issue number AND this is an interactive session, immediately apply
	# status:in-review + self-assign so the pulse's dispatch-dedup guard
	# blocks parallel worker dispatch. Silent on failure — the agent-driven
	# contract in prompts/build.txt covers the fallback path. Guard on
	# helper presence so the worktree create works even before Phase 1
	# has been deployed to the running environment.
	# t2260: pass explicit --issue arg if provided for unambiguous claim.
	_interactive_session_auto_claim "$branch" "$path" "$explicit_issue" || true

	_print_worktree_add_success "$path" "$branch"

	# Localdev integration (t1224.8): auto-create branch subdomain route
	localdev_auto_branch "$branch"

	# Preview proxy integration (GH#21560): allocate port + register proxy route
	preview_proxy_auto_allocate "$branch"

	return 0
}

# List all worktrees with branch names, merge status, and current marker.
cmd_list() {
	echo -e "${BOLD}Git Worktrees:${NC}"
	echo ""

	local current_path
	current_path=$(pwd)

	# Parse worktree list
	local worktree_path=""
	local worktree_branch=""
	local is_bare=""

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ "$line" == "bare" ]]; then
			is_bare="true"
		elif [[ -z "$line" ]]; then
			# End of entry, print it
			if [[ -n "$worktree_path" ]]; then
				local marker=""
				if [[ "$worktree_path" == "$current_path" ]]; then
					marker=" ${GREEN}← current${NC}"
				fi

				if [[ "$is_bare" == "true" ]]; then
					echo -e "  ${YELLOW}(bare)${NC} $worktree_path"
				else
					# Check if branch is merged into default branch
					local merged_marker=""
					local default_branch
					default_branch=$(get_default_branch)
					if [[ -n "$worktree_branch" ]] && git branch --merged "$default_branch" 2>/dev/null | grep -q "^\s*$worktree_branch$"; then
						merged_marker=" ${YELLOW}(merged)${NC}"
					fi

					echo -e "  ${BOLD}$worktree_branch${NC}$merged_marker$marker"
					echo -e "    $worktree_path"
				fi
				echo ""
			fi
			worktree_path=""
			worktree_branch=""
			is_bare=""
		fi
	done < <(
		git worktree list --porcelain
		echo ""
	)

	return 0
}

# Validate that a resolved worktree path is safe to remove.
# Checks: not main worktree, not current directory, ownership.
# Args: $1=path_to_remove
# Returns 0 if safe to remove, 1 if blocked.
_remove_validate_path() {
	local path_to_remove="$1"

	# Don't allow removing main worktree
	# NOTE: avoid piping git worktree list through head — with set -o pipefail
	# and many worktrees, head closes the pipe early, git gets SIGPIPE (exit 141),
	# and pipefail propagates the failure causing set -e to abort the script.
	local _porcelain main_worktree
	_porcelain=$(git worktree list --porcelain)
	main_worktree="${_porcelain%%$'\n'*}"      # first line
	main_worktree="${main_worktree#worktree }" # strip prefix
	if [[ "$path_to_remove" == "$main_worktree" ]]; then
		echo -e "${RED}Error: Cannot remove main worktree${NC}"
		return 1
	fi

	# Check if we're currently in the worktree to remove
	if [[ "$(pwd)" == "$path_to_remove"* ]]; then
		echo -e "${RED}Error: Cannot remove worktree while inside it${NC}"
		echo "First: cd $(get_repo_root)" || exit
		return 1
	fi

	# Ownership check (t189): refuse to remove worktrees owned by other sessions
	if is_worktree_owned_by_others "$path_to_remove"; then
		_remove_show_owner_error "$path_to_remove"
		if [[ "${WORKTREE_FORCE_REMOVE:-}" != "true" ]]; then
			# t2976: audit log — removal blocked by ownership registry
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$path_to_remove" "owned-skip"
			return 1
		fi
		echo -e "${YELLOW}--force specified, proceeding with removal${NC}"
	fi

	return 0
}

# Clean up aidevops runtime files and execute the git worktree remove.
# Also handles unregistration and localdev cleanup.
# Args: $1=path_to_remove
# Returns 0 on success, 1 on failure.
_remove_cleanup_and_execute() {
	local path_to_remove="$1"

	# Clean up aidevops runtime files before removal (prevents "contains untracked files" error)
	# Use trash_path for recoverable deletion; fall back to rm -rf if trash unavailable.
	trash_path "$path_to_remove/.agents/loop-state" || true
	trash_path "$path_to_remove/.agents/tmp" || true
	rm -f "$path_to_remove/.agents/.DS_Store" 2>/dev/null || true
	rmdir "$path_to_remove/.agent" 2>/dev/null || true # Only removes if empty

	# Capture branch name before removal for localdev cleanup (t1224.8)
	local removed_branch=""
	removed_branch="$(git -C "$path_to_remove" branch --show-current 2>/dev/null || echo "")"

	echo -e "${BLUE}Removing worktree: $path_to_remove${NC}"
	# Move the worktree directory to trash BEFORE git deregisters it.
	# This makes accidental removal recoverable — the directory survives in trash.
	# git worktree prune then cleans up the now-missing entry from .git/worktrees/.
	if ! trash_path "$path_to_remove"; then
		# trash unavailable or failed — fall back to git worktree remove
		git worktree remove "$path_to_remove" || return 1
	else
		git worktree prune 2>/dev/null || true
	fi

	# Unregister ownership (t189)
	unregister_worktree "$path_to_remove"

	echo -e "${GREEN}Worktree removed successfully${NC}"

	# t2976: audit log — manual removal completed
	log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_WH_CALLER" "$path_to_remove" "manual"

	# Localdev integration (t1224.8): auto-remove branch subdomain route
	if [[ -n "$removed_branch" ]]; then
		localdev_auto_branch_rm "$removed_branch"
	fi

	# Preview proxy integration (GH#21560): free port + deregister proxy route
	if [[ -n "$removed_branch" ]]; then
		preview_proxy_auto_free "$removed_branch"
	fi

	return 0
}

# Remove a worktree by branch name or path, with optional --force.
cmd_remove() {
	local target=""
	local force_remove=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force | -f)
			force_remove=true
			shift
			;;
		*)
			target="$1"
			shift
			;;
		esac
	done

	if [[ -z "$target" ]]; then
		echo -e "${RED}Error: Path or branch name required${NC}"
		echo "Usage: worktree-helper.sh remove <path|branch> [--force]"
		return 1
	fi

	# Export for ownership check
	if [[ "$force_remove" == "true" ]]; then
		export WORKTREE_FORCE_REMOVE="true"
	fi

	# Resolve target to an absolute path
	local path_to_remove
	if ! path_to_remove=$(_remove_resolve_path "$target"); then
		return 1
	fi

	# Validate path is safe to remove
	_remove_validate_path "$path_to_remove" || return 1

	# Clean up runtime files and execute removal
	_remove_cleanup_and_execute "$path_to_remove" || return 1

	return 0
}

# Show status of the current worktree (repo, branch, type, total count).
cmd_status() {
	local repo_root
	repo_root=$(get_repo_root)

	if [[ -z "$repo_root" ]]; then
		echo -e "${RED}Error: Not in a git repository${NC}"
		return 1
	fi

	local current_branch
	current_branch=$(get_current_branch)

	echo -e "${BOLD}Current Worktree Status:${NC}"
	echo ""
	echo -e "  Repository: ${BOLD}$(get_repo_name)${NC}"
	echo -e "  Branch:     ${BOLD}$current_branch${NC}"
	echo -e "  Path:       $(pwd)"

	if is_main_worktree; then
		echo -e "  Type:       ${BLUE}Main worktree${NC}"
	else
		echo -e "  Type:       ${GREEN}Linked worktree${NC}"
	fi

	# Count total worktrees
	local count
	count=$(git worktree list | wc -l | tr -d ' ')
	echo ""
	echo -e "  Total worktrees: $count"

	if [[ "$count" -gt 1 ]]; then
		echo ""
		echo "Run 'worktree-helper.sh list' to see all worktrees"
	fi

	return 0
}

# Switch to a worktree for the given branch, creating one if needed.
cmd_switch() {
	local branch="${1:-}"

	if [[ -z "$branch" ]]; then
		echo -e "${RED}Error: Branch name required${NC}"
		echo "Usage: worktree-helper.sh switch <branch>"
		return 1
	fi

	# Check if worktree exists for this branch
	if worktree_exists_for_branch "$branch"; then
		local path
		path=$(get_worktree_path_for_branch "$branch")
		echo -e "${GREEN}Worktree exists for '$branch'${NC}"
		echo ""
		echo "Path: $path"
		echo ""
		echo "To switch:"
		echo "  cd $path" || exit
		return 0
	fi

	# Create new worktree
	echo -e "${BLUE}No worktree for '$branch', creating one...${NC}"
	cmd_add "$branch"
	return $?
}

# =============================================================================
# Clean Command sub-library (worktree-clean-lib.sh)
# =============================================================================
# shellcheck source=./worktree-clean-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worktree-clean-lib.sh"

# Manage the worktree ownership registry (list or prune stale entries).
cmd_registry() {
	local subcmd="${1:-list}"

	case "$subcmd" in
	list | ls)
		[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
			echo "No registry entries"
			return 0
		}
		echo -e "${BOLD}Worktree Ownership Registry:${NC}"
		echo ""
		local entries
		entries=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
                SELECT worktree_path, branch, owner_pid, owner_session, owner_batch, task_id, created_at
                FROM worktree_owners ORDER BY created_at DESC;
            " 2>/dev/null || echo "")
		if [[ -z "$entries" ]]; then
			echo "  (empty)"
			return 0
		fi
		while IFS='|' read -r wt_path branch pid session batch task created; do
			local alive_status="${RED}dead${NC}"
			if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
				alive_status="${GREEN}alive${NC}"
			fi
			echo -e "  ${BOLD}$branch${NC}"
			echo -e "    Path:    $wt_path"
			echo -e "    PID:     $pid ($alive_status)"
			[[ -n "$session" ]] && echo -e "    Session: $session"
			[[ -n "$batch" ]] && echo -e "    Batch:   $batch"
			[[ -n "$task" ]] && echo -e "    Task:    $task"
			echo -e "    Created: $created"
			echo ""
		done <<<"$entries"
		;;
	prune)
		shift # Remove 'prune' from args
		local verbose=""
		if [[ "${1:-}" == "-v" ]] || [[ "${1:-}" == "--verbose" ]]; then
			verbose="true"
			export VERBOSE="true"
		fi

		[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
			echo "No registry entries to prune"
			return 0
		}

		# Count before pruning
		local before_count
		before_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners;" 2>/dev/null || echo "0")

		echo -e "${BLUE}Pruning stale registry entries...${NC}"
		[[ -n "$verbose" ]] && echo ""
		prune_worktree_registry

		# Count after pruning
		local after_count
		after_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners;" 2>/dev/null || echo "0")
		local pruned=$((before_count - after_count))

		echo -e "${GREEN}Done: pruned $pruned of $before_count entries ($after_count remaining)${NC}"
		;;
	*)
		echo "Usage: worktree-helper.sh registry [list|prune]"
		;;
	esac
	return 0
}

# Print the overview and commands section of the help output.
_help_print_overview_and_commands() {
	cat <<'EOF'
Git Worktree Helper - Parallel Branch Development

OVERVIEW
  Git worktrees allow multiple working directories, each on a different branch,
  sharing the same git database. Perfect for:
  - Multiple terminal tabs on different branches
  - Parallel AI sessions without branch conflicts
  - Quick context switching without stashing

COMMANDS
  add <branch> [path] [--issue NNN] [--base REF]
                         Create worktree for branch
                         Path auto-generated as ~/Git/{repo}-{branch-slug}
                         --issue NNN: explicit issue number for auto-claim (t2260)
                         --base REF:  explicit base for new branch. Default is
                                      origin/<default-branch> (t2802). Also honours
                                      AIDEVOPS_WORKTREE_BASE env var.

  list                   List all worktrees with status

  remove <path|branch> [--force]
                         Remove a worktree (keeps branch)
                         Refuses if owned by another active session (t189)
                         Use --force to override ownership check

  status                 Show current worktree info

  switch <branch>        Get/create worktree for branch (prints path)

  clean [--auto] [--force-merged]
                         Remove worktrees for merged branches
                         --auto: skip confirmation prompt (for automated cleanup)
                         --force-merged: force-remove dirty worktrees when PR is
                           confirmed merged (dirty state = abandoned WIP). Also
                           detects squash merges via gh pr list.
                         Skips worktrees owned by other active sessions (t189)

  registry [list|prune]  View or prune the ownership registry (t189, t197)
                         list: Show all registered worktrees with ownership info
                         prune [-v|--verbose]: Clean dead/corrupted entries:
                           - Dead PIDs with missing directories
                           - Paths with ANSI escape codes
                           - Test artifacts in /tmp or /var/folders

  help                   Show this help

OWNERSHIP SAFETY (t189)
  Worktrees are registered to the creating session's PID. Removal is blocked
  if another session's process is still alive. This prevents cross-session
  worktree removal that destroys another agent's working directory.

  Registry: ~/.aidevops/.agent-workspace/worktree-registry.db

EOF
	return 0
}

# Print the examples, directory structure, and notes sections of the help output.
_help_print_examples_and_notes() {
	cat <<'EOF'
EXAMPLES
  # Start work on a feature (creates worktree)
  worktree-helper.sh add feature/user-auth
  cd ~/Git/myrepo-feature-user-auth || exit

  # Open another terminal for a bugfix
  worktree-helper.sh add bugfix/login-timeout
  cd ~/Git/myrepo-bugfix-login-timeout || exit

  # List all worktrees
  worktree-helper.sh list

  # After merging, clean up
  worktree-helper.sh clean

  # View ownership registry
  worktree-helper.sh registry list

DIRECTORY STRUCTURE
  ~/Git/myrepo/                      # Main worktree (main branch)
  ~/Git/myrepo-feature-user-auth/    # Linked worktree (feature/user-auth)
  ~/Git/myrepo-bugfix-login/         # Linked worktree (bugfix/login)

STALE REMOTE DETECTION (t1060, GH#3797)
  When creating a new branch, the script checks for stale remote refs
  on all configured remotes (not just origin).

  Interactive mode:
    - Merged stale: offers to delete (recommended) or continue
    - Unmerged stale: warns and defaults to abort (data safety)

  Headless mode (no tty):
    - Merged stale: auto-deletes the remote ref and continues
    - Unmerged stale: warns but proceeds without deleting

LOCALDEV INTEGRATION (t1224.8)
  For projects registered with 'localdev add', worktree creation auto-runs
  'localdev branch <project> <branch>' to create a subdomain route
  (e.g., feature-auth.myapp.local). Worktree removal auto-cleans the route.

  Detection: matches repo name against ~/.local-dev-proxy/ports.json
  Requires: localdev-helper.sh in the same scripts directory

NOTES
  - All worktrees share the same .git database (commits, stashes, refs)
  - Each worktree is independent - no branch switching affects others
  - Removing a worktree does NOT delete the branch
  - Main worktree cannot be removed

EOF
	return 0
}

# Display usage information and available commands.
cmd_help() {
	_help_print_overview_and_commands
	_help_print_examples_and_notes
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	add)
		cmd_add "$@"
		;;
	list | ls)
		cmd_list "$@"
		;;
	remove | rm)
		cmd_remove "$@"
		;;
	status | st)
		cmd_status "$@"
		;;
	switch | sw)
		cmd_switch "$@"
		;;
	clean)
		cmd_clean "$@"
		;;
	registry | reg)
		cmd_registry "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo -e "${RED}Unknown command: $command${NC}"
		echo "Run 'worktree-helper.sh help' for usage"
		return 1
		;;
	esac
}

main "$@"
