#!/usr/bin/env bash
# Tool Version Check
# Checks versions of key tools and flags outdated ones
#
# Usage:
#   tool-version-check.sh              # Check all tools
#   tool-version-check.sh --update     # Check and update outdated tools
#   tool-version-check.sh --category npm  # Check only npm tools
#   tool-version-check.sh --json       # Output as JSON
#
# Categories: npm, brew, pip, custom, all (default)

# shellcheck disable=SC1091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly BOLD='\033[1m'

# Parse arguments
AUTO_UPDATE=false
CATEGORY="all"
JSON_OUTPUT=false
QUIET=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	--update | -u)
		AUTO_UPDATE=true
		shift
		;;
	--category | -c)
		if [[ -z "${2:-}" ]]; then
			echo "Error: --category requires a value (npm, brew, pip, custom, all)"
			exit 1
		fi
		CATEGORY="$2"
		shift 2
		;;
	--json | -j)
		JSON_OUTPUT=true
		shift
		;;
	--quiet | -q)
		QUIET=true
		shift
		;;
	--help | -h)
		echo "Usage: tool-version-check.sh [OPTIONS]"
		echo ""
		echo "Options:"
		echo "  --update, -u       Automatically update outdated tools"
		echo "  --category, -c     Check only specific category (npm, brew, pip, custom, all)"
		echo "  --json, -j         Output results as JSON"
		echo "  --quiet, -q        Only show outdated tools"
		echo "  --help, -h         Show this help"
		exit 0
		;;
	*)
		echo "Unknown option: $1"
		exit 1
		;;
	esac
done

# Detect how OpenCode was installed — build the right upgrade command.
# update_cmd is executed via `bash -c` so it must be a self-contained string.
# Use `command -v` path directly: bun-installed binaries live under ~/.bun/bin/,
# so the path itself contains "bun". This avoids `readlink -f` which is a GNU
# extension not available on macOS by default.
# shellcheck disable=SC2016  # Single quotes intentional: string is a bash -c payload, must not expand at assignment time
_oc_upgrade_cmd='if r=$(command -v opencode 2>/dev/null); [[ "$r" == *bun* ]]; then bun install -g opencode-ai@latest; else npm install -g opencode-ai@latest; fi'

# Tool definitions
# Format: category|display_name|cli_command|version_flag|package_name|update_command

NPM_TOOLS=(
	"npm|OpenCode|opencode|--version|opencode-ai|${_oc_upgrade_cmd}"
	"npm|Claude Code CLI|claude|--version|@anthropic-ai/claude-code|npm install -g @anthropic-ai/claude-code@latest"
	"npm|Augment CLI|auggie|--version|@augmentcode/auggie@prerelease|npm install -g @augmentcode/auggie@prerelease"
	"npm|Repomix|repomix|--version|repomix|npm install -g repomix@latest"
	"npm|DSPyGround|dspyground|--version|dspyground|npm install -g dspyground@latest"
	"npm|LocalWP MCP|mcp-local-wp|--version|@verygoodplugins/mcp-local-wp|npm install -g @verygoodplugins/mcp-local-wp@latest"
	"npm|Beads UI|beads-ui|--version|beads-ui|npm install -g beads-ui@latest"
	"npm|BDUI|bdui|--version|bdui|npm install -g bdui@latest"
	"npm|Chrome DevTools MCP|chrome-devtools-mcp|--version|chrome-devtools-mcp|npm install -g chrome-devtools-mcp@latest"
	"npm|GSC MCP|mcp-server-gsc|--version|mcp-server-gsc|npm install -g mcp-server-gsc@latest"
	"npm|Playwriter MCP|playwriter|--version|playwriter|npm install -g playwriter@latest"
	"npm|macOS Automator MCP|macos-automator-mcp|--version|@steipete/macos-automator-mcp|npm install -g @steipete/macos-automator-mcp@latest"
	"npm|Claude Code MCP|claude-code-mcp|--version|@steipete/claude-code-mcp|npm install -g @steipete/claude-code-mcp@latest"
	"npm|Google Workspace CLI|gws|--version|@googleworkspace/cli|npm install -g @googleworkspace/cli@latest"
)

BREW_TOOLS=(
	"brew|GitHub CLI|gh|--version|gh|brew upgrade gh"
	"brew|GitLab CLI|glab|--version|glab|brew upgrade glab"
	"brew|Worktrunk|wt|--version|max-sixty/worktrunk/wt|brew upgrade max-sixty/worktrunk/wt"
	"brew|Beads CLI|bd|version|steveyegge/beads/bd|brew upgrade steveyegge/beads/bd"
	"brew|jq|jq|--version|jq|brew upgrade jq"
	"brew|ShellCheck|shellcheck|--version|shellcheck|brew upgrade shellcheck"
)

PIP_TOOLS=(
	"pip|Beads Viewer|beads_viewer|--version|beads-viewer|pip install --upgrade beads-viewer"
	"pip|DSPy|dspy|--version|dspy-ai|pip install --upgrade dspy-ai"
	"pip|Crawl4AI|crawl4ai|--version|crawl4ai|pip install --upgrade crawl4ai"
	"pip|Analytics MCP|analytics-mcp|--version|analytics-mcp|pipx upgrade analytics-mcp"
	"pip|Outscraper MCP|outscraper-mcp-server|--version|outscraper-mcp-server|uv tool upgrade outscraper-mcp-server"
)

# Tools installed via curl/custom installers (not in brew/npm/pip registries)
# Latest version cannot be checked via registry — use "self" category
# which skips latest-version lookup and just reports installed version
CUSTOM_TOOLS=(
	"self|Cursor CLI|agent|--version|cursor-agent|agent update"
)

# Counters
OUTDATED_COUNT=0
INSTALLED_COUNT=0
NOT_INSTALLED_COUNT=0
TIMEOUT_COUNT=0
UNKNOWN_COUNT=0
declare -a OUTDATED_PACKAGES=()
declare -a JSON_RESULTS=()

# Timeout for local --version calls (seconds).
# A well-behaved --version should return in <1s. 10s is generous enough for
# slow interpreters (Python, Ruby) while still catching hung MCP servers.
readonly VERSION_TIMEOUT=10

# Get installed version from npm global package.json
# Fallback for tools where --version starts a server instead of printing a version
get_npm_pkg_version() {
	local pkg="$1"
	local npm_root
	npm_root="$(npm root -g 2>/dev/null)" || return 1
	[[ -n "$npm_root" ]] || return 1
	local pkg_json="${npm_root}/${pkg}/package.json"
	if [[ -f "$pkg_json" ]]; then
		grep -oE '"version"\s*:\s*"[0-9]+\.[0-9]+\.[0-9]+"' "$pkg_json" |
			grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
		return 0
	fi
	return 1
}

# Get installed version
get_installed_version() {
	local cmd="$1"
	local ver_flag="$2"
	local pkg="${3:-}"

	if command -v "$cmd" &>/dev/null; then
		local version
		# Timeout version checks — some tools (MCP servers) start a blocking
		# server process when given --version instead of printing a version.
		# Without a timeout, the subshell hangs forever.
		# NOTE: Do NOT pipe timeout_sec to head/grep — on macOS the background
		# process fallback may not close the pipe write end on kill, causing
		# head to block forever. Use a temp file instead.
		local _ver_log
		if ! _ver_log=$(mktemp "${TMPDIR:-/tmp}/tool-ver.XXXXXX"); then
			echo "unknown"
			return 0
		fi
		local _ver_rc=0
		# shellcheck disable=SC2086
		timeout_sec "$VERSION_TIMEOUT" "$cmd" $ver_flag >"$_ver_log" 2>/dev/null || _ver_rc=$?

		if [[ "$_ver_rc" -eq 124 ]]; then
			# timeout_sec killed the process — command hung (MCP server started)
			rm -f "$_ver_log"
			# Fallback: read version from npm package.json
			if [[ -n "$pkg" ]]; then
				version=$(get_npm_pkg_version "$pkg")
				if [[ -n "$version" ]]; then
					echo "$version"
					return 0
				fi
			fi
			echo "timeout"
			return 0
		fi

		local ver_output
		ver_output=$(head -1 "$_ver_log")
		rm -f "$_ver_log"
		version=$(echo "$ver_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		if [[ -z "$version" ]]; then
			version=$(echo "$ver_output" | grep -oE '[0-9]+\.[0-9]+' | head -1)
		fi

		# If --version produced no parseable version, try npm package.json fallback
		if [[ -z "$version" ]] && [[ -n "$pkg" ]]; then
			local pkg_version
			pkg_version=$(get_npm_pkg_version "$pkg")
			if [[ -n "$pkg_version" ]]; then
				echo "$pkg_version"
				return 0
			fi
		fi

		echo "${version:-unknown}"
	else
		echo "not installed"
	fi
	return 0
}

# timeout_sec() is now provided by shared-constants.sh (sourced above).
# Moved there in t1504 so all scripts get portable timeout support.

# Timeout for external package manager queries (seconds)
readonly PKG_QUERY_TIMEOUT=30

get_public_release_tag() {
	local repo="$1"
	local tag=""
	tag=$(timeout_sec "$PKG_QUERY_TIMEOUT" curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
		grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v?[^"]+"' |
		head -1 |
		sed -E 's/.*"v?([^"]+)"/\1/' || true)
	echo "$tag"
	return 0
}

# Get latest npm version
get_npm_latest() {
	local pkg="$1"
	# Use timeout to prevent hanging on npm view
	timeout_sec "$PKG_QUERY_TIMEOUT" npm view "$pkg" version 2>/dev/null || echo "unknown"
	return 0
}

# Get latest brew version
get_brew_latest() {
	local pkg="$1"
	local brew_bin=""
	brew_bin=$(command -v brew 2>/dev/null || true)
	if [[ -n "$brew_bin" && -x "$brew_bin" ]]; then
		timeout_sec "$PKG_QUERY_TIMEOUT" "$brew_bin" info "$pkg" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
	elif [[ "$pkg" == "gh" ]]; then
		get_public_release_tag "cli/cli"
	else
		echo "unknown"
	fi
	return 0
}

# Get latest pip version
get_pip_latest() {
	local pkg="$1"
	timeout_sec "$PKG_QUERY_TIMEOUT" pip index versions "$pkg" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
	return 0
}

# Compare versions (returns 0 if v1 < v2)
version_lt() {
	local v1="$1"
	local v2="$2"

	if [[ "$v1" == "$v2" ]]; then
		return 1
	fi

	# Use sort -V for version comparison
	local lowest
	lowest=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)
	[[ "$lowest" == "$v1" ]]
}

# Check a single tool
check_tool() {
	local category="$1"
	local name="$2"
	local cmd="$3"
	local ver_flag="$4"
	local pkg="$5"
	local update_cmd="$6"

	local installed
	# Pass package name for npm tools so fallback to package.json works
	if [[ "$category" == "npm" ]]; then
		installed=$(get_installed_version "$cmd" "$ver_flag" "$pkg")
	else
		installed=$(get_installed_version "$cmd" "$ver_flag")
	fi

	local latest="unknown"
	case "$category" in
	npm) latest=$(get_npm_latest "$pkg") ;;
	brew) latest=$(get_brew_latest "$pkg") ;;
	pip) latest=$(get_pip_latest "$pkg") ;;
	self) latest="$installed" ;; # Self-updating tools — no registry to check
	*) latest="unknown" ;;
	esac

	local status="up_to_date"
	local icon="✓"
	local color="$GREEN"

	if [[ "$installed" == "not installed" ]]; then
		status="not_installed"
		icon="○"
		color="$YELLOW"
		((++NOT_INSTALLED_COUNT))
	elif [[ "$installed" == "timeout" ]]; then
		status="timeout"
		icon="⏱"
		color="$RED"
		((++TIMEOUT_COUNT))
	elif [[ "$installed" == "unknown" || "$latest" == "unknown" ]]; then
		status="unknown"
		icon="?"
		color="$YELLOW"
		((++UNKNOWN_COUNT))
	elif [[ "$installed" != "$latest" ]] && version_lt "$installed" "$latest"; then
		status="outdated"
		icon="⬆"
		color="$RED"
		((++OUTDATED_COUNT))
		OUTDATED_PACKAGES+=("$update_cmd")
	else
		((++INSTALLED_COUNT))
	fi

	# JSON output (escape special characters for valid JSON)
	if [[ "$JSON_OUTPUT" == "true" ]]; then
		# Escape backslashes and double quotes for JSON safety
		local json_name="${name//\\/\\\\}"
		json_name="${json_name//\"/\\\"}"
		local json_update="${update_cmd//\\/\\\\}"
		json_update="${json_update//\"/\\\"}"
		JSON_RESULTS+=("{\"name\": \"$json_name\", \"category\": \"$category\", \"installed\": \"$installed\", \"latest\": \"$latest\", \"status\": \"$status\", \"update_cmd\": \"$json_update\"}")
	else
		# Console output
		if [[ "$QUIET" == "true" && "$status" != "outdated" && "$status" != "timeout" ]]; then
			return
		fi

		case "$status" in
		not_installed)
			echo -e "${color}${icon}  $name: not installed${NC}"
			if [[ "$QUIET" != "true" ]]; then
				echo "   Latest: $latest"
			fi
			;;
		outdated)
			echo -e "${color}${icon}  $name: $installed → $latest (UPDATE AVAILABLE)${NC}"
			;;
		timeout)
			echo -e "${color}${icon}  $name: --version hung (killed after ${VERSION_TIMEOUT}s)${NC}"
			;;
		unknown)
			echo -e "${color}${icon}  $name: $installed (could not check latest)${NC}"
			;;
		up_to_date)
			echo -e "${color}${icon}  $name: $installed${NC}"
			;;
		*)
			echo -e "${color}${icon}  $name: $installed (status: $status)${NC}"
			;;
		esac
	fi
}

# Check tools by category
check_category() {
	local cat_name="$1"
	shift
	local tools=("$@")

	if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
		echo ""
		echo -e "${BOLD}${CYAN}=== $cat_name Tools ===${NC}"
	fi

	local category name cmd ver_flag pkg update_cmd
	for tool_spec in "${tools[@]}"; do
		IFS='|' read -r category name cmd ver_flag pkg update_cmd <<<"$tool_spec"
		check_tool "$category" "$name" "$cmd" "$ver_flag" "$pkg" "$update_cmd"
	done
	return 0
}

# Dispatch category checks based on CATEGORY variable
_check_all_categories() {
	case "$CATEGORY" in
	npm)
		check_category "NPM" "${NPM_TOOLS[@]}"
		;;
	brew)
		check_category "Homebrew" "${BREW_TOOLS[@]}"
		;;
	pip)
		check_category "Python/Pip" "${PIP_TOOLS[@]}"
		;;
	custom)
		check_category "Custom/Self-Updating" "${CUSTOM_TOOLS[@]}"
		;;
	all | *)
		if [[ ${#NPM_TOOLS[@]} -gt 0 ]]; then
			check_category "NPM" "${NPM_TOOLS[@]}"
		fi
		if command -v brew &>/dev/null && [[ ${#BREW_TOOLS[@]} -gt 0 ]]; then
			check_category "Homebrew" "${BREW_TOOLS[@]}"
		fi
		if command -v pip &>/dev/null && [[ ${#PIP_TOOLS[@]} -gt 0 ]]; then
			check_category "Python/Pip" "${PIP_TOOLS[@]}"
		fi
		if [[ ${#CUSTOM_TOOLS[@]} -gt 0 ]]; then
			check_category "Custom/Self-Updating" "${CUSTOM_TOOLS[@]}"
		fi
		;;
	esac
	return 0
}

# Emit JSON output for all results and return
_output_json_results() {
	echo "{"
	echo "  \"summary\": {"
	echo "    \"installed\": $INSTALLED_COUNT,"
	echo "    \"outdated\": $OUTDATED_COUNT,"
	echo "    \"not_installed\": $NOT_INSTALLED_COUNT,"
	echo "    \"timeout\": $TIMEOUT_COUNT,"
	echo "    \"unknown\": $UNKNOWN_COUNT"
	echo "  },"
	echo "  \"tools\": ["
	local first=true
	for result in "${JSON_RESULTS[@]}"; do
		if [[ "$first" == "true" ]]; then
			first=false
		else
			echo ","
		fi
		echo -n "    $result"
	done
	echo ""
	echo "  ]"
	echo "}"
	return 0
}

# Print summary counts and handle auto-update or update instructions
_output_summary_and_updates() {
	# Summary (skip in quiet mode if nothing outdated)
	if [[ "$QUIET" == "true" && $OUTDATED_COUNT -eq 0 ]]; then
		return 0
	fi

	if [[ "$QUIET" != "true" ]]; then
		echo ""
		echo -e "${BOLD}Summary${NC}"
		echo "  Installed & up to date: $INSTALLED_COUNT"
		echo "  Outdated: $OUTDATED_COUNT"
		echo "  Not installed: $NOT_INSTALLED_COUNT"
		if [[ $TIMEOUT_COUNT -gt 0 ]]; then
			echo "  Timeout (version check hung): $TIMEOUT_COUNT"
		fi
		if [[ $UNKNOWN_COUNT -gt 0 ]]; then
			echo "  Unknown (could not verify): $UNKNOWN_COUNT"
		fi
		echo ""
	fi

	if [[ $OUTDATED_COUNT -gt 0 ]]; then
		if [[ "$AUTO_UPDATE" == "true" ]]; then
			echo -e "${BLUE}Updating outdated tools...${NC}"
			echo ""
			for update_cmd in "${OUTDATED_PACKAGES[@]}"; do
				echo "  Running: $update_cmd"
				# Run update command directly (not via eval for security)
				# Commands are hardcoded in tool definitions, not user input
				# Timeout prevents hangs on slow registries/network issues
				# Use timeout_sec for macOS compatibility (no native timeout)
				# NOTE: Do NOT pipe timeout_sec output to tail/head — on macOS the
				# perl alarm fallback doesn't close the pipe's write end on SIGALRM,
				# causing tail to block forever. Use a temp file instead.
				local _update_log
				if ! _update_log=$(mktemp "${TMPDIR:-/tmp}/tool-update.XXXXXX"); then
					echo -e "  ${RED}✗ Failed to create temp log${NC}"
					continue
				fi
				if timeout_sec 120 bash -c "$update_cmd" >"$_update_log" 2>&1; then
					tail -2 "$_update_log"
					echo -e "  ${GREEN}✓ Updated${NC}"
				else
					tail -2 "$_update_log"
					echo -e "  ${RED}✗ Failed${NC}"
				fi
				rm -f "$_update_log"
				echo ""
			done
			echo -e "${GREEN}Updates complete. Re-run to verify.${NC}"
		else
			echo "To update all outdated tools, run:"
			echo "  tool-version-check.sh --update"
			echo ""
			echo "Or update individually:"
			for update_cmd in "${OUTDATED_PACKAGES[@]}"; do
				echo "  $update_cmd"
			done
		fi
	else
		echo -e "${GREEN}All installed tools are up to date!${NC}"
	fi
	return 0
}

# Main
main() {
	if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
		echo -e "${BOLD}${BLUE}Tool Version Check${NC}"
		echo "=================="
	fi

	_check_all_categories

	if [[ "$JSON_OUTPUT" == "true" ]]; then
		_output_json_results
		return 0
	fi

	_output_summary_and_updates
}

main
exit $?
