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
		app_name="OpenCode CLI"
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
			app_name="OpenCode CLI"
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
# Detect session time and response time from runtime DB
# =============================================================================
# Returns pipe-separated: session_seconds|response_seconds
# Session time: now - session.time_created
# Response time: now - last user message timestamp

_detect_session_times() {
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	if [[ "${OPENCODE:-}" != "1" ]] && ! ps -o comm= -p "${PPID:-0}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q opencode; then
		echo "|"
		return 0
	fi

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo "|"
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
		echo "|"
		return 0
	fi

	local session_seconds
	session_seconds=$(sqlite3 "$db_path" "
		SELECT (strftime('%s','now') * 1000 - time_created) / 1000
		FROM session WHERE id='${session_id}'
	" 2>/dev/null || echo "")

	local response_seconds
	response_seconds=$(sqlite3 "$db_path" "
		SELECT (strftime('%s','now') * 1000 - MAX(time_created)) / 1000
		FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '$.role') = 'user'
	" 2>/dev/null || echo "")

	echo "${session_seconds}|${response_seconds}"
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
# generate — produce the signature line
# =============================================================================

cmd_generate() {
	local model="${AIDEVOPS_SIG_MODEL:-}"
	local tokens="${AIDEVOPS_SIG_TOKENS:-}"
	local cli_name="${AIDEVOPS_SIG_CLI:-}"
	local cli_version="${AIDEVOPS_SIG_CLI_VERSION:-}"
	local issue_ref="" issue_created=""

	# Parse args
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
		*) shift ;;
		esac
	done

	# Auto-detect CLI if not provided
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

	# Auto-detect tokens from session DB if not provided
	if [[ -z "$tokens" ]]; then
		tokens=$(_detect_session_tokens)
	fi

	# Get aidevops version
	local aidevops_version
	aidevops_version=$(aidevops_find_version)

	# Build the signature parts
	local parts=""

	# Part 1: CLI with link and version
	if [[ -n "$cli_name" ]]; then
		local url
		url=$(_cli_url "$cli_name")
		if [[ -n "$url" ]]; then
			if [[ -n "$cli_version" ]]; then
				parts="[${cli_name}](${url}) v${cli_version}"
			else
				parts="[${cli_name}](${url})"
			fi
		else
			if [[ -n "$cli_version" ]]; then
				parts="${cli_name} v${cli_version}"
			else
				parts="${cli_name}"
			fi
		fi
	fi

	# Part 2: aidevops with link and version
	local aidevops_part="[aidevops.sh](https://aidevops.sh) v${aidevops_version}"
	if [[ -n "$parts" ]]; then
		parts="${parts}, ${aidevops_part}"
	else
		parts="${aidevops_part}"
	fi

	# Part 3: model
	if [[ -n "$model" ]]; then
		parts="${parts}, ${model}"
	fi

	# Part 4: tokens (formatted with commas)
	if [[ -n "$tokens" ]] && [[ "$tokens" != "0" ]]; then
		local formatted
		formatted=$(_format_number "$tokens")
		parts="${parts}, ${formatted} tokens"
	fi

	# Part 5: time metrics (session, response, total)
	local session_time_str="" response_time_str="" total_time_str=""

	local times_raw
	times_raw=$(_detect_session_times)
	local session_secs response_secs
	session_secs="${times_raw%%|*}"
	response_secs="${times_raw##*|}"

	if [[ -n "$session_secs" ]] && [[ "$session_secs" -gt 0 ]] 2>/dev/null; then
		session_time_str=$(_format_duration "$session_secs")
	fi
	if [[ -n "$response_secs" ]] && [[ "$response_secs" -gt 0 ]] 2>/dev/null; then
		response_time_str=$(_format_duration "$response_secs")
	fi

	if [[ -n "$issue_ref" ]] || [[ -n "$issue_created" ]]; then
		local total_secs
		total_secs=$(_detect_total_time "$issue_ref" "$issue_created")
		if [[ -n "$total_secs" ]] && [[ "$total_secs" -gt 0 ]] 2>/dev/null; then
			total_time_str=$(_format_duration "$total_secs")
		fi
	fi

	if [[ -n "$session_time_str" ]]; then
		parts="${parts}, session: ${session_time_str}"
	fi
	if [[ -n "$response_time_str" ]]; then
		parts="${parts}, response: ${response_time_str}"
	fi
	if [[ -n "$total_time_str" ]]; then
		parts="${parts}, total: ${total_time_str}"
	fi

	echo "$parts"
	return 0
}

# =============================================================================
# footer — produce the full footer block (--- + signature)
# =============================================================================

cmd_footer() {
	local sig
	sig=$(cmd_generate "$@")
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
  --issue OWNER/REPO#NUM    GitHub issue ref for total time (e.g., owner/repo#42)
  --issue-created ISO       Issue creation timestamp for total time

Auto-detected fields (OpenCode sessions):
  - CLI name and version
  - Token count (input+output from session DB)
  - Session time (duration since session start)
  - Response time (duration since last user message)

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
