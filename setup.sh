#!/usr/bin/env bash
set -euo pipefail

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 2.110.13
#
# Quick Install:
#   npm install -g aidevops && aidevops update          (recommended)
#   brew install marcusquinn/tap/aidevops && aidevops update  (Homebrew)
#   curl -fsSL https://aidevops.sh -o /tmp/aidevops-setup.sh && bash /tmp/aidevops-setup.sh  (manual)

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global flags
CLEAN_MODE=false
INTERACTIVE_MODE=false
NON_INTERACTIVE="${AIDEVOPS_NON_INTERACTIVE:-false}"
UPDATE_TOOLS_MODE=false
REPO_URL="https://github.com/marcusquinn/aidevops.git"
INSTALL_DIR="$HOME/Git/aidevops"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Spinner for long-running operations
# Usage: run_with_spinner "Installing package..." command arg1 arg2
run_with_spinner() {
	local message="$1"
	shift
	local pid
	local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
	local i=0

	# Start command in background
	"$@" &>/dev/null &
	pid=$!

	# Show spinner while command runs
	printf "${BLUE}[INFO]${NC} %s " "$message"
	while kill -0 "$pid" 2>/dev/null; do
		printf "\r${BLUE}[INFO]${NC} %s %s" "$message" "${spin_chars:i++%${#spin_chars}:1}"
		sleep 0.1
	done

	# Check exit status
	wait "$pid"
	local exit_code=$?

	# Clear spinner and show result
	printf "\r"
	if [[ $exit_code -eq 0 ]]; then
		print_success "$message done"
	else
		print_error "$message failed"
	fi

	return $exit_code
}

# Verified install: download script to temp file, inspect, then execute
# Replaces unsafe curl|sh patterns with download-verify-execute
# Usage: verified_install "description" "url" [extra_args...]
# Options (set before calling):
#   VERIFIED_INSTALL_SUDO="true"  - run with sudo
#   VERIFIED_INSTALL_SHELL="sh"  - use sh instead of bash (default: bash)
# Returns: 0 on success, 1 on failure
verified_install() {
	local description="$1"
	local url="$2"
	shift 2
	local extra_args=("$@")
	local shell="${VERIFIED_INSTALL_SHELL:-bash}"
	local use_sudo="${VERIFIED_INSTALL_SUDO:-false}"

	# Reset options for next call
	VERIFIED_INSTALL_SUDO="false"
	VERIFIED_INSTALL_SHELL="bash"

	# Create secure temp file
	local tmp_script
	tmp_script=$(mktemp "${TMPDIR:-/tmp}/aidevops-install-XXXXXX.sh") || {
		print_error "Failed to create temp file for $description"
		return 1
	}

	# Ensure cleanup on exit from this function
	# shellcheck disable=SC2064
	trap "rm -f '$tmp_script'" RETURN

	# Download script to file (not piped to shell)
	print_info "Downloading $description install script..."
	if ! curl -fsSL "$url" -o "$tmp_script" 2>/dev/null; then
		print_error "Failed to download $description install script from $url"
		return 1
	fi

	# Verify download is non-empty and looks like a script
	if [[ ! -s "$tmp_script" ]]; then
		print_error "Downloaded $description script is empty"
		return 1
	fi

	# Basic content safety check: reject binary content
	if file "$tmp_script" 2>/dev/null | grep -qv 'text'; then
		print_error "Downloaded $description script appears to be binary, not a shell script"
		return 1
	fi

	# Make executable
	chmod +x "$tmp_script"

	# Execute from file
	local cmd=("$shell" "$tmp_script" "${extra_args[@]}")
	if [[ "$use_sudo" == "true" ]]; then
		cmd=(sudo "$shell" "$tmp_script" "${extra_args[@]}")
	fi

	if "${cmd[@]}"; then
		print_success "$description installed"
		return 0
	else
		print_error "$description installation failed"
		return 1
	fi
}

# Find OpenCode config file (checks multiple possible locations)
# Returns: path to config file, or empty string if not found
find_opencode_config() {
	local candidates=(
		"$HOME/.config/opencode/opencode.json"                     # XDG standard (Linux, some macOS)
		"$HOME/.opencode/opencode.json"                            # Alternative location
		"$HOME/Library/Application Support/opencode/opencode.json" # macOS standard
	)
	for candidate in "${candidates[@]}"; do
		if [[ -f "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

# Find best python3 binary (prefer Homebrew/pyenv over system)
find_python3() {
	local candidates=(
		"/opt/homebrew/bin/python3"
		"/usr/local/bin/python3"
		"$HOME/.pyenv/shims/python3"
	)
	for candidate in "${candidates[@]}"; do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	# Fallback to PATH
	if command -v python3 &>/dev/null; then
		command -v python3
		return 0
	fi
	return 1
}

# Install a package globally via npm or bun, with sudo when needed on Linux.
# Usage: npm_global_install "package-name" OR npm_global_install "package@version"
# Uses bun if available (no sudo needed), falls back to npm.
# On Linux with apt-installed npm, automatically prepends sudo.
# Returns: 0 on success, 1 on failure
npm_global_install() {
	local pkg="$1"

	if command -v bun >/dev/null 2>&1; then
		bun install -g "$pkg"
		return $?
	elif command -v npm >/dev/null 2>&1; then
		# npm global installs need sudo on Linux when prefix dir isn't writable
		if [[ "$(uname)" != "Darwin" ]] && [[ ! -w "$(npm config get prefix 2>/dev/null)/lib" ]]; then
			sudo npm install -g "$pkg"
		else
			npm install -g "$pkg"
		fi
		return $?
	else
		return 1
	fi
}

# Confirm step in interactive mode
# Usage: confirm_step "Step description" && function_to_run
# Returns: 0 if confirmed or not interactive, 1 if skipped
confirm_step() {
	local step_name="$1"

	# Skip confirmation in non-interactive mode
	if [[ "$INTERACTIVE_MODE" != "true" ]]; then
		return 0
	fi

	echo ""
	echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo -e "${BLUE}Step:${NC} $step_name"
	echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

	while true; do
		echo -n -e "${GREEN}Run this step? [Y]es / [n]o / [q]uit: ${NC}"
		read -r response
		# Convert to lowercase (bash 3.2 compatible)
		response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
		case "$response" in
		y | yes | "")
			return 0
			;;
		n | no | s | skip)
			print_warning "Skipped: $step_name"
			return 1
			;;
		q | quit | exit)
			echo ""
			print_info "Setup cancelled by user"
			exit 0
			;;
		*)
			echo "Please answer: y (yes), n (no), or q (quit)"
			;;
		esac
	done
}

# Backup rotation settings
BACKUP_KEEP_COUNT=10

# Create a backup with rotation (keeps last N backups)
# Usage: create_backup_with_rotation <source_path> <backup_name>
# Example: create_backup_with_rotation "$target_dir" "agents"
# Creates: ~/.aidevops/agents-backups/20251221_123456/
create_backup_with_rotation() {
	local source_path="$1"
	local backup_name="$2"
	local backup_base="$HOME/.aidevops/${backup_name}-backups"
	local backup_dir
	backup_dir="$backup_base/$(date +%Y%m%d_%H%M%S)"

	# Create backup directory
	mkdir -p "$backup_dir"

	# Copy source to backup
	if [[ -d "$source_path" ]]; then
		cp -R "$source_path" "$backup_dir/"
	elif [[ -f "$source_path" ]]; then
		cp "$source_path" "$backup_dir/"
	else
		print_warning "Source path does not exist: $source_path"
		return 1
	fi

	print_info "Backed up to $backup_dir"

	# Rotate old backups (keep last N)
	local backup_count
	backup_count=$(find "$backup_base" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ')

	if [[ $backup_count -gt $BACKUP_KEEP_COUNT ]]; then
		local to_delete=$((backup_count - BACKUP_KEEP_COUNT))
		print_info "Rotating backups: removing $to_delete old backup(s), keeping last $BACKUP_KEEP_COUNT"

		# Delete oldest backups (sorted by name = sorted by date)
		find "$backup_base" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort | head -n "$to_delete" | while read -r old_backup; do
			rm -rf "$old_backup"
		done
	fi

	return 0
}

# Validate namespace string for safe use in paths and shell commands
# Returns 0 if valid, 1 if invalid
# Valid: alphanumeric, dash, underscore, forward slash (no .., no shell metacharacters)
validate_namespace() {
    local ns="$1"
    # Reject empty
    [[ -z "$ns" ]] && return 1
    # Reject path traversal
    [[ "$ns" == *".."* ]] && return 1
    # Reject shell metacharacters and dangerous characters
    [[ "$ns" =~ [^a-zA-Z0-9/_-] ]] && return 1
    # Reject absolute paths
    [[ "$ns" == /* ]] && return 1
    # Reject trailing slash (causes issues with rsync/tar exclusions)
    [[ "$ns" == */ ]] && return 1
    return 0
}

# Remove deprecated agent paths that have been moved
# This ensures clean upgrades when agents are reorganized
cleanup_deprecated_paths() {
	local agents_dir="$HOME/.aidevops/agents"
	local cleaned=0

	# List of deprecated paths (add new ones here when reorganizing)
	local deprecated_paths=(
		# v2.40.7: wordpress moved from root to tools/wordpress
		"$agents_dir/wordpress.md"
		"$agents_dir/wordpress"
		# v2.41.0: build-agent and build-mcp moved from root to tools/
		"$agents_dir/build-agent.md"
		"$agents_dir/build-agent"
		"$agents_dir/build-mcp.md"
		"$agents_dir/build-mcp"
		# v2.93.3: moltbot renamed to openclaw (formerly clawdbot)
		"$agents_dir/tools/ai-assistants/clawdbot.md"
		"$agents_dir/tools/ai-assistants/moltbot.md"
		# Removed non-OpenCode AI tool docs (focus on OpenCode only)
		"$agents_dir/tools/ai-assistants/windsurf.md"
		"$agents_dir/tools/ai-assistants/configuration.md"
		"$agents_dir/tools/ai-assistants/status.md"
		# Removed oh-my-opencode integration (no longer supported)
		"$agents_dir/tools/opencode/oh-my-opencode.md"
		# t199.8: youtube moved from root to content/distribution/youtube/
		"$agents_dir/youtube.md"
		"$agents_dir/youtube"
	)

	for path in "${deprecated_paths[@]}"; do
		if [[ -e "$path" ]]; then
			rm -rf "$path"
			((cleaned++)) || true
		fi
	done

	if [[ $cleaned -gt 0 ]]; then
		print_info "Cleaned up $cleaned deprecated agent path(s)"
	fi

	# Remove oh-my-opencode config file if present
	local omo_config="$HOME/.config/opencode/oh-my-opencode.json"
	if [[ -f "$omo_config" ]]; then
		rm -f "$omo_config"
		print_info "Removed deprecated oh-my-opencode config"
	fi

	# Remove oh-my-opencode from plugin array in opencode.json if present
	local opencode_config
	opencode_config=$(find_opencode_config 2>/dev/null) || true
	if [[ -n "$opencode_config" ]] && [[ -f "$opencode_config" ]] && command -v jq &>/dev/null; then
		if jq -e '.plugin | index("oh-my-opencode")' "$opencode_config" >/dev/null 2>&1; then
			local tmp_file
			tmp_file=$(mktemp)
			trap 'rm -f "${tmp_file:-}"' RETURN
			jq '.plugin = [.plugin[] | select(. != "oh-my-opencode")]' "$opencode_config" >"$tmp_file" && mv "$tmp_file" "$opencode_config"
			print_info "Removed oh-my-opencode from OpenCode plugin list"
		fi
	fi

	return 0
}

# Migrate .agent -> .agents in user projects and local config
# v2.104.0: Industry converging on .agents/ folder convention (aligning with AGENTS.md)
# This migrates:
# 1. .agent symlinks in user projects -> .agents
# 2. .agent/loop-state/ -> .agents/loop-state/ in user projects
# 3. .gitignore entries in user projects
# 4. References in user's AI assistant configs
# 5. References in ~/.aidevops/ config files
migrate_agent_to_agents_folder() {
	print_info "Checking for .agent -> .agents migration..."

	local migrated=0

	# 1. Migrate .agent symlinks in registered repos
	local repos_file="$HOME/.config/aidevops/repos.json"
	if [[ -f "$repos_file" ]] && command -v jq &>/dev/null; then
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path" ]] && continue

			# Migrate .agent symlink to .agents
			if [[ -L "$repo_path/.agent" ]]; then
				local target
				target=$(readlink "$repo_path/.agent")
				rm -f "$repo_path/.agent"
				ln -s "$target" "$repo_path/.agents" 2>/dev/null || true
				print_info "  Migrated symlink: $repo_path/.agent -> .agents"
				((migrated++)) || true
			elif [[ -d "$repo_path/.agent" && ! -L "$repo_path/.agent" ]]; then
				# Real directory (not symlink) - rename it
				if [[ ! -e "$repo_path/.agents" ]]; then
					mv "$repo_path/.agent" "$repo_path/.agents"
					print_info "  Renamed directory: $repo_path/.agent -> .agents"
					((migrated++)) || true
				fi
			fi

			# Update .gitignore: add .agents, keep .agent for backward compat
			local gitignore="$repo_path/.gitignore"
			if [[ -f "$gitignore" ]]; then
				# Add .agents entry if not present
				if ! grep -q "^\.agents$" "$gitignore" 2>/dev/null; then
					# Replace .agent with .agents if it exists
					if grep -q "^\.agent$" "$gitignore" 2>/dev/null; then
						sed -i '' 's/^\.agent$/.agents/' "$gitignore" 2>/dev/null ||
							sed -i 's/^\.agent$/.agents/' "$gitignore" 2>/dev/null || true
					else
						echo ".agents" >>"$gitignore"
					fi
					print_info "  Updated .gitignore in $(basename "$repo_path")"
				fi

				# Update .agent/loop-state/ -> .agents/loop-state/
				if grep -q "^\.agent/loop-state/" "$gitignore" 2>/dev/null; then
					sed -i '' 's|^\.agent/loop-state/|.agents/loop-state/|' "$gitignore" 2>/dev/null ||
						sed -i 's|^\.agent/loop-state/|.agents/loop-state/|' "$gitignore" 2>/dev/null || true
				fi
			fi
		done < <(jq -r '.initialized_repos[].path' "$repos_file" 2>/dev/null)
	fi

	# 2. Also scan ~/Git/ for any .agent symlinks or directories not in repos.json
	if [[ -d "$HOME/Git" ]]; then
		while IFS= read -r -d '' agent_path; do
			local repo_dir
			repo_dir=$(dirname "$agent_path")

			if [[ -L "$agent_path" ]]; then
				# Symlink: migrate or clean up stale
				if [[ ! -e "$repo_dir/.agents" ]]; then
					local target
					target=$(readlink "$agent_path")
					rm -f "$agent_path"
					ln -s "$target" "$repo_dir/.agents" 2>/dev/null || true
					print_info "  Migrated symlink: $agent_path -> .agents"
					((migrated++)) || true
				else
					# .agents already exists, remove stale .agent symlink
					rm -f "$agent_path"
					print_info "  Removed stale symlink: $agent_path (.agents already exists)"
					((migrated++)) || true
				fi
			elif [[ -d "$agent_path" ]]; then
				# Directory: rename to .agents if .agents doesn't exist
				if [[ ! -e "$repo_dir/.agents" ]]; then
					mv "$agent_path" "$repo_dir/.agents"
					print_info "  Renamed directory: $agent_path -> .agents"
					((migrated++)) || true
				fi
			fi
		done < <(find "$HOME/Git" -maxdepth 3 -name ".agent" \( -type l -o -type d \) -print0 2>/dev/null)
	fi

	# 3. Update AI assistant config files that reference .agent/
	local ai_config_files=(
		"$HOME/.config/opencode/agent/AGENTS.md"
		"$HOME/.config/Claude/AGENTS.md"
		"$HOME/.claude/commands/AGENTS.md"
		"$HOME/.opencode/AGENTS.md"
	)

	for config_file in "${ai_config_files[@]}"; do
		if [[ -f "$config_file" ]]; then
			if grep -q '\.agent/' "$config_file" 2>/dev/null; then
				sed -i '' 's|\.agent/|.agents/|g' "$config_file" 2>/dev/null ||
					sed -i 's|\.agent/|.agents/|g' "$config_file" 2>/dev/null || true
				print_info "  Updated references in $config_file"
				((migrated++)) || true
			fi
		fi
	done

	# 4. Update session greeting cache if it references .agent/
	local greeting_cache="$HOME/.aidevops/cache/session-greeting.txt"
	if [[ -f "$greeting_cache" ]]; then
		if grep -q '\.agent/' "$greeting_cache" 2>/dev/null; then
			sed -i '' 's|\.agent/|.agents/|g' "$greeting_cache" 2>/dev/null ||
				sed -i 's|\.agent/|.agents/|g' "$greeting_cache" 2>/dev/null || true
		fi
	fi

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated .agent -> .agents reference(s)"
	else
		print_info "No .agent -> .agents migration needed"
	fi

	return 0
}

# Remove deprecated MCP entries from opencode.json
# These MCPs have been replaced by curl-based subagents (zero context cost)
cleanup_deprecated_mcps() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	# MCPs replaced by curl subagents in v2.79.0
	local deprecated_mcps=(
		"hetzner-awardsapp"
		"hetzner-brandlight"
		"hetzner-marcusquinn"
		"hetzner-storagebox"
		"ahrefs"
		"serper"
		"dataforseo"
		"hostinger-api"
		"shadcn"
		"repomix"
	)

	# Tool rules to remove (for MCPs that no longer exist)
	local deprecated_tools=(
		"hetzner-*"
		"hostinger-api_*"
		"ahrefs_*"
		"dataforseo_*"
		"serper_*"
		"shadcn_*"
		"repomix_*"
	)

	local cleaned=0
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	cp "$opencode_config" "$tmp_config"

	for mcp in "${deprecated_mcps[@]}"; do
		if jq -e ".mcp[\"$mcp\"]" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.mcp[\"$mcp\"])" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((cleaned++)) || true
		fi
	done

	for tool in "${deprecated_tools[@]}"; do
		if jq -e ".tools[\"$tool\"]" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.tools[\"$tool\"])" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
		fi
	done

	# Also remove deprecated tool refs from SEO agent
	if jq -e '.agent.SEO.tools["dataforseo_*"]' "$tmp_config" >/dev/null 2>&1; then
		jq 'del(.agent.SEO.tools["dataforseo_*"]) | del(.agent.SEO.tools["serper_*"]) | del(.agent.SEO.tools["ahrefs_*"])' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
	fi

	# Migrate npx/pipx commands to full binary paths (faster startup, PATH-independent)
	# Parallel arrays avoid bash associative array issues with @ in package names
	local -a mcp_pkgs=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"@steipete/macos-automator-mcp"
		"@steipete/claude-code-mcp"
		"analytics-mcp"
	)
	local -a mcp_bins=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"macos-automator-mcp"
		"claude-code-mcp"
		"analytics-mcp"
	)

	local i
	for i in "${!mcp_pkgs[@]}"; do
		local pkg="${mcp_pkgs[$i]}"
		local bin_name="${mcp_bins[$i]}"
		# Find MCP key using npx/bunx/pipx for this package (single query)
		local mcp_key
		mcp_key=$(jq -r --arg pkg "$pkg" '.mcp | to_entries[] | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' "$tmp_config" 2>/dev/null | head -1)

		if [[ -n "$mcp_key" ]]; then
			# Resolve full path for the binary
			local full_path
			full_path=$(resolve_mcp_binary_path "$bin_name")
			if [[ -n "$full_path" ]]; then
				jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command = [$p]' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
				((cleaned++)) || true
			fi
		fi
	done

	# Migrate outscraper from bash -c wrapper to full binary path
	if jq -e '.mcp.outscraper.command | join(" ") | test("bash.*outscraper")' "$tmp_config" >/dev/null 2>&1; then
		local outscraper_path
		outscraper_path=$(resolve_mcp_binary_path "outscraper-mcp-server")
		if [[ -n "$outscraper_path" ]]; then
			# Source the API key and set it in environment
			local outscraper_key=""
			if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
				# shellcheck source=/dev/null
				outscraper_key=$(source "$HOME/.config/aidevops/credentials.sh" && echo "${OUTSCRAPER_API_KEY:-}")
			fi
			jq --arg p "$outscraper_path" --arg key "$outscraper_key" '.mcp.outscraper.command = [$p] | .mcp.outscraper.environment = {"OUTSCRAPER_API_KEY": $key}' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((cleaned++)) || true
		fi
	fi

	if [[ $cleaned -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_info "Updated $cleaned MCP entry/entries in opencode.json (using full binary paths)"
	else
		rm -f "$tmp_config"
	fi

	# Always resolve bare binary names to full paths (fixes PATH-dependent startup)
	update_mcp_paths_in_opencode

	return 0
}

# Disable MCPs globally that should only be enabled on-demand via subagents
# This reduces session startup context by disabling rarely-used MCPs
# - playwriter: ~3K tokens - enable via @playwriter subagent
# - augment-context-engine: ~1K tokens - enable via @augment-context-engine subagent
# - gh_grep: ~600 tokens - replaced by @github-search subagent (uses rg/bash)
# - google-analytics-mcp: ~800 tokens - enable via @google-analytics subagent
# - context7: ~800 tokens - enable via @context7 subagent (for library docs lookup)
disable_ondemand_mcps() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	# MCPs to disable globally (these have subagent alternatives or are unused)
	# Note: use exact MCP key names from opencode.json
	local -a ondemand_mcps=(
		"playwriter"
		"augment-context-engine"
		"gh_grep"
		"google-analytics-mcp"
		"grep_app"
		"websearch"
		# KEEP ENABLED: osgrep (semantic code search), context7 (library docs)
	)

	local disabled=0
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	cp "$opencode_config" "$tmp_config"

	for mcp in "${ondemand_mcps[@]}"; do
		# Only disable MCPs that exist in the config
		# Don't add fake entries - they break OpenCode's config validation
		if jq -e ".mcp[\"$mcp\"]" "$tmp_config" >/dev/null 2>&1; then
			local current_enabled
			current_enabled=$(jq -r ".mcp[\"$mcp\"].enabled // \"true\"" "$tmp_config")
			if [[ "$current_enabled" != "false" ]]; then
				jq ".mcp[\"$mcp\"].enabled = false" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
				((disabled++)) || true
			fi
		fi
	done

	# Remove invalid MCP entries added by v2.100.16 bug
	# These have type "stdio" (invalid - only "local" or "remote" are valid)
	# or command ["echo", "disabled"] which breaks OpenCode
	local invalid_mcps=("grep_app" "websearch" "context7" "augment-context-engine")
	for mcp in "${invalid_mcps[@]}"; do
		# Check for invalid type "stdio" or dummy command
		if jq -e ".mcp[\"$mcp\"].type == \"stdio\" or .mcp[\"$mcp\"].command[0] == \"echo\"" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.mcp[\"$mcp\"])" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			print_info "Removed invalid MCP entry: $mcp"
			disabled=1 # Mark as changed
		fi
	done

	# Re-enable MCPs that were accidentally disabled (v2.100.16-17 bug)
	local -a keep_enabled=("osgrep" "context7")
	for mcp in "${keep_enabled[@]}"; do
		if jq -e ".mcp[\"$mcp\"].enabled == false" "$tmp_config" >/dev/null 2>&1; then
			jq ".mcp[\"$mcp\"].enabled = true" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			print_info "Re-enabled $mcp MCP"
			disabled=1 # Mark as changed
		fi
	done

	if [[ $disabled -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_info "Disabled $disabled MCP(s) globally (use subagents to enable on-demand)"
	else
		rm -f "$tmp_config"
	fi

	return 0
}

# Validate and repair OpenCode config schema
# Fixes common issues from manual editing or AI-generated configs:
# - MCP entries missing "type": "local" field
# - tools entries as objects {} instead of booleans
# If invalid, backs up and regenerates using the generator script
validate_opencode_config() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local needs_repair=false
	local issues=""

	# Check 0: Remove deprecated top-level keys that OpenCode no longer recognizes
	# "compaction" was removed in OpenCode v1.1.x - causes "Unrecognized key" error
	local deprecated_keys=("compaction")
	for key in "${deprecated_keys[@]}"; do
		if jq -e ".[\"$key\"]" "$opencode_config" >/dev/null 2>&1; then
			local tmp_fix
			tmp_fix=$(mktemp)
			trap 'rm -f "${tmp_fix:-}"' RETURN
			if jq "del(.[\"$key\"])" "$opencode_config" >"$tmp_fix" 2>/dev/null; then
				create_backup_with_rotation "$opencode_config" "opencode"
				mv "$tmp_fix" "$opencode_config"
				print_info "Removed deprecated '$key' key from OpenCode config"
			else
				rm -f "$tmp_fix"
			fi
		fi
	done

	# Check 1: MCP entries must have "type" field (usually "local")
	# Invalid: {"mcp": {"foo": {"command": "..."}}}
	# Valid:   {"mcp": {"foo": {"type": "local", "command": "..."}}}
	local mcps_without_type
	mcps_without_type=$(jq -r '.mcp // {} | to_entries[] | select(.value.type == null and .value.command != null) | .key' "$opencode_config" 2>/dev/null | head -5)
	if [[ -n "$mcps_without_type" ]]; then
		needs_repair=true
		issues="${issues}\n  - MCP entries missing 'type' field: $(echo "$mcps_without_type" | tr '\n' ', ' | sed 's/,$//')"
	fi

	# Check 2: tools entries must be booleans, not objects
	# Invalid: {"tools": {"gh_grep": {}}}
	# Valid:   {"tools": {"gh_grep": true}}
	local tools_as_objects
	tools_as_objects=$(jq -r '.tools // {} | to_entries[] | select(.value | type == "object") | .key' "$opencode_config" 2>/dev/null | head -5)
	if [[ -n "$tools_as_objects" ]]; then
		needs_repair=true
		issues="${issues}\n  - tools entries as objects instead of booleans: $(echo "$tools_as_objects" | tr '\n' ', ' | sed 's/,$//')"
	fi

	# Check 3: Try to parse with opencode (if available) to catch other schema issues
	if command -v opencode &>/dev/null; then
		local validation_output
		if ! validation_output=$(opencode --version 2>&1); then
			# If opencode fails to start, config might be invalid
			if echo "$validation_output" | grep -q "Configuration is invalid"; then
				needs_repair=true
				issues="${issues}\n  - OpenCode reports invalid configuration"
			fi
		fi
	fi

	if [[ "$needs_repair" == "true" ]]; then
		print_warning "OpenCode config has schema issues:$issues"

		# Backup the invalid config
		create_backup_with_rotation "$opencode_config" "opencode"
		print_info "Backed up invalid config"

		# Remove the invalid config so generator creates fresh one
		rm -f "$opencode_config"

		# Regenerate using the generator script
		local generator_script="$HOME/.aidevops/agents/scripts/generate-opencode-agents.sh"
		if [[ -x "$generator_script" ]]; then
			print_info "Regenerating OpenCode config with correct schema..."
			if "$generator_script" >/dev/null 2>&1; then
				print_success "OpenCode config regenerated successfully"
			else
				print_warning "Config regeneration failed - run manually: $generator_script"
			fi
		else
			print_warning "Generator script not found - run setup.sh again after agents are deployed"
		fi
	fi

	return 0
}

# Migrate mcp-env.sh to credentials.sh (v2.105.0)
# Renames the credential file and creates backward-compatible symlink
migrate_mcp_env_to_credentials() {
	local config_dir="$HOME/.config/aidevops"
	local old_file="$config_dir/mcp-env.sh"
	local new_file="$config_dir/credentials.sh"
	local migrated=0

	# Migrate root-level mcp-env.sh -> credentials.sh
	if [[ -f "$old_file" && ! -L "$old_file" ]]; then
		if [[ ! -f "$new_file" ]]; then
			mv "$old_file" "$new_file"
			chmod 600 "$new_file"
			((migrated++)) || true
			print_info "Renamed mcp-env.sh to credentials.sh"
		fi
		# Create backward-compatible symlink
		if [[ ! -L "$old_file" ]]; then
			ln -sf "credentials.sh" "$old_file"
			print_info "Created symlink mcp-env.sh -> credentials.sh"
		fi
	fi

	# Migrate tenant-level mcp-env.sh -> credentials.sh
	local tenants_dir="$config_dir/tenants"
	if [[ -d "$tenants_dir" ]]; then
		for tenant_dir in "$tenants_dir"/*/; do
			[[ -d "$tenant_dir" ]] || continue
			local tenant_old="$tenant_dir/mcp-env.sh"
			local tenant_new="$tenant_dir/credentials.sh"
			if [[ -f "$tenant_old" && ! -L "$tenant_old" ]]; then
				if [[ ! -f "$tenant_new" ]]; then
					mv "$tenant_old" "$tenant_new"
					chmod 600 "$tenant_new"
					((migrated++)) || true
				fi
				if [[ ! -L "$tenant_old" ]]; then
					ln -sf "credentials.sh" "$tenant_old"
				fi
			fi
		done
	fi

	# Update shell rc files that source the old path
	for rc_file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
		if [[ -f "$rc_file" ]] && grep -q 'source.*mcp-env\.sh' "$rc_file" 2>/dev/null; then
			# shellcheck disable=SC2016
			sed -i '' 's|source.*\.config/aidevops/mcp-env\.sh|source "$HOME/.config/aidevops/credentials.sh"|g' "$rc_file" 2>/dev/null ||
				sed -i 's|source.*\.config/aidevops/mcp-env\.sh|source "$HOME/.config/aidevops/credentials.sh"|g' "$rc_file" 2>/dev/null || true
			((migrated++)) || true
			print_info "Updated $rc_file to source credentials.sh"
		fi
	done

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated mcp-env.sh -> credentials.sh reference(s)"
	fi

	return 0
}

# Migrate old config-backups to new per-type backup structure
# This runs once to clean up the legacy backup directory
migrate_old_backups() {
	local old_backup_dir="$HOME/.aidevops/config-backups"

	# Skip if old directory doesn't exist
	if [[ ! -d "$old_backup_dir" ]]; then
		return 0
	fi

	# Count old backups
	local old_count
	old_count=$(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ')

	if [[ $old_count -eq 0 ]]; then
		# Empty directory, just remove it
		rm -rf "$old_backup_dir"
		return 0
	fi

	print_info "Migrating $old_count old backups to new structure..."

	# Create new backup directories
	mkdir -p "$HOME/.aidevops/agents-backups"
	mkdir -p "$HOME/.aidevops/opencode-backups"

	# Move the most recent backups (up to BACKUP_KEEP_COUNT) to new locations
	# Old backups contained mixed content, so we'll just keep the newest ones as agents backups
	local migrated=0
	for backup in $(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r | head -n "$BACKUP_KEEP_COUNT"); do
		local backup_name
		backup_name=$(basename "$backup")

		# Check if it contains agents folder (most common)
		if [[ -d "$backup/agents" ]]; then
			mv "$backup" "$HOME/.aidevops/agents-backups/$backup_name"
			((migrated++)) || true
		# Check if it contains opencode.json
		elif [[ -f "$backup/opencode.json" ]]; then
			mv "$backup" "$HOME/.aidevops/opencode-backups/$backup_name"
			((migrated++)) || true
		fi
	done

	# Remove remaining old backups and the old directory
	rm -rf "$old_backup_dir"

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated recent backups, removed $((old_count - migrated)) old backups"
	else
		print_info "Cleaned up $old_count old backups"
	fi

	return 0
}

# Migrate loop state from .claude/ to .agents/loop-state/ in user projects
# Also migrates from legacy .agents/loop-state/ to .agents/loop-state/
# The migration is non-destructive: moves files, doesn't delete originals until confirmed
migrate_loop_state_directories() {
	print_info "Checking for legacy loop state directories..."

	local migrated=0
	local git_dirs=()

	# Find Git repositories in common locations
	# Check ~/Git/ and current directory's parent
	for search_dir in "$HOME/Git" "$(dirname "$(pwd)")"; do
		if [[ -d "$search_dir" ]]; then
			while IFS= read -r -d '' git_dir; do
				git_dirs+=("$(dirname "$git_dir")")
			done < <(find "$search_dir" -maxdepth 3 -type d -name ".git" -print0 2>/dev/null)
		fi
	done

	for repo_dir in "${git_dirs[@]}"; do
		local old_state_dir="$repo_dir/.claude"
		local legacy_state_dir="$repo_dir/.agent/loop-state"
		local new_state_dir="$repo_dir/.agents/loop-state"

		# Migrate from .claude/ (oldest legacy path)
		if [[ -d "$old_state_dir" ]]; then
			local has_loop_state=false
			if [[ -f "$old_state_dir/ralph-loop.local.state" ]] ||
				[[ -f "$old_state_dir/loop-state.json" ]] ||
				[[ -d "$old_state_dir/receipts" ]]; then
				has_loop_state=true
			fi

			if [[ "$has_loop_state" == "true" ]]; then
				print_info "Found legacy loop state in: $repo_dir/.claude/"
				mkdir -p "$new_state_dir"

				for file in ralph-loop.local.state loop-state.json re-anchor.md guardrails.md; do
					if [[ -f "$old_state_dir/$file" ]]; then
						mv "$old_state_dir/$file" "$new_state_dir/"
						print_info "  Moved $file"
					fi
				done

				if [[ -d "$old_state_dir/receipts" ]]; then
					mv "$old_state_dir/receipts" "$new_state_dir/"
					print_info "  Moved receipts/"
				fi

				local remaining
				remaining=$(find "$old_state_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

				if [[ "$remaining" -eq 0 ]]; then
					rmdir "$old_state_dir" 2>/dev/null && print_info "  Removed empty .claude/"
				else
					print_warning "  .claude/ has other files, not removing"
				fi

				((migrated++)) || true
			fi
		fi

		# Migrate from .agents/loop-state/ (v2.51.0-v2.103.0 path) to .agents/loop-state/
		if [[ -d "$legacy_state_dir" ]] && [[ "$legacy_state_dir" != "$new_state_dir" ]]; then
			print_info "Found legacy loop state in: $repo_dir/.agent/loop-state/"
			mkdir -p "$new_state_dir"

			# Move all files from old to new
			if [[ -n "$(ls -A "$legacy_state_dir" 2>/dev/null)" ]]; then
				cp -R "$legacy_state_dir"/* "$new_state_dir/" 2>/dev/null || true
				rm -rf "$legacy_state_dir"
				print_info "  Migrated .agents/loop-state/ -> .agents/loop-state/"
				((migrated++)) || true
			fi
		fi

		# Update .gitignore if needed
		local gitignore="$repo_dir/.gitignore"
		if [[ -f "$gitignore" ]]; then
			if ! grep -q "^\.agents/loop-state/" "$gitignore" 2>/dev/null; then
				echo ".agents/loop-state/" >>"$gitignore"
				print_info "  Added .agents/loop-state/ to .gitignore"
			fi
		fi
	done

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated loop state in $migrated repositories"
	else
		print_info "No legacy loop state directories found"
	fi

	return 0
}

# Bootstrap: Clone or update repo if running remotely (via curl)
bootstrap_repo() {
	# Detect if running from curl (no script directory context)
	local script_path="${BASH_SOURCE[0]}"

	# If script_path is empty, stdin, bash, or /dev/fd/* (process substitution), we're running from curl
	# bash <(curl ...) produces paths like /dev/fd/63
	if [[ -z "$script_path" || "$script_path" == "/dev/stdin" || "$script_path" == "bash" || "$script_path" == /dev/fd/* ]]; then
		print_info "Remote install detected - bootstrapping repository..."

		# On macOS, offer choice: install locally or in an OrbStack VM
		if [[ "$(uname)" == "Darwin" ]]; then
			echo ""
			echo "Where would you like to install aidevops?"
			echo ""
			echo "  1) Install on this Mac (recommended)"
			echo "  2) Install in a Linux VM (via OrbStack)"
			echo ""
			read -r -p "Choose [1/2] (default: 1): " install_target

			if [[ "$install_target" == "2" ]]; then
				print_info "Setting up OrbStack VM installation..."

				# Install OrbStack if not present
				if ! command -v orb >/dev/null 2>&1 && [[ ! -d "/Applications/OrbStack.app" ]]; then
					if command -v brew >/dev/null 2>&1; then
						print_info "Installing OrbStack via Homebrew..."
						brew install --cask orbstack
					else
						print_error "Homebrew is required to install OrbStack"
						echo "Install Homebrew first: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
						echo "Then re-run this installer."
						exit 1
					fi
				fi

				# Wait for OrbStack to be ready
				if ! command -v orb >/dev/null 2>&1; then
					print_info "Waiting for OrbStack CLI to become available..."
					# OrbStack installs the CLI at /usr/local/bin/orb
					local wait_count=0
					while ! command -v orb >/dev/null 2>&1 && [[ $wait_count -lt 30 ]]; do
						sleep 2
						((wait_count++)) || true
					done
					if ! command -v orb >/dev/null 2>&1; then
						print_error "OrbStack CLI not found after installation"
						echo "Open OrbStack.app manually, then re-run this installer."
						exit 1
					fi
				fi

				# Create or use existing Ubuntu VM
				local vm_name="aidevops"
				if orb list 2>/dev/null | grep -qxF "$vm_name"; then
					print_info "Using existing OrbStack VM: $vm_name"
				else
					print_info "Creating Ubuntu VM: $vm_name..."
					orb create ubuntu "$vm_name"
				fi

				# Run the installer inside the VM
				print_info "Installing aidevops inside the VM..."
				echo ""
				orb run -m "$vm_name" bash -c 'bash <(curl -fsSL https://aidevops.sh/install)'

				echo ""
				print_success "aidevops installed in OrbStack VM: $vm_name"
				echo ""
				echo "To use aidevops in the VM:"
				echo "  orb shell $vm_name              # Enter the VM"
				echo "  orb run -m $vm_name opencode    # Run OpenCode directly"
				echo ""
				exit 0
			fi
		fi

		# Auto-install git if missing (required for cloning)
		if ! command -v git >/dev/null 2>&1; then
			print_warning "git is required but not installed - attempting auto-install..."
			if [[ "$(uname)" == "Darwin" ]]; then
				# macOS: xcode-select --install triggers git install
				print_info "Installing Xcode Command Line Tools (includes git)..."
				if xcode-select --install 2>/dev/null; then
					# Wait for installation to complete (timeout after 5 minutes)
					print_info "Waiting for Xcode CLT installation to complete (timeout: 5m)..."
					local xcode_wait=0
					local xcode_max_wait=300
					until command -v git >/dev/null 2>&1; do
						sleep 5
						xcode_wait=$((xcode_wait + 5))
						if [[ $xcode_wait -ge $xcode_max_wait ]]; then
							print_error "Timed out waiting for Xcode CLT installation after ${xcode_max_wait}s"
							echo "Complete the installation manually, then re-run this installer."
							exit 1
						fi
					done
					print_success "git installed via Xcode Command Line Tools"
				else
					# Already installed or failed
					if ! command -v git >/dev/null 2>&1; then
						print_error "git installation failed"
						echo "Install git manually: brew install git (macOS)"
						exit 1
					fi
				fi
			elif command -v apt-get >/dev/null 2>&1; then
				print_info "Installing git via apt..."
				sudo apt-get update -qq && sudo apt-get install -y -qq git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v dnf >/dev/null 2>&1; then
				print_info "Installing git via dnf..."
				sudo dnf install -y git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v yum >/dev/null 2>&1; then
				print_info "Installing git via yum..."
				sudo yum install -y git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v pacman >/dev/null 2>&1; then
				print_info "Installing git via pacman..."
				sudo pacman -S --noconfirm git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v apk >/dev/null 2>&1; then
				print_info "Installing git via apk..."
				sudo apk add git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			else
				print_error "git is required but not installed and no supported package manager found"
				echo "Install git manually and re-run the installer"
				exit 1
			fi
		fi

		# Create parent directory
		mkdir -p "$(dirname "$INSTALL_DIR")"

		if [[ -d "$INSTALL_DIR/.git" ]]; then
			print_info "Existing installation found - updating..."
			cd "$INSTALL_DIR" || exit 1
			if ! git pull --ff-only; then
				print_warning "Git pull failed - trying reset to origin/main"
				git fetch origin
				git reset --hard origin/main
			fi
		else
			print_info "Cloning aidevops to $INSTALL_DIR..."
			if [[ -d "$INSTALL_DIR" ]]; then
				print_warning "Directory exists but is not a git repo - backing up"
				mv "$INSTALL_DIR" "$INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
			fi
			if ! git clone "$REPO_URL" "$INSTALL_DIR"; then
				print_error "Failed to clone repository"
				exit 1
			fi
		fi

		print_success "Repository ready at $INSTALL_DIR"

		# Re-execute the local script
		cd "$INSTALL_DIR" || exit 1
		exec bash "./setup.sh" "$@"
	fi
}

# Detect package manager
detect_package_manager() {
	if command -v brew >/dev/null 2>&1; then
		echo "brew"
	elif command -v apt-get >/dev/null 2>&1; then
		echo "apt"
	elif command -v dnf >/dev/null 2>&1; then
		echo "dnf"
	elif command -v yum >/dev/null 2>&1; then
		echo "yum"
	elif command -v pacman >/dev/null 2>&1; then
		echo "pacman"
	elif command -v apk >/dev/null 2>&1; then
		echo "apk"
	else
		echo "unknown"
	fi
}

# Install packages using detected package manager
install_packages() {
	local pkg_manager="$1"
	shift
	local packages=("$@")

	case "$pkg_manager" in
	brew)
		brew install "${packages[@]}"
		;;
	apt)
		sudo apt-get update && sudo apt-get install -y "${packages[@]}"
		;;
	dnf)
		sudo dnf install -y "${packages[@]}"
		;;
	yum)
		sudo yum install -y "${packages[@]}"
		;;
	pacman)
		sudo pacman -S --noconfirm "${packages[@]}"
		;;
	apk)
		sudo apk add "${packages[@]}"
		;;
	*)
		return 1
		;;
	esac
}

# Offer to install Homebrew (Linuxbrew) on Linux when brew is not available
# Many tools in the aidevops ecosystem (Beads, Worktrunk, bv) are distributed
# via Homebrew taps. On macOS, brew is almost always present. On Linux, this
# function offers to install it so those tools can be installed automatically.
# Returns: 0 if brew is now available, 1 if user declined or install failed
ensure_homebrew() {
	# Already available
	if command -v brew &>/dev/null; then
		return 0
	fi

	# Only offer on Linux (macOS users should install Homebrew themselves)
	if [[ "$(uname)" == "Darwin" ]]; then
		print_warning "Homebrew not found. Install from https://brew.sh"
		return 1
	fi

	# Non-interactive mode: skip
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		return 1
	fi

	echo ""
	print_info "Homebrew (Linuxbrew) is not installed."
	print_info "Several optional tools (Beads CLI, Worktrunk, bv) install via Homebrew taps."
	echo ""
	read -r -p "Install Homebrew for Linux? [Y/n]: " install_brew

	if [[ ! "$install_brew" =~ ^[Yy]?$ ]]; then
		print_info "Skipped Homebrew installation"
		return 1
	fi

	print_info "Installing Homebrew (Linuxbrew)..."

	# Prerequisites for Linuxbrew
	if command -v apt-get &>/dev/null; then
		sudo apt-get update -qq
		sudo apt-get install -y -qq build-essential procps curl file git
	elif command -v dnf &>/dev/null; then
		sudo dnf groupinstall -y 'Development Tools'
		sudo dnf install -y procps-ng curl file git
	elif command -v yum &>/dev/null; then
		sudo yum groupinstall -y 'Development Tools'
		sudo yum install -y procps-ng curl file git
	fi

	# Install Homebrew using verified_install pattern
	if verified_install "Homebrew" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"; then
		# Add Homebrew to PATH for this session
		local brew_prefix="/home/linuxbrew/.linuxbrew"
		if [[ -x "$brew_prefix/bin/brew" ]]; then
			eval "$("$brew_prefix/bin/brew" shellenv)"
		fi

		# Persist to shell rc files
		local brew_line="eval \"\$($brew_prefix/bin/brew shellenv)\""
		local rc_file
		while IFS= read -r rc_file; do
			[[ -z "$rc_file" ]] && continue
			if ! grep -q 'linuxbrew' "$rc_file" 2>/dev/null; then
				{
					echo ""
					echo "# Homebrew (Linuxbrew) - added by aidevops setup"
					echo "$brew_line"
				} >>"$rc_file"
			fi
		done < <(get_all_shell_rcs)

		if command -v brew &>/dev/null; then
			print_success "Homebrew installed and added to PATH"
			return 0
		else
			print_warning "Homebrew installed but not yet in PATH. Restart your shell or run:"
			echo "  $brew_line"
			return 1
		fi
	else
		print_warning "Homebrew installation failed"
		return 1
	fi
}

# Check system requirements
check_requirements() {
	print_info "Checking system requirements..."

	# Ensure Homebrew is in PATH (macOS Apple Silicon)
	if [[ -x "/opt/homebrew/bin/brew" ]] && ! echo "$PATH" | grep -q "/opt/homebrew/bin"; then
		eval "$(/opt/homebrew/bin/brew shellenv)"
		print_warning "Homebrew not in PATH - added for this session"

		# Auto-fix: add Homebrew to all existing shell rc files
		local brew_line='eval "$(/opt/homebrew/bin/brew shellenv)"'
		local fixed_rc=false
		local rc_file
		while IFS= read -r rc_file; do
			[[ -z "$rc_file" ]] && continue
			if ! grep -q '/opt/homebrew/bin/brew' "$rc_file" 2>/dev/null; then
				echo "" >>"$rc_file"
				echo "# Homebrew (added by aidevops setup)" >>"$rc_file"
				echo "$brew_line" >>"$rc_file"
				print_success "Added Homebrew to PATH in $rc_file"
				fixed_rc=true
			fi
		done < <(get_all_shell_rcs)

		if [[ "$fixed_rc" == "false" ]]; then
			echo ""
			echo "  To fix permanently, add to your shell rc file:"
			echo "    $brew_line"
			echo ""
		fi
	fi

	# Also check Intel Mac Homebrew location
	if [[ -x "/usr/local/bin/brew" ]] && ! echo "$PATH" | grep -q "/usr/local/bin"; then
		eval "$(/usr/local/bin/brew shellenv)"
		print_warning "Homebrew (/usr/local/bin) not in PATH - added for this session"

		local intel_brew_line='eval "$(/usr/local/bin/brew shellenv)"'
		local intel_rc
		while IFS= read -r intel_rc; do
			[[ -z "$intel_rc" ]] && continue
			if ! grep -q '/usr/local/bin/brew' "$intel_rc" 2>/dev/null; then
				echo "" >>"$intel_rc"
				echo "# Homebrew Intel Mac (added by aidevops setup)" >>"$intel_rc"
				echo "$intel_brew_line" >>"$intel_rc"
				print_success "Added Homebrew to PATH in $intel_rc"
			fi
		done < <(get_all_shell_rcs)
	fi

	local missing_deps=()

	# Check for required commands
	command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
	command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
	command -v ssh >/dev/null 2>&1 || missing_deps+=("ssh")

	if [[ ${#missing_deps[@]} -gt 0 ]]; then
		print_warning "Missing required dependencies: ${missing_deps[*]}"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" == "unknown" ]]; then
			print_error "Could not detect package manager"
			echo ""
			echo "Please install manually:"
			echo "  macOS: brew install ${missing_deps[*]}"
			echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
			echo "  Fedora: sudo dnf install ${missing_deps[*]}"
			echo "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
			echo "  Arch: sudo pacman -S ${missing_deps[*]}"
			echo "  Alpine: sudo apk add ${missing_deps[*]}"
			exit 1
		fi

		# In non-interactive mode, fail fast on missing deps
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			print_error "Cannot continue without required dependencies (non-interactive mode)"
			exit 1
		fi

		echo ""
		read -r -p "Install missing dependencies using $pkg_manager? [Y/n]: " install_deps

		if [[ "$install_deps" =~ ^[Yy]?$ ]]; then
			print_info "Installing ${missing_deps[*]}..."
			if install_packages "$pkg_manager" "${missing_deps[@]}"; then
				print_success "Dependencies installed successfully"
			else
				print_error "Failed to install dependencies"
				exit 1
			fi
		else
			print_error "Cannot continue without required dependencies"
			exit 1
		fi
	fi

	print_success "All required dependencies found"
}

# Check for quality/linting tools (shellcheck, shfmt)
# These are optional but recommended for development
check_quality_tools() {
	print_info "Checking quality tools..."

	local missing_tools=()

	# Check for shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		print_success "shellcheck: $(shellcheck --version | head -1)"
	else
		missing_tools+=("shellcheck")
	fi

	# Check for shfmt
	if command -v shfmt >/dev/null 2>&1; then
		print_success "shfmt: $(shfmt --version)"
	else
		missing_tools+=("shfmt")
	fi

	# If all tools present, return early
	if [[ ${#missing_tools[@]} -eq 0 ]]; then
		print_success "All quality tools installed"
		return 0
	fi

	# Show missing tools
	print_warning "Missing quality tools: ${missing_tools[*]}"
	print_info "These tools are used by linters-local.sh for code quality checks"

	# In non-interactive mode, just warn and continue
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		print_info "Install later: brew install ${missing_tools[*]}"
		return 0
	fi

	# Offer to install
	local pkg_manager
	pkg_manager=$(detect_package_manager)

	if [[ "$pkg_manager" == "unknown" ]]; then
		print_info "Install manually:"
		echo "  macOS: brew install ${missing_tools[*]}"
		echo "  Ubuntu/Debian: sudo apt-get install ${missing_tools[*]}"
		echo "  Fedora: sudo dnf install ${missing_tools[*]}"
		return 0
	fi

	echo ""
	read -r -p "Install quality tools using $pkg_manager? [Y/n]: " install_quality

	if [[ "$install_quality" =~ ^[Yy]?$ ]]; then
		print_info "Installing ${missing_tools[*]}..."
		if install_packages "$pkg_manager" "${missing_tools[@]}"; then
			print_success "Quality tools installed successfully"
		else
			print_warning "Failed to install some quality tools - continuing anyway"
		fi
	else
		print_info "Skipped quality tools installation"
		print_info "Install later: $pkg_manager install ${missing_tools[*]}"
	fi

	return 0
}

# Detect the current running shell (not $SHELL which is the login default)
# On a fresh Mac, $SHELL is /bin/zsh but setup may be run via bash <(curl ...)
# Returns: "bash" or "zsh" or the shell name
detect_running_shell() {
	if [[ -n "${ZSH_VERSION:-}" ]]; then
		echo "zsh"
	elif [[ -n "${BASH_VERSION:-}" ]]; then
		echo "bash"
	else
		basename "${SHELL:-/bin/bash}"
	fi
	return 0
}

# Detect the user's preferred/default shell (what they'll use day-to-day)
# This is $SHELL (login shell), not necessarily what's running setup.sh
detect_default_shell() {
	basename "${SHELL:-/bin/bash}"
	return 0
}

# Get the appropriate shell rc file for a given shell
# Usage: get_shell_rc "zsh" or get_shell_rc "bash"
get_shell_rc() {
	local shell_name="$1"
	case "$shell_name" in
	zsh)
		echo "$HOME/.zshrc"
		;;
	bash)
		if [[ "$(uname)" == "Darwin" ]]; then
			echo "$HOME/.bash_profile"
		else
			echo "$HOME/.bashrc"
		fi
		;;
	fish)
		echo "$HOME/.config/fish/config.fish"
		;;
	ksh)
		echo "$HOME/.kshrc"
		;;
	*)
		# Fallback: check common rc files
		if [[ -f "$HOME/.zshrc" ]]; then
			echo "$HOME/.zshrc"
		elif [[ -f "$HOME/.bashrc" ]]; then
			echo "$HOME/.bashrc"
		elif [[ -f "$HOME/.bash_profile" ]]; then
			echo "$HOME/.bash_profile"
		else
			echo ""
		fi
		;;
	esac
	return 0
}

# Get ALL shell rc files that should be updated (both bash and zsh on macOS)
# On macOS, users may switch between bash and zsh, so we update both if they exist
# Returns newline-separated list of rc files
get_all_shell_rcs() {
	local rcs=()

	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: always include zsh (default since Catalina) and bash_profile
		[[ -f "$HOME/.zshrc" ]] && rcs+=("$HOME/.zshrc")
		[[ -f "$HOME/.bash_profile" ]] && rcs+=("$HOME/.bash_profile")
		# If neither exists, create .zshrc (macOS default)
		if [[ ${#rcs[@]} -eq 0 ]]; then
			touch "$HOME/.zshrc"
			rcs+=("$HOME/.zshrc")
		fi
	else
		# Linux: use the default shell's rc file
		local default_shell
		default_shell=$(detect_default_shell)
		local rc
		rc=$(get_shell_rc "$default_shell")
		if [[ -n "$rc" ]]; then
			rcs+=("$rc")
		fi
	fi

	printf '%s\n' "${rcs[@]}"
	return 0
}

# Setup Oh My Zsh (optional, offered early so later tools benefit from zsh)
# On a fresh Mac, the default shell is zsh but Oh My Zsh is not installed.
# Many tools (completions, plugins, themes) work better with Oh My Zsh.
# This is opt-in (lowercase y, not capital Y) since some users prefer plain zsh.
setup_oh_my_zsh() {
	# Only relevant if zsh is available
	if ! command -v zsh >/dev/null 2>&1; then
		print_info "zsh not found - skipping Oh My Zsh setup"
		return 0
	fi

	# Check if Oh My Zsh is already installed
	if [[ -d "$HOME/.oh-my-zsh" ]]; then
		print_success "Oh My Zsh already installed"
		return 0
	fi

	local default_shell
	default_shell=$(detect_default_shell)

	# Only offer if zsh is the default shell (or on macOS where it's the system default)
	if [[ "$default_shell" != "zsh" && "$(uname)" != "Darwin" ]]; then
		print_info "Default shell is $default_shell (not zsh) - skipping Oh My Zsh"
		return 0
	fi

	print_info "Oh My Zsh enhances zsh with themes, plugins, and completions"
	echo "  Many tools installed later (git, fd, brew) benefit from Oh My Zsh plugins."
	echo "  This is optional - plain zsh works fine without it."
	echo ""

	read -r -p "Install Oh My Zsh? [y/N]: " install_omz

	if [[ "$install_omz" =~ ^[Yy]$ ]]; then
		print_info "Installing Oh My Zsh..."
		# Use verified download + --unattended to avoid changing the shell or starting zsh
		VERIFIED_INSTALL_SHELL="sh"
		if verified_install "Oh My Zsh" "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" --unattended; then
			print_success "Oh My Zsh installed"

			# Ensure .zshrc exists (Oh My Zsh creates it, but verify)
			if [[ ! -f "$HOME/.zshrc" ]]; then
				print_warning ".zshrc not created - Oh My Zsh may not have installed correctly"
			fi

			# If the user's default shell isn't zsh, offer to change it
			if [[ "$default_shell" != "zsh" ]]; then
				echo ""
				read -r -p "Change default shell to zsh? [y/N]: " change_shell
				if [[ "$change_shell" =~ ^[Yy]$ ]]; then
					if chsh -s "$(command -v zsh)"; then
						print_success "Default shell changed to zsh"
						print_info "Restart your terminal for the change to take effect"
					else
						print_warning "Failed to change shell - run manually: chsh -s $(command -v zsh)"
					fi
				fi
			fi
		else
			print_warning "Oh My Zsh installation failed"
			print_info "Install manually: curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/omz-install.sh && sh /tmp/omz-install.sh"
		fi
	else
		print_info "Skipped Oh My Zsh installation"
		print_info "Install later: curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/omz-install.sh && sh /tmp/omz-install.sh"
	fi

	return 0
}

# Ensure shell compatibility when switching between bash and zsh
# Best practice: create a shared profile sourced by both shells, so users
# don't lose PATH entries, aliases, exports, or tool integrations when
# switching their default shell. This is especially important on macOS
# where the system default changed from bash to zsh in Catalina, and many
# users have years of bash customizations they don't want to lose.
setup_shell_compatibility() {
	print_info "Setting up cross-shell compatibility..."

	local shared_profile="$HOME/.shell_common"
	local zsh_rc="$HOME/.zshrc"

	# If shared profile already exists, we've already set this up
	if [[ -f "$shared_profile" ]]; then
		print_success "Cross-shell compatibility already configured ($shared_profile)"
		return 0
	fi

	# Need both bash and zsh to be relevant
	if ! command -v zsh >/dev/null 2>&1; then
		print_info "zsh not installed - cross-shell setup not needed"
		return 0
	fi
	if ! command -v bash >/dev/null 2>&1; then
		print_info "bash not installed - cross-shell setup not needed"
		return 0
	fi

	# Collect all bash config files that exist
	# macOS: .bash_profile (login) + .bashrc (interactive, often sourced by .bash_profile)
	# Linux: .bashrc (primary) + .bash_profile (login, often sources .bashrc)
	# We check all of them on both platforms since tools write to either
	local -a bash_files=()
	[[ -f "$HOME/.bash_profile" ]] && bash_files+=("$HOME/.bash_profile")
	[[ -f "$HOME/.bashrc" ]] && bash_files+=("$HOME/.bashrc")
	[[ -f "$HOME/.profile" ]] && bash_files+=("$HOME/.profile")

	if [[ ${#bash_files[@]} -eq 0 ]]; then
		print_info "No bash config files found - skipping cross-shell setup"
		return 0
	fi

	if [[ ! -f "$zsh_rc" ]]; then
		print_info "No .zshrc found - skipping cross-shell setup"
		return 0
	fi

	# Count customizations across all bash config files
	local total_exports=0
	local total_aliases=0
	local total_paths=0

	for src_file in "${bash_files[@]}"; do
		local n
		# grep -c outputs "0" on no match (exit 1); "|| true" prevents exit
		# without appending a second "0" line (which breaks arithmetic)
		n=$(grep -cE '^\s*export\s+[A-Z]' "$src_file" 2>/dev/null) || true
		total_exports=$((total_exports + ${n:-0}))
		n=$(grep -cE '^\s*alias\s+' "$src_file" 2>/dev/null) || true
		total_aliases=$((total_aliases + ${n:-0}))
		n=$(grep -cE 'PATH.*=' "$src_file" 2>/dev/null) || true
		total_paths=$((total_paths + ${n:-0}))
	done

	if [[ $total_exports -eq 0 && $total_aliases -eq 0 && $total_paths -eq 0 ]]; then
		print_info "No bash customizations detected - skipping cross-shell setup"
		return 0
	fi

	print_info "Detected bash customizations across ${#bash_files[@]} file(s):"
	echo "  Exports: $total_exports, Aliases: $total_aliases, PATH entries: $total_paths"
	echo ""
	print_info "Best practice: create a shared profile (~/.shell_common) sourced by"
	print_info "both bash and zsh, so your customizations work in either shell."
	echo ""

	local setup_compat="Y"
	if [[ "$NON_INTERACTIVE" != "true" ]]; then
		read -r -p "Create shared shell profile for cross-shell compatibility? [Y/n]: " setup_compat
	fi

	if [[ ! "$setup_compat" =~ ^[Yy]?$ ]]; then
		print_info "Skipped cross-shell compatibility setup"
		print_info "Set up later by creating ~/.shell_common and sourcing it from both shells"
		return 0
	fi

	# Extract portable customizations from bash config into shared profile
	# We extract: exports, PATH modifications, aliases, eval statements, source commands
	# We skip: bash-specific syntax (shopt, PROMPT_COMMAND, PS1, completion, bind, etc.)
	# We deduplicate lines that appear in multiple files (e.g. .bash_profile sources .bashrc)
	print_info "Creating shared profile: $shared_profile"

	{
		echo "# Shared shell profile - sourced by both bash and zsh"
		echo "# Created by aidevops setup to preserve customizations across shell switches"
		echo "# Edit this file for settings you want in BOTH bash and zsh"
		echo "# Shell-specific settings go in ~/.bashrc or ~/.zshrc"
		echo ""
	} >"$shared_profile"

	# Track lines we've already written to avoid duplicates
	# (common on Linux where .bash_profile sources .bashrc)
	local -a seen_lines=()
	local extracted=0

	for src_file in "${bash_files[@]}"; do
		local src_basename
		src_basename=$(basename "$src_file")
		local added_header=false

		while IFS= read -r line || [[ -n "$line" ]]; do
			# Skip empty lines
			[[ -z "$line" ]] && continue
			# Skip pure comment lines
			[[ "$line" =~ ^[[:space:]]*# ]] && continue

			# Skip bash-specific settings that don't work in zsh
			case "$line" in
			*shopt*) continue ;;
			*PROMPT_COMMAND*) continue ;;
			*PS1=*) continue ;;
			*PS2=*) continue ;;
			*bash_completion*) continue ;;
			*"complete "*) continue ;;
			*"bind "*) continue ;;
			*HISTCONTROL*) continue ;;
			*HISTFILESIZE*) continue ;;
			*HISTSIZE*) continue ;;
			*"source /etc/bash"*) continue ;;
			*". /etc/bash"*) continue ;;
			*"source /etc/profile"*) continue ;;
			*". /etc/profile"*) continue ;;
			# Skip lines that source .bashrc from .bash_profile (circular)
			*".bashrc"*) continue ;;
			# Skip lines that source .shell_common (we'll add this ourselves)
			*"shell_common"*) continue ;;
			esac

			# Match portable lines: exports, aliases, PATH, eval, source/dot-source
			local is_portable=false
			case "$line" in
			export\ [A-Z]* | export\ PATH*) is_portable=true ;;
			alias\ *) is_portable=true ;;
			eval\ *) is_portable=true ;;
			*PATH=*) is_portable=true ;;
			esac
			# Also match 'source' and '. ' commands (tool integrations like nvm, rvm, pyenv)
			if [[ "$is_portable" == "false" ]]; then
				case "$line" in
				source\ * | .\ /* | .\ \$* | .\ \~*) is_portable=true ;;
				esac
			fi

			if [[ "$is_portable" == "true" ]]; then
				# Deduplicate: skip if we've already seen this exact line
				local is_dup=false
				local seen
				for seen in "${seen_lines[@]}"; do
					if [[ "$seen" == "$line" ]]; then
						is_dup=true
						break
					fi
				done
				if [[ "$is_dup" == "true" ]]; then
					continue
				fi

				if [[ "$added_header" == "false" ]]; then
					echo "" >>"$shared_profile"
					echo "# From $src_basename" >>"$shared_profile"
					added_header=true
				fi
				echo "$line" >>"$shared_profile"
				seen_lines+=("$line")
				((extracted++)) || true
			fi
		done <"$src_file"
	done

	if [[ $extracted -eq 0 ]]; then
		rm -f "$shared_profile"
		print_info "No portable customizations found to extract"
		return 0
	fi

	chmod 644 "$shared_profile"
	print_success "Extracted $extracted unique customization(s) to $shared_profile"

	# Add sourcing to .zshrc if not already present
	if ! grep -q 'shell_common' "$zsh_rc" 2>/dev/null; then
		{
			echo ""
			echo "# Cross-shell compatibility (added by aidevops setup)"
			echo "# Sources shared profile so bash customizations work in zsh too"
			# shellcheck disable=SC2016
			echo '[ -f "$HOME/.shell_common" ] && . "$HOME/.shell_common"'
		} >>"$zsh_rc"
		print_success "Added shared profile sourcing to .zshrc"
	fi

	# Add sourcing to bash config files if not already present
	for src_file in "${bash_files[@]}"; do
		if ! grep -q 'shell_common' "$src_file" 2>/dev/null; then
			{
				echo ""
				echo "# Cross-shell compatibility (added by aidevops setup)"
				echo "# Shared profile - edit ~/.shell_common for settings in both shells"
				# shellcheck disable=SC2016
				echo '[ -f "$HOME/.shell_common" ] && . "$HOME/.shell_common"'
			} >>"$src_file"
			print_success "Added shared profile sourcing to $(basename "$src_file")"
		fi
	done

	echo ""
	print_success "Cross-shell compatibility configured"
	print_info "Your customizations are now in: $shared_profile"
	print_info "Both bash and zsh will source this file automatically."
	print_info "Edit ~/.shell_common for settings you want in both shells."
	print_info "Use ~/.bashrc or ~/.zshrc for shell-specific settings only."

	return 0
}

# Check for optional dependencies
check_optional_deps() {
	print_info "Checking optional dependencies..."

	local missing_optional=()

	if ! command -v sshpass >/dev/null 2>&1; then
		missing_optional+=("sshpass")
	else
		print_success "sshpass found"
	fi

	if [[ ${#missing_optional[@]} -gt 0 ]]; then
		print_warning "Missing optional dependencies: ${missing_optional[*]}"
		echo "  sshpass - needed for password-based SSH (like Hostinger)"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			read -r -p "Install optional dependencies using $pkg_manager? [Y/n]: " install_optional

			if [[ "$install_optional" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_optional[*]}..."
				if install_packages "$pkg_manager" "${missing_optional[@]}"; then
					print_success "Optional dependencies installed"
				else
					print_warning "Failed to install optional dependencies (non-critical)"
				fi
			else
				print_info "Skipped optional dependencies"
			fi
		fi
	fi
	return 0
}

# Setup Git CLI tools
setup_git_clis() {
	print_info "Setting up Git CLI tools..."

	local cli_tools=()
	local missing_packages=()
	local missing_names=()

	# Check for GitHub CLI
	if ! command -v gh >/dev/null 2>&1; then
		missing_packages+=("gh")
		missing_names+=("GitHub CLI")
	else
		cli_tools+=("GitHub CLI")
	fi

	# Check for GitLab CLI
	if ! command -v glab >/dev/null 2>&1; then
		missing_packages+=("glab")
		missing_names+=("GitLab CLI")
	else
		cli_tools+=("GitLab CLI")
	fi

	# Report found tools
	if [[ ${#cli_tools[@]} -gt 0 ]]; then
		print_success "Found Git CLI tools: ${cli_tools[*]}"
	fi

	# Offer to install missing tools
	if [[ ${#missing_packages[@]} -gt 0 ]]; then
		print_warning "Missing Git CLI tools: ${missing_names[*]}"
		echo "  These provide enhanced Git platform integration (repos, PRs, issues)"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			echo ""
			read -r -p "Install Git CLI tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " install_git_clis

			if [[ "$install_git_clis" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_packages[*]}..."
				if install_packages "$pkg_manager" "${missing_packages[@]}"; then
					print_success "Git CLI tools installed"
					echo ""
					echo "📋 Next steps - authenticate each CLI:"
					for pkg in "${missing_packages[@]}"; do
						case "$pkg" in
						gh) echo "  • gh auth login" ;;
						glab) echo "  • glab auth login" ;;
						esac
					done
				else
					print_warning "Failed to install some Git CLI tools (non-critical)"
				fi
			else
				print_info "Skipped Git CLI tools installation"
				echo ""
				echo "📋 Manual installation:"
				echo "  macOS: brew install ${missing_packages[*]}"
				echo "  Ubuntu: sudo apt install ${missing_packages[*]}"
				echo "  Fedora: sudo dnf install ${missing_packages[*]}"
			fi
		else
			echo ""
			echo "📋 Manual installation:"
			echo "  macOS: brew install ${missing_packages[*]}"
			echo "  Ubuntu: sudo apt install ${missing_packages[*]}"
			echo "  Fedora: sudo dnf install ${missing_packages[*]}"
		fi
	else
		print_success "All Git CLI tools installed and ready!"
	fi

	# Check for Gitea CLI separately (not in standard package managers)
	if ! command -v tea >/dev/null 2>&1; then
		print_info "Gitea CLI (tea) not found - install manually if needed:"
		echo "  go install code.gitea.io/tea/cmd/tea@latest"
		echo "  Or download from: https://dl.gitea.io/tea/"
	else
		print_success "Gitea CLI (tea) found"
	fi

	return 0
}

# Setup file discovery tools (fd, ripgrep) for efficient file searching
setup_file_discovery_tools() {
	print_info "Setting up file discovery tools..."

	local missing_tools=()
	local missing_packages=()
	local missing_names=()

	local fd_version
	if command -v fd >/dev/null 2>&1; then
		fd_version=$(fd --version 2>/dev/null | head -1 || echo "unknown")
		print_success "fd found: $fd_version"
	elif command -v fdfind >/dev/null 2>&1; then
		fd_version=$(fdfind --version 2>/dev/null | head -1 || echo "unknown")
		print_success "fd found (as fdfind): $fd_version"
		print_warning "Note: 'fd' alias not active in current shell. Restart shell or run: alias fd=fdfind"
	else
		missing_tools+=("fd")
		missing_packages+=("fd")
		missing_names+=("fd (fast file finder)")
	fi

	# Check for ripgrep
	if ! command -v rg >/dev/null 2>&1; then
		missing_tools+=("rg")
		missing_packages+=("ripgrep")
		missing_names+=("ripgrep (fast content search)")
	else
		local rg_version
		rg_version=$(rg --version 2>/dev/null | head -1 || echo "unknown")
		print_success "ripgrep found: $rg_version"
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing file discovery tools: ${missing_names[*]}"
		echo ""
		echo "  These tools provide 10x faster file discovery than built-in glob:"
		echo "    fd      - Fast alternative to 'find', respects .gitignore"
		echo "    ripgrep - Fast alternative to 'grep', respects .gitignore"
		echo ""
		echo "  AI agents use these for efficient codebase navigation."
		echo ""

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			local install_fd_tools="y"
			if [[ "$INTERACTIVE_MODE" == "true" ]]; then
				read -r -p "Install file discovery tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " install_fd_tools
			fi

			if [[ "$install_fd_tools" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_packages[*]}..."

				# Handle package name differences across package managers
				local actual_packages=()
				for pkg in "${missing_packages[@]}"; do
					case "$pkg_manager" in
					apt)
						# Debian/Ubuntu uses fd-find instead of fd
						if [[ "$pkg" == "fd" ]]; then
							actual_packages+=("fd-find")
						else
							actual_packages+=("$pkg")
						fi
						;;
					*)
						actual_packages+=("$pkg")
						;;
					esac
				done

				if install_packages "$pkg_manager" "${actual_packages[@]}"; then
					print_success "File discovery tools installed"

					# On Debian/Ubuntu, fd is installed as fdfind - create alias in all existing shell rc files
					if [[ "$pkg_manager" == "apt" ]] && command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
						local rc_files=("$HOME/.bashrc" "$HOME/.zshrc")
						local added_to=""

						for rc_file in "${rc_files[@]}"; do
							[[ ! -f "$rc_file" ]] && continue

							if ! grep -q 'alias fd="fdfind"' "$rc_file" 2>/dev/null; then
								if { echo '' >>"$rc_file" &&
									echo '# fd-find alias for Debian/Ubuntu (added by aidevops)' >>"$rc_file" &&
									echo 'alias fd="fdfind"' >>"$rc_file"; }; then
									added_to="${added_to:+$added_to, }$rc_file"
								fi
							fi
						done

						if [[ -n "$added_to" ]]; then
							print_success "Added alias fd=fdfind to: $added_to"
							echo "  Restart your shell to activate"
						else
							print_success "fd alias already configured"
						fi
					fi
				else
					print_warning "Failed to install some file discovery tools (non-critical)"
				fi
			else
				print_info "Skipped file discovery tools installation"
				echo ""
				echo "  Manual installation:"
				echo "    macOS:        brew install fd ripgrep"
				echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep"
				echo "    Fedora:       sudo dnf install fd-find ripgrep"
				echo "    Arch:         sudo pacman -S fd ripgrep"
			fi
		else
			echo ""
			echo "  Manual installation:"
			echo "    macOS:        brew install fd ripgrep"
			echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep"
			echo "    Fedora:       sudo dnf install fd-find ripgrep"
			echo "    Arch:         sudo pacman -S fd ripgrep"
		fi
	else
		print_success "All file discovery tools installed!"
	fi

	return 0
}

# Setup shell linting tools (shellcheck, shfmt)
setup_shell_linting_tools() {
	print_info "Setting up shell linting tools..."

	local missing_tools=()
	local pkg_manager
	pkg_manager=$(detect_package_manager)

	# Check shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		local sc_path sc_arch
		sc_path=$(command -v shellcheck)
		# Prefer arm64 if present (universal/fat binaries report both architectures)
		local sc_file_output
		sc_file_output=$(file "$sc_path" 2>/dev/null)
		if echo "$sc_file_output" | grep -q 'arm64'; then
			sc_arch="arm64"
		else
			sc_arch=$(echo "$sc_file_output" | grep -oE '(x86_64)' | head -1)
		fi
		if [[ "$(uname -m)" == "arm64" ]] && [[ "$sc_arch" == "x86_64" ]]; then
			print_warning "shellcheck found but running under Rosetta (x86_64)"
			print_info "  Run 'rosetta-audit-helper.sh migrate' to fix"
		else
			print_success "shellcheck found ($(shellcheck --version 2>/dev/null | grep 'version:' | awk '{print $2}'))"
		fi
	else
		missing_tools+=("shellcheck")
	fi

	# Check shfmt
	if command -v shfmt >/dev/null 2>&1; then
		print_success "shfmt found ($(shfmt --version 2>/dev/null))"
	else
		missing_tools+=("shfmt")
	fi

	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing shell linting tools: ${missing_tools[*]}"
		echo "  shellcheck - static analysis for shell scripts"
		echo "  shfmt      - shell script formatter (fast syntax checks)"

		if [[ "$pkg_manager" != "unknown" ]]; then
			local install_linters
			if [[ "${NON_INTERACTIVE:-}" == "true" ]]; then
				install_linters="Y"
			else
				read -r -p "Install missing shell linting tools using $pkg_manager? [Y/n]: " install_linters
			fi

			if [[ "$install_linters" =~ ^[Yy]?$ ]]; then
				if install_packages "$pkg_manager" "${missing_tools[@]}"; then
					print_success "Shell linting tools installed"
				else
					print_warning "Failed to install some shell linting tools"
				fi
			else
				print_info "Skipped shell linting tools"
			fi
		else
			echo "  Install manually:"
			echo "    macOS: brew install ${missing_tools[*]}"
			echo "    Linux: apt install ${missing_tools[*]}"
		fi
	fi

	return 0
}

# Rosetta audit - detect x86 Homebrew packages on Apple Silicon
setup_rosetta_audit() {
	# Skip on non-Apple-Silicon or non-macOS
	if [[ "$(uname)" != "Darwin" ]] || [[ "$(uname -m)" != "arm64" ]]; then
		print_info "Rosetta audit: not applicable (Intel Mac or non-macOS)"
		return 0
	fi

	# Skip if no dual-brew setup
	if [[ ! -x "/usr/local/bin/brew" ]] || [[ ! -x "/opt/homebrew/bin/brew" ]]; then
		print_success "Rosetta audit: clean Homebrew setup (no x86 brew detected)"
		return 0
	fi

	print_info "Detected dual Homebrew (x86 + ARM) — checking for Rosetta overhead..."

	local x86_only_count dup_count
	dup_count=$(comm -12 \
		<(/usr/local/bin/brew list --formula 2>/dev/null | sort) \
		<(/opt/homebrew/bin/brew list --formula 2>/dev/null | sort) | wc -l | tr -d ' ')
	x86_only_count=$(comm -23 \
		<(/usr/local/bin/brew list --formula 2>/dev/null | sort) \
		<(/opt/homebrew/bin/brew list --formula 2>/dev/null | sort) | wc -l | tr -d ' ')

	local total=$((x86_only_count + dup_count))

	if [[ "$total" -eq 0 ]]; then
		print_success "No x86 Homebrew packages found — clean ARM setup"
		return 0
	fi

	print_warning "Found $total x86 Homebrew packages ($x86_only_count x86-only, $dup_count duplicates)"
	echo "  These run under Rosetta 2 emulation with ~30% performance overhead"
	echo ""
	echo "  To audit:   rosetta-audit-helper.sh scan"
	echo "  To migrate: rosetta-audit-helper.sh migrate --dry-run"
	echo "  To fix:     rosetta-audit-helper.sh migrate"

	return 0
}
# Setup Worktrunk - Git worktree management for parallel AI agent workflows
setup_worktrunk() {
	print_info "Setting up Worktrunk (git worktree management)..."

	# Check if worktrunk (wt) is already installed
	if command -v wt >/dev/null 2>&1; then
		local wt_version
		wt_version=$(wt --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Worktrunk already installed: $wt_version"

		# Check if shell integration is installed (check all rc files)
		local wt_integrated=false
		local rc_file
		while IFS= read -r rc_file; do
			[[ -z "$rc_file" ]] && continue
			if [[ -f "$rc_file" ]] && grep -q "worktrunk" "$rc_file" 2>/dev/null; then
				wt_integrated=true
				break
			fi
		done < <(get_all_shell_rcs)

		if [[ "$wt_integrated" == "false" ]]; then
			print_info "Shell integration not detected"
			read -r -p "Install Worktrunk shell integration (enables 'wt switch' to change directories)? [Y/n]: " install_shell
			if [[ "$install_shell" =~ ^[Yy]?$ ]]; then
				print_info "Installing shell integration..."
				if wt config shell install; then
					print_success "Shell integration installed"
					print_info "Restart your terminal for the change to take effect"
				else
					print_warning "Shell integration failed - run manually: wt config shell install"
				fi
			fi
		else
			print_success "Shell integration already configured"
		fi
		return 0
	fi

	# Worktrunk not installed - offer to install
	print_info "Worktrunk makes git worktrees as easy as branches"
	echo "  • wt switch feat     - Switch/create worktree (with cd)"
	echo "  • wt list            - List worktrees with CI status"
	echo "  • wt merge           - Squash/rebase/merge + cleanup"
	echo "  • Hooks for automated setup (npm install, etc.)"
	echo ""
	echo "  Note: aidevops also includes worktree-helper.sh as a fallback"
	echo ""

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	if [[ "$pkg_manager" == "brew" ]]; then
		read -r -p "Install Worktrunk via Homebrew? [Y/n]: " install_wt

		if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Worktrunk via Homebrew" brew install max-sixty/worktrunk/wt; then
				# Install shell integration (don't use spinner - command is fast and may need interaction)
				print_info "Installing shell integration..."
				if wt config shell install; then
					print_success "Shell integration installed"
					print_info "Restart your terminal or source your shell config"
				else
					print_warning "Shell integration failed - run manually: wt config shell install"
				fi

				echo ""
				print_info "Quick start:"
				echo "  wt switch feature/my-feature  # Create/switch to worktree"
				echo "  wt list                       # List all worktrees"
				echo "  wt merge                      # Merge and cleanup"
				echo ""
				print_info "Documentation: ~/.aidevops/agents/tools/git/worktrunk.md"
			else
				print_warning "Homebrew installation failed"
				echo "  Try: cargo install worktrunk && wt config shell install"
			fi
		else
			print_info "Skipped Worktrunk installation"
			print_info "Install later: brew install max-sixty/worktrunk/wt"
			print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
		fi
	elif command -v cargo >/dev/null 2>&1; then
		read -r -p "Install Worktrunk via Cargo? [Y/n]: " install_wt

		if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Worktrunk via Cargo" cargo install worktrunk; then
				# Install shell integration (don't use spinner - command is fast and may need interaction)
				print_info "Installing shell integration..."
				if wt config shell install; then
					print_success "Shell integration installed"
					print_info "Restart your terminal or source your shell config"
				else
					print_warning "Shell integration failed - run manually: wt config shell install"
				fi
			else
				print_warning "Cargo installation failed"
			fi
		else
			print_info "Skipped Worktrunk installation"
		fi
	else
		print_warning "Worktrunk not installed"
		echo ""
		echo "  Install options:"
		echo "    macOS/Linux (Homebrew): brew install max-sixty/worktrunk/wt"
		echo "    Cargo:                  cargo install worktrunk"
		echo "    Windows:                winget install max-sixty.worktrunk"
		echo ""
		echo "  After install: wt config shell install"
		echo ""
		print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
	fi

	return 0
}

# Setup recommended tools (Tabby terminal, Zed editor)
setup_recommended_tools() {
	print_info "Checking recommended development tools..."

	local missing_tools=()
	local missing_names=()

	# Check for Tabby terminal
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS - check Applications folder
		if [[ ! -d "/Applications/Tabby.app" ]]; then
			missing_tools+=("tabby")
			missing_names+=("Tabby (modern terminal)")
		else
			print_success "Tabby terminal found"
		fi
	elif [[ "$(uname)" == "Linux" ]]; then
		# Linux - check if tabby command exists
		if ! command -v tabby >/dev/null 2>&1; then
			missing_tools+=("tabby")
			missing_names+=("Tabby (modern terminal)")
		else
			print_success "Tabby terminal found"
		fi
	fi

	# Check for Zed editor
	local zed_exists=false
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS - check Applications folder
		if [[ ! -d "/Applications/Zed.app" ]]; then
			missing_tools+=("zed")
			missing_names+=("Zed (AI-native editor)")
		else
			print_success "Zed editor found"
			zed_exists=true
		fi
	elif [[ "$(uname)" == "Linux" ]]; then
		# Linux - check if zed command exists
		if ! command -v zed >/dev/null 2>&1; then
			missing_tools+=("zed")
			missing_names+=("Zed (AI-native editor)")
		else
			print_success "Zed editor found"
			zed_exists=true
		fi
	fi

	# Check for OpenCode extension in existing Zed installation
	if [[ "$zed_exists" == "true" ]]; then
		local zed_extensions_dir=""
		if [[ "$(uname)" == "Darwin" ]]; then
			zed_extensions_dir="$HOME/Library/Application Support/Zed/extensions/installed"
		elif [[ "$(uname)" == "Linux" ]]; then
			zed_extensions_dir="$HOME/.local/share/zed/extensions/installed"
		fi

		if [[ -d "$zed_extensions_dir" ]]; then
			if [[ ! -d "$zed_extensions_dir/opencode" ]]; then
				read -r -p "Install OpenCode extension for Zed? [Y/n]: " install_opencode_ext
				if [[ "$install_opencode_ext" =~ ^[Yy]?$ ]]; then
					print_info "Installing OpenCode extension..."
					if [[ "$(uname)" == "Darwin" ]]; then
						open "zed://extension/opencode" 2>/dev/null
						print_success "OpenCode extension install triggered"
						print_info "Zed will open and prompt to install the extension"
					elif [[ "$(uname)" == "Linux" ]]; then
						xdg-open "zed://extension/opencode" 2>/dev/null ||
							print_info "Open Zed and install 'opencode' from Extensions"
					fi
				fi
			else
				print_success "OpenCode extension already installed in Zed"
			fi
		fi
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing recommended tools: ${missing_names[*]}"
		echo "  Tabby - Modern terminal with profiles, SSH manager, split panes"
		echo "  Zed   - High-performance AI-native code editor"
		echo ""

		# Install Tabby if missing
		if [[ " ${missing_tools[*]} " =~ " tabby " ]]; then
			read -r -p "Install Tabby terminal? [Y/n]: " install_tabby

			if [[ "$install_tabby" =~ ^[Yy]?$ ]]; then
				if [[ "$(uname)" == "Darwin" ]]; then
					if command -v brew >/dev/null 2>&1; then
						if run_with_spinner "Installing Tabby" brew install --cask tabby; then
							: # Success message handled by spinner
						else
							print_warning "Failed to install Tabby via Homebrew"
							echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
						fi
					else
						print_warning "Homebrew not found"
						echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
					fi
				elif [[ "$(uname)" == "Linux" ]]; then
					local arch
					arch=$(uname -m)
					# Tabby packagecloud repo only has x86_64 packages
					# ARM64 (aarch64) must use .deb from GitHub releases or skip
					if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
						# Clean up stale Tabby packagecloud repo if it exists from a previous run
						# (it causes apt-get update failures on ARM64)
						if [[ -f /etc/apt/sources.list.d/eugeny_tabby.list ]]; then
							print_info "Removing stale Tabby packagecloud repo (not available for ARM64)..."
							sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.list
							sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.sources
							sudo apt-get update -qq 2>/dev/null || true
						fi
						print_warning "Tabby packages are not available for ARM64 Linux via package manager"
						echo "  Download ARM64 .deb from: https://github.com/Eugeny/tabby/releases/latest"
						echo "  Or skip Tabby - it's optional (a modern terminal emulator)"
					else
						local pkg_manager
						pkg_manager=$(detect_package_manager)
						case "$pkg_manager" in
						apt)
							# Add packagecloud repo for Tabby (verified download, not piped to sudo)
							VERIFIED_INSTALL_SUDO="true"
							if verified_install "Tabby repository (apt)" "https://packagecloud.io/install/repositories/eugeny/tabby/script.deb.sh"; then
								if ! sudo apt-get install -y tabby-terminal; then
									print_warning "Tabby package not found for this architecture"
									echo "  Download from: https://github.com/Eugeny/tabby/releases/latest"
								fi
							fi
							;;
						dnf | yum)
							VERIFIED_INSTALL_SUDO="true"
							if verified_install "Tabby repository (rpm)" "https://packagecloud.io/install/repositories/eugeny/tabby/script.rpm.sh"; then
								if ! sudo "$pkg_manager" install -y tabby-terminal; then
									print_warning "Tabby package not found for this architecture"
									echo "  Download from: https://github.com/Eugeny/tabby/releases/latest"
								fi
							fi
							;;
						pacman)
							# AUR package
							print_info "Tabby available in AUR as 'tabby-bin'"
							echo "  Install with: yay -S tabby-bin"
							;;
						*)
							echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
							;;
						esac
					fi
				fi
			else
				print_info "Skipped Tabby installation"
			fi
		fi

		# Install Zed if missing
		if [[ " ${missing_tools[*]} " =~ " zed " ]]; then
			read -r -p "Install Zed editor? [Y/n]: " install_zed

			if [[ "$install_zed" =~ ^[Yy]?$ ]]; then
				local zed_installed=false
				if [[ "$(uname)" == "Darwin" ]]; then
					if command -v brew >/dev/null 2>&1; then
						if run_with_spinner "Installing Zed" brew install --cask zed; then
							zed_installed=true
						else
							print_warning "Failed to install Zed via Homebrew"
							echo "  Download manually: https://zed.dev/download"
						fi
					else
						print_warning "Homebrew not found"
						echo "  Download manually: https://zed.dev/download"
					fi
				elif [[ "$(uname)" == "Linux" ]]; then
					# Zed provides an install script for Linux (verified download)
					VERIFIED_INSTALL_SHELL="sh"
					if verified_install "Zed" "https://zed.dev/install.sh"; then
						zed_installed=true
					else
						print_warning "Failed to install Zed"
						echo "  See: https://zed.dev/docs/linux"
					fi
				fi

				# Install OpenCode extension for Zed
				if [[ "$zed_installed" == "true" ]]; then
					read -r -p "Install OpenCode extension for Zed? [Y/n]: " install_opencode_ext
					if [[ "$install_opencode_ext" =~ ^[Yy]?$ ]]; then
						print_info "Installing OpenCode extension..."
						if [[ "$(uname)" == "Darwin" ]]; then
							open "zed://extension/opencode" 2>/dev/null
							print_success "OpenCode extension install triggered"
							print_info "Zed will open and prompt to install the extension"
						elif [[ "$(uname)" == "Linux" ]]; then
							xdg-open "zed://extension/opencode" 2>/dev/null ||
								print_info "Open Zed and install 'opencode' from Extensions (Cmd+Shift+X)"
						fi
					fi
				fi
			else
				print_info "Skipped Zed installation"
			fi
		fi
	else
		print_success "All recommended tools installed!"
	fi

	return 0
}

# Setup MiniSim - iOS/Android emulator launcher (macOS only)
setup_minisim() {
	# Only available on macOS
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	print_info "Setting up MiniSim (iOS/Android emulator launcher)..."

	# Check if MiniSim is already installed
	if [[ -d "/Applications/MiniSim.app" ]]; then
		print_success "MiniSim already installed"
		print_info "Global shortcut: Option + Shift + E"
		return 0
	fi

	# Check if Xcode or Android Studio is installed (MiniSim needs at least one)
	local has_xcode=false
	local has_android=false

	if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices >/dev/null 2>&1; then
		has_xcode=true
	fi

	if [[ -n "${ANDROID_HOME:-}" ]] || [[ -n "${ANDROID_SDK_ROOT:-}" ]] || [[ -d "$HOME/Library/Android/sdk" ]]; then
		has_android=true
	fi

	if [[ "$has_xcode" == "false" && "$has_android" == "false" ]]; then
		print_info "MiniSim requires Xcode (iOS) or Android Studio (Android)"
		print_info "Install one of these first, then re-run setup to install MiniSim"
		return 0
	fi

	# Show what's available
	local available_for=""
	if [[ "$has_xcode" == "true" ]]; then
		available_for="iOS simulators"
	fi
	if [[ "$has_android" == "true" ]]; then
		if [[ -n "$available_for" ]]; then
			available_for="$available_for and Android emulators"
		else
			available_for="Android emulators"
		fi
	fi

	print_info "MiniSim is a menu bar app for launching $available_for"
	echo "  Features:"
	echo "    - Global shortcut: Option + Shift + E"
	echo "    - Launch/manage iOS simulators and Android emulators"
	echo "    - Copy device UDID/ADB ID"
	echo "    - Cold boot Android emulators"
	echo "    - Run Android emulators without audio (saves Bluetooth battery)"
	echo ""

	# Check if Homebrew is available
	if ! command -v brew >/dev/null 2>&1; then
		print_warning "Homebrew not found - cannot install MiniSim automatically"
		echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
		return 0
	fi

	local install_minisim
	read -r -p "Install MiniSim? [Y/n]: " install_minisim

	if [[ "$install_minisim" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing MiniSim" brew install --cask minisim; then
			print_info "Global shortcut: Option + Shift + E"
			print_info "Documentation: ~/.aidevops/agents/tools/mobile/minisim.md"
		else
			print_warning "Failed to install MiniSim via Homebrew"
			echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
		fi
	else
		print_info "Skipped MiniSim installation"
		print_info "Install later: brew install --cask minisim"
	fi

	return 0
}

# Setup SSH key if needed
setup_ssh_key() {
	print_info "Checking SSH key setup..."

	if [[ ! -f ~/.ssh/id_ed25519 ]]; then
		print_warning "Ed25519 SSH key not found"
		read -r -p "Generate new Ed25519 SSH key? [Y/n]: " generate_key

		if [[ "$generate_key" =~ ^[Yy]?$ ]]; then
			read -r -p "Enter your email address: " email
			ssh-keygen -t ed25519 -C "$email"
			print_success "SSH key generated"
		else
			print_info "Skipping SSH key generation"
		fi
	else
		print_success "Ed25519 SSH key found"
	fi
	return 0
}

# Setup configuration files
setup_configs() {
	print_info "Setting up configuration files..."

	# Create configs directory if it doesn't exist
	mkdir -p configs

	# Copy template configs if they don't exist
	for template in configs/*.txt; do
		if [[ -f "$template" ]]; then
			config_file="${template%.txt}"
			if [[ ! -f "$config_file" ]]; then
				cp "$template" "$config_file"
				print_success "Created $(basename "$config_file")"
				print_warning "Please edit $(basename "$config_file") with your actual credentials"
			else
				print_info "Found existing config: $(basename "$config_file") - Skipping"
			fi
		fi
	done

	return 0
}

# Set proper permissions
set_permissions() {
	print_info "Setting proper file permissions..."

	# Make scripts executable (suppress errors for missing paths)
	chmod +x ./*.sh 2>/dev/null || true
	chmod +x .agents/scripts/*.sh 2>/dev/null || true
	chmod +x ssh/*.sh 2>/dev/null || true

	# Secure configuration files
	chmod 600 configs/*.json 2>/dev/null || true

	print_success "File permissions set"
	return 0
}

# Add ~/.local/bin to PATH in shell config
# Writes to ALL existing shell rc files (bash + zsh on macOS) for cross-shell compat
add_local_bin_to_path() {
	local path_line='export PATH="$HOME/.local/bin:$PATH"'
	local added_to=""
	local already_in=""

	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue

		# Create the rc file if it doesn't exist (ensure parent dir exists for fish etc.)
		if [[ ! -f "$rc_file" ]]; then
			mkdir -p "$(dirname "$rc_file")"
			touch "$rc_file"
		fi

		# Check if already added
		if grep -q '\.local/bin' "$rc_file" 2>/dev/null; then
			already_in="${already_in:+$already_in, }$rc_file"
			continue
		fi

		# Add to shell config
		echo "" >>"$rc_file"
		echo "# Added by aidevops setup" >>"$rc_file"
		echo "$path_line" >>"$rc_file"
		added_to="${added_to:+$added_to, }$rc_file"
	done < <(get_all_shell_rcs)

	if [[ -n "$added_to" ]]; then
		print_success "Added $HOME/.local/bin to PATH in: $added_to"
		print_info "Restart your terminal to use 'aidevops' command"
	fi

	if [[ -n "$already_in" ]]; then
		print_info "$HOME/.local/bin already in PATH in: $already_in"
	fi

	if [[ -z "$added_to" && -z "$already_in" ]]; then
		print_warning "Could not detect shell config file"
		print_info "Add this to your shell config: $path_line"
	fi

	# Also export for current session
	export PATH="$HOME/.local/bin:$PATH"

	return 0
}

# Install aidevops CLI command
install_aidevops_cli() {
	print_info "Installing aidevops CLI command..."

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local cli_source="$script_dir/aidevops.sh"
	local cli_target="/usr/local/bin/aidevops"

	if [[ ! -f "$cli_source" ]]; then
		print_warning "aidevops.sh not found - skipping CLI installation"
		return 0
	fi

	# Check if we can write to /usr/local/bin
	if [[ -w "/usr/local/bin" ]]; then
		# Direct symlink
		ln -sf "$cli_source" "$cli_target"
		print_success "Installed aidevops command to $cli_target"
	elif [[ -w "$HOME/.local/bin" ]] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
		# Use ~/.local/bin instead
		cli_target="$HOME/.local/bin/aidevops"
		ln -sf "$cli_source" "$cli_target"
		print_success "Installed aidevops command to $cli_target"

		# Check if ~/.local/bin is in PATH and add it if not
		if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
			add_local_bin_to_path
		fi
	else
		# Need sudo
		print_info "Installing aidevops command requires sudo..."
		if sudo ln -sf "$cli_source" "$cli_target"; then
			print_success "Installed aidevops command to $cli_target"
		else
			print_warning "Could not install aidevops command globally"
			print_info "You can run it directly: $cli_source"
		fi
	fi

	return 0
}

# Setup shell aliases
# Writes to all existing shell rc files for cross-shell compatibility
setup_aliases() {
	print_info "Setting up shell aliases..."

	local default_shell
	default_shell=$(detect_default_shell)

	# Fish shell uses different alias syntax
	local is_fish=false
	if [[ "$default_shell" == "fish" ]]; then
		is_fish=true
	fi

	local alias_block_bash
	alias_block_bash=$(
		cat <<'ALIASES'

# AI Assistant Server Access Framework
alias servers='./.agents/scripts/servers-helper.sh'
alias servers-list='./.agents/scripts/servers-helper.sh list'
alias hostinger='./.agents/scripts/hostinger-helper.sh'
alias hetzner='./.agents/scripts/hetzner-helper.sh'
alias aws-helper='./.agents/scripts/aws-helper.sh'
ALIASES
	)

	local alias_block_fish
	alias_block_fish=$(
		cat <<'ALIASES'

# AI Assistant Server Access Framework
alias servers './.agents/scripts/servers-helper.sh'
alias servers-list './.agents/scripts/servers-helper.sh list'
alias hostinger './.agents/scripts/hostinger-helper.sh'
alias hetzner './.agents/scripts/hetzner-helper.sh'
alias aws-helper './.agents/scripts/aws-helper.sh'
ALIASES
	)

	# Check if aliases already exist in any rc file (including fish config)
	local any_configured=false
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if grep -q "# AI Assistant Server Access" "$rc_file" 2>/dev/null; then
			any_configured=true
			break
		fi
	done < <(get_all_shell_rcs)
	# Also check fish config (not included in get_all_shell_rcs on macOS)
	if [[ "$any_configured" == "false" ]]; then
		local fish_config="$HOME/.config/fish/config.fish"
		if grep -q "# AI Assistant Server Access" "$fish_config" 2>/dev/null; then
			any_configured=true
		fi
	fi

	if [[ "$any_configured" == "true" ]]; then
		print_info "Server Access aliases already configured - Skipping"
		return 0
	fi

	print_info "Detected default shell: $default_shell"
	read -r -p "Add shell aliases? [Y/n]: " add_aliases

	if [[ "$add_aliases" =~ ^[Yy]?$ ]]; then
		local added_to=""

		# Handle fish separately
		if [[ "$is_fish" == "true" ]]; then
			local fish_rc="$HOME/.config/fish/config.fish"
			mkdir -p "$HOME/.config/fish"
			echo "$alias_block_fish" >>"$fish_rc"
			added_to="$fish_rc"
		else
			# Add to all bash/zsh rc files
			while IFS= read -r rc_file; do
				[[ -z "$rc_file" ]] && continue

				# Create if it doesn't exist
				if [[ ! -f "$rc_file" ]]; then
					touch "$rc_file"
				fi

				# Skip if already has aliases
				if grep -q "# AI Assistant Server Access" "$rc_file" 2>/dev/null; then
					continue
				fi

				echo "$alias_block_bash" >>"$rc_file"
				added_to="${added_to:+$added_to, }$rc_file"
			done < <(get_all_shell_rcs)
		fi

		if [[ -n "$added_to" ]]; then
			print_success "Aliases added to: $added_to"
			print_info "Restart your terminal to use aliases"
		fi
	else
		print_info "Skipped alias setup by user request"
	fi
	return 0
}

# Setup terminal title integration (syncs tab title with git repo/branch)
setup_terminal_title() {
	print_info "Setting up terminal title integration..."

	local setup_script=".agents/scripts/terminal-title-setup.sh"

	if [[ ! -f "$setup_script" ]]; then
		print_warning "Terminal title setup script not found - skipping"
		return 0
	fi

	# Check if already installed (check all rc files)
	local title_configured=false
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if [[ -f "$rc_file" ]] && grep -q "aidevops terminal-title" "$rc_file" 2>/dev/null; then
			title_configured=true
			break
		fi
	done < <(get_all_shell_rcs)

	if [[ "$title_configured" == "true" ]]; then
		print_info "Terminal title integration already configured - Skipping"
		return 0
	fi

	# Show current status before asking
	echo ""
	print_info "Terminal title integration syncs your terminal tab with git repo/branch"
	print_info "Example: Tab shows 'aidevops/feature/xyz' when in that branch"
	echo ""
	echo "Current status:"

	# Shell info
	local shell_name
	shell_name=$(detect_default_shell)
	local shell_info="$shell_name"
	if [[ "$shell_name" == "zsh" ]] && [[ -d "$HOME/.oh-my-zsh" ]]; then
		shell_info="$shell_name (Oh-My-Zsh)"
	fi
	echo "  Shell: $shell_info"

	# Tabby info
	local tabby_config="$HOME/Library/Application Support/tabby/config.yaml"
	if [[ -f "$tabby_config" ]]; then
		local disabled_count
		disabled_count=$(grep -c "disableDynamicTitle: true" "$tabby_config" 2>/dev/null || echo "0")
		if [[ "$disabled_count" -gt 0 ]]; then
			echo "  Tabby: detected, dynamic titles disabled in $disabled_count profile(s) (will fix)"
		else
			echo "  Tabby: detected, dynamic titles enabled"
		fi
	fi

	echo ""
	read -r -p "Install terminal title integration? [Y/n]: " install_title

	if [[ "$install_title" =~ ^[Yy]?$ ]]; then
		if bash "$setup_script" install; then
			print_success "Terminal title integration installed"
		else
			print_warning "Terminal title setup encountered issues (non-critical)"
		fi
	else
		print_info "Skipped terminal title setup by user request"
		print_info "You can install later with: ~/.aidevops/agents/scripts/terminal-title-setup.sh install"
	fi

	return 0
}

# Deploy AI assistant templates
deploy_ai_templates() {
	print_info "Deploying AI assistant templates..."

	if [[ -f "templates/deploy-templates.sh" ]]; then
		print_info "Running template deployment script..."
		if bash templates/deploy-templates.sh; then
			print_success "AI assistant templates deployed successfully"
		else
			print_warning "Template deployment encountered issues (non-critical)"
		fi
	else
		print_warning "Template deployment script not found - skipping"
	fi
	return 0
}

# Extract OpenCode prompts from binary (for Plan+ system-reminder)
# Must run before deploy_aidevops_agents so the cache exists for injection
extract_opencode_prompts() {
	local extract_script=".agents/scripts/extract-opencode-prompts.sh"
	if [[ -f "$extract_script" ]]; then
		if bash "$extract_script"; then
			print_success "OpenCode prompts extracted"
		else
			print_warning "OpenCode prompt extraction encountered issues (non-critical)"
		fi
	fi
	return 0
}

# Check if upstream OpenCode prompts have drifted from our synced version
check_opencode_prompt_drift() {
	local drift_script=".agents/scripts/opencode-prompt-drift-check.sh"
	if [[ -f "$drift_script" ]]; then
		local output exit_code=0
		output=$(bash "$drift_script" --quiet 2>/dev/null) || exit_code=$?
		if [[ "$exit_code" -eq 1 && "$output" == PROMPT_DRIFT* ]]; then
			local local_hash upstream_hash
			local_hash=$(echo "$output" | cut -d'|' -f2)
			upstream_hash=$(echo "$output" | cut -d'|' -f3)
			print_warning "OpenCode upstream prompt has changed (${local_hash} → ${upstream_hash})"
			print_info "  Review: https://github.com/anomalyco/opencode/compare/${local_hash}...${upstream_hash}"
			print_info "  Update .agents/prompts/build.txt if needed"
		elif [[ "$exit_code" -eq 0 ]]; then
			print_success "OpenCode prompt in sync with upstream"
		else
			print_warning "Could not check prompt drift (network issue or missing dependency)"
		fi
	fi
	return 0
}

# Deploy aidevops agents to user location
deploy_aidevops_agents() {
	print_info "Deploying aidevops agents to ~/.aidevops/agents/..."

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local source_dir="$script_dir/.agents"
	local target_dir="$HOME/.aidevops/agents"
	local plugins_file="$HOME/.config/aidevops/plugins.json"

	# Validate source directory exists (catches curl install from wrong directory)
	if [[ ! -d "$source_dir" ]]; then
		print_error "Agent source directory not found: $source_dir"
		print_info "This usually means setup.sh was run from the wrong directory."
		print_info "The bootstrap should have cloned the repo and re-executed."
		print_info ""
		print_info "To fix manually:"
		print_info "  cd ~/Git/aidevops && ./setup.sh"
		return 1
	fi

	# Collect plugin namespace directories to preserve during deployment
	local -a plugin_namespaces=()
	if [[ -f "$plugins_file" ]] && command -v jq &>/dev/null; then
		local ns
		local safe_ns
		while IFS= read -r ns; do
			if [[ -n "$ns" ]] && safe_ns=$(sanitize_plugin_namespace "$ns" 2>/dev/null); then
				plugin_namespaces+=("$safe_ns")
			fi
		done < <(jq -r '.plugins[].namespace // empty' "$plugins_file" 2>/dev/null)
	fi

	# Create backup if target exists (with rotation)
	if [[ -d "$target_dir" ]]; then
		create_backup_with_rotation "$target_dir" "agents"
	fi

	# Create target directory and copy agents
	mkdir -p "$target_dir"

	# If clean mode, remove stale files first (preserving user and plugin directories)
	if [[ "$CLEAN_MODE" == "true" ]]; then
		# Build list of directories to preserve: custom, draft, plus plugin namespaces
		local -a preserved_dirs=("custom" "draft")
		if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
			for pns in "${plugin_namespaces[@]}"; do
				preserved_dirs+=("$pns")
			done
		fi
		print_info "Clean mode: removing stale files from $target_dir (preserving ${preserved_dirs[*]})"
		local tmp_preserve
		tmp_preserve="$(mktemp -d)"
		trap 'rm -rf "${tmp_preserve:-}"' RETURN
		if [[ -z "$tmp_preserve" || ! -d "$tmp_preserve" ]]; then
			print_error "Failed to create temp dir for preserving agents"
			return 1
		fi
		local preserve_failed=false
		for pdir in "${preserved_dirs[@]}"; do
			if [[ -d "$target_dir/$pdir" ]]; then
				if ! cp -R "$target_dir/$pdir" "$tmp_preserve/$pdir"; then
					preserve_failed=true
				fi
			fi
		done
		if [[ "$preserve_failed" == "true" ]]; then
			print_error "Failed to preserve user/plugin agents; aborting clean"
			rm -rf "$tmp_preserve"
			return 1
		fi
		rm -rf "${target_dir:?}"/*
		# Restore preserved directories
		for pdir in "${preserved_dirs[@]}"; do
			if [[ -d "$tmp_preserve/$pdir" ]]; then
				cp -R "$tmp_preserve/$pdir" "$target_dir/$pdir"
			fi
		done
		rm -rf "$tmp_preserve"
	fi

	# Copy all agent files and folders, excluding:
	# - loop-state/ (local runtime state, not agents)
	# - custom/ (user's private agents, never overwritten)
	# - draft/ (user's experimental agents, never overwritten)
	# - plugin namespace directories (managed separately)
	# Use rsync for selective exclusion
	local deploy_ok=false
	if command -v rsync &>/dev/null; then
		local -a rsync_excludes=("--exclude=loop-state/" "--exclude=custom/" "--exclude=draft/")
		if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
			for pns in "${plugin_namespaces[@]}"; do
				rsync_excludes+=("--exclude=${pns}/")
			done
		fi
		if rsync -a "${rsync_excludes[@]}" "$source_dir/" "$target_dir/"; then
			deploy_ok=true
		fi
	else
		# Fallback: use tar with exclusions to match rsync behavior
		local -a tar_excludes=("--exclude=loop-state" "--exclude=custom" "--exclude=draft")
		if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
			for pns in "${plugin_namespaces[@]}"; do
				tar_excludes+=("--exclude=$pns")
			done
		fi
		if (cd "$source_dir" && tar cf - "${tar_excludes[@]}" .) | (cd "$target_dir" && tar xf -); then
			deploy_ok=true
		fi
	fi

	if [[ "$deploy_ok" == "true" ]]; then
		print_success "Deployed agents to $target_dir"

		# Set permissions on scripts
		chmod +x "$target_dir/scripts/"*.sh 2>/dev/null || true

		# Count what was deployed
		local agent_count
		agent_count=$(find "$target_dir" -name "*.md" -type f | wc -l | tr -d ' ')
		local script_count
		script_count=$(find "$target_dir/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')

		print_info "Deployed $agent_count agent files and $script_count scripts"

		# Copy VERSION file from repo root to deployed agents
		if [[ -f "$script_dir/VERSION" ]]; then
			if cp "$script_dir/VERSION" "$target_dir/VERSION"; then
				print_info "Copied VERSION file to deployed agents"
			else
				print_warning "Failed to copy VERSION file (Plan+ may not read version correctly)"
			fi
		else
			print_warning "VERSION file not found in repo root"
		fi

		# Inject extracted OpenCode plan-reminder into Plan+ if available
		local plan_reminder="$HOME/.aidevops/cache/opencode-prompts/plan-reminder.txt"
		local plan_plus="$target_dir/plan-plus.md"
		if [[ -f "$plan_reminder" && -f "$plan_plus" ]]; then
			# Check if plan-plus.md has the placeholder marker
			if grep -q "OPENCODE-PLAN-REMINDER-INJECT" "$plan_plus"; then
				# Replace placeholder with extracted content using sed
				# (awk -v doesn't handle multi-line content with special chars well)
				local tmp_file
				tmp_file=$(mktemp)
				trap 'rm -f "${tmp_file:-}"' RETURN
				local in_placeholder=false
				while IFS= read -r line || [[ -n "$line" ]]; do
					if [[ "$line" == *"OPENCODE-PLAN-REMINDER-INJECT-START"* ]]; then
						echo "$line" >>"$tmp_file"
						cat "$plan_reminder" >>"$tmp_file"
						in_placeholder=true
					elif [[ "$line" == *"OPENCODE-PLAN-REMINDER-INJECT-END"* ]]; then
						echo "$line" >>"$tmp_file"
						in_placeholder=false
					elif [[ "$in_placeholder" == false ]]; then
						echo "$line" >>"$tmp_file"
					fi
				done <"$plan_plus"
				mv "$tmp_file" "$plan_plus"
				print_info "Injected OpenCode plan-reminder into Plan+"
			fi
		fi
		# Migrate mailbox from TOON files to SQLite (if old files exist)
		local aidevops_workspace_dir="${AIDEVOPS_WORKSPACE_DIR:-$HOME/.aidevops/.agent-workspace}"
		local mail_dir="${AIDEVOPS_MAIL_DIR:-${aidevops_workspace_dir}/mail}"
		local mail_script="$target_dir/scripts/mail-helper.sh"
		if [[ -x "$mail_script" ]] && find "$mail_dir" -name "*.toon" 2>/dev/null | grep -q .; then
			if "$mail_script" migrate; then
				print_success "Mailbox migration complete"
			else
				print_warning "Mailbox migration had issues (non-critical, old files preserved)"
			fi
		fi

		# Migration: wavespeed.md moved from services/ai-generation/ to tools/video/ (v2.111+)
		local old_wavespeed="$target_dir/services/ai-generation/wavespeed.md"
		if [[ -f "$old_wavespeed" ]]; then
			rm -f "$old_wavespeed"
			rmdir "$target_dir/services/ai-generation" 2>/dev/null || true
			print_info "Migrated wavespeed.md from services/ai-generation/ to tools/video/"
		fi

		# Deploy enabled plugins from plugins.json
		deploy_plugins "$target_dir" "$plugins_file"
	else
		print_error "Failed to deploy agents"
		return 1
	fi

	return 0
}

# Sanitize plugin namespace to prevent path traversal
# Arguments: namespace string from plugins.json
# Returns: sanitized namespace (basename only, no ../ or absolute paths)
# Exit: 0 on success, 1 if namespace is invalid/suspicious
sanitize_plugin_namespace() {
	local ns="$1"
	# Strip any path components, keep only the final directory name
	# This prevents ../../../etc/passwd and /absolute/paths
	ns=$(basename "$ns")
	# Additional safety: reject if it starts with . or contains suspicious chars
	if [[ "$ns" =~ ^\.|\.\.|[[:space:]]|[\\/] ]]; then
		return 1
	fi
	# Reject empty result
	if [[ -z "$ns" ]]; then
		return 1
	fi
	echo "$ns"
	return 0
}

# Deploy enabled plugins from plugins.json
# Arguments: target_dir, plugins_file
deploy_plugins() {
	local target_dir="$1"
	local plugins_file="$2"

	# Skip if no plugins.json or no jq
	if [[ ! -f "$plugins_file" ]]; then
		return 0
	fi
	if ! command -v jq &>/dev/null; then
		print_warning "jq not found; skipping plugin deployment"
		return 0
	fi

	local plugin_count
	plugin_count=$(jq '.plugins | length' "$plugins_file" 2>/dev/null || echo "0")
	if [[ "$plugin_count" -eq 0 ]]; then
		return 0
	fi

	local enabled_count
	enabled_count=$(jq '[.plugins[] | select(.enabled != false)] | length' "$plugins_file" 2>/dev/null || echo "0")
	if [[ "$enabled_count" -eq 0 ]]; then
		print_info "No enabled plugins to deploy ($plugin_count configured, all disabled)"
		return 0
	fi

	# Remove directories for disabled plugins (cleanup)
	local disabled_ns
	local safe_ns
	while IFS= read -r disabled_ns; do
		[[ -z "$disabled_ns" ]] && continue
		# Sanitize namespace to prevent path traversal
		if ! safe_ns=$(sanitize_plugin_namespace "$disabled_ns"); then
			print_warning "  Skipping invalid plugin namespace: $disabled_ns"
			continue
		fi
		if [[ -d "$target_dir/$safe_ns" ]]; then
			rm -rf "${target_dir:?}/${safe_ns:?}"
			print_info "  Removed disabled plugin directory: $safe_ns"
		fi
	done < <(jq -r '.plugins[] | select(.enabled == false) | .namespace // empty' "$plugins_file" 2>/dev/null)

	print_info "Deploying $enabled_count plugin(s)..."

	local deployed=0
	local failed=0
	local skipped=0

	# Process each enabled plugin
	local safe_pns
	while IFS=$'\t' read -r pname prepo pns pbranch; do
		[[ -z "$pname" ]] && continue
		pbranch="${pbranch:-main}"

		# Sanitize namespace to prevent path traversal
		if ! safe_pns=$(sanitize_plugin_namespace "$pns"); then
			print_warning "  Skipping plugin '$pname' with invalid namespace: $pns"
			failed=$((failed + 1))
			continue
		fi

		local clone_dir="$target_dir/$safe_pns"

		if [[ -d "$clone_dir" ]]; then
			# Plugin directory exists — skip re-clone during setup
			# Users can force update via: aidevops plugin update [name]
			skipped=$((skipped + 1))
			continue
		fi

		# Clone plugin repo
		print_info "  Installing plugin '$pname' ($prepo)..."
		if git clone --branch "$pbranch" --depth 1 "$prepo" "$clone_dir" 2>/dev/null; then
			# Remove .git directory (tracked via plugins.json, not nested git)
			rm -rf "$clone_dir/.git"
			# Set permissions on any scripts
			if [[ -d "$clone_dir/scripts" ]]; then
				chmod +x "$clone_dir/scripts/"*.sh 2>/dev/null || true
			fi
			deployed=$((deployed + 1))
		else
			print_warning "  Failed to install plugin '$pname' (network or auth issue)"
			failed=$((failed + 1))
		fi
	done < <(jq -r '.plugins[] | select(.enabled != false) | [.name, .repo, .namespace, (.branch // "main")] | @tsv' "$plugins_file" 2>/dev/null)

	# Summary
	if [[ "$deployed" -gt 0 ]]; then
		print_success "Deployed $deployed plugin(s)"
	fi
	if [[ "$skipped" -gt 0 ]]; then
		print_info "$skipped plugin(s) already deployed (use 'aidevops plugin update' to refresh)"
	fi
	if [[ "$failed" -gt 0 ]]; then
		print_warning "$failed plugin(s) failed to deploy (non-blocking)"
	fi

	return 0
}

# Generate Agent Skills SKILL.md files for cross-tool compatibility
generate_agent_skills() {
	print_info "Generating Agent Skills SKILL.md files..."

	local skills_script="$HOME/.aidevops/agents/scripts/generate-skills.sh"

	if [[ -f "$skills_script" ]]; then
		if bash "$skills_script" 2>/dev/null; then
			print_success "Agent Skills SKILL.md files generated"
		else
			print_warning "Agent Skills generation encountered issues (non-critical)"
		fi
	else
		print_warning "Agent Skills generator not found at $skills_script"
	fi

	return 0
}

# Create symlinks for imported skills to AI assistant skill directories
create_skill_symlinks() {
	print_info "Creating symlinks for imported skills..."

	local skill_sources="$HOME/.aidevops/agents/configs/skill-sources.json"
	local agents_dir="$HOME/.aidevops/agents"

	# Skip if no skill-sources.json or jq not available
	if [[ ! -f "$skill_sources" ]]; then
		print_info "No imported skills found (skill-sources.json not present)"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot create skill symlinks"
		return 0
	fi

	# Check if there are any skills
	local skill_count
	skill_count=$(jq '.skills | length' "$skill_sources" 2>/dev/null || echo "0")

	if [[ "$skill_count" -eq 0 ]]; then
		print_info "No imported skills to symlink"
		return 0
	fi

	# AI assistant skill directories
	local skill_dirs=(
		"$HOME/.config/opencode/skills"
		"$HOME/.codex/skills"
		"$HOME/.claude/skills"
		"$HOME/.config/amp/tools"
	)

	# Create skill directories if they don't exist
	for dir in "${skill_dirs[@]}"; do
		mkdir -p "$dir" 2>/dev/null || true
	done

	local created_count=0

	# Read each skill and create symlinks
	while IFS= read -r skill_json; do
		local name local_path
		name=$(echo "$skill_json" | jq -r '.name')
		local_path=$(echo "$skill_json" | jq -r '.local_path')

		# Skip if path doesn't exist
		local full_path="$agents_dir/${local_path#.agents/}"
		if [[ ! -f "$full_path" ]]; then
			print_warning "Skill file not found: $full_path"
			continue
		fi

		# Create symlinks in each AI assistant directory
		for skill_dir in "${skill_dirs[@]}"; do
			local target_file

			# Amp expects <name>.md directly, others expect <name>/SKILL.md
			if [[ "$skill_dir" == *"/amp/tools" ]]; then
				target_file="$skill_dir/${name}.md"
			else
				local target_dir="$skill_dir/$name"
				target_file="$target_dir/SKILL.md"
				# Create skill subdirectory
				mkdir -p "$target_dir" 2>/dev/null || continue
			fi

			# Create symlink (remove existing first)
			rm -f "$target_file" 2>/dev/null || true
			if ln -sf "$full_path" "$target_file" 2>/dev/null; then
				((created_count++)) || true
			fi
		done
	done < <(jq -c '.skills[]' "$skill_sources" 2>/dev/null)

	if [[ $created_count -gt 0 ]]; then
		print_success "Created $created_count skill symlinks across AI assistants"
	else
		print_info "No skill symlinks created"
	fi

	return 0
}

# Check for updates to imported skills from upstream repositories
check_skill_updates() {
	print_info "Checking for skill updates..."

	local skill_sources="$HOME/.aidevops/agents/configs/skill-sources.json"

	# Skip if no skill-sources.json or required tools not available
	if [[ ! -f "$skill_sources" ]]; then
		print_info "No imported skills to check"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot check skill updates"
		return 0
	fi

	if ! command -v curl &>/dev/null; then
		print_warning "curl not found - cannot check skill updates"
		return 0
	fi

	local skill_count
	skill_count=$(jq '.skills | length' "$skill_sources" 2>/dev/null || echo "0")

	if [[ "$skill_count" -eq 0 ]]; then
		print_info "No imported skills to check"
		return 0
	fi

	local updates_available=0
	local update_list=""

	# Check each skill for updates
	while IFS= read -r skill_json; do
		local name upstream_url upstream_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		upstream_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		# Skip skills without upstream URL or commit (e.g., context7 imports)
		if [[ -z "$upstream_url" || "$upstream_url" == "null" ]]; then
			continue
		fi
		if [[ -z "$upstream_commit" ]]; then
			continue
		fi

		# Extract owner/repo from GitHub URL
		local owner_repo
		owner_repo=$(echo "$upstream_url" | sed -E 's|https://github.com/||; s|\.git$||; s|/tree/.*||')

		if [[ -z "$owner_repo" || ! "$owner_repo" =~ / ]]; then
			continue
		fi

		# Get latest commit from GitHub API (silent, with timeout)
		local api_response latest_commit
		api_response=$(curl -s --max-time 5 "https://api.github.com/repos/$owner_repo/commits?per_page=1" 2>/dev/null)

		# Check if response is an array (success) or object (error like rate limit)
		if echo "$api_response" | jq -e 'type == "array"' >/dev/null 2>&1; then
			latest_commit=$(echo "$api_response" | jq -r '.[0].sha // empty')
		else
			# API returned error object, skip this skill
			continue
		fi

		if [[ -n "$latest_commit" && "$latest_commit" != "$upstream_commit" ]]; then
			((updates_available++)) || true
			update_list="${update_list}\n  - $name (${upstream_commit:0:7} → ${latest_commit:0:7})"
		fi
	done < <(jq -c '.skills[]' "$skill_sources" 2>/dev/null)

	if [[ $updates_available -gt 0 ]]; then
		print_warning "Skill updates available:$update_list"
		print_info "Run: ~/.aidevops/agents/scripts/add-skill-helper.sh check-updates"
		print_info "To update a skill: ~/.aidevops/agents/scripts/add-skill-helper.sh add <url> --force"
	else
		print_success "All imported skills are up to date"
	fi

	return 0
}

# Security scan imported skills using Cisco Skill Scanner
scan_imported_skills() {
	print_info "Running security scan on imported skills..."

	local security_helper="$HOME/.aidevops/agents/scripts/security-helper.sh"

	if [[ ! -f "$security_helper" ]]; then
		print_warning "security-helper.sh not found - skipping skill scan"
		return 0
	fi

	# Install skill-scanner if not present
	# Fallback chain: uv -> pipx -> venv+symlink -> pip3 --user (legacy)
	# PEP 668 (Ubuntu 24.04+) blocks pip3 --user, so we try isolated methods first
	if ! command -v skill-scanner &>/dev/null; then
		local installed=false

		# 1. uv tool install (preferred - fast, isolated)
		if [[ "$installed" == "false" ]] && command -v uv &>/dev/null; then
			print_info "Installing Cisco Skill Scanner via uv..."
			if run_with_spinner "Installing cisco-ai-skill-scanner" uv tool install cisco-ai-skill-scanner; then
				print_success "Cisco Skill Scanner installed via uv"
				installed=true
			fi
		fi

		# 2. pipx install (designed for isolated app installs)
		if [[ "$installed" == "false" ]] && command -v pipx &>/dev/null; then
			print_info "Installing Cisco Skill Scanner via pipx..."
			if run_with_spinner "Installing cisco-ai-skill-scanner" pipx install cisco-ai-skill-scanner; then
				print_success "Cisco Skill Scanner installed via pipx"
				installed=true
			fi
		fi

		# 3. venv + symlink (works on PEP 668 systems without uv/pipx)
		if [[ "$installed" == "false" ]] && command -v python3 &>/dev/null; then
			local venv_dir="$HOME/.aidevops/.agent-workspace/work/cisco-scanner-env"
			local bin_dir="$HOME/.local/bin"
			print_info "Installing Cisco Skill Scanner in isolated venv..."
			if python3 -m venv "$venv_dir" 2>/dev/null &&
				"$venv_dir/bin/pip" install cisco-ai-skill-scanner 2>/dev/null; then
				mkdir -p "$bin_dir"
				ln -sf "$venv_dir/bin/skill-scanner" "$bin_dir/skill-scanner"
				print_success "Cisco Skill Scanner installed via venv ($venv_dir)"
				installed=true
			else
				rm -rf "$venv_dir" 2>/dev/null || true
			fi
		fi

		# 4. pip3 --user (legacy fallback, fails on PEP 668 systems)
		if [[ "$installed" == "false" ]] && command -v pip3 &>/dev/null; then
			print_info "Installing Cisco Skill Scanner via pip3 --user..."
			if run_with_spinner "Installing cisco-ai-skill-scanner" pip3 install --user cisco-ai-skill-scanner 2>/dev/null; then
				print_success "Cisco Skill Scanner installed via pip3"
				installed=true
			fi
		fi

		if [[ "$installed" == "false" ]]; then
			print_warning "Failed to install Cisco Skill Scanner - skipping security scan"
			print_info "Install manually with: uv tool install cisco-ai-skill-scanner"
			print_info "Or: pipx install cisco-ai-skill-scanner"
			return 0
		fi
	fi

	if bash "$security_helper" skill-scan all 2>/dev/null; then
		print_success "All imported skills passed security scan"
	else
		print_warning "Some imported skills have security findings - review with: aidevops skill scan"
	fi

	return 0
}

# Inject aidevops reference into AI assistant AGENTS.md files
inject_agents_reference() {
	print_info "Adding aidevops reference to AI assistant configurations..."

	local reference_line='Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.'

	# AI assistant agent directories - these get cleaned and receive AGENTS.md reference
	# Format: "config_dir:agents_subdir" where agents_subdir is the folder containing agent files
	# Only OpenCode and Claude Code (companion CLI) are actively supported
	local ai_agent_dirs=(
		"$HOME/.config/opencode:agent"
		"$HOME/.claude:commands"
		"$HOME/.opencode:."
	)

	local updated_count=0

	for entry in "${ai_agent_dirs[@]}"; do
		local config_dir="${entry%%:*}"
		local agents_subdir="${entry##*:}"
		local agents_dir="$config_dir/$agents_subdir"
		local agents_file="$agents_dir/AGENTS.md"

		# Only process if the config directory exists (tool is installed)
		if [[ -d "$config_dir" ]]; then
			# Create agents subdirectory if needed
			mkdir -p "$agents_dir"

			# Check if AGENTS.md exists and has our reference
			if [[ -f "$agents_file" ]]; then
				# Check first line for our reference
				local first_line
				first_line=$(head -1 "$agents_file" 2>/dev/null || echo "")
				if [[ "$first_line" != *"~/.aidevops/agents/AGENTS.md"* ]]; then
					# Prepend reference to existing file
					local temp_file
					temp_file=$(mktemp)
					trap 'rm -f "${temp_file:-}"' RETURN
					echo "$reference_line" >"$temp_file"
					echo "" >>"$temp_file"
					cat "$agents_file" >>"$temp_file"
					mv "$temp_file" "$agents_file"
					print_success "Added reference to $agents_file"
					((updated_count++)) || true
				else
					print_info "Reference already exists in $agents_file"
				fi
			else
				# Create new file with just the reference
				echo "$reference_line" >"$agents_file"
				print_success "Created $agents_file with aidevops reference"
				((updated_count++)) || true
			fi
		fi
	done

	if [[ $updated_count -eq 0 ]]; then
		print_info "No AI assistant configs found to update (tools may not be installed yet)"
	else
		print_success "Updated $updated_count AI assistant configuration(s)"
	fi

	# Deploy OpenCode config-level AGENTS.md from managed template
	# This controls the session greeting (auto-loaded by OpenCode from config root)
	local opencode_config_dir="$HOME/.config/opencode"
	local opencode_config_agents="$opencode_config_dir/AGENTS.md"
	local template_source="$INSTALL_DIR/templates/opencode-config-agents.md"

	if [[ -d "$opencode_config_dir" && -f "$template_source" ]]; then
		# Backup if file exists and differs from template
		if [[ -f "$opencode_config_agents" ]]; then
			if ! diff -q "$template_source" "$opencode_config_agents" &>/dev/null; then
				create_backup_with_rotation "$opencode_config_agents" "opencode-agents"
			fi
		fi
		if cp "$template_source" "$opencode_config_agents"; then
			print_success "Deployed greeting template to $opencode_config_agents"
		else
			print_error "Failed to deploy greeting template to $opencode_config_agents"
		fi
	fi

	return 0
}

# Update OpenCode configuration
update_opencode_config() {
	print_info "Updating OpenCode configuration..."

	# Generate OpenCode commands (independent of opencode.json — writes to ~/.config/opencode/command/)
	# Run this first so /onboarding and other commands exist even if opencode.json hasn't been created yet
	local commands_script=".agents/scripts/generate-opencode-commands.sh"
	if [[ -f "$commands_script" ]]; then
		print_info "Generating OpenCode commands..."
		if bash "$commands_script"; then
			print_success "OpenCode commands configured"
		else
			print_warning "OpenCode command generation encountered issues"
		fi
	else
		print_warning "OpenCode command generator not found at $commands_script"
	fi

	# Generate OpenCode agent configuration (requires opencode.json)
	# - Primary agents: Added to opencode.json (for Tab order & MCP control)
	# - Subagents: Generated as markdown in ~/.config/opencode/agent/
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_info "OpenCode config (opencode.json) not found — agent configuration skipped (commands still generated)"
		return 0
	fi

	print_info "Found OpenCode config at: $opencode_config"

	# Create backup (with rotation)
	create_backup_with_rotation "$opencode_config" "opencode"

	local generator_script=".agents/scripts/generate-opencode-agents.sh"
	if [[ -f "$generator_script" ]]; then
		print_info "Generating OpenCode agent configuration..."
		if bash "$generator_script"; then
			print_success "OpenCode agents configured (11 primary in JSON, subagents as markdown)"
		else
			print_warning "OpenCode agent generation encountered issues"
		fi
	else
		print_warning "OpenCode agent generator not found at $generator_script"
	fi

	return 0
}

# Verify repository location
verify_location() {
	local current_dir
	current_dir="$(pwd)"
	local expected_location="$HOME/Git/aidevops"

	if [[ "$current_dir" != "$expected_location" ]]; then
		print_warning "Repository is not in the recommended location"
		print_info "Current location: $current_dir"
		print_info "Recommended location: $expected_location"
		echo ""
		echo "For optimal AI assistant integration, consider moving this repository to:"
		echo "  mkdir -p ~/git"
		echo "  mv '$current_dir' '$expected_location'"
		echo ""
	else
		print_success "Repository is in the recommended location: $expected_location"
	fi
	return 0
}

# Setup Python environment for DSPy
setup_python_env() {
	print_info "Setting up Python environment for DSPy..."

	# Check if Python 3 is available
	local python3_bin
	if ! python3_bin=$(find_python3); then
		print_warning "Python 3 not found - DSPy setup skipped"
		print_info "Install Python 3.8+ to enable DSPy integration"
		return
	fi

	local python_version
	python_version=$("$python3_bin" --version | cut -d' ' -f2 | cut -d'.' -f1-2)
	local version_check
	version_check=$("$python3_bin" -c "import sys; print(1 if sys.version_info >= (3, 8) else 0)")

	if [[ "$version_check" != "1" ]]; then
		print_warning "Python 3.8+ required for DSPy, found $python_version - DSPy setup skipped"
		return
	fi

	# Create Python virtual environment
	if [[ ! -d "python-env/dspy-env" ]] || [[ ! -f "python-env/dspy-env/bin/activate" ]]; then
		print_info "Creating Python virtual environment for DSPy..."
		mkdir -p python-env
		# Remove corrupted venv if directory exists but activate script is missing
		if [[ -d "python-env/dspy-env" ]] && [[ ! -f "python-env/dspy-env/bin/activate" ]]; then
			rm -rf python-env/dspy-env
		fi
		if python3 -m venv python-env/dspy-env; then
			print_success "Python virtual environment created"
		else
			print_warning "Failed to create Python virtual environment - DSPy setup skipped"
			return
		fi
	else
		print_info "Python virtual environment already exists"
	fi

	# Install DSPy dependencies
	print_info "Installing DSPy dependencies..."
	# shellcheck source=/dev/null
	if [[ -f "python-env/dspy-env/bin/activate" ]]; then
		source python-env/dspy-env/bin/activate
	else
		print_warning "Python venv activate script not found - DSPy setup skipped"
		return
	fi
	pip install --upgrade pip >/dev/null 2>&1

	if run_with_spinner "Installing DSPy dependencies" pip install -r requirements.txt; then
		: # Success message handled by spinner
	else
		print_info "Check requirements.txt or run manually:"
		print_info "  source python-env/dspy-env/bin/activate && pip install -r requirements.txt"
	fi
}

# Setup Node.js environment for DSPyGround
setup_nodejs_env() {
	print_info "Setting up Node.js environment for DSPyGround..."

	# Check if Node.js is available
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - DSPyGround setup skipped"
		print_info "Install Node.js 18+ to enable DSPyGround integration"
		return
	fi

	local node_version
	node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ $node_version -lt 18 ]]; then
		print_warning "Node.js 18+ required for DSPyGround, found v$node_version - DSPyGround setup skipped"
		return
	fi

	# Check if npm is available
	if ! command -v npm &>/dev/null; then
		print_warning "npm not found - DSPyGround setup skipped"
		return
	fi

	# Install DSPyGround globally if not already installed
	if ! command -v dspyground &>/dev/null; then
		if run_with_spinner "Installing DSPyGround" npm_global_install dspyground; then
			: # Success message handled by spinner
		else
			print_warning "Try manually: sudo npm install -g dspyground"
		fi
	else
		print_success "DSPyGround already installed"
	fi
}

# Install MCP servers globally for fast startup (no npx/pipx overhead)
install_mcp_packages() {
	print_info "Installing MCP server packages globally (eliminates npx startup delay)..."

	# Node.js MCP packages to install globally
	local -a node_mcps=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"@steipete/macos-automator-mcp"
		"@steipete/claude-code-mcp"
	)

	if ! command -v bun &>/dev/null && ! command -v npm &>/dev/null; then
		print_warning "Neither bun nor npm found - cannot install MCP packages"
		print_info "Install bun (recommended): npm install -g bun OR brew install oven-sh/bun/bun"
		return 0
	fi

	local installer="npm"
	command -v bun &>/dev/null && installer="bun"
	print_info "Using $installer to install/update Node.js MCP packages..."

	# Always install latest (bun install -g is fast and idempotent)
	local updated=0
	local failed=0
	local pkg
	for pkg in "${node_mcps[@]}"; do
		local short_name="${pkg##*/}" # Strip @scope/ prefix for display
		if run_with_spinner "Installing $short_name" npm_global_install "${pkg}@latest"; then
			((updated++)) || true
		else
			((failed++)) || true
			print_warning "Failed to install/update $pkg"
		fi
	done

	if [[ $updated -gt 0 ]]; then
		print_success "$updated Node.js MCP packages installed/updated to latest via $installer"
	fi
	if [[ $failed -gt 0 ]]; then
		print_warning "$failed packages failed (check network or package names)"
	fi

	# Python MCP packages (install or upgrade)
	if command -v pipx &>/dev/null; then
		print_info "Installing/updating analytics-mcp via pipx..."
		if command -v analytics-mcp &>/dev/null; then
			pipx upgrade analytics-mcp >/dev/null 2>&1 || true
		else
			pipx install analytics-mcp >/dev/null 2>&1 || print_warning "Failed to install analytics-mcp"
		fi
	fi

	if command -v uv &>/dev/null; then
		print_info "Installing/updating outscraper-mcp-server via uv..."
		if command -v outscraper-mcp-server &>/dev/null; then
			uv tool upgrade outscraper-mcp-server >/dev/null 2>&1 || true
		else
			uv tool install outscraper-mcp-server >/dev/null 2>&1 || print_warning "Failed to install outscraper-mcp-server"
		fi
	fi

	# Update opencode.json with resolved full paths for all MCP binaries
	update_mcp_paths_in_opencode

	print_info "MCP servers will start instantly (no registry lookups on each launch)"
	return 0
}

# Resolve full path for an MCP binary, checking common install locations
# Usage: resolve_mcp_binary_path "binary-name"
# Returns: full path on stdout, or empty string if not found
resolve_mcp_binary_path() {
	local bin_name="$1"
	local resolved=""

	# Check common locations in priority order
	local search_paths=(
		"$HOME/.bun/bin/$bin_name"
		"/opt/homebrew/bin/$bin_name"
		"/usr/local/bin/$bin_name"
		"$HOME/.local/bin/$bin_name"
		"$HOME/.npm-global/bin/$bin_name"
	)

	for path in "${search_paths[@]}"; do
		if [[ -x "$path" ]]; then
			resolved="$path"
			break
		fi
	done

	# Fallback: use command -v if in PATH (portable, POSIX-compliant)
	if [[ -z "$resolved" ]]; then
		resolved=$(command -v "$bin_name" 2>/dev/null || true)
	fi

	echo "$resolved"
	return 0
}

# Update opencode.json MCP commands to use full binary paths
# This ensures MCPs start regardless of PATH configuration
update_mcp_paths_in_opencode() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN
	cp "$opencode_config" "$tmp_config"

	local updated=0

	# Get all MCP entries with local commands
	local mcp_keys
	mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | .key' "$tmp_config" 2>/dev/null)

	while IFS= read -r mcp_key; do
		[[ -z "$mcp_key" ]] && continue

		# Get the first element of the command array (the binary)
		local current_cmd
		current_cmd=$(jq -r --arg k "$mcp_key" '.mcp[$k].command[0]' "$tmp_config" 2>/dev/null)

		# Skip if already a full path
		if [[ "$current_cmd" == /* ]]; then
			# Verify the path still exists
			if [[ ! -x "$current_cmd" ]]; then
				# Path is stale, try to resolve
				local bin_name
				bin_name=$(basename "$current_cmd")
				local new_path
				new_path=$(resolve_mcp_binary_path "$bin_name")
				if [[ -n "$new_path" && "$new_path" != "$current_cmd" ]]; then
					jq --arg k "$mcp_key" --arg p "$new_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
					((updated++)) || true
				fi
			fi
			continue
		fi

		# Skip docker (container runtime) and node (resolved separately below)
		case "$current_cmd" in
		docker | node) continue ;;
		esac

		# Resolve the full path
		local full_path
		full_path=$(resolve_mcp_binary_path "$current_cmd")

		if [[ -n "$full_path" && "$full_path" != "$current_cmd" ]]; then
			jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((updated++)) || true
		fi
	done <<<"$mcp_keys"

	# Also resolve 'node' commands (e.g., quickfile, amazon-order-history)
	# These use ["node", "/path/to/index.js"] - node itself should be resolved
	local node_path
	node_path=$(resolve_mcp_binary_path "node")
	if [[ -n "$node_path" ]]; then
		local node_mcp_keys
		node_mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | select(.value.command[0] == "node") | .key' "$tmp_config" 2>/dev/null)
		while IFS= read -r mcp_key; do
			[[ -z "$mcp_key" ]] && continue
			jq --arg k "$mcp_key" --arg p "$node_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((updated++)) || true
		done <<<"$node_mcp_keys"
	fi

	if [[ $updated -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_success "Updated $updated MCP commands to use full binary paths in opencode.json"
	else
		rm -f "$tmp_config"
	fi

	return 0
}

# Setup LocalWP MCP server for AI database access
setup_localwp_mcp() {
	print_info "Setting up LocalWP MCP server..."

	# Check if LocalWP is installed
	local localwp_found=false
	if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
		localwp_found=true
	fi

	if [[ "$localwp_found" != "true" ]]; then
		print_info "LocalWP not found - skipping MCP server setup"
		print_info "Install LocalWP from: https://localwp.com/"
		return 0
	fi

	print_success "LocalWP found"

	# Check if npm is available
	if ! command -v npm &>/dev/null; then
		print_warning "npm not found - cannot install LocalWP MCP server"
		print_info "Install Node.js and npm first"
		return 0
	fi

	# Check if mcp-local-wp is already installed
	if command -v mcp-local-wp &>/dev/null; then
		print_success "LocalWP MCP server already installed"
		return 0
	fi

	# Offer to install mcp-local-wp
	print_info "LocalWP MCP server enables AI assistants to query WordPress databases"
	read -r -p "Install LocalWP MCP server (@verygoodplugins/mcp-local-wp)? [Y/n]: " install_mcp

	if [[ "$install_mcp" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing LocalWP MCP server" npm_global_install "@verygoodplugins/mcp-local-wp"; then
			print_info "Start with: ~/.aidevops/agents/scripts/localhost-helper.sh start-mcp"
			print_info "Or configure in OpenCode MCP settings for auto-start"
		else
			print_info "Try manually: sudo npm install -g @verygoodplugins/mcp-local-wp"
		fi
	else
		print_info "Skipped LocalWP MCP server installation"
		print_info "Install later: npm install -g @verygoodplugins/mcp-local-wp"
	fi

	return 0
}

# Setup Augment Context Engine MCP
setup_augment_context_engine() {
	print_info "Setting up Augment Context Engine MCP..."

	# Check Node.js version (requires 22+)
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - Augment Context Engine setup skipped"
		print_info "Install Node.js 22+ to enable Augment Context Engine"
		return
	fi

	local node_version
	node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ $node_version -lt 22 ]]; then
		print_warning "Node.js 22+ required for Augment Context Engine, found v$node_version"
		print_info "Install: brew install node@22 (macOS) or nvm install 22"
		return
	fi

	# Check if auggie is installed
	if ! command -v auggie &>/dev/null; then
		print_warning "Auggie CLI not found"
		print_info "Install with: npm install -g @augmentcode/auggie@prerelease"
		print_info "Then run: auggie login"
		return
	fi

	# Check if logged in
	if [[ ! -f "$HOME/.augment/session.json" ]]; then
		print_warning "Auggie not logged in"
		print_info "Run: auggie login"
		return
	fi

	print_success "Auggie CLI found and authenticated"

	# MCP configuration is handled by generate-opencode-agents.sh for OpenCode

	print_info "Augment Context Engine available as MCP in OpenCode"
	print_info "Verification: 'What is this project? Please use codebase retrieval tool.'"

	return 0
}

# Setup osgrep - Local Semantic Search
setup_osgrep() {
	print_info "Setting up osgrep (local semantic search)..."

	# Check Node.js version (requires 18+)
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - osgrep setup skipped"
		print_info "Install Node.js 18+ to enable osgrep"
		return 0
	fi

	local node_version
	node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ $node_version -lt 18 ]]; then
		print_warning "Node.js 18+ required for osgrep, found v$node_version"
		print_info "Install: brew install node@18 (macOS) or nvm install 18"
		return 0
	fi

	# Check if osgrep is installed
	if ! command -v osgrep &>/dev/null; then
		echo ""
		print_info "osgrep provides 100% local semantic search (no cloud, no auth)"
		echo "  • Search code by meaning, not just keywords"
		echo "  • Works offline with ~150MB local embedding models"
		echo "  • Configured as MCP in OpenCode"
		echo ""

		read -r -p "Install osgrep CLI? [Y/n]: " install_osgrep
		if [[ "$install_osgrep" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing osgrep CLI" npm_global_install osgrep; then
				print_info "Now downloading embedding models (~150MB)..."
				# osgrep setup is interactive, don't use spinner
				if osgrep setup; then
					print_success "osgrep installed and configured"
				else
					print_warning "Model download failed - run manually: osgrep setup"
				fi
			else
				print_warning "Installation failed - try manually: sudo npm install -g osgrep"
				return 0
			fi
		else
			print_info "Skipped osgrep installation"
			print_info "Install later: npm install -g osgrep && osgrep setup"
			return 0
		fi
	fi

	# Check if models are downloaded
	if [[ ! -d "$HOME/.osgrep" ]]; then
		print_warning "osgrep models not yet downloaded"
		read -r -p "Download embedding models now (~150MB)? [Y/n]: " download_models
		if [[ "$download_models" =~ ^[Yy]?$ ]]; then
			if osgrep setup; then
				print_success "osgrep models downloaded"
			else
				print_warning "Model download failed - run manually: osgrep setup"
			fi
		else
			print_info "Download later: osgrep setup"
		fi
	else
		print_success "osgrep CLI installed and configured"
	fi

	print_info "Verification: 'Search for authentication handling in this codebase'"
	return 0
}

# Install Beads CLI from GitHub release binary
# Downloads the prebuilt binary for the current platform from GitHub releases.
# Returns: 0 on success, 1 on failure
install_beads_binary() {
	local os arch tarball_name
	os=$(uname -s | tr '[:upper:]' '[:lower:]')
	arch=$(uname -m)

	# Map architecture names to Beads release naming convention
	case "$arch" in
	x86_64 | amd64) arch="amd64" ;;
	aarch64 | arm64) arch="arm64" ;;
	*)
		print_warning "Unsupported architecture for Beads binary download: $arch"
		return 1
		;;
	esac

	# Get latest version tag from GitHub API
	local latest_version
	latest_version=$(curl -fsSL "https://api.github.com/repos/steveyegge/beads/releases/latest" 2>/dev/null |
		grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/')

	if [[ -z "$latest_version" ]]; then
		print_warning "Could not determine latest Beads version from GitHub"
		return 1
	fi

	tarball_name="beads_${latest_version}_${os}_${arch}.tar.gz"
	local download_url="https://github.com/steveyegge/beads/releases/download/v${latest_version}/${tarball_name}"

	print_info "Downloading Beads CLI v${latest_version} (${os}/${arch})..."

	local tmp_dir
	tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" RETURN

	if ! curl -fsSL "$download_url" -o "$tmp_dir/$tarball_name" 2>/dev/null; then
		print_warning "Failed to download Beads binary from $download_url"
		return 1
	fi

	# Extract and install
	if ! tar -xzf "$tmp_dir/$tarball_name" -C "$tmp_dir" 2>/dev/null; then
		print_warning "Failed to extract Beads binary"
		return 1
	fi

	# Find the bd binary in the extracted files
	local bd_binary
	bd_binary=$(find "$tmp_dir" -name "bd" -type f 2>/dev/null | head -1)
	if [[ -z "$bd_binary" ]]; then
		print_warning "bd binary not found in downloaded archive"
		return 1
	fi

	# Install to a writable location
	local install_dir="/usr/local/bin"
	if [[ ! -w "$install_dir" ]]; then
		if command -v sudo &>/dev/null; then
			sudo install -m 755 "$bd_binary" "$install_dir/bd"
		else
			# Fallback to user-local bin
			install_dir="$HOME/.local/bin"
			mkdir -p "$install_dir"
			install -m 755 "$bd_binary" "$install_dir/bd"
			# Ensure ~/.local/bin is in PATH
			if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
				export PATH="$HOME/.local/bin:$PATH"
				print_info "Added ~/.local/bin to PATH for this session"
			fi
		fi
	else
		install -m 755 "$bd_binary" "$install_dir/bd"
	fi

	if command -v bd &>/dev/null; then
		print_success "Beads CLI installed via binary download (v${latest_version})"
		return 0
	else
		print_warning "Beads binary installed to $install_dir/bd but not found in PATH"
		return 1
	fi
}

# Install Beads CLI via Go
# Returns: 0 on success, 1 on failure
install_beads_go() {
	if ! command -v go &>/dev/null; then
		return 1
	fi
	if run_with_spinner "Installing Beads via Go" go install github.com/steveyegge/beads/cmd/bd@latest; then
		print_info "Ensure \$GOPATH/bin is in your PATH"
		return 0
	fi
	print_warning "Go installation failed"
	return 1
}

# Setup Beads - Task Graph Visualization
setup_beads() {
	print_info "Setting up Beads (task graph visualization)..."

	# Check if Beads CLI (bd) is already installed
	if command -v bd &>/dev/null; then
		local bd_version
		bd_version=$(bd --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Beads CLI (bd) already installed: $bd_version"
	else
		# Try to install via Homebrew first (macOS/Linux with Homebrew)
		if command -v brew &>/dev/null; then
			if run_with_spinner "Installing Beads via Homebrew" brew install steveyegge/beads/bd; then
				: # Success message handled by spinner
			else
				print_warning "Homebrew tap installation failed, trying alternative..."
				install_beads_binary || install_beads_go
			fi
		elif command -v go &>/dev/null; then
			if run_with_spinner "Installing Beads via Go" go install github.com/steveyegge/beads/cmd/bd@latest; then
				print_info "Ensure \$GOPATH/bin is in your PATH"
			else
				print_warning "Go installation failed, trying binary download..."
				install_beads_binary
			fi
		else
			# No brew, no Go -- try binary download first, then offer Homebrew install
			if ! install_beads_binary; then
				# Binary download failed -- offer to install Homebrew (Linux only)
				if ensure_homebrew; then
					# Homebrew now available, retry via tap
					if run_with_spinner "Installing Beads via Homebrew" brew install steveyegge/beads/bd; then
						: # Success
					else
						print_warning "Homebrew tap installation failed"
					fi
				else
					print_warning "Beads CLI (bd) not installed"
					echo ""
					echo "  Install options:"
					echo "    Binary download:        https://github.com/steveyegge/beads/releases"
					echo "    macOS/Linux (Homebrew):  brew install steveyegge/beads/bd"
					echo "    Go:                      go install github.com/steveyegge/beads/cmd/bd@latest"
					echo ""
				fi
			fi
		fi
	fi

	print_info "Beads provides task graph visualization for TODO.md and PLANS.md"
	print_info "After installation, run: aidevops init beads"

	# Offer to install optional Beads UI tools
	setup_beads_ui

	return 0
}

# Setup Beads UI Tools (optional visualization tools)
setup_beads_ui() {
	echo ""
	print_info "Beads UI tools provide enhanced visualization:"
	echo "  • bv (Go)            - PageRank, critical path, graph analytics TUI"
	echo "  • beads-ui (Node.js) - Web dashboard with live updates"
	echo "  • bdui (Node.js)     - React/Ink terminal UI"
	echo "  • perles (Rust)      - BQL query language TUI"
	echo ""

	read -r -p "Install optional Beads UI tools? [Y/n]: " install_beads_ui

	if [[ ! "$install_beads_ui" =~ ^[Yy]?$ ]]; then
		print_info "Skipped Beads UI tools (can install later from beads.md docs)"
		return 0
	fi

	local installed_count=0

	# bv (beads_viewer) - Go TUI installed via Homebrew
	# https://github.com/Dicklesworthstone/beads_viewer
	read -r -p "  Install bv (TUI with PageRank, critical path, graph analytics)? [Y/n]: " install_viewer
	if [[ "$install_viewer" =~ ^[Yy]?$ ]]; then
		if command -v brew &>/dev/null; then
			# brew install user/tap/formula auto-taps
			if run_with_spinner "Installing bv via Homebrew" brew install dicklesworthstone/tap/bv; then
				print_info "Run: bv (in a beads-enabled project)"
				((installed_count++)) || true
			else
				print_warning "Homebrew install failed - try manually:"
				print_info "  brew install dicklesworthstone/tap/bv"
			fi
		else
			# No Homebrew - try install script or Go
			print_warning "Homebrew not found"
			if command -v go &>/dev/null; then
				# Go available - use go install
				if run_with_spinner "Installing bv via Go" go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest; then
					print_info "Run: bv (in a beads-enabled project)"
					((installed_count++)) || true
				else
					print_warning "Go install failed"
				fi
			else
				# Offer verified install script (download-then-execute, not piped)
				read -r -p "  Install bv via install script? [Y/n]: " use_script
				if [[ "$use_script" =~ ^[Yy]?$ ]]; then
					if verified_install "bv (beads viewer)" "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh"; then
						print_info "Run: bv (in a beads-enabled project)"
						((installed_count++)) || true
					else
						print_warning "Install script failed - try manually:"
						print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
					fi
				else
					print_info "Install later:"
					print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
					print_info "  Go: go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest"
				fi
			fi
		fi
	fi

	# beads-ui (Node.js)
	if command -v npm &>/dev/null; then
		read -r -p "  Install beads-ui (Web dashboard)? [Y/n]: " install_web
		if [[ "$install_web" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing beads-ui" npm_global_install beads-ui; then
				print_info "Run: beads-ui"
				((installed_count++)) || true
			fi
		fi

		read -r -p "  Install bdui (React/Ink TUI)? [Y/n]: " install_bdui
		if [[ "$install_bdui" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing bdui" npm_global_install bdui; then
				print_info "Run: bdui"
				((installed_count++)) || true
			fi
		fi
	fi

	# perles (Rust)
	if command -v cargo &>/dev/null; then
		read -r -p "  Install perles (BQL query language TUI)? [Y/n]: " install_perles
		if [[ "$install_perles" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing perles (Rust compile)" cargo install perles; then
				print_info "Run: perles"
				((installed_count++)) || true
			fi
		fi
	fi

	if [[ $installed_count -gt 0 ]]; then
		print_success "Installed $installed_count Beads UI tool(s)"
	else
		print_info "No Beads UI tools installed"
	fi

	echo ""
	print_info "Beads UI documentation: ~/.aidevops/agents/tools/task-management/beads.md"

	return 0
}

# Setup Browser Automation Tools (Bun, dev-browser, Playwriter)
setup_browser_tools() {
	print_info "Setting up browser automation tools..."

	local has_bun=false
	local has_node=false

	# Check Bun
	if command -v bun &>/dev/null; then
		has_bun=true
		print_success "Bun $(bun --version) found"
	fi

	# Check Node.js (for Playwriter)
	if command -v node &>/dev/null; then
		has_node=true
	fi

	# Install Bun if not present (required for dev-browser)
	if [[ "$has_bun" == "false" ]]; then
		print_info "Installing Bun (required for dev-browser)..."
		if verified_install "Bun" "https://bun.sh/install"; then
			# Source the updated PATH
			export BUN_INSTALL="$HOME/.bun"
			export PATH="$BUN_INSTALL/bin:$PATH"
			if command -v bun &>/dev/null; then
				has_bun=true
				print_success "Bun installed: $(bun --version)"

				# Bun's installer may only write to the running shell's rc file.
				# Ensure Bun PATH is in all shell rc files for cross-shell compat.
				local bun_path_line='export BUN_INSTALL="$HOME/.bun"'
				local bun_export_line='export PATH="$BUN_INSTALL/bin:$PATH"'
				local bun_rc
				while IFS= read -r bun_rc; do
					[[ -z "$bun_rc" ]] && continue
					if [[ ! -f "$bun_rc" ]]; then
						touch "$bun_rc"
					fi
					if ! grep -q '\.bun' "$bun_rc" 2>/dev/null; then
						echo "" >>"$bun_rc"
						echo "# Bun (added by aidevops setup)" >>"$bun_rc"
						echo "$bun_path_line" >>"$bun_rc"
						echo "$bun_export_line" >>"$bun_rc"
						print_info "Added Bun to PATH in $bun_rc"
					fi
				done < <(get_all_shell_rcs)
			fi
		else
			print_warning "Bun installation failed - dev-browser will need manual setup"
		fi
	fi

	# Setup dev-browser if Bun is available
	if [[ "$has_bun" == "true" ]]; then
		local dev_browser_dir="$HOME/.aidevops/dev-browser"

		if [[ -d "${dev_browser_dir}/skills/dev-browser" ]]; then
			print_success "dev-browser already installed"
		else
			print_info "Installing dev-browser (stateful browser automation)..."
			local dev_browser_output
			if dev_browser_output=$(bash "$HOME/.aidevops/agents/scripts/dev-browser-helper.sh" setup 2>&1); then
				print_success "dev-browser installed"
				print_info "Start server with: bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start"
			else
				print_warning "dev-browser setup failed:"
				# Show last few lines of error output for debugging
				echo "$dev_browser_output" | tail -5 | sed 's/^/  /'
				echo ""
				print_info "Run manually to see full output:"
				print_info "  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup"
			fi
		fi
	fi

	# Playwriter MCP (Node.js based, runs via npx)
	if [[ "$has_node" == "true" ]]; then
		print_success "Playwriter MCP available (runs via npx playwriter@latest)"
		print_info "Install Chrome extension: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe"
	else
		print_warning "Node.js not found - Playwriter MCP unavailable"
	fi

	# Playwright MCP (cross-browser testing automation)
	if [[ "$has_node" == "true" ]]; then
		print_info "Setting up Playwright MCP..."

		# Check if Playwright browsers are installed (--no-install prevents auto-download)
		if npx --no-install playwright --version &>/dev/null 2>&1; then
			print_success "Playwright already installed"
		else
			local install_playwright
			read -r -p "Install Playwright MCP with browsers (chromium, firefox, webkit)? [Y/n]: " install_playwright

			if [[ "$install_playwright" =~ ^[Yy]?$ ]]; then
				print_info "Installing Playwright browsers..."
				# Use -y to auto-confirm npx install, suppress the "install without dependencies" warning
				# Use PIPESTATUS to check npx exit code, not grep's exit code
				npx -y playwright@latest install 2>&1 | grep -v "WARNING: It looks like you are running"
				if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
					print_success "Playwright browsers installed"
				else
					print_warning "Playwright browser installation failed"
					print_info "Run manually: npx -y playwright@latest install"
				fi
			else
				print_info "Skipped Playwright installation"
				print_info "Install later with: npx playwright install"
			fi
		fi

		print_info "Playwright MCP runs via: npx playwright-mcp@latest"
	fi

	if [[ "$has_node" == "true" ]]; then
		print_info "Browser tools: dev-browser (stateful), Playwriter (extension), Playwright (testing), Stagehand (AI)"
	else
		print_info "Browser tools: dev-browser (stateful), Stagehand (AI)"
	fi
	return 0
}

# Setup Node.js runtime (required for Bun, OpenCode, and MCP servers)
setup_nodejs() {
	# Check if Node.js is already installed
	if command -v node >/dev/null 2>&1; then
		local node_version
		node_version=$(node --version 2>/dev/null || echo "unknown")
		print_success "Node.js already installed: $node_version"
		# Distro nodejs package may not include npm — install it if missing
		if ! command -v npm >/dev/null 2>&1; then
			print_info "npm not found (distro nodejs package may omit it) — installing..."
			local pkg_manager
			pkg_manager=$(detect_package_manager)
			case "$pkg_manager" in
			apt) sudo apt-get install -y npm 2>/dev/null || print_warning "Failed to install npm via apt" ;;
			dnf | yum) sudo "$pkg_manager" install -y npm 2>/dev/null || print_warning "Failed to install npm via $pkg_manager" ;;
			brew) brew install npm 2>/dev/null || print_warning "Failed to install npm via brew" ;;
			*) print_warning "Cannot auto-install npm — install manually" ;;
			esac
		fi
		return 0
	fi

	print_info "Node.js is required for OpenCode, MCP servers, and many tools"

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	case "$pkg_manager" in
	brew)
		read -r -p "Install Node.js via Homebrew? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Node.js" brew install node; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apt)
		read -r -p "Install Node.js via apt? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			# Clean up stale Tabby packagecloud repo if present (causes apt-get update failures)
			if [[ -f /etc/apt/sources.list.d/eugeny_tabby.list ]]; then
				local arch
				arch=$(uname -m)
				if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
					print_info "Removing stale Tabby repo (not available for ARM64)..."
					sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.list
					sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.sources
				fi
			fi
			# Use NodeSource for a recent version (apt default may be old)
			print_info "Installing Node.js (via NodeSource for latest LTS)..."
			if command -v curl >/dev/null 2>&1; then
				VERIFIED_INSTALL_SUDO="true"
				if verified_install "NodeSource repository" "https://deb.nodesource.com/setup_22.x"; then
					# Install nodejs (NodeSource bundles npm, but distro fallback may not)
					# Include npm explicitly in case NodeSource setup failed silently
					# and apt falls back to the distro nodejs package (which lacks npm)
					if sudo apt-get install -y nodejs npm 2>/dev/null || sudo apt-get install -y nodejs; then
						print_success "Node.js installed: $(node --version)"
					else
						print_warning "Node.js installation failed"
					fi
				else
					# Fallback to distro package
					print_info "Falling back to distro Node.js package..."
					if sudo apt-get install -y nodejs npm; then
						print_success "Node.js installed: $(node --version)"
					else
						print_warning "Node.js installation failed"
					fi
				fi
			else
				if sudo apt-get install -y nodejs npm; then
					print_success "Node.js installed: $(node --version)"
				else
					print_warning "Node.js installation failed"
				fi
			fi
		fi
		;;
	dnf | yum)
		read -r -p "Install Node.js via $pkg_manager? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo "$pkg_manager" install -y nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	pacman)
		read -r -p "Install Node.js via pacman? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo pacman -S --noconfirm nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apk)
		read -r -p "Install Node.js via apk? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo apk add nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	*)
		print_warning "No supported package manager found for Node.js installation"
		echo "  Install manually: https://nodejs.org/"
		;;
	esac

	return 0
}

# Setup OpenCode CLI (the AI coding tool that aidevops is built for)
setup_opencode_cli() {
	print_info "Setting up OpenCode CLI..."

	# Check if OpenCode is already installed
	if command -v opencode >/dev/null 2>&1; then
		local oc_version
		oc_version=$(opencode --version 2>/dev/null | head -1 || echo "unknown")
		print_success "OpenCode already installed: $oc_version"
		return 0
	fi

	# Need either bun or npm to install
	local installer=""
	local install_pkg="opencode-ai@latest"

	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found - cannot install OpenCode"
		print_info "Install Node.js first, then re-run setup"
		return 0
	fi

	print_info "OpenCode is the AI coding tool that aidevops is built for"
	echo "  It provides an AI-powered terminal interface for development tasks."
	echo ""

	local install_oc="Y"
	if [[ "$NON_INTERACTIVE" != "true" ]]; then
		read -r -p "Install OpenCode via $installer? [Y/n]: " install_oc || install_oc="Y"
	fi
	if [[ "$install_oc" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing OpenCode" npm_global_install "$install_pkg"; then
			print_success "OpenCode installed"

			# Offer authentication
			echo ""
			print_info "OpenCode needs authentication to use AI models."
			print_info "Run 'opencode auth login' to authenticate."
			echo ""
		else
			print_warning "OpenCode installation failed"
			print_info "Try manually: sudo npm install -g $install_pkg"
		fi
	else
		print_info "Skipped OpenCode installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

# Setup OrbStack VM (macOS only - offers to install aidevops in a Linux VM)
setup_orbstack_vm() {
	# Only available on macOS
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	# Check if OrbStack is already installed
	if [[ -d "/Applications/OrbStack.app" ]] || command -v orb >/dev/null 2>&1; then
		print_success "OrbStack already installed"
		return 0
	fi

	print_info "OrbStack provides fast, lightweight Linux VMs on macOS"
	echo "  You can run aidevops in an isolated Linux environment."
	echo "  This is optional - aidevops works natively on macOS too."
	echo ""

	if ! command -v brew >/dev/null 2>&1; then
		print_info "OrbStack available at: https://orbstack.dev/"
		return 0
	fi

	read -r -p "Install OrbStack? [y/N]: " install_orb
	if [[ "$install_orb" =~ ^[Yy]$ ]]; then
		if run_with_spinner "Installing OrbStack" brew install --cask orbstack; then
			print_success "OrbStack installed"
			print_info "Create a VM: orb create ubuntu aidevops"
			print_info "Then install aidevops inside: orb run aidevops bash <(curl -fsSL https://aidevops.sh/install)"
		else
			print_warning "OrbStack installation failed"
			print_info "Download manually: https://orbstack.dev/"
		fi
	else
		print_info "Skipped OrbStack installation"
	fi

	return 0
}

# Setup AI Orchestration Frameworks (Langflow, CrewAI, AutoGen)
setup_ai_orchestration() {
	print_info "Setting up AI orchestration frameworks..."

	local has_python=false

	# Check Python (prefer Homebrew/pyenv over system)
	local python3_bin
	if python3_bin=$(find_python3); then
		local python_version
		python_version=$("$python3_bin" --version 2>&1 | cut -d' ' -f2)
		local major minor
		major=$(echo "$python_version" | cut -d. -f1)
		minor=$(echo "$python_version" | cut -d. -f2)

		if [[ $major -ge 3 ]] && [[ $minor -ge 10 ]]; then
			has_python=true
			print_success "Python $python_version found (3.10+ required)"
		else
			print_warning "Python 3.10+ required for AI orchestration, found $python_version"
			echo ""
			echo "  Upgrade options:"
			echo "    macOS (Homebrew): brew install python@3.12"
			echo "    macOS (pyenv):    pyenv install 3.12 && pyenv global 3.12"
			echo "    Ubuntu/Debian:    sudo apt install python3.12"
			echo "    Fedora:           sudo dnf install python3.12"
			echo ""
		fi
	else
		print_warning "Python 3 not found - AI orchestration frameworks unavailable"
		echo ""
		echo "  Install options:"
		echo "    macOS: brew install python@3.12"
		echo "    Linux: sudo apt install python3 (or dnf/pacman)"
		echo ""
		return 0
	fi

	if [[ "$has_python" == "false" ]]; then
		return 0
	fi

	# Create orchestration directory
	mkdir -p "$HOME/.aidevops/orchestration"

	# Info about available frameworks
	print_info "AI Orchestration Frameworks available:"
	echo "  - Langflow: Visual flow builder (localhost:7860)"
	echo "  - CrewAI: Multi-agent teams (localhost:8501)"
	echo "  - AutoGen: Microsoft agentic AI (localhost:8081)"
	echo ""
	print_info "Setup individual frameworks with:"
	echo "  bash .agents/scripts/langflow-helper.sh setup"
	echo "  bash .agents/scripts/crewai-helper.sh setup"
	echo "  bash .agents/scripts/autogen-helper.sh setup"
	echo ""
	print_info "See .agents/tools/ai-orchestration/overview.md for comparison"

	return 0
}

# Install Claude Code PreToolUse hooks to block destructive git/filesystem commands
setup_safety_hooks() {
	print_info "Setting up Claude Code safety hooks..."

	# Check Python is available
	if ! command -v python3 &>/dev/null; then
		print_warning "Python 3 not found - safety hooks require Python 3"
		return 0
	fi

	local helper_script="$HOME/.aidevops/agents/scripts/install-hooks-helper.sh"
	if [[ ! -f "$helper_script" ]]; then
		# Fall back to repo copy
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		helper_script="$script_dir/.agents/scripts/install-hooks-helper.sh"
	fi

	if [[ ! -f "$helper_script" ]]; then
		print_warning "install-hooks-helper.sh not found - skipping safety hooks"
		return 0
	fi

	if bash "$helper_script" install; then
		print_success "Claude Code safety hooks installed"
	else
		print_warning "Safety hook installation encountered issues (non-critical)"
	fi
	return 0
}

# Setup OpenCode Plugins
# Helper function to add/update a single plugin in OpenCode config
add_opencode_plugin() {
	local plugin_name="$1"
	local plugin_spec="$2"
	local opencode_config="$3"

	# Check if plugin array exists and if plugin is already configured
	local has_plugin_array
	has_plugin_array=$(jq -e '.plugin' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")

	if [[ "$has_plugin_array" == "true" ]]; then
		# Check if plugin is already in the array
		local plugin_exists
		plugin_exists=$(jq -e --arg p "$plugin_name" '.plugin | map(select(startswith($p))) | length > 0' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")

		if [[ "$plugin_exists" == "true" ]]; then
			# Update existing plugin to latest version
			local temp_file
			temp_file=$(mktemp)
			trap 'rm -f "${temp_file:-}"' RETURN
			jq --arg old "$plugin_name" --arg new "$plugin_spec" \
				'.plugin = [.plugin[] | if startswith($old) then $new else . end]' \
				"$opencode_config" >"$temp_file" && mv "$temp_file" "$opencode_config"
			print_success "Updated $plugin_name to latest version"
		else
			# Add plugin to existing array
			local temp_file
			temp_file=$(mktemp)
			trap 'rm -f "${temp_file:-}"' RETURN
			jq --arg p "$plugin_spec" '.plugin += [$p]' "$opencode_config" >"$temp_file" && mv "$temp_file" "$opencode_config"
			print_success "Added $plugin_name plugin to OpenCode config"
		fi
	else
		# Create plugin array with the plugin
		local temp_file
		temp_file=$(mktemp)
		trap 'rm -f "${temp_file:-}"' RETURN
		jq --arg p "$plugin_spec" '. + {plugin: [$p]}' "$opencode_config" >"$temp_file" && mv "$temp_file" "$opencode_config"
		print_success "Created plugin array with $plugin_name"
	fi
}

setup_opencode_plugins() {
	print_info "Setting up OpenCode plugins..."

	# Check if OpenCode is installed
	if ! command -v opencode &>/dev/null; then
		print_warning "OpenCode not found - plugin setup skipped"
		print_info "Install OpenCode first: https://opencode.ai"
		return 0
	fi

	# Check if config exists
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_warning "OpenCode config not found - plugin setup skipped"
		return 0
	fi

	# Check if jq is available
	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot update OpenCode config"
		return 0
	fi

	# Setup aidevops compaction plugin (local file plugin)
	local aidevops_plugin_path="$HOME/.aidevops/agents/plugins/opencode-aidevops/index.mjs"
	if [[ -f "$aidevops_plugin_path" ]]; then
		print_info "Setting up aidevops compaction plugin..."
		add_opencode_plugin "file://$HOME/.aidevops" "file://${aidevops_plugin_path}" "$opencode_config"
		print_success "aidevops compaction plugin registered (preserves context across compaction)"
	fi

	# Note: opencode-anthropic-auth is built into OpenCode v1.1.36+
	# Adding it as an external plugin causes TypeError due to double-loading.
	# Removed in v2.90.0 - see PR #230.

	print_info "After setup, authenticate with: opencode auth login"
	print_info "  • For Claude OAuth: Select 'Anthropic' → 'Claude Pro/Max' (built-in)"

	return 0
}
setup_seo_mcps() {
	print_info "Setting up SEO integrations..."

	# SEO services use curl-based subagents (no MCP needed)
	# Subagents: serper.md, dataforseo.md, ahrefs.md, google-search-console.md
	print_info "SEO uses curl-based subagents (zero context cost until invoked)"

	# Check if credentials are configured
	if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
		# shellcheck source=/dev/null
		source "$HOME/.config/aidevops/credentials.sh"

		[[ -n "$DATAFORSEO_USERNAME" ]] && print_success "DataForSEO credentials configured" ||
			print_info "DataForSEO: set DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD in credentials.sh"

		[[ -n "$SERPER_API_KEY" ]] && print_success "Serper API key configured" ||
			print_info "Serper: set SERPER_API_KEY in credentials.sh"

		[[ -n "$AHREFS_API_KEY" ]] && print_success "Ahrefs API key configured" ||
			print_info "Ahrefs: set AHREFS_API_KEY in credentials.sh"
	else
		print_info "Configure SEO API credentials in ~/.config/aidevops/credentials.sh"
	fi

	# GSC uses MCP (OAuth2 complexity warrants it)
	local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"
	if [[ -f "$gsc_creds" ]]; then
		print_success "Google Search Console credentials configured"
	else
		print_info "GSC: Create service account JSON at $gsc_creds"
		print_info "  See: ~/.aidevops/agents/seo/google-search-console.md"
	fi

	print_info "SEO documentation: ~/.aidevops/agents/seo/"
	return 0
}

# Setup Google Analytics MCP (uses shared GSC service account credentials)
setup_google_analytics_mcp() {
	print_info "Setting up Google Analytics MCP..."

	local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"

	# Check if opencode.json exists
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_warning "OpenCode config not found - skipping Google Analytics MCP"
		return 0
	fi

	# Check if jq is available
	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot add Google Analytics MCP to config"
		print_info "Install jq and re-run setup, or manually add the MCP config"
		return 0
	fi

	# Check if pipx is available
	if ! command -v pipx &>/dev/null; then
		print_warning "pipx not found - Google Analytics MCP requires pipx"
		print_info "Install pipx: brew install pipx (macOS) or pip install pipx"
		print_info "Then re-run setup to add Google Analytics MCP"
		return 0
	fi

	# Auto-detect credentials from shared GSC service account
	local creds_path=""
	local project_id=""
	local enable_mcp="false"

	if [[ -f "$gsc_creds" ]]; then
		creds_path="$gsc_creds"
		# Extract project_id from service account JSON
		project_id=$(jq -r '.project_id // empty' "$gsc_creds" 2>/dev/null)
		if [[ -n "$project_id" ]]; then
			enable_mcp="true"
			print_success "Found GSC credentials - sharing with Google Analytics MCP"
			print_info "Project: $project_id"
		fi
	fi

	# Check if google-analytics-mcp already exists in config
	if jq -e '.mcp["google-analytics-mcp"]' "$opencode_config" >/dev/null 2>&1; then
		# Update existing entry if we have credentials now
		if [[ "$enable_mcp" == "true" ]]; then
			local tmp_config
			tmp_config=$(mktemp)
			trap 'rm -f "${tmp_config:-}"' RETURN
			if jq --arg creds "$creds_path" --arg proj "$project_id" \
				'.mcp["google-analytics-mcp"].environment.GOOGLE_APPLICATION_CREDENTIALS = $creds |
                 .mcp["google-analytics-mcp"].environment.GOOGLE_PROJECT_ID = $proj |
                 .mcp["google-analytics-mcp"].enabled = true' \
				"$opencode_config" >"$tmp_config" 2>/dev/null; then
				mv "$tmp_config" "$opencode_config"
				print_success "Updated Google Analytics MCP with GSC credentials (enabled)"
			else
				rm -f "$tmp_config"
				print_warning "Failed to update Google Analytics MCP config"
			fi
		else
			print_info "Google Analytics MCP already configured in OpenCode"
		fi
		return 0
	fi

	# Add google-analytics-mcp to opencode.json
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	if jq --arg creds "$creds_path" --arg proj "$project_id" --argjson enabled "$enable_mcp" \
		'.mcp["google-analytics-mcp"] = {
        "type": "local",
        "command": ["analytics-mcp"],
        "environment": {
            "GOOGLE_APPLICATION_CREDENTIALS": $creds,
            "GOOGLE_PROJECT_ID": $proj
        },
        "enabled": $enabled
    }' "$opencode_config" >"$tmp_config" 2>/dev/null; then
		mv "$tmp_config" "$opencode_config"
		if [[ "$enable_mcp" == "true" ]]; then
			print_success "Added Google Analytics MCP to OpenCode (enabled with GSC credentials)"
		else
			print_success "Added Google Analytics MCP to OpenCode (disabled - no credentials found)"
			print_info "To enable: Create service account JSON at $gsc_creds"
		fi
		print_info "Or use the google-analytics subagent which enables it automatically"
	else
		rm -f "$tmp_config"
		print_warning "Failed to add Google Analytics MCP to config"
	fi

	# Show setup instructions
	print_info "Google Analytics MCP setup:"
	print_info "  1. Enable Google Analytics Admin & Data APIs in Google Cloud Console"
	print_info "  2. Configure ADC: gcloud auth application-default login --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform"
	print_info "  3. Update GOOGLE_APPLICATION_CREDENTIALS path in opencode.json"
	print_info "  4. Set GOOGLE_PROJECT_ID in opencode.json"
	print_info "Documentation: ~/.aidevops/agents/services/analytics/google-analytics.md"

	return 0
}

# Setup QuickFile MCP server (UK accounting API)
setup_quickfile_mcp() {
	print_info "Setting up QuickFile MCP server..."

	local quickfile_dir="$HOME/Git/quickfile-mcp"
	local credentials_dir="$HOME/.config/.quickfile-mcp"
	local credentials_file="$credentials_dir/credentials.json"

	# Check if Node.js is available
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - QuickFile MCP setup skipped"
		print_info "Install Node.js 18+ to enable QuickFile MCP"
		return 0
	fi

	# Check if already cloned and built
	if [[ -f "$quickfile_dir/dist/index.js" ]]; then
		print_success "QuickFile MCP already installed at $quickfile_dir"
	else
		print_info "QuickFile MCP provides AI access to UK accounting (invoices, clients, reports)"
		read -r -p "Clone and build QuickFile MCP server? [Y/n]: " install_qf

		if [[ "$install_qf" =~ ^[Yy]?$ ]]; then
			if [[ ! -d "$quickfile_dir" ]]; then
				if run_with_spinner "Cloning quickfile-mcp" git clone https://github.com/marcusquinn/quickfile-mcp.git "$quickfile_dir"; then
					print_success "Cloned quickfile-mcp"
				else
					print_warning "Failed to clone quickfile-mcp"
					return 0
				fi
			fi

			if run_with_spinner "Installing dependencies" npm install --prefix "$quickfile_dir"; then
				if run_with_spinner "Building QuickFile MCP" npm run build --prefix "$quickfile_dir"; then
					print_success "QuickFile MCP built successfully"
				else
					print_warning "Build failed - try manually: cd $quickfile_dir && npm run build"
					return 0
				fi
			else
				print_warning "npm install failed - try manually: cd $quickfile_dir && npm install"
				return 0
			fi
		else
			print_info "Skipped QuickFile MCP installation"
			print_info "Install later: git clone https://github.com/marcusquinn/quickfile-mcp.git ~/Git/quickfile-mcp"
			return 0
		fi
	fi

	# Check credentials
	if [[ -f "$credentials_file" ]]; then
		print_success "QuickFile credentials configured at $credentials_file"
	else
		print_info "QuickFile credentials not found"
		print_info "Create credentials:"
		print_info "  mkdir -p $credentials_dir && chmod 700 $credentials_dir"
		print_info "  Create $credentials_file with:"
		print_info "    accountNumber: from QuickFile dashboard (top-right)"
		print_info "    apiKey: Account Settings > 3rd Party Integrations > API Key"
		print_info "    applicationId: Account Settings > Create a QuickFile App"
	fi

	# Update OpenCode config if available
	local opencode_config
	if opencode_config=$(find_opencode_config); then
		local quickfile_entry
		quickfile_entry=$(jq -r '.mcp.quickfile // empty' "$opencode_config" 2>/dev/null)

		if [[ -z "$quickfile_entry" ]]; then
			print_info "Adding QuickFile MCP to OpenCode config..."
			local node_path
			node_path=$(resolve_mcp_binary_path "node")
			[[ -z "$node_path" ]] && node_path="node"

			local tmp_config
			tmp_config=$(mktemp)
			trap 'rm -f "${tmp_config:-}"' RETURN

			if jq --arg np "$node_path" --arg dp "$quickfile_dir/dist/index.js" \
				'.mcp.quickfile = {"type": "local", "command": [$np, $dp], "enabled": true}' \
				"$opencode_config" >"$tmp_config" 2>/dev/null; then
				create_backup_with_rotation "$opencode_config" "opencode"
				mv "$tmp_config" "$opencode_config"
				print_success "QuickFile MCP added to OpenCode config"
			else
				rm -f "$tmp_config"
				print_warning "Failed to update OpenCode config - add manually"
			fi
		else
			print_success "QuickFile MCP already in OpenCode config"
		fi
	fi

	print_info "Documentation: ~/.aidevops/agents/services/accounting/quickfile.md"
	return 0
}

# Setup multi-tenant credential storage
setup_multi_tenant_credentials() {
	print_info "Multi-tenant credential storage..."

	local credential_helper="$HOME/.aidevops/agents/scripts/credential-helper.sh"

	if [[ ! -f "$credential_helper" ]]; then
		# Try local script if deployed version not available yet
		credential_helper=".agents/scripts/credential-helper.sh"
	fi

	if [[ ! -f "$credential_helper" ]]; then
		print_warning "credential-helper.sh not found - skipping"
		return 0
	fi

	# Check if already initialized
	if [[ -d "$HOME/.config/aidevops/tenants" ]]; then
		local tenant_count
		tenant_count=$(find "$HOME/.config/aidevops/tenants" -maxdepth 1 -type d | wc -l)
		# Subtract 1 for the tenants/ dir itself
		tenant_count=$((tenant_count - 1))
		print_success "Multi-tenant already initialized ($tenant_count tenant(s))"
		bash "$credential_helper" status
		return 0
	fi

	# Check if there are existing credentials to migrate
	if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
		local key_count
		key_count=$(grep -c "^export " "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || echo "0")
		print_info "Found $key_count existing API keys in credentials.sh"
		print_info "Multi-tenant enables managing separate credential sets for:"
		echo "  - Multiple clients (agency/freelance work)"
		echo "  - Multiple environments (production, staging)"
		echo "  - Multiple accounts (personal, work)"
		echo ""
		print_info "Your existing keys will be migrated to a 'default' tenant."
		print_info "Everything continues to work as before - this is non-breaking."
		echo ""

		read -r -p "Enable multi-tenant credential storage? [Y/n]: " enable_mt
		enable_mt=$(echo "$enable_mt" | tr '[:upper:]' '[:lower:]')

		if [[ "$enable_mt" =~ ^[Yy]?$ || "$enable_mt" == "yes" ]]; then
			bash "$credential_helper" init
			print_success "Multi-tenant credential storage enabled"
			echo ""
			print_info "Quick start:"
			echo "  credential-helper.sh create client-name    # Create a tenant"
			echo "  credential-helper.sh switch client-name    # Switch active tenant"
			echo "  credential-helper.sh set KEY val --tenant X  # Add key to tenant"
			echo "  credential-helper.sh status                # Show current state"
		else
			print_info "Skipped. Enable later: credential-helper.sh init"
		fi
	else
		print_info "No existing credentials found. Multi-tenant available when needed."
		print_info "Enable later: credential-helper.sh init"
	fi

	return 0
}

# Check for tool updates after setup
check_tool_updates() {
	print_info "Checking for tool updates..."

	local tool_check_script="$HOME/.aidevops/agents/scripts/tool-version-check.sh"

	if [[ ! -f "$tool_check_script" ]]; then
		# Try local script if deployed version not available yet
		tool_check_script=".agents/scripts/tool-version-check.sh"
	fi

	if [[ ! -f "$tool_check_script" ]]; then
		print_warning "Tool version check script not found - skipping update check"
		return 0
	fi

	# Run the check in quiet mode first to see if there are updates
	# Capture both output and exit code
	local outdated_output
	local check_exit_code
	outdated_output=$(bash "$tool_check_script" --quiet 2>&1) || check_exit_code=$?
	check_exit_code=${check_exit_code:-0}

	# If the script failed, warn and continue
	if [[ $check_exit_code -ne 0 ]]; then
		print_warning "Tool version check encountered an error (exit code: $check_exit_code)"
		print_info "Run 'aidevops update-tools' manually to check for updates"
		return 0
	fi

	if [[ -z "$outdated_output" ]]; then
		print_success "All tools are up to date!"
		return 0
	fi

	# Show what's outdated
	echo ""
	print_warning "Some tools have updates available:"
	echo ""
	bash "$tool_check_script" --quiet
	echo ""

	read -r -p "Update all outdated tools now? [Y/n]: " do_update

	if [[ "$do_update" =~ ^[Yy]?$ || "$do_update" == "Y" ]]; then
		print_info "Updating tools..."
		bash "$tool_check_script" --update
		print_success "Tool updates complete!"
	else
		print_info "Skipped tool updates"
		print_info "Run 'aidevops update-tools' anytime to update tools"
	fi

	return 0
}

# Parse command line arguments
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--clean)
			CLEAN_MODE=true
			shift
			;;
		--interactive | -i)
			INTERACTIVE_MODE=true
			shift
			;;
		--non-interactive | -n)
			NON_INTERACTIVE=true
			shift
			;;
		--update | -u)
			UPDATE_TOOLS_MODE=true
			shift
			;;
		--help | -h)
			echo "Usage: ./setup.sh [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --clean            Remove stale files before deploying (cleans ~/.aidevops/agents/)"
			echo "  --interactive, -i  Ask confirmation before each step"
			echo "  --non-interactive, -n  Deploy agents only, skip all optional installs (no prompts)"
			echo "  --update, -u       Check for and offer to update outdated tools after setup"
			echo "  --help             Show this help message"
			echo ""
			echo "Default behavior adds/overwrites files without removing deleted agents."
			echo "Use --clean after removing or renaming agents to sync deletions."
			echo "Use --interactive to control each step individually."
			echo "Use --non-interactive for CI/CD or AI agent shells (no stdin required)."
			echo "Use --update to check for tool updates after setup completes."
			exit 0
			;;
		*)
			print_error "Unknown option: $1"
			echo "Use --help for usage information"
			exit 1
			;;
		esac
	done
	return 0
}

# Main setup function
main() {
	# Bootstrap first (handles curl install)
	bootstrap_repo "$@"

	parse_args "$@"

	# Guard: --interactive and --non-interactive are mutually exclusive
	if [[ "$INTERACTIVE_MODE" == "true" && "$NON_INTERACTIVE" == "true" ]]; then
		print_error "--interactive and --non-interactive cannot be used together"
		exit 1
	fi

	echo "🤖 AI DevOps Framework Setup"
	echo "============================="
	if [[ "$CLEAN_MODE" == "true" ]]; then
		echo "Mode: Clean (removing stale files)"
	fi
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		echo "Mode: Non-interactive (deploy + migrations only, no prompts)"
	elif [[ "$INTERACTIVE_MODE" == "true" ]]; then
		echo "Mode: Interactive (confirm each step)"
		echo ""
		echo "Controls: [Y]es (default) / [n]o skip / [q]uit"
	fi
	if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
		echo "Mode: Update (will check for tool updates after setup)"
	fi
	echo ""

	# Non-interactive mode: deploy agents only, skip all optional installs
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		print_info "Non-interactive mode: deploying agents and running safe migrations only"
		verify_location
		check_requirements
		set_permissions
		migrate_old_backups
		migrate_loop_state_directories
		migrate_agent_to_agents_folder
		migrate_mcp_env_to_credentials
		cleanup_deprecated_paths
		cleanup_deprecated_mcps
		validate_opencode_config
		deploy_aidevops_agents
		setup_safety_hooks
		generate_agent_skills
		create_skill_symlinks
		scan_imported_skills
		inject_agents_reference
		update_opencode_config
		disable_ondemand_mcps
	else
		# Required steps (always run)
		verify_location
		check_requirements

		# Quality tools check (optional but recommended)
		confirm_step "Check quality tools (shellcheck, shfmt)" && check_quality_tools

		# Core runtime setup (early - many later steps depend on these)
		confirm_step "Setup Node.js runtime (required for OpenCode and tools)" && setup_nodejs

		# Shell environment setup (early, so later tools benefit from zsh/Oh My Zsh)
		confirm_step "Setup Oh My Zsh (optional, enhances zsh)" && setup_oh_my_zsh
		confirm_step "Setup cross-shell compatibility (preserve bash config in zsh)" && setup_shell_compatibility

		# OrbStack (macOS only - offer VM option early)
		confirm_step "Setup OrbStack (lightweight Linux VMs on macOS)" && setup_orbstack_vm

		# Optional steps with confirmation in interactive mode
		confirm_step "Check optional dependencies (bun, node, python)" && check_optional_deps
		confirm_step "Setup recommended tools (Tabby, Zed, etc.)" && setup_recommended_tools
		confirm_step "Setup MiniSim (iOS/Android emulator launcher)" && setup_minisim
		confirm_step "Setup Git CLIs (gh, glab, tea)" && setup_git_clis
		confirm_step "Setup file discovery tools (fd, ripgrep)" && setup_file_discovery_tools
		confirm_step "Setup shell linting tools (shellcheck, shfmt)" && setup_shell_linting_tools
		confirm_step "Rosetta audit (Apple Silicon x86 migration)" && setup_rosetta_audit
		confirm_step "Setup Worktrunk (git worktree management)" && setup_worktrunk
		confirm_step "Setup SSH key" && setup_ssh_key
		confirm_step "Setup configuration files" && setup_configs
		confirm_step "Set secure permissions on config files" && set_permissions
		confirm_step "Install aidevops CLI command" && install_aidevops_cli
		confirm_step "Setup shell aliases" && setup_aliases
		confirm_step "Setup terminal title integration" && setup_terminal_title
		confirm_step "Deploy AI templates to home directories" && deploy_ai_templates
		confirm_step "Migrate old backups to new structure" && migrate_old_backups
		confirm_step "Migrate loop state from .claude/.agent/ to .agents/loop-state/" && migrate_loop_state_directories
		confirm_step "Migrate .agent -> .agents in user projects" && migrate_agent_to_agents_folder
		confirm_step "Migrate mcp-env.sh -> credentials.sh" && migrate_mcp_env_to_credentials
		confirm_step "Cleanup deprecated agent paths" && cleanup_deprecated_paths
		confirm_step "Cleanup deprecated MCP entries (hetzner, serper, etc.)" && cleanup_deprecated_mcps
		confirm_step "Validate and repair OpenCode config schema" && validate_opencode_config
		confirm_step "Extract OpenCode prompts" && extract_opencode_prompts
		confirm_step "Check OpenCode prompt drift" && check_opencode_prompt_drift
		confirm_step "Deploy aidevops agents to ~/.aidevops/agents/" && deploy_aidevops_agents
		confirm_step "Install Claude Code safety hooks (block destructive commands)" && setup_safety_hooks
		confirm_step "Setup multi-tenant credential storage" && setup_multi_tenant_credentials
		confirm_step "Generate agent skills (SKILL.md files)" && generate_agent_skills
		confirm_step "Create symlinks for imported skills" && create_skill_symlinks
		confirm_step "Check for skill updates from upstream" && check_skill_updates
		confirm_step "Security scan imported skills" && scan_imported_skills
		confirm_step "Inject agents reference into AI configs" && inject_agents_reference
		confirm_step "Setup Python environment (DSPy, crawl4ai)" && setup_python_env
		confirm_step "Setup Node.js environment" && setup_nodejs_env
		confirm_step "Install MCP packages globally (fast startup)" && install_mcp_packages
		confirm_step "Setup LocalWP MCP server" && setup_localwp_mcp
		confirm_step "Setup Augment Context Engine MCP" && setup_augment_context_engine
		confirm_step "Setup osgrep (local semantic search)" && setup_osgrep
		confirm_step "Setup Beads task management" && setup_beads
		confirm_step "Setup SEO integrations (curl subagents)" && setup_seo_mcps
		confirm_step "Setup Google Analytics MCP" && setup_google_analytics_mcp
		confirm_step "Setup QuickFile MCP (UK accounting)" && setup_quickfile_mcp
		confirm_step "Setup browser automation tools" && setup_browser_tools
		confirm_step "Setup AI orchestration frameworks info" && setup_ai_orchestration
		confirm_step "Setup OpenCode CLI (AI coding tool)" && setup_opencode_cli
		confirm_step "Setup OpenCode plugins" && setup_opencode_plugins
		# Run AFTER OpenCode CLI install so opencode.json may exist for agent config
		confirm_step "Update OpenCode configuration" && update_opencode_config
		# Run AFTER all MCP setup functions to ensure disabled state persists
		confirm_step "Disable on-demand MCPs globally" && disable_ondemand_mcps
	fi

	echo ""
	print_success "🎉 Setup complete!"

	# Enable auto-update if not already enabled
	local auto_update_script="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"
	if [[ -x "$auto_update_script" ]] && [[ "${AIDEVOPS_AUTO_UPDATE:-true}" != "false" ]]; then
		if ! crontab -l 2>/dev/null | grep -q "aidevops-auto-update"; then
			if [[ "$NON_INTERACTIVE" == "true" ]]; then
				# Non-interactive: enable silently
				bash "$auto_update_script" enable >/dev/null 2>&1 || true
				print_info "Auto-update enabled (every 10 min). Disable: aidevops auto-update disable"
			else
				echo ""
				echo "Auto-update keeps aidevops current by checking every 10 minutes."
				echo "Safe to run while AI sessions are active."
				echo ""
				read -r -p "Enable auto-update? [Y/n]: " enable_auto
				if [[ "$enable_auto" =~ ^[Yy]?$ || -z "$enable_auto" ]]; then
					bash "$auto_update_script" enable
				else
					print_info "Skipped. Enable later: aidevops auto-update enable"
				fi
			fi
		fi
	fi

	echo ""
	echo "CLI Command:"
	echo "  aidevops init         - Initialize aidevops in a project"
	echo "  aidevops features     - List available features"
	echo "  aidevops status       - Check installation status"
	echo "  aidevops update       - Update to latest version"
	echo "  aidevops update-tools - Check for and update installed tools"
	echo "  aidevops uninstall    - Remove aidevops"
	echo ""
	echo "Deployed to:"
	echo "  ~/.aidevops/agents/     - Agent files (main agents, subagents, scripts)"
	echo "  ~/.aidevops/*-backups/  - Backups with rotation (keeps last $BACKUP_KEEP_COUNT)"
	echo ""
	echo "Next steps:"
	echo "1. Edit configuration files in configs/ with your actual credentials"
	echo "2. Setup Git CLI tools and authentication (shown during setup)"
	echo "3. Setup API keys: bash .agents/scripts/setup-local-api-keys.sh setup"
	echo "4. Test access: ./.agents/scripts/servers-helper.sh list"
	echo "5. Read documentation: ~/.aidevops/agents/AGENTS.md"
	echo ""
	echo "For development on aidevops framework itself:"
	echo "  See ~/Git/aidevops/AGENTS.md"
	echo ""
	echo "OpenCode Primary Agents (12 total, Tab to switch):"
	echo "• Plan+      - Enhanced planning with context tools (read-only)"
	echo "• Build+     - Enhanced build with context tools (full access)"
	echo "• Accounts, AI-DevOps, Content, Health, Legal, Marketing,"
	echo "  Research, Sales, SEO, WordPress"
	echo ""
	echo "Agent Skills (SKILL.md):"
	echo "• 21 SKILL.md files generated in ~/.aidevops/agents/"
	echo "• Skills include: wordpress, seo, aidevops, build-mcp, and more"
	echo ""
	echo "MCP Integrations (OpenCode):"
	echo "• Augment Context Engine - Cloud semantic codebase retrieval"
	echo "• Context7               - Real-time library documentation"
	echo "• osgrep                 - Local semantic search (100% private)"
	echo "• GSC                    - Google Search Console (MCP + OAuth2)"
	echo "• Google Analytics       - Analytics data (shared GSC credentials)"
	echo ""
	echo "SEO Integrations (curl subagents - no MCP overhead):"
	echo "• DataForSEO             - Comprehensive SEO data APIs"
	echo "• Serper                 - Google Search API"
	echo "• Ahrefs                 - Backlink and keyword data"
	echo ""
	echo "DSPy & DSPyGround Integration:"
	echo "• ./.agents/scripts/dspy-helper.sh        - DSPy prompt optimization toolkit"
	echo "• ./.agents/scripts/dspyground-helper.sh  - DSPyGround playground interface"
	echo "• python-env/dspy-env/              - Python virtual environment for DSPy"
	echo "• data/dspy/                        - DSPy projects and datasets"
	echo "• data/dspyground/                  - DSPyGround projects and configurations"
	echo ""
	echo "Task Management:"
	echo "• Beads CLI (bd)                    - Task graph visualization"
	echo "• beads-sync-helper.sh              - Sync TODO.md/PLANS.md with Beads"
	echo "• todo-ready.sh                     - Show tasks with no open blockers"
	echo "• Run: aidevops init beads          - Initialize Beads in a project"
	echo ""
	echo "Security reminders:"
	echo "- Never commit configuration files with real credentials"
	echo "- Use strong passwords and enable MFA on all accounts"
	echo "- Regularly rotate API tokens and SSH keys"
	echo ""
	echo "Happy server managing! 🚀"
	echo ""

	# Check for tool updates if --update flag was passed
	if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
		echo ""
		check_tool_updates
	fi

	# Offer to launch onboarding for new users (only if not running inside OpenCode and not non-interactive)
	if [[ "$NON_INTERACTIVE" != "true" ]] && [[ -z "${OPENCODE_SESSION:-}" ]] && command -v opencode &>/dev/null; then
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
		echo ""
		echo "Ready to configure your services?"
		echo ""
		echo "Launch OpenCode with the onboarding wizard to:"
		echo "  - See which services are already configured"
		echo "  - Get personalized recommendations based on your work"
		echo "  - Set up API keys and credentials interactively"
		echo ""
		read -r -p "Launch OpenCode with /onboarding now? [Y/n]: " launch_onboarding
		if [[ "$launch_onboarding" =~ ^[Yy]?$ || "$launch_onboarding" == "Y" ]]; then
			echo ""
			echo "Starting OpenCode with onboarding wizard..."
			# Launch with /onboarding prompt only — don't use --agent flag because
			# the "Onboarding" agent only exists after generate-opencode-agents.sh
			# writes to opencode.json, which requires opencode.json to already exist.
			# On first run it won't, so --agent "Onboarding" causes a fatal error.
			opencode --prompt "/onboarding"
		else
			echo ""
			echo "You can run /onboarding anytime in OpenCode to configure services."
		fi
	fi

	return 0
}

# Run setup
main "$@"
