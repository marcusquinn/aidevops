#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-signature-helper.sh — Generate signature footer for GitHub comments
# =============================================================================
#
# Produces a one-line signature footer for issues, PRs, and comments created
# by aidevops agents. Format:
#
#   ---
#   [OpenCode CLI](https://opencode.ai) v1.3.3, [aidevops.sh](https://aidevops.sh) v3.5.6, anthropic/opus-4-6, 1,234 tokens
#
# Usage:
#   gh-signature-helper.sh generate [--model MODEL] [--tokens N] [--subagent-tokens N] [--cli NAME] [--cli-version VER]
#   gh-signature-helper.sh footer   [--model MODEL] [--tokens N] [--subagent-tokens N] [--cli NAME] [--cli-version VER]
#   gh-signature-helper.sh help
#
# The "generate" command outputs just the signature line (no leading ---).
# The "footer" command outputs the full footer block (--- + newline + signature).
#
# Environment variables (override auto-detection):
#   AIDEVOPS_SIG_CLI          CLI name (e.g., "OpenCode CLI")
#   AIDEVOPS_SIG_CLI_VERSION  CLI version (e.g., "1.3.3")
#   AIDEVOPS_SIG_MODEL        Model ID (e.g., "anthropic/opus-4-6")
#   AIDEVOPS_SIG_TOKENS       Token count (e.g., "1234")
#
# Dependencies: lib/version.sh (aidevops version), aidevops-update-check.sh (CLI detection),
#   token-ledger-helper.sh (subagent token counts, optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit

# shellcheck source=lib/version.sh
source "${SCRIPT_DIR}/lib/version.sh"

# =============================================================================
# CLI-to-URL mapping
# =============================================================================
# Maps CLI display names to their canonical repo/website URLs.
# Add new runtimes here as they become supported.

_cli_url() {
	local cli_name="$1"
	# Bash 3.2 compat: no ${var,,} — use tr for case conversion
	local cli_lower
	cli_lower=$(printf '%s' "$cli_name" | tr '[:upper:]' '[:lower:]')

	case "$cli_lower" in
	*opencode*) echo "https://opencode.ai" ;;
	*claude*code*) echo "https://claude.ai/code" ;;
	*cursor*) echo "https://cursor.com" ;;
	*windsurf*) echo "https://windsurf.com" ;;
	*aider*) echo "https://aider.chat" ;;
	*continue*) echo "https://continue.dev" ;;
	*copilot*) echo "https://github.com/features/copilot" ;;
	*cody*) echo "https://sourcegraph.com/cody" ;;
	*kilo*code*) echo "https://kilocode.ai" ;;
	*augment*) echo "https://augmentcode.com" ;;
	*factory* | *droid*) echo "https://factory.ai" ;;
	*codex*) echo "https://github.com/openai/codex" ;;
	*warp*) echo "https://warp.dev" ;;
	*) echo "" ;;
	esac
	return 0
}

# =============================================================================
# OpenCode version detection (cross-platform)
# =============================================================================
# Tries multiple methods to find the OpenCode version. Install paths vary
# across macOS (Homebrew, npm -g, bun) and Linux (npm -g, bun, nix).
# Returns version string (e.g., "1.3.5") or empty.

_detect_opencode_version() {
	local ver=""

	# Method 1: opencode --version (if in PATH)
	ver=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
	if [[ -n "$ver" ]]; then
		echo "$ver"
		return 0
	fi

	# Method 2: npm global (works on both macOS and Linux)
	ver=$(npm list -g opencode-ai --json 2>/dev/null | jq -r '.dependencies["opencode-ai"].version // empty' 2>/dev/null || echo "")
	if [[ -n "$ver" ]]; then
		echo "$ver"
		return 0
	fi

	# Method 3: bun global — check multiple known paths
	local bun_paths=(
		"${HOME}/.bun/install/global/node_modules/opencode-ai/package.json"
		"${HOME}/.bun/install/global/node_modules/.cache/opencode-ai/package.json"
	)
	local bp
	for bp in "${bun_paths[@]}"; do
		ver=$(jq -r '.version // empty' "$bp" 2>/dev/null || echo "")
		if [[ -n "$ver" ]]; then
			echo "$ver"
			return 0
		fi
	done

	# Method 4: resolve the binary path and find package.json nearby
	local bin_path
	bin_path=$(command -v opencode 2>/dev/null || echo "")
	if [[ -n "$bin_path" ]]; then
		# Follow symlinks to the real path
		local real_path
		real_path=$(readlink -f "$bin_path" 2>/dev/null || readlink "$bin_path" 2>/dev/null || echo "$bin_path")
		# Walk up to find package.json (typically ../package.json or ../../package.json)
		local dir
		dir=$(dirname "$real_path" 2>/dev/null || echo "")
		local depth=0
		while [[ -n "$dir" ]] && [[ "$dir" != "/" ]] && [[ $depth -lt 4 ]]; do
			if [[ -f "${dir}/package.json" ]]; then
				ver=$(jq -r '.version // empty' "${dir}/package.json" 2>/dev/null || echo "")
				if [[ -n "$ver" ]]; then
					echo "$ver"
					return 0
				fi
			fi
			dir=$(dirname "$dir" 2>/dev/null || echo "")
			depth=$((depth + 1))
		done
	fi

	echo ""
	return 0
}

# =============================================================================
# CLI detection (reuses aidevops-update-check.sh logic)
# =============================================================================

_detect_cli() {
	local update_check="${SCRIPT_DIR}/aidevops-update-check.sh"
	if [[ -x "$update_check" ]]; then
		# detect_app() outputs "Name|version" or "Name"
		local result
		result=$("$update_check" 2>/dev/null <<<"" | head -1 || echo "")
		# The script's main() runs on execution; we need just detect_app.
		# Safer: source the function directly isn't possible (it runs main).
		# Use the env-var detection inline instead.
		:
	fi

	# Inline detection (mirrors aidevops-update-check.sh detect_app)
	local app_name="" app_version=""

	if [[ "${OPENCODE:-}" == "1" ]]; then
		app_name="OpenCode"
		app_version=$(_detect_opencode_version)
	elif [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		app_name="Claude Code"
		app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
	elif [[ -n "${CURSOR_SESSION:-}" ]] || [[ "${TERM_PROGRAM:-}" == "cursor" ]]; then
		app_name="Cursor"
	elif [[ -n "${WINDSURF_SESSION:-}" ]]; then
		app_name="Windsurf"
	elif [[ -n "${CONTINUE_SESSION:-}" ]]; then
		app_name="Continue"
	elif [[ -n "${AIDER_SESSION:-}" ]]; then
		app_name="Aider"
		app_version=$(aider --version 2>/dev/null | head -1 || echo "")
	elif [[ -n "${FACTORY_DROID:-}" ]]; then
		app_name="Factory Droid"
	elif [[ -n "${AUGMENT_SESSION:-}" ]]; then
		app_name="Augment"
	elif [[ -n "${COPILOT_SESSION:-}" ]]; then
		app_name="GitHub Copilot"
	elif [[ -n "${CODY_SESSION:-}" ]]; then
		app_name="Cody"
	elif [[ -n "${KILO_SESSION:-}" ]]; then
		app_name="Kilo Code"
	elif [[ -n "${WARP_SESSION:-}" ]]; then
		app_name="Warp"
	else
		# Fallback: check parent process name.
		# Use both comm (short) and args (full command line) because on Linux
		# ps -o comm= truncates to 15 chars — "node" instead of "opencode"
		# when run via Node.js (GH#13012).
		local parent parent_args parent_lower
		parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
		parent_args=$(ps -o args= -p "${PPID:-0}" 2>/dev/null || echo "")
		parent_lower=$(printf '%s %s' "$parent" "$parent_args" | tr '[:upper:]' '[:lower:]')
		case "$parent_lower" in
		*opencode*)
			app_name="OpenCode"
			app_version=$(_detect_opencode_version)
			;;
		*claude*)
			app_name="Claude Code"
			app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
			;;
		*cursor*) app_name="Cursor" ;;
		*windsurf*) app_name="Windsurf" ;;
		*aider*)
			app_name="Aider"
			app_version=$(aider --version 2>/dev/null | head -1 || echo "")
			;;
		*) app_name="" ;;
		esac
	fi

	echo "${app_name}|${app_version}"
	return 0
}

# =============================================================================
# Resolve OpenCode DB path (XDG_DATA_HOME-aware)
# =============================================================================
# Headless workers run with XDG_DATA_HOME redirected to an isolated temp dir
# (headless-runtime-helper.sh auth isolation). The session DB is created there,
# not at the default ~/.local/share/opencode/opencode.db. Without this, the
# signature helper can't find the worker's session data and footers show time
# but no tokens (GH#15486).

_opencode_db_path() {
	printf '%s' "${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/opencode.db"
	return 0
}

# =============================================================================
# Auto-detect session token count from runtime DB
# =============================================================================
# Queries the runtime's session database for cumulative token usage.
# Currently supports OpenCode (SQLite DB, path resolved via _opencode_db_path).
# Returns total input+output tokens for the most recent session in the current
# working directory, or empty string if unavailable.

# =============================================================================
# _build_session_dir_list — resolve project directories for session matching
# =============================================================================
# Builds a SQL-safe comma-separated list of quoted directory paths for use in
# SQLite IN() clauses. Excludes root and temp paths that would match stale
# sessions from unrelated contexts (GH#13046 — pulse runs from / via launchd).
# Output: SQL fragment like "'path1', 'path2'" or empty string.

_build_session_dir_list() {
	local cwd repo_root canonical_dir main_worktree
	cwd=$(pwd 2>/dev/null || echo "")
	if [[ -z "$cwd" ]]; then
		echo ""
		return 0
	fi

	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
	canonical_dir="${repo_root%%.*}"

	# Resolve the main worktree path (first entry in git worktree list).
	# In linked worktrees, cwd/repo_root differ from the canonical repo path
	# where sessions are typically stored (GH#12965).
	main_worktree=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //' || echo "")

	local dir_list="" d
	for d in "$cwd" "$repo_root" "$canonical_dir" "$main_worktree"; do
		case "$d" in
		"" | "/" | "/tmp" | "/private/tmp" | "/var/tmp") continue ;;
		esac
		if [[ -n "$dir_list" ]]; then
			dir_list="${dir_list}, '${d}'"
		else
			dir_list="'${d}'"
		fi
	done

	echo "$dir_list"
	return 0
}

# =============================================================================
# _find_opencode_pid — locate the OpenCode process PID
# =============================================================================
# Returns the PID of the running OpenCode process, or empty string.
# Strategy 1: OPENCODE_PID env var (set in interactive TUI sessions).
# Strategy 2: Walk PPID chain up to 10 levels, matching "opencode" in comm or
#   args. Checks both because on Linux ps -o comm= truncates to 15 chars and
#   may show "node" instead of "opencode" when run via Node.js (GH#13012).

_find_opencode_pid() {
	if [[ -n "${OPENCODE_PID:-}" ]]; then
		echo "$OPENCODE_PID"
		return 0
	fi

	local walk_pid="${PPID:-0}"
	local walk_depth=0
	while [[ "$walk_pid" -gt 1 ]] && [[ "$walk_depth" -lt 10 ]] 2>/dev/null; do
		local walk_comm walk_args walk_lower
		walk_comm=$(ps -o comm= -p "$walk_pid" 2>/dev/null || echo "")
		walk_args=$(ps -o args= -p "$walk_pid" 2>/dev/null || echo "")
		walk_lower=$(printf '%s %s' "$walk_comm" "$walk_args" | tr '[:upper:]' '[:lower:]')
		if [[ "$walk_lower" == *opencode* ]]; then
			echo "$walk_pid"
			return 0
		fi
		walk_pid=$(ps -o ppid= -p "$walk_pid" 2>/dev/null | tr -d ' ' || echo "0")
		walk_depth=$((walk_depth + 1))
	done

	echo ""
	return 0
}

# =============================================================================
# _pid_start_epoch — convert a PID's start time to Unix epoch seconds
# =============================================================================
# Uses GNU date -d (Linux) with BSD date -j fallback (macOS).
# Returns epoch integer, or empty string if conversion fails.

_pid_start_epoch() {
	local pid="$1"
	local lstart
	lstart=$(ps -o lstart= -p "$pid" 2>/dev/null || echo "")
	if [[ -z "$lstart" ]]; then
		echo ""
		return 0
	fi
	# Try GNU date first (Linux), then BSD date (macOS)
	date -d "$lstart" "+%s" 2>/dev/null ||
		date -j -f "%a %b %d %H:%M:%S %Y" "$lstart" "+%s" 2>/dev/null ||
		echo ""
	return 0
}

# =============================================================================
# _find_session_id — shared session identification for all detectors
# =============================================================================
# Finds the current OpenCode session ID using multiple heuristics:
# 1. OPENCODE_PID / PPID chain → match session by process start time
# 2. Most recently created session in this directory
# 3. Most recently created session globally (within 10 minutes)
#
# Delegates directory resolution to _build_session_dir_list,
# PID detection to _find_opencode_pid, and epoch conversion to _pid_start_epoch.

_find_session_id() {
	local db_path="$1"

	local dir_list
	dir_list=$(_build_session_dir_list)

	local session_id=""

	# Strategy 1: match by process start time (most precise)
	local target_pid
	target_pid=$(_find_opencode_pid)
	if [[ -n "$target_pid" ]] && [[ -n "$dir_list" ]]; then
		local epoch
		epoch=$(_pid_start_epoch "$target_pid")
		if [[ -n "$epoch" ]]; then
			local pid_start_ms=$((epoch * 1000))
			session_id=$(sqlite3 "$db_path" "
				SELECT id FROM session
				WHERE directory IN (${dir_list})
				ORDER BY ABS(time_created - ${pid_start_ms}) ASC LIMIT 1
			" 2>/dev/null || echo "")
		fi
	fi

	# Strategy 2: most recently created session matching directory
	# (not updated — avoids picking long-running supervisor sessions)
	if [[ -z "$session_id" ]] && [[ -n "$dir_list" ]]; then
		session_id=$(sqlite3 "$db_path" "
			SELECT id FROM session
			WHERE directory IN (${dir_list})
			ORDER BY time_created DESC LIMIT 1
		" 2>/dev/null || echo "")
	fi

	# Strategy 3: most recently created session globally (within 10 minutes).
	# Fallback when directory matching fails — e.g., workers in worktrees
	# not yet in the DB, or scripts running from non-project directories.
	# 10-minute window (tightened from 1h) limits false matches to concurrent
	# sessions on the same machine (GH#13012, GH#13046).
	if [[ -z "$session_id" ]]; then
		session_id=$(sqlite3 "$db_path" "
			SELECT id FROM session
			WHERE time_created > (strftime('%s','now') - 600) * 1000
			ORDER BY time_created DESC LIMIT 1
		" 2>/dev/null || echo "")
	fi

	echo "$session_id"
	return 0
}

# Sum non-cached input + output tokens for a session.
# Args:
#   $1 - sqlite db path
#   $2 - session ID
#   $3 - since milliseconds epoch (optional; include messages >= this time)
# Output: integer token count (may be 0)
_sum_session_tokens_for_session() {
	local db_path="$1"
	local session_id="$2"
	local since_ms="${3:-}"

	local since_filter=""
	if [[ -n "$since_ms" ]] && [[ "$since_ms" =~ ^[0-9]+$ ]] && [[ "$since_ms" -gt 0 ]]; then
		since_filter="AND time_created >= ${since_ms}"
	fi

	sqlite3 "$db_path" "
		SELECT COALESCE(SUM(
			CASE
				WHEN json_extract(data, '$.tokens.input') >
				     COALESCE(json_extract(data, '$.tokens.cache.read'), 0)
				THEN MAX(
					json_extract(data, '$.tokens.input')
					- COALESCE(json_extract(data, '$.tokens.cache.read'), 0)
					- COALESCE(json_extract(data, '$.tokens.cache.write'), 0),
					0)
				ELSE json_extract(data, '$.tokens.input')
			END
			+ json_extract(data, '$.tokens.output')
		), 0)
		FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '$.tokens.input') > 0
		  ${since_filter}
	" 2>/dev/null || echo ""
	return 0
}

_detect_session_tokens_with_since() {
	local since_epoch="${1:-}"
	local db_path
	db_path=$(_opencode_db_path)

	# If the OpenCode DB exists, try it — don't gate on process detection.
	# The old PPID-only check failed on Linux where the immediate parent is
	# "node" or "bun" rather than "opencode" (GH#13012).
	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	local since_ms=""
	if [[ -n "$since_epoch" ]] && [[ "$since_epoch" =~ ^[0-9]+$ ]] && [[ "$since_epoch" -gt 0 ]]; then
		since_ms=$((since_epoch * 1000))
	fi

	local total_tokens
	total_tokens=$(_sum_session_tokens_for_session "$db_path" "$session_id" "$since_ms")

	if [[ -n "$total_tokens" ]] && [[ "$total_tokens" =~ ^[0-9]+$ ]]; then
		echo "$total_tokens"
	else
		echo ""
	fi
	return 0
}

_detect_session_tokens() {
	_detect_session_tokens_with_since ""
	return 0
}

# Resolve issue creation time to epoch seconds.
# Args: issue_ref (OWNER/REPO#NUM), issue_created ISO timestamp
# Output: epoch seconds, or empty string if unavailable
_resolve_issue_created_epoch() {
	local issue_ref="$1"
	local issue_created="$2"

	if [[ -n "$issue_created" ]]; then
		local parsed_epoch=""
		if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created" "+%s" &>/dev/null 2>&1; then
			parsed_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created" "+%s" 2>/dev/null || echo "")
		elif date -d "$issue_created" "+%s" &>/dev/null 2>&1; then
			parsed_epoch=$(date -d "$issue_created" "+%s" 2>/dev/null || echo "")
		fi

		if [[ -n "$parsed_epoch" ]]; then
			echo "$parsed_epoch"
			return 0
		fi
	fi

	if [[ -n "$issue_ref" ]] && command -v gh &>/dev/null; then
		local repo_slug issue_number created_at
		repo_slug="${issue_ref%%#*}"
		issue_number="${issue_ref##*#}"
		if [[ -n "$repo_slug" ]] && [[ -n "$issue_number" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
			created_at=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.created_at' 2>/dev/null || echo "")
			if [[ -n "$created_at" ]]; then
				_resolve_issue_created_epoch "" "$created_at"
				return 0
			fi
		fi
	fi

	echo ""
	return 0
}

# Detect session tokens scoped to issue creation time when issue context is known.
# Args: issue_ref (OWNER/REPO#NUM), issue_created ISO timestamp
# Output: scoped token count, or empty when issue timestamp/session unavailable.
_detect_issue_scoped_tokens() {
	local issue_ref="$1"
	local issue_created="$2"

	local issue_created_epoch
	issue_created_epoch=$(_resolve_issue_created_epoch "$issue_ref" "$issue_created")
	if [[ -z "$issue_created_epoch" ]] || ! [[ "$issue_created_epoch" =~ ^[0-9]+$ ]] || [[ "$issue_created_epoch" -le 0 ]]; then
		echo ""
		return 0
	fi

	_detect_session_tokens_with_since "$issue_created_epoch"
	return 0
}

# =============================================================================
# Detect subagent tokens from the runtime-agnostic token ledger
# =============================================================================
# Reads the token-ledger-helper.sh JSONL ledger for the current session and
# returns the total subagent token count. Returns empty string if no ledger
# exists or no entries are found.
#
# The ledger is written by subagents via token-ledger-helper.sh record.
# This function is the read-side integration for signature footers.

_detect_subagent_tokens() {
	local ledger_helper="${SCRIPT_DIR}/token-ledger-helper.sh"

	if [[ ! -x "$ledger_helper" ]]; then
		echo ""
		return 0
	fi

	local total
	total=$("$ledger_helper" sum 2>/dev/null || echo "")

	if [[ -n "$total" ]] && [[ "$total" =~ ^[0-9]+$ ]] && [[ "$total" -gt 0 ]]; then
		echo "$total"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect model from runtime DB
# =============================================================================
# Queries the OpenCode session DB for the model used in the current session.
# Returns "provider/model" (e.g., "anthropic/claude-sonnet-4-6") or empty.
# This eliminates the need for callers to pass --model explicitly (GH#12965).

_detect_session_model() {
	local db_path
	db_path=$(_opencode_db_path)

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	# Extract provider/model from the first message that has model data
	local provider model_id
	provider=$(sqlite3 "$db_path" "
		SELECT json_extract(data, '\$.model.providerID')
		FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '\$.model.modelID') IS NOT NULL
		LIMIT 1
	" 2>/dev/null || echo "")

	model_id=$(sqlite3 "$db_path" "
		SELECT json_extract(data, '\$.model.modelID')
		FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '\$.model.modelID') IS NOT NULL
		LIMIT 1
	" 2>/dev/null || echo "")

	if [[ -n "$provider" ]] && [[ -n "$model_id" ]]; then
		echo "${provider}/${model_id}"
	elif [[ -n "$model_id" ]]; then
		echo "$model_id"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect session type: "interactive" (>1 user messages) or "worker" (0-1)
# =============================================================================

_detect_session_type() {
	local db_path
	db_path=$(_opencode_db_path)

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	local user_msg_count
	user_msg_count=$(sqlite3 "$db_path" "
		SELECT COUNT(*) FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '$.role') = 'user'
	" 2>/dev/null || echo "0")

	if [[ "$user_msg_count" -gt 1 ]] 2>/dev/null; then
		echo "interactive"
	else
		echo "worker"
	fi
	return 0
}

# =============================================================================
# Detect session time from runtime DB
# =============================================================================
# Returns session duration in seconds (now - session.time_created), or empty.

_detect_session_time() {
	local db_path
	db_path=$(_opencode_db_path)

	# If the OpenCode DB exists, try it — don't gate on process detection.
	# The old PPID-only check failed on Linux where the immediate parent is
	# "node" or "bun" rather than "opencode" (GH#13012).
	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	local session_seconds
	session_seconds=$(sqlite3 "$db_path" "
		SELECT (strftime('%s','now') * 1000 - time_created) / 1000
		FROM session WHERE id='${session_id}'
	" 2>/dev/null || echo "")

	if [[ -n "$session_seconds" ]] && [[ "$session_seconds" -gt 0 ]] 2>/dev/null; then
		echo "$session_seconds"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Sum token counts from all signature footers on an issue's comments
# =============================================================================
# Fetches issue comments, filters to the authenticated GitHub user, extracts
# token counts from signature footers ("spent N tokens" or "has used N tokens"),
# and returns the sum. This is a lower bound — workers killed before commenting
# are not counted.
#
# Args: $1 - issue_ref (OWNER/REPO#NUMBER)
# Output: total token count (integer), or empty string if unavailable

_sum_issue_tokens() {
	local issue_ref="$1"

	if [[ -z "$issue_ref" ]] || ! command -v gh &>/dev/null; then
		echo ""
		return 0
	fi

	local repo_slug issue_number
	repo_slug="${issue_ref%%#*}"
	issue_number="${issue_ref##*#}"

	if [[ -z "$repo_slug" ]] || [[ -z "$issue_number" ]] || ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		echo ""
		return 0
	fi

	# Get the authenticated user's login
	local gh_user
	gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$gh_user" ]]; then
		echo ""
		return 0
	fi

	# Fetch all comments by this user, extract token counts from signature footers
	# Patterns: "spent 1,234 tokens" (current) and "has used 1,234 tokens" (older)
	local token_values
	token_values=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq ".[] | select(.user.login == \"${gh_user}\") | .body" 2>/dev/null |
		grep -oE '(spent|has used) [0-9,]+ tokens' |
		grep -oE '[0-9,]+' |
		tr -d ',' || echo "")

	if [[ -z "$token_values" ]]; then
		echo ""
		return 0
	fi

	# Sum all extracted values
	local total=0
	local val
	while IFS= read -r val; do
		if [[ -n "$val" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
			total=$((total + val))
		fi
	done <<<"$token_values"

	if [[ "$total" -gt 0 ]]; then
		echo "$total"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect total time from issue creation to now
# =============================================================================
# Accepts --issue OWNER/REPO#NUMBER or --issue-created ISO-TIMESTAMP.

_detect_total_time() {
	local issue_ref="$1"
	local issue_created="$2"

	if [[ -n "$issue_created" ]]; then
		local created_epoch now_epoch
		if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created" "+%s" &>/dev/null 2>&1; then
			created_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created" "+%s" 2>/dev/null || echo "")
		else
			created_epoch=$(date -d "$issue_created" "+%s" 2>/dev/null || echo "")
		fi
		if [[ -n "$created_epoch" ]]; then
			now_epoch=$(date "+%s")
			echo $((now_epoch - created_epoch))
			return 0
		fi
	fi

	if [[ -n "$issue_ref" ]] && command -v gh &>/dev/null; then
		local repo_slug issue_number created_at
		repo_slug="${issue_ref%%#*}"
		issue_number="${issue_ref##*#}"
		if [[ -n "$repo_slug" ]] && [[ -n "$issue_number" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
			created_at=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.created_at' 2>/dev/null || echo "")
			if [[ -n "$created_at" ]]; then
				_detect_total_time "" "$created_at"
				return $?
			fi
		fi
	fi

	echo ""
	return 0
}

# =============================================================================
# Format duration in seconds to human-readable
# =============================================================================
# Examples: 45 → "45s", 120 → "2m", 3700 → "1h 1m", 90061 → "1d 1h"

_format_duration() {
	local seconds="$1"
	if [[ -z "$seconds" ]] || [[ "$seconds" -le 0 ]] 2>/dev/null; then
		echo ""
		return 0
	fi

	local days hours minutes
	days=$((seconds / 86400))
	hours=$(((seconds % 86400) / 3600))
	minutes=$(((seconds % 3600) / 60))

	if [[ $days -gt 0 ]]; then
		if [[ $hours -gt 0 ]]; then
			echo "${days}d ${hours}h"
		else
			echo "${days}d"
		fi
	elif [[ $hours -gt 0 ]]; then
		if [[ $minutes -gt 0 ]]; then
			echo "${hours}h ${minutes}m"
		else
			echo "${hours}h"
		fi
	elif [[ $minutes -gt 0 ]]; then
		echo "${minutes}m"
	else
		echo "${seconds}s"
	fi
	return 0
}

# =============================================================================
# Format number with commas (Bash 3.2 compatible)
# =============================================================================

_format_number() {
	local num="$1"
	# Strip non-digits
	num=$(printf '%s' "$num" | tr -cd '0-9')
	if [[ -z "$num" ]]; then
		echo "0"
		return 0
	fi
	# Pure bash comma insertion (macOS BSD sed lacks label loops)
	local formatted=""
	local len=${#num}
	local i=0
	while [[ $i -lt $len ]]; do
		local remaining=$((len - i))
		if [[ $i -gt 0 ]] && [[ $((remaining % 3)) -eq 0 ]]; then
			formatted="${formatted},"
		fi
		formatted="${formatted}${num:$i:1}"
		i=$((i + 1))
	done
	echo "$formatted"
	return 0
}

# =============================================================================
# _parse_generate_args — parse CLI args for cmd_generate
# =============================================================================
# Outputs pipe-separated: model|tokens|cli_name|cli_version|issue_ref|issue_created|solved|no_session|session_type_override|time_secs|subagent_tokens

_parse_generate_args() {
	local model="${AIDEVOPS_SIG_MODEL:-}"
	local tokens="${AIDEVOPS_SIG_TOKENS:-}"
	local cli_name="${AIDEVOPS_SIG_CLI:-}"
	local cli_version="${AIDEVOPS_SIG_CLI_VERSION:-}"
	local issue_ref="" issue_created="" solved="false" no_session="false"
	local session_type_override="" time_secs="" subagent_tokens=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		--tokens)
			tokens="$2"
			shift 2
			;;
		--cli)
			cli_name="$2"
			shift 2
			;;
		--cli-version)
			cli_version="$2"
			shift 2
			;;
		--issue)
			issue_ref="$2"
			shift 2
			;;
		--issue-created)
			issue_created="$2"
			shift 2
			;;
		--solved)
			solved="true"
			shift
			;;
		--no-session)
			no_session="true"
			shift
			;;
		--session-type)
			session_type_override="$2"
			shift 2
			;;
		--time)
			time_secs="$2"
			shift 2
			;;
		--subagent-tokens)
			subagent_tokens="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$model" "$tokens" "$cli_name" "$cli_version" \
		"$issue_ref" "$issue_created" "$solved" "$no_session" \
		"$session_type_override" "$time_secs" "$subagent_tokens"
	return 0
}

# =============================================================================
# _resolve_cli_inputs — auto-detect CLI name/version if not provided
# =============================================================================
# Outputs pipe-separated: cli_name|cli_version

_resolve_cli_inputs() {
	local cli_name="$1"
	local cli_version="$2"

	if [[ -z "$cli_name" ]]; then
		local detected
		detected=$(_detect_cli)
		cli_name="${detected%%|*}"
		if [[ -z "$cli_version" ]]; then
			cli_version="${detected#*|}"
			# If no pipe separator was present, cli_version == cli_name
			if [[ "$cli_version" == "$cli_name" ]]; then
				cli_version=""
			fi
		fi
	fi

	printf '%s|%s\n' "$cli_name" "$cli_version"
	return 0
}

# =============================================================================
# _collect_time_metrics — gather session and total time strings
# =============================================================================
# Outputs pipe-separated: session_time_str|total_time_str

_collect_time_metrics() {
	local issue_ref="$1"
	local issue_created="$2"

	local session_time_str="" total_time_str=""

	local session_secs
	session_secs=$(_detect_session_time)

	if [[ -n "$session_secs" ]] && [[ "$session_secs" -gt 0 ]] 2>/dev/null; then
		session_time_str=$(_format_duration "$session_secs")
	fi

	if [[ -n "$issue_ref" ]] || [[ -n "$issue_created" ]]; then
		local total_secs
		total_secs=$(_detect_total_time "$issue_ref" "$issue_created")
		if [[ -n "$total_secs" ]] && [[ "$total_secs" -gt 0 ]] 2>/dev/null; then
			total_time_str=$(_format_duration "$total_secs")
		fi
	fi

	printf '%s|%s\n' "$session_time_str" "$total_time_str"
	return 0
}

# =============================================================================
# _build_signature — assemble the natural-language signature string
# =============================================================================
# Args: model cli_name cli_version tokens session_time_str total_time_str solved issue_total_tokens session_type subagent_tokens

_build_signature() {
	local model="$1"
	local cli_name="$2"
	local cli_version="$3"
	local tokens="$4"
	local session_time_str="$5"
	local total_time_str="$6"
	local solved="$7"
	local issue_total_tokens="${8:-}"
	local session_type="${9:-}"
	local subagent_tokens="${10:-}"

	local aidevops_version
	aidevops_version=$(aidevops_find_version)

	# Strip provider prefix from model (anthropic/claude-opus-4-6 → claude-opus-4-6)
	local display_model="$model"
	if [[ "$display_model" == */* ]]; then
		display_model="${display_model##*/}"
	fi

	# Target: [aidevops.sh](...) v3.5.10 in [CLI](...) v1.3.3 with claude-opus-4-6 used N tokens for Xm, Zm since this issue was created.
	local sig="[aidevops.sh](https://aidevops.sh) v${aidevops_version}"

	# "plugin for [CLI] vX.Y.Z"
	if [[ -n "$cli_name" ]]; then
		local url
		url=$(_cli_url "$cli_name")
		if [[ -n "$url" ]]; then
			sig="${sig} plugin for [${cli_name}](${url})"
		else
			sig="${sig} plugin for ${cli_name}"
		fi
		if [[ -n "$cli_version" ]]; then
			sig="${sig} v${cli_version}"
		fi
	fi

	# "with model"
	if [[ -n "$display_model" ]]; then
		sig="${sig} with ${display_model}"
	fi

	# "spent Xm and N tokens (incl. M subagent) on this." — time first, tokens second
	local has_time="" has_tokens="" has_subagent_tokens=""
	if [[ -n "$session_time_str" ]]; then has_time="true"; fi
	if [[ -n "$tokens" ]] && [[ "$tokens" != "0" ]]; then has_tokens="true"; fi
	if [[ -n "$subagent_tokens" ]] && [[ "$subagent_tokens" != "0" ]]; then has_subagent_tokens="true"; fi

	if [[ -n "$has_time" ]] || [[ -n "$has_tokens" ]]; then
		sig="${sig} spent"
		if [[ -n "$has_time" ]]; then
			sig="${sig} ${session_time_str}"
		fi
		if [[ -n "$has_time" ]] && [[ -n "$has_tokens" ]]; then
			sig="${sig} and"
		fi
		if [[ -n "$has_tokens" ]]; then
			local formatted
			formatted=$(_format_number "$tokens")
			sig="${sig} ${formatted} tokens"
			# Append subagent breakdown when subagent tokens are present
			if [[ -n "$has_subagent_tokens" ]]; then
				local formatted_subagent
				formatted_subagent=$(_format_number "$subagent_tokens")
				sig="${sig} (incl. ${formatted_subagent} subagent)"
			fi
		fi
		if [[ "$session_type" == "interactive" ]]; then
			sig="${sig} on this with the user in an interactive session."
		elif [[ "$session_type" == "worker" ]]; then
			sig="${sig} on this as a headless worker."
		elif [[ "$session_type" == "routine" ]]; then
			sig="${sig} on this as a headless bash routine."
		else
			sig="${sig} on this."
		fi
	fi

	local has_stats=""
	if [[ -n "$has_time" ]] || [[ -n "$has_tokens" ]] || [[ -n "$total_time_str" ]]; then
		has_stats="true"
	fi

	# Total time as a separate sentence
	if [[ -n "$total_time_str" ]]; then
		if [[ "$solved" == "true" ]]; then
			sig="${sig} Solved in ${total_time_str}."
		else
			sig="${sig} Overall, ${total_time_str} since this issue was created."
		fi
	fi

	# Issue total tokens (cumulative across all sessions on this issue)
	if [[ -n "$issue_total_tokens" ]] && [[ "$issue_total_tokens" != "0" ]]; then
		local formatted_total
		formatted_total=$(_format_number "$issue_total_tokens")
		sig="${sig} ${formatted_total} total tokens on this issue."
	fi

	# If signature is just the version (no CLI, model, tokens, or time),
	# append "automated scan" so it reads naturally on non-LLM issues
	if [[ -z "$cli_name" ]] && [[ -z "$display_model" ]] && [[ -z "$has_stats" ]] && [[ -z "$issue_total_tokens" ]]; then
		sig="${sig} automated scan."
	fi

	echo "$sig"
	return 0
}

# =============================================================================
# generate — produce the signature line
# =============================================================================

cmd_generate() {
	# Parse arguments
	local parsed
	parsed=$(_parse_generate_args "$@")
	local model tokens cli_name cli_version issue_ref issue_created solved no_session
	local session_type_override time_secs subagent_tokens
	IFS='|' read -r model tokens cli_name cli_version issue_ref issue_created solved no_session \
		session_type_override time_secs subagent_tokens <<<"$parsed"

	# Auto-detect CLI name/version
	local cli_resolved
	cli_resolved=$(_resolve_cli_inputs "$cli_name" "$cli_version")
	cli_name="${cli_resolved%%|*}"
	cli_version="${cli_resolved##*|}"

	# Skip session DB detection when --no-session is set (GH#13046).
	# Used by callers running outside OpenCode (e.g., pulse-wrapper via launchd)
	# where session DB lookups would return misleading data from unrelated sessions.
	local session_time_str="" total_time_str="" issue_total_tokens="" session_type=""

	if [[ "$no_session" != "true" ]]; then
		# Auto-detect model from session DB if not provided (GH#12965)
		if [[ -z "$model" ]]; then
			model=$(_detect_session_model)
		fi

		# Auto-detect tokens from session DB if not provided.
		# When issue context is provided, scope tokens to issue lifetime first
		# (prevents unrelated early-session work inflating issue/PR signatures).
		if [[ -z "$tokens" ]]; then
			if [[ -n "$issue_ref" ]] || [[ -n "$issue_created" ]]; then
				tokens=$(_detect_issue_scoped_tokens "$issue_ref" "$issue_created")
			fi
			if [[ -z "$tokens" ]]; then
				tokens=$(_detect_session_tokens)
			fi
		fi

		# Auto-detect subagent tokens from the runtime-agnostic ledger (GH#17507).
		# Only auto-detect if not explicitly provided via --subagent-tokens.
		if [[ -z "$subagent_tokens" ]]; then
			subagent_tokens=$(_detect_subagent_tokens)
		fi

		# Add subagent tokens to the main token total so the signature shows
		# the combined count. The original subagent_tokens value is preserved
		# for the breakdown annotation.
		if [[ -n "$subagent_tokens" ]] && [[ "$subagent_tokens" =~ ^[0-9]+$ ]] && [[ "$subagent_tokens" -gt 0 ]]; then
			local main_tokens="${tokens:-0}"
			main_tokens=$(printf '%s' "$main_tokens" | tr -cd '0-9')
			main_tokens="${main_tokens:-0}"
			tokens=$((main_tokens + subagent_tokens))
		fi

		# Collect time metrics
		local time_metrics
		time_metrics=$(_collect_time_metrics "$issue_ref" "$issue_created")
		IFS='|' read -r session_time_str total_time_str <<<"$time_metrics"

		# Sum issue total tokens (prior comments + current session) when --issue is set.
		# Only show when there are prior comments with tokens — otherwise the total
		# equals the current session's count, which is redundant.
		if [[ -n "$issue_ref" ]]; then
			local prior_tokens
			prior_tokens=$(_sum_issue_tokens "$issue_ref")
			if [[ -n "$prior_tokens" ]] && [[ "$prior_tokens" -gt 0 ]] 2>/dev/null; then
				local current_tokens="${tokens:-0}"
				current_tokens=$(printf '%s' "$current_tokens" | tr -cd '0-9')
				current_tokens="${current_tokens:-0}"
				issue_total_tokens=$((prior_tokens + current_tokens))
			fi
		fi

		# Detect session type (interactive vs worker)
		session_type=$(_detect_session_type)
	fi

	# Apply explicit overrides (--time and --session-type take precedence)
	if [[ -n "$time_secs" ]] && [[ "$time_secs" -gt 0 ]] 2>/dev/null; then
		session_time_str=$(_format_duration "$time_secs")
	fi
	if [[ -n "$session_type_override" ]]; then
		session_type="$session_type_override"
	fi

	# Build and emit the signature
	_build_signature \
		"$model" "$cli_name" "$cli_version" "$tokens" \
		"$session_time_str" "$total_time_str" "$solved" "$issue_total_tokens" "$session_type" \
		"$subagent_tokens"
	return 0
}

# =============================================================================
# footer — produce the full footer block (--- + signature)
# =============================================================================

cmd_footer() {
	# Check for --body flag to enable dedup (skip if body already has signature)
	local args=() body_to_check=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body)
			body_to_check="$2"
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done

	# Dedup: if the body already contains an aidevops signature, skip
	if [[ -n "$body_to_check" ]] && [[ "$body_to_check" == *"aidevops.sh"* ]]; then
		return 0
	fi

	local sig
	# ${args[@]+"${args[@]}"} handles empty array under set -u (Bash 3.2 compat)
	sig=$(cmd_generate ${args[@]+"${args[@]}"})
	printf '\n---\n%s\n' "$sig"
	return 0
}

# =============================================================================
# help
# =============================================================================

show_help() {
	cat <<'EOF'
gh-signature-helper.sh — Generate signature footer for GitHub comments

Usage:
  gh-signature-helper.sh generate [OPTIONS]
  gh-signature-helper.sh footer   [OPTIONS]
  gh-signature-helper.sh help

Commands:
  generate    Output the signature line (no leading ---)
  footer      Output the full footer block (--- + newline + signature)
  help        Show this help

Options:
  --model MODEL             Model ID (e.g., anthropic/claude-opus-4-6)
  --tokens N                Token count (auto-detected from OpenCode DB if omitted)
  --subagent-tokens N       Subagent token count (auto-detected from ledger if omitted)
  --cli NAME                CLI name override (e.g., "OpenCode CLI")
  --cli-version VER         CLI version override (e.g., "1.3.3")
  --issue OWNER/REPO#NUM    GitHub issue ref for total time and token summing
  --issue-created ISO       Issue creation timestamp for total time
  --solved                  Use "Solved in Xm." instead of "Xm since this issue was created."

Auto-detected fields (OpenCode sessions):
  - CLI name and version
  - Token count (input+output from session DB)
  - Subagent token count (from token-ledger-helper.sh JSONL ledger)
  - Session time (duration since session start)
  - Issue total tokens (sum of all signature footers by the authenticated
    GitHub user on the issue's comments, plus current session tokens).
    Lower bound — workers killed before commenting are not counted.

Environment variables (override auto-detection):
  AIDEVOPS_SIG_CLI          CLI name
  AIDEVOPS_SIG_CLI_VERSION  CLI version
  AIDEVOPS_SIG_MODEL        Model ID
  AIDEVOPS_SIG_TOKENS       Token count

Examples:
  # Auto-detect everything, just specify model
  gh-signature-helper.sh generate --model anthropic/claude-opus-4-6

  # With issue ref for total time (queries GitHub API)
  gh-signature-helper.sh footer --model anthropic/claude-sonnet-4-6 --issue owner/repo#42

  # Use in a gh issue comment
  FOOTER=$(gh-signature-helper.sh footer --model anthropic/claude-sonnet-4-6 --issue owner/repo#42)
  gh issue comment 42 --repo owner/repo --body "Comment body${FOOTER}"
EOF
	return 0
}

# =============================================================================
# main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	generate) cmd_generate "$@" ;;
	footer) cmd_footer "$@" ;;
	help | --help | -h) show_help ;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help >&2
		return 1
		;;
	esac
}

main "$@"
