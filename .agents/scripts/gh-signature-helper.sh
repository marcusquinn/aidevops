#!/usr/bin/env bash
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
#   gh-signature-helper.sh generate [--model MODEL] [--tokens N] [--cli NAME] [--cli-version VER]
#   gh-signature-helper.sh footer   [--model MODEL] [--tokens N] [--cli NAME] [--cli-version VER]
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
# Dependencies: lib/version.sh (aidevops version), aidevops-update-check.sh (CLI detection)

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
		# Try multiple version detection methods (install path varies: bun, npm, homebrew)
		app_version=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
		if [[ -z "$app_version" ]]; then
			app_version=$(npm list -g opencode-ai --json 2>/dev/null | jq -r '.dependencies["opencode-ai"].version // empty' 2>/dev/null || echo "")
		fi
		if [[ -z "$app_version" ]]; then
			app_version=$(jq -r '.version // empty' ~/.bun/install/global/node_modules/opencode-ai/package.json 2>/dev/null || echo "")
		fi
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
		# Fallback: check parent process name
		local parent parent_lower
		parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
		parent_lower=$(printf '%s' "$parent" | tr '[:upper:]' '[:lower:]')
		case "$parent_lower" in
		*opencode*)
			app_name="OpenCode"
			app_version=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
			if [[ -z "$app_version" ]]; then
				app_version=$(npm list -g opencode-ai --json 2>/dev/null | jq -r '.dependencies["opencode-ai"].version // empty' 2>/dev/null || echo "")
			fi
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
# Auto-detect session token count from runtime DB
# =============================================================================
# Queries the runtime's session database for cumulative token usage.
# Currently supports OpenCode (SQLite DB at ~/.local/share/opencode/opencode.db).
# Returns total input+output tokens for the most recent session in the current
# working directory, or empty string if unavailable.

_detect_session_tokens() {
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	# Only attempt for OpenCode (other runtimes can be added later)
	if [[ "${OPENCODE:-}" != "1" ]] && ! ps -o comm= -p "${PPID:-0}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q opencode; then
		echo ""
		return 0
	fi

	if [[ ! -r "$db_path" ]]; then
		echo ""
		return 0
	fi

	if ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	# Find the most recently updated session matching the current directory
	local cwd
	cwd=$(pwd 2>/dev/null || echo "")
	if [[ -z "$cwd" ]]; then
		echo ""
		return 0
	fi

	# Also check the canonical repo root and worktree's linked repo
	local repo_root canonical_dir
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
	# Worktree paths like ~/Git/repo.branch-name → canonical is ~/Git/repo
	canonical_dir="${repo_root%%.*}"

	local session_id
	session_id=$(sqlite3 "$db_path" "
		SELECT id FROM session
		WHERE directory IN ('${cwd}', '${repo_root}', '${canonical_dir}')
		ORDER BY time_updated DESC LIMIT 1
	" 2>/dev/null || echo "")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	# Sum input + output tokens only. Cache tokens (cache.read, cache.write)
	# represent the same context re-loaded each turn — counting them
	# cumulatively inflates the number by ~100x (175K context × N turns).
	# Input + output reflects actual new content processed per session.
	local total_tokens
	total_tokens=$(sqlite3 "$db_path" "
		SELECT COALESCE(
			SUM(json_extract(data, '$.tokens.input')) +
			SUM(json_extract(data, '$.tokens.output')), 0
		)
		FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '$.tokens.input') > 0
	" 2>/dev/null || echo "")

	if [[ -n "$total_tokens" ]] && [[ "$total_tokens" -gt 0 ]] 2>/dev/null; then
		echo "$total_tokens"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect session type: "interactive" (>1 user messages) or "worker" (0-1)
# =============================================================================

_detect_session_type() {
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local cwd repo_root canonical_dir
	cwd=$(pwd 2>/dev/null || echo "")
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
	canonical_dir="${repo_root%%.*}"

	local session_id=""
	if [[ -n "${OPENCODE_PID:-}" ]]; then
		local pid_start_epoch lstart
		lstart=$(ps -o lstart= -p "$OPENCODE_PID" 2>/dev/null || echo "")
		if [[ -n "$lstart" ]]; then
			pid_start_epoch=$(date -j -f "%a %b %d %H:%M:%S %Y" "$lstart" "+%s" 2>/dev/null ||
				date -d "$lstart" "+%s" 2>/dev/null || echo "")
		fi
		if [[ -n "$pid_start_epoch" ]]; then
			local pid_start_ms=$((pid_start_epoch * 1000))
			session_id=$(sqlite3 "$db_path" "
				SELECT id FROM session
				WHERE directory IN ('${cwd}', '${repo_root}', '${canonical_dir}')
				ORDER BY ABS(time_created - ${pid_start_ms}) ASC LIMIT 1
			" 2>/dev/null || echo "")
		fi
	fi

	if [[ -z "$session_id" ]]; then
		session_id=$(sqlite3 "$db_path" "
			SELECT id FROM session
			WHERE directory IN ('${cwd}', '${repo_root}', '${canonical_dir}')
			ORDER BY time_updated DESC LIMIT 1
		" 2>/dev/null || echo "")
	fi

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
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	if [[ "${OPENCODE:-}" != "1" ]] && ! ps -o comm= -p "${PPID:-0}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q opencode; then
		echo ""
		return 0
	fi

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local cwd repo_root canonical_dir
	cwd=$(pwd 2>/dev/null || echo "")
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
	canonical_dir="${repo_root%%.*}"

	# Find session using PID-matching strategy (same as _detect_session_tokens)
	local session_id=""
	if [[ -n "${OPENCODE_PID:-}" ]]; then
		local pid_start_epoch lstart
		lstart=$(ps -o lstart= -p "$OPENCODE_PID" 2>/dev/null || echo "")
		if [[ -n "$lstart" ]]; then
			pid_start_epoch=$(date -j -f "%a %b %d %H:%M:%S %Y" "$lstart" "+%s" 2>/dev/null ||
				date -d "$lstart" "+%s" 2>/dev/null || echo "")
		fi
		if [[ -n "$pid_start_epoch" ]]; then
			local pid_start_ms=$((pid_start_epoch * 1000))
			session_id=$(sqlite3 "$db_path" "
				SELECT id FROM session
				WHERE directory IN ('${cwd}', '${repo_root}', '${canonical_dir}')
				ORDER BY ABS(time_created - ${pid_start_ms}) ASC LIMIT 1
			" 2>/dev/null || echo "")
		fi
	fi

	if [[ -z "$session_id" ]]; then
		session_id=$(sqlite3 "$db_path" "
			SELECT id FROM session
			WHERE directory IN ('${cwd}', '${repo_root}', '${canonical_dir}')
			ORDER BY time_updated DESC LIMIT 1
		" 2>/dev/null || echo "")
	fi

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
		if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created" "+%s" &>/dev/null 2>&1; then
			created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created" "+%s" 2>/dev/null || echo "")
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
# Outputs pipe-separated: model|tokens|cli_name|cli_version|issue_ref|issue_created|solved

_parse_generate_args() {
	local model="${AIDEVOPS_SIG_MODEL:-}"
	local tokens="${AIDEVOPS_SIG_TOKENS:-}"
	local cli_name="${AIDEVOPS_SIG_CLI:-}"
	local cli_version="${AIDEVOPS_SIG_CLI_VERSION:-}"
	local issue_ref="" issue_created="" solved="false"

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
		*) shift ;;
		esac
	done

	printf '%s|%s|%s|%s|%s|%s|%s\n' \
		"$model" "$tokens" "$cli_name" "$cli_version" \
		"$issue_ref" "$issue_created" "$solved"
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
# Args: model cli_name cli_version tokens session_time_str total_time_str solved issue_total_tokens session_type

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

	# "spent Xm and N tokens on this." — time first, tokens second
	local has_time="" has_tokens=""
	if [[ -n "$session_time_str" ]]; then has_time="true"; fi
	if [[ -n "$tokens" ]] && [[ "$tokens" != "0" ]]; then has_tokens="true"; fi

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
		fi
		if [[ "$session_type" == "interactive" ]]; then
			sig="${sig} on this with the user in an interactive session."
		elif [[ "$session_type" == "worker" ]]; then
			sig="${sig} on this as a headless worker."
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
	local model tokens cli_name cli_version issue_ref issue_created solved
	IFS='|' read -r model tokens cli_name cli_version issue_ref issue_created solved <<<"$parsed"

	# Auto-detect CLI name/version
	local cli_resolved
	cli_resolved=$(_resolve_cli_inputs "$cli_name" "$cli_version")
	cli_name="${cli_resolved%%|*}"
	cli_version="${cli_resolved##*|}"

	# Auto-detect tokens from session DB if not provided
	if [[ -z "$tokens" ]]; then
		tokens=$(_detect_session_tokens)
	fi

	# Collect time metrics
	local time_metrics
	time_metrics=$(_collect_time_metrics "$issue_ref" "$issue_created")
	local session_time_str total_time_str
	IFS='|' read -r session_time_str total_time_str <<<"$time_metrics"

	# Sum issue total tokens (prior comments + current session) when --issue is set.
	# Only show when there are prior comments with tokens — otherwise the total
	# equals the current session's count, which is redundant.
	local issue_total_tokens=""
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
	local session_type
	session_type=$(_detect_session_type)

	# Build and emit the signature
	_build_signature \
		"$model" "$cli_name" "$cli_version" "$tokens" \
		"$session_time_str" "$total_time_str" "$solved" "$issue_total_tokens" "$session_type"
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
  --cli NAME                CLI name override (e.g., "OpenCode CLI")
  --cli-version VER         CLI version override (e.g., "1.3.3")
  --issue OWNER/REPO#NUM    GitHub issue ref for total time and token summing
  --issue-created ISO       Issue creation timestamp for total time
  --solved                  Use "Solved in Xm." instead of "Xm since this issue was created."

Auto-detected fields (OpenCode sessions):
  - CLI name and version
  - Token count (input+output from session DB)
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
