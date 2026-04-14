#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# Worktree Ownership Registry (t189)
# SQLite-backed registry that tracks which session/batch owns each worktree.
# Prevents cross-session worktree removal — the root cause of t189.
#
# Extracted from shared-constants.sh to keep that file < 2000 lines.
# Source shared-constants.sh (which sources this file) rather than sourcing
# this file directly — the include guard prevents double-loading.
#
# Available to all scripts that source shared-constants.sh.
#
# Usage: source .agents/scripts/shared-constants.sh
#        # Then call register_worktree, claim_worktree_ownership, etc.

# cool — include guard prevents readonly errors when sourced multiple times
[[ -n "${_SHARED_WORKTREE_REGISTRY_LOADED:-}" ]] && return 0
_SHARED_WORKTREE_REGISTRY_LOADED=1

# =============================================================================
# Worktree Ownership Registry (t189)
# =============================================================================

WORKTREE_REGISTRY_DIR="${WORKTREE_REGISTRY_DIR:-${HOME}/.aidevops/.agent-workspace}"
WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-${WORKTREE_REGISTRY_DIR}/worktree-registry.db}"

# Get the command name (basename) for a given PID.
# Returns empty string if the PID does not exist or info is unavailable.
# Arguments:
#   $1 - PID to inspect
# Returns: command basename on stdout
_get_proc_comm() {
	local pid="${1:-}"
	[[ -z "$pid" ]] && return 0

	local comm=""
	if [[ -r "/proc/$pid/status" ]]; then
		# Linux: read Name field from /proc
		comm=$(awk '/^Name:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
	else
		# macOS/BSD: use ps
		comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ') || comm=""
	fi
	printf '%s' "${comm##*/}"
	return 0
}

# Get the parent PID for a given PID.
# Returns empty string if the PID does not exist or info is unavailable.
# Arguments:
#   $1 - PID to inspect
# Returns: parent PID on stdout
_get_proc_ppid() {
	local pid="${1:-}"
	[[ -z "$pid" ]] && return 0

	local parent_pid=""
	if [[ -r "/proc/$pid/status" ]]; then
		# Linux: read PPid field from /proc
		parent_pid=$(awk '/^PPid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
	else
		# macOS/BSD: use ps
		parent_pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || parent_pid=""
	fi
	printf '%s' "$parent_pid"
	return 0
}

# Check if a command name matches a known AI interactive runtime.
# These are long-lived processes that spawn transient bash subprocesses for tool calls.
# Arguments:
#   $1 - command basename (e.g. ".opencode", "claude", "node")
# Returns: 0 if it is a known AI runtime, 1 otherwise
_is_ai_runtime_comm() {
	local comm="${1:-}"
	case "$comm" in
	# OpenCode runtime (may appear as ".opencode" on Linux)
	opencode | .opencode)
		return 0
		;;
	# Claude Code CLI
	claude | .claude)
		return 0
		;;
	# Node.js-based runtimes (Claude Code, OpenCode web, etc.)
	# Only match if the parent is not itself a shell — node is too generic
	# to match unconditionally, but it is the common wrapper for AI runtimes.
	node | .node)
		return 0
		;;
	esac
	return 1
}

# Check if a command name is a transient shell subprocess.
# Arguments:
#   $1 - command basename
# Returns: 0 if it is a shell, 1 otherwise
_is_shell_comm() {
	local comm="${1:-}"
	case "$comm" in
	bash | sh | dash | zsh | ksh | fish)
		return 0
		;;
	esac
	return 1
}

# Resolve the long-lived process ID that should own a worktree lock.
# Priority:
#   1) Explicit override (first argument)
#   2) OpenCode interactive PID (OPENCODE_PID)
#   3) If PPID is a transient shell whose parent is a known AI runtime,
#      return the AI runtime PID (GH#18090 fix)
#   4) PPID as-is (stable user shell or other long-lived process)
#   5) Current shell PID ($$)
# Returns: PID string on stdout
#
# GH#18090: Interactive sessions (Claude Code, OpenCode) spawn short-lived bash
# subprocesses for tool calls. Registering PPID directly causes stale registry
# entries because the bash process exits immediately after the tool call.
# We check one level up: if PPID is a shell AND its parent is a known AI runtime,
# use the AI runtime PID. This avoids collapsing independent user shell sessions
# (e.g. multiple tmux panes) under a single parent PID.
_resolve_worktree_owner_pid() {
	local explicit_pid="${1:-}"
	if [[ -n "$explicit_pid" ]]; then
		printf '%s' "$explicit_pid"
		return 0
	fi

	if [[ -n "${OPENCODE_PID:-}" ]]; then
		printf '%s' "$OPENCODE_PID"
		return 0
	fi

	if [[ -n "${PPID:-}" ]]; then
		# Check if PPID is a transient shell subprocess of a known AI runtime.
		# If so, register the AI runtime PID instead of the short-lived shell.
		local ppid_comm
		ppid_comm=$(_get_proc_comm "$PPID")
		if _is_shell_comm "$ppid_comm"; then
			local grandparent_pid
			grandparent_pid=$(_get_proc_ppid "$PPID")
			if [[ -n "$grandparent_pid" ]] && [[ "$grandparent_pid" -gt 1 ]] 2>/dev/null; then
				local grandparent_comm
				grandparent_comm=$(_get_proc_comm "$grandparent_pid")
				if _is_ai_runtime_comm "$grandparent_comm"; then
					# PPID is a shell spawned by an AI runtime — use the runtime PID
					printf '%s' "$grandparent_pid"
					return 0
				fi
			fi
		fi
		# PPID is not a transient AI-runtime shell — use it as-is
		printf '%s' "$PPID"
		return 0
	fi

	printf '%s' "$$"
	return 0
}

# SQL-escape a value for SQLite (double single quotes)
_wt_sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
}

# Normalize a filesystem path to a stable absolute form.
# This prevents duplicate registry rows for equivalent paths
# such as /var/... vs /private/var/... on macOS.
_wt_normalize_path() {
	local raw_path="$1"
	if [[ -z "$raw_path" ]]; then
		printf '%s' ""
		return 0
	fi

	local normalized=""
	if command -v python3 >/dev/null 2>&1; then
		normalized=$(
			python3 - "$raw_path" <<'PY' 2>/dev/null || true
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
		)
	fi

	if [[ -z "$normalized" ]]; then
		if [[ -d "$raw_path" ]]; then
			normalized=$(cd "$raw_path" 2>/dev/null && pwd -P) || normalized="$raw_path"
		else
			normalized="$raw_path"
		fi
	fi

	printf '%s' "$normalized"
	return 0
}

# Resolve the registry key for a worktree path.
# If a legacy non-normalized row already exists for an equivalent path,
# return that stored key so ownership checks remain backward compatible.
# Otherwise return the normalized path.
_wt_registry_lookup_path() {
	local requested_path="$1"
	local normalized
	normalized=$(_wt_normalize_path "$requested_path")

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
		printf '%s' "$normalized"
		return 0
	}

	local stored_path=""
	while IFS= read -r stored_path; do
		[[ -z "$stored_path" ]] && continue
		local stored_normalized
		stored_normalized=$(_wt_normalize_path "$stored_path")
		if [[ "$stored_normalized" == "$normalized" ]]; then
			printf '%s' "$stored_path"
			return 0
		fi
	done < <(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT worktree_path FROM worktree_owners;" 2>/dev/null || true)

	printf '%s' "$normalized"
	return 0
}

# Initialize the registry database
_init_registry_db() {
	mkdir -p "$WORKTREE_REGISTRY_DIR" 2>/dev/null || true
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        CREATE TABLE IF NOT EXISTS worktree_owners (
            worktree_path TEXT PRIMARY KEY,
            branch        TEXT,
            owner_pid     INTEGER,
            owner_session TEXT DEFAULT '',
            owner_batch   TEXT DEFAULT '',
            task_id       TEXT DEFAULT '',
            created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
    " 2>/dev/null || true
	return 0
}

# Register ownership of a worktree
# Arguments:
#   $1 - worktree path (required)
#   $2 - branch name (required)
#   Flags: --task <id>, --batch <id>, --session <id>
register_worktree() {
	local wt_path="$1"
	local branch="$2"
	shift 2

	local task_id="" batch_id="" session_id="" owner_pid_override=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task_id="${2:-}"
			shift 2
			;;
		--batch)
			batch_id="${2:-}"
			shift 2
			;;
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--owner-pid)
			owner_pid_override="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$session_id" ]]; then
		session_id="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
	fi

	local owner_pid
	owner_pid=$(_resolve_worktree_owner_pid "$owner_pid_override")

	_init_registry_db
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	sqlite3 "$WORKTREE_REGISTRY_DB" "
        INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session, owner_batch, task_id)
        VALUES
		 ('$(_wt_sql_escape "$wt_path")',
		  '$(_wt_sql_escape "$branch")',
		  ${owner_pid},
		  '$(_wt_sql_escape "$session_id")',
		  '$(_wt_sql_escape "$batch_id")',
		  '$(_wt_sql_escape "$task_id")');
    " 2>/dev/null || true
	return 0
}

# Claim ownership of a worktree without overwriting another live owner.
# Arguments:
#   $1 - worktree path (required)
#   $2 - branch name (required)
#   Flags: --task <id>, --batch <id>, --session <id>, --owner-pid <pid>
# Returns:
#   0 - ownership acquired or already held by this owner_pid
#   1 - another live owner currently holds the worktree
claim_worktree_ownership() {
	local wt_path="$1"
	local branch="$2"
	shift 2

	local task_id="" batch_id="" session_id="" owner_pid_override=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task_id="${2:-}"
			shift 2
			;;
		--batch)
			batch_id="${2:-}"
			shift 2
			;;
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--owner-pid)
			owner_pid_override="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$session_id" ]]; then
		session_id="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
	fi

	local owner_pid
	owner_pid=$(_resolve_worktree_owner_pid "$owner_pid_override")

	_init_registry_db
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	local existing_owner_pid
	existing_owner_pid=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")

	if [[ -n "$existing_owner_pid" ]] && [[ "$existing_owner_pid" != "$owner_pid" ]]; then
		if ! kill -0 "$existing_owner_pid" 2>/dev/null; then
			unregister_worktree "$wt_path"
		fi
	fi

	sqlite3 "$WORKTREE_REGISTRY_DB" "
        INSERT OR IGNORE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session, owner_batch, task_id)
        VALUES
            ('$(_wt_sql_escape "$wt_path")',
             '$(_wt_sql_escape "$branch")',
             ${owner_pid},
             '$(_wt_sql_escape "$session_id")',
             '$(_wt_sql_escape "$batch_id")',
             '$(_wt_sql_escape "$task_id")');
    " 2>/dev/null || true

	local final_owner_pid
	final_owner_pid=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")

	if [[ "$final_owner_pid" == "$owner_pid" ]]; then
		sqlite3 "$WORKTREE_REGISTRY_DB" "
            UPDATE worktree_owners
            SET branch = '$(_wt_sql_escape "$branch")',
                owner_session = '$(_wt_sql_escape "$session_id")',
                owner_batch = '$(_wt_sql_escape "$batch_id")',
                task_id = '$(_wt_sql_escape "$task_id")'
            WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
        " 2>/dev/null || true
		return 0
	fi

	return 1
}

# Unregister ownership of a worktree
# Arguments:
#   $1 - worktree path (required)
unregister_worktree() {
	local wt_path="$1"

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || true
	return 0
}

# Check who owns a worktree
# Arguments:
#   $1 - worktree path
# Output: owner info (pid|session|batch|task|created_at) or empty
# Returns: 0 if owned, 1 if not owned
check_worktree_owner() {
	local wt_path="$1"

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	local owner_info
	owner_info=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid, owner_session, owner_batch, task_id, created_at
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")

	if [[ -n "$owner_info" ]]; then
		echo "$owner_info"
		return 0
	fi
	return 1
}

# Check if a worktree is owned by a DIFFERENT process (still alive)
# Arguments:
#   $1 - worktree path
# Returns: 0 if owned by another live process, 1 if safe to remove
is_worktree_owned_by_others() {
	local wt_path="$1"

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	local owner_pid
	owner_pid=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")

	# No owner registered
	[[ -z "$owner_pid" ]] && return 1

	# We own it
	[[ "$owner_pid" == "$$" ]] && return 1

	# Owner process is dead — stale entry, safe to remove
	if ! kill -0 "$owner_pid" 2>/dev/null; then
		# Clean up stale entry
		unregister_worktree "$wt_path"
		return 1
	fi

	# Owner process is alive and it's not us — NOT safe to remove
	return 0
}

# Prune stale registry entries (dead PIDs, missing directories, corrupted paths)
# (t197) Enhanced to handle:
#   - Dead PIDs with missing directories
#   - Paths with ANSI escape codes (corrupted entries)
#   - Test artifacts in /tmp or /var/folders
prune_worktree_registry() {
	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0

	local pruned_count=0

	# First, delete entries with ANSI escape codes (corrupted entries)
	# These often have newlines and break normal parsing
	local ansi_count
	ansi_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners 
        WHERE worktree_path LIKE '%'||char(27)||'%' 
           OR worktree_path LIKE '%[0;%'
           OR worktree_path LIKE '%[1m%';
        SELECT changes();
    " 2>/dev/null || echo "0")
	pruned_count=$((pruned_count + ansi_count))
	[[ -n "${VERBOSE:-}" && "$ansi_count" -gt 0 ]] && echo "  Pruned $ansi_count entries with ANSI escape codes"

	# Next, delete test artifacts in temp directories
	local temp_count
	temp_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners 
        WHERE worktree_path LIKE '/tmp/%' 
           OR worktree_path LIKE '/var/folders/%';
        SELECT changes();
    " 2>/dev/null || echo "0")
	pruned_count=$((pruned_count + temp_count))
	[[ -n "${VERBOSE:-}" && "$temp_count" -gt 0 ]] && echo "  Pruned $temp_count test artifacts in temp directories"

	# Now process remaining entries for dead PIDs and missing directories
	local entries
	entries=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
        SELECT worktree_path, owner_pid FROM worktree_owners;
    " 2>/dev/null || echo "")

	if [[ -n "$entries" ]]; then
		while IFS='|' read -r wt_path owner_pid; do
			local should_prune=false
			local prune_reason=""

			# Directory no longer exists
			if [[ ! -d "$wt_path" ]]; then
				should_prune=true
				prune_reason="directory missing"
			# Owner process is dead (only prune if directory also missing)
			elif [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null && [[ ! -d "$wt_path" ]]; then
				should_prune=true
				prune_reason="dead PID and directory missing"
			fi

			if [[ "$should_prune" == "true" ]]; then
				unregister_worktree "$wt_path"
				((++pruned_count))
				[[ -n "${VERBOSE:-}" ]] && echo "  Pruned: $wt_path ($prune_reason)"
			fi
		done <<<"$entries"
	fi

	[[ -n "${VERBOSE:-}" ]] && echo "Pruned $pruned_count entries total"
	return 0
}
