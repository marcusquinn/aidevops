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
		app_version=$(jq -r '.version // empty' ~/.bun/install/global/node_modules/opencode-ai/package.json 2>/dev/null || echo "")
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
  gh-signature-helper.sh generate [--model MODEL] [--tokens N] [--cli NAME] [--cli-version VER]
  gh-signature-helper.sh footer   [--model MODEL] [--tokens N] [--cli NAME] [--cli-version VER]
  gh-signature-helper.sh help

Commands:
  generate    Output the signature line (no leading ---)
  footer      Output the full footer block (--- + newline + signature)
  help        Show this help

Options:
  --model MODEL         Model ID (e.g., anthropic/claude-opus-4-6)
  --tokens N            Token count for the session
  --cli NAME            CLI name override (e.g., "OpenCode CLI")
  --cli-version VER     CLI version override (e.g., "1.3.3")

Environment variables (override auto-detection):
  AIDEVOPS_SIG_CLI          CLI name
  AIDEVOPS_SIG_CLI_VERSION  CLI version
  AIDEVOPS_SIG_MODEL        Model ID
  AIDEVOPS_SIG_TOKENS       Token count

Examples:
  # Auto-detect everything, just specify model
  gh-signature-helper.sh generate --model anthropic/claude-opus-4-6

  # Full footer with all fields
  gh-signature-helper.sh footer --model anthropic/claude-sonnet-4-6 --tokens 45000

  # Override CLI detection
  gh-signature-helper.sh generate --cli "OpenCode CLI" --cli-version "1.3.3" --model anthropic/claude-opus-4-6 --tokens 1234

  # Use in a gh issue comment
  FOOTER=$(gh-signature-helper.sh footer --model anthropic/claude-sonnet-4-6)
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
