#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
# =============================================================================
# Worktree Helper -- Path Utilities + cmd_add Sub-Library
# =============================================================================
# Worktree path resolution, trash/cleanup utilities, branch existence checks,
# remove target resolution, interactive auto-claim, and all cmd_add helpers.
#
# Usage: source "${SCRIPT_DIR}/worktree-helper-add.sh"
#
# Dependencies:
#   - shared-constants.sh (colour vars, print_*, register_worktree,
#     unregister_worktree, check_worktree_owner, is_worktree_owned_by_others,
#     prune_worktree_registry)
#   - worktree-helper-git.sh (get_repo_root, get_repo_name, get_default_branch,
#     branch_exists already defined before this file is sourced)
#   - worktree-helper-integration.sh (localdev_auto_branch,
#     preview_proxy_auto_allocate already defined before this file is sourced)
#   - canonical-guard-helper.sh (is_registered_canonical, optional)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_ADD_LIB_LOADED:-}" ]] && return 0
_WORKTREE_ADD_LIB_LOADED=1

# GH#22238: node_modules restore is useful for interactive worktrees but can
# saturate CPU when many pulse precreations run concurrently. Serialize the
# copy path and fail open quickly; workers can still install/fallback later if
# dependency restore is skipped during overload.
: "${WORKTREE_NODE_MODULES_RESTORE_ENABLED:=1}"
: "${WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S:=2}"
: "${WORKTREE_NODE_MODULES_RESTORE_MAX_DIRS:=2}"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Worktree Path Utilities ---

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

# --- Remove Helpers ---

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

# --- Interactive Auto-Claim ---

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

# --- cmd_add Helpers ---

# Restore gitignored node_modules from the canonical repo into a new worktree.
# Git worktrees only contain tracked files — dirs in .gitignore are missing.
# If .opencode/tool/*.ts imports from node_modules the runtime crashes on
# startup. See pulse-dispatch-worker-launch.sh _dlw_restore_worktree_deps.
_restore_worktree_node_modules_lock_dir() {
	local workspace_dir="${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}"
	printf '%s\n' "${workspace_dir}/tmp/worktree-node-modules-restore.lock.d"
	return 0
}

_restore_worktree_node_modules_acquire_lock() {
	local lock_dir="$1"
	local timeout_s="${WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S}"
	local elapsed=0
	[[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=2
	mkdir -p "${lock_dir%/*}" 2>/dev/null || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if [[ -d "$lock_dir" ]]; then
			local lock_mtime now_epoch age_s
			lock_mtime=$(_file_mtime_epoch "$lock_dir")
			now_epoch=$(date +%s)
			age_s=$((now_epoch - lock_mtime))
			if ((age_s > 60)); then
				rmdir "$lock_dir" 2>/dev/null || true
				continue
			fi
		fi
		if ((elapsed >= timeout_s * 10)); then
			return 1
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || true
	return 0
}

_restore_worktree_node_modules_release_lock() {
	local lock_dir="$1"
	rm -f "${lock_dir}/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_restore_worktree_node_modules() {
	local wt_path="$1"
	local repo_root="$2"

	[[ -n "$repo_root" && -d "$wt_path" ]] || return 0
	[[ "$WORKTREE_NODE_MODULES_RESTORE_ENABLED" == "1" ]] || return 0

	local _lock_dir=""
	_lock_dir=$(_restore_worktree_node_modules_lock_dir)
	if ! _restore_worktree_node_modules_acquire_lock "$_lock_dir"; then
		print_warning "Skipping node_modules restore for ${wt_path}: another restore is active"
		return 0
	fi

	local _pkg_file=""
	local _restored=0
	local _max_dirs="$WORKTREE_NODE_MODULES_RESTORE_MAX_DIRS"
	[[ "$_max_dirs" =~ ^[0-9]+$ ]] || _max_dirs=2
	while IFS= read -r _pkg_file; do
		if ((_restored >= _max_dirs)); then
			break
		fi
		local _pdir="" _rel=""
		_pdir=$(dirname "$_pkg_file") || continue
		_rel="${_pdir#"$wt_path"}"
		local _src="${repo_root}${_rel}/node_modules"
		local _dst="${wt_path}${_rel}/node_modules"
		if [[ -d "$_src" && ! -d "$_dst" ]]; then
			# t2889: fast_cp uses APFS clonefile / btrfs reflink CoW where
			# available — sub-second copy on macOS, near-zero disk delta.
			fast_cp "$_src" "$_dst" 2>/dev/null || true
			_restored=$((_restored + 1))
		fi
	done < <(find "$wt_path" -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null)
	_restore_worktree_node_modules_release_lock "$_lock_dir"
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
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
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

# --- cmd_add ---

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
	# contract in AGENTS.md covers the fallback path. Guard on
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
