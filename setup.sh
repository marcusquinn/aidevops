#!/usr/bin/env bash

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 2.159.0
#
# Quick Install:
#   npm install -g aidevops && aidevops update          (recommended)
#   brew install marcusquinn/tap/aidevops && aidevops update  (Homebrew)
#   bash <(curl -fsSL https://aidevops.sh/install)                     (manual)

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
# Platform constants — exported for sourced setup-modules (shell-env.sh,
# tool-install.sh) that reference them at runtime.
PLATFORM_MACOS=$([[ "$(uname -s)" == "Darwin" ]] && echo true || echo false)
PLATFORM_ARM64=$([[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]] && echo true || echo false)
export PLATFORM_MACOS PLATFORM_ARM64
readonly PLATFORM_MACOS PLATFORM_ARM64
# Repo constants — exported; consumed by setup-modules/core.sh, agent-deploy.sh
REPO_URL="https://github.com/marcusquinn/aidevops.git"
INSTALL_DIR="$HOME/Git/aidevops"
export REPO_URL INSTALL_DIR

# Source modular setup functions (t316.2)
# These modules are sourced only when setup.sh is run from the repo directory
# (not during bootstrap from curl, which re-execs after cloning)
SETUP_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.agents/scripts/setup" 2>/dev/null && pwd)" || true
if [[ -d "$SETUP_MODULES_DIR" ]]; then
	# shellcheck disable=SC1091  # Dynamic path via $SETUP_MODULES_DIR; files exist at runtime
	source "$SETUP_MODULES_DIR/_common.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_backup.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_validation.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_migration.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_shell.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_installation.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_deployment.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_opencode.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_tools.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_services.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_bootstrap.sh"
fi

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Source shared-constants for config support (is_feature_enabled / config_enabled)
# Try repo-local first, then deployed location
_SHARED_CONSTANTS="${BASH_SOURCE[0]%/*}/.agents/scripts/shared-constants.sh"
if [[ ! -f "$_SHARED_CONSTANTS" ]]; then
	_SHARED_CONSTANTS="$HOME/.aidevops/agents/scripts/shared-constants.sh"
fi
if [[ -f "$_SHARED_CONSTANTS" ]]; then
	# shellcheck disable=SC1090  # Dynamic path resolved at runtime
	source "$_SHARED_CONSTANTS"
fi
unset _SHARED_CONSTANTS

# Escape a string for safe embedding in XML (plist heredocs).
# Prevents XML injection if paths contain &, <, >, ", or ' characters.
_xml_escape() {
	local str="$1"
	str="${str//&/&amp;}"
	str="${str//</&lt;}"
	str="${str//>/&gt;}"
	str="${str//\"/&quot;}"
	str="${str//\'/&apos;}"
	printf '%s' "$str"
	return 0
}

# Escape a string for safe embedding in crontab entries.
# Wraps value in single quotes (prevents $(…), backtick, and variable expansion
# by cron's /bin/sh). Embedded single quotes are escaped via the '\'' idiom.
_cron_escape() {
	local str="$1"
	# Replace each ' with '\'' (end quote, escaped quote, start quote)
	str="${str//\'/\'\\\'\'}"
	printf "'%s'" "$str"
	return 0
}

# Check if a launchd agent is loaded (SIGPIPE-safe for pipefail, t1265)
_launchd_has_agent() {
	local label="$1"
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$label"
	return $?
}

# Spinner for long-running operations
# Usage: run_with_spinner "Installing package..." command arg1 arg2
run_with_spinner() {
	local message="$1"
	shift
	local pid
	local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
	local i=0

	# Suppress Homebrew's slow auto-update for all backgrounded brew commands.
	# run_with_spinner backgrounds via "$@" &, so env var prefix syntax
	# (VAR=x cmd) doesn't propagate. Export globally for the child process.
	local _brew_was_set="${HOMEBREW_NO_AUTO_UPDATE:-}"
	local _cmd="${1:-}"
	local _subcmd="${2:-}"
	if [[ "$_cmd" == "brew" && "$_subcmd" != "update" ]]; then
		export HOMEBREW_NO_AUTO_UPDATE=1
	fi

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

	# Restore HOMEBREW_NO_AUTO_UPDATE to previous state
	if [[ -z "$_brew_was_set" ]]; then
		unset HOMEBREW_NO_AUTO_UPDATE
	fi

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
	# Build cmd array once; prepend sudo conditionally to avoid duplicating the safe expansion
	# Use ${extra_args[@]+"${extra_args[@]}"} for safe expansion under set -u when array is empty
	local cmd=()
	[[ "$use_sudo" == "true" ]] && cmd+=(sudo)
	cmd+=("$shell" "$tmp_script" ${extra_args[@]+"${extra_args[@]}"})

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

# Install a package globally via npm, with sudo when needed on Linux.
# Usage: npm_global_install "package-name" OR npm_global_install "package@version"
# On Linux with apt-installed npm, automatically prepends sudo.
# Returns: 0 on success, 1 on failure
npm_global_install() {
	local pkg="$1"

	if command -v npm >/dev/null 2>&1; then
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

# =============================================================================
# Bootstrap guard: detect curl/process-substitution execution
# When running via `bash <(curl ...)`, BASH_SOURCE[0] is /dev/fd/NN and the
# setup-modules/ directory doesn't exist at that path. We must clone the repo
# first, then re-exec the local copy. This MUST run before any source lines.
# =============================================================================
_setup_script_dir="$(dirname "${BASH_SOURCE[0]}")"
if [[ ! -d "$_setup_script_dir/setup-modules" ]]; then
	# Running from curl pipe or process substitution — bootstrap the repo
	print_info "Remote install detected — bootstrapping repository..."

	# Auto-install git if missing
	if ! command -v git >/dev/null 2>&1; then
		if [[ "$(uname)" == "Darwin" ]]; then
			print_info "Installing Xcode Command Line Tools (includes git)..."
			xcode-select --install 2>/dev/null || true
			xcode_wait=0
			while ! command -v git >/dev/null 2>&1 && [[ $xcode_wait -lt 300 ]]; do
				sleep 5
				xcode_wait=$((xcode_wait + 5))
			done
			if ! command -v git >/dev/null 2>&1; then
				print_error "git not available after Xcode CLT install. Re-run after installation completes."
				exit 1
			fi
		elif command -v apt-get >/dev/null 2>&1; then
			sudo apt-get update -qq && sudo apt-get install -y -qq git
		elif command -v dnf >/dev/null 2>&1; then
			sudo dnf install -y git
		elif command -v yum >/dev/null 2>&1; then
			sudo yum install -y git
		elif command -v pacman >/dev/null 2>&1; then
			sudo pacman -S --noconfirm git
		elif command -v apk >/dev/null 2>&1; then
			sudo apk add git
		else
			print_error "git is required but not installed and no supported package manager found"
			exit 1
		fi
	fi

	# Clone or update the repo
	mkdir -p "$(dirname "$INSTALL_DIR")"
	if [[ -d "$INSTALL_DIR/.git" ]]; then
		print_info "Existing installation found — updating..."
		cd "$INSTALL_DIR" || exit 1
		git pull --ff-only || {
			print_warning "Git pull failed — resetting to origin/main"
			git fetch origin
			git reset --hard origin/main
		}
	else
		if [[ -d "$INSTALL_DIR" ]]; then
			print_warning "Directory exists but is not a git repo — backing up"
			mv "$INSTALL_DIR" "$INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
		fi
		print_info "Cloning aidevops to $INSTALL_DIR..."
		git clone "$REPO_URL" "$INSTALL_DIR" || {
			print_error "Failed to clone repository"
			exit 1
		}
	fi

	print_success "Repository ready at $INSTALL_DIR"

	# Re-execute the local copy (which has setup-modules/ available)
	cd "$INSTALL_DIR" || exit 1
	exec bash "./setup.sh" "$@"
fi
unset _setup_script_dir

# Source modularized setup functions
# shellcheck disable=SC1091  # Dynamic path via BASH_SOURCE; files exist at runtime
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/core.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/migrations.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/shell-env.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/tool-install.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/mcp-setup.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/agent-deploy.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/config.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/plugins.sh"

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

# Initialize ~/.config/aidevops/settings.json with documented defaults.
# Idempotent — merges missing keys without overwriting existing values.
init_settings_json() {
	local settings_helper="$HOME/.aidevops/agents/scripts/settings-helper.sh"
	if [[ -x "$settings_helper" ]]; then
		if bash "$settings_helper" init >/dev/null 2>&1; then
			print_info "Settings file initialized: ~/.config/aidevops/settings.json"
		fi
	else
		# Fallback: try from repo directory (first run before deployment)
		local repo_helper
		repo_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.agents/scripts/settings-helper.sh"
		if [[ -x "$repo_helper" ]]; then
			if bash "$repo_helper" init >/dev/null 2>&1; then
				print_info "Settings file initialized: ~/.config/aidevops/settings.json"
			fi
		fi
	fi
	return 0
}

# Main setup function
main() {
	# Bootstrap first (handles curl install)
	bootstrap_repo "$@"

	parse_args "$@"

	# Auto-detect non-interactive terminals (CI/CD, agent shells, piped stdin)
	# Must run after parse_args so explicit --interactive flag takes precedence
	if [[ "$INTERACTIVE_MODE" != "true" && ! -t 0 ]]; then
		NON_INTERACTIVE=true
	fi

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
		migrate_pulse_repos_to_repos_json
		cleanup_deprecated_paths
		cleanup_deprecated_mcps
		cleanup_stale_bun_opencode
		validate_opencode_config
		deploy_aidevops_agents
		sync_agent_sources
		setup_shellcheck_wrapper
		if is_feature_enabled safety_hooks 2>/dev/null; then
			setup_safety_hooks
		fi
		init_settings_json

		# Parallelise independent skill operations (t1356: ~84s serial -> ~18s parallel)
		# generate_agent_skills (18s), create_skill_symlinks (<1s), and
		# scan_imported_skills (66s serial, ~10s with parallel scanning) are independent.
		generate_agent_skills &
		local _pid_skills=$!
		create_skill_symlinks &
		local _pid_symlinks=$!
		scan_imported_skills &
		local _pid_scan=$!
		wait "$_pid_skills" 2>/dev/null || print_warning "Agent skills generation encountered issues (non-critical)"
		wait "$_pid_symlinks" 2>/dev/null || print_warning "Skill symlink creation encountered issues (non-critical)"
		wait "$_pid_scan" 2>/dev/null || print_warning "Skill security scan encountered issues (non-critical)"

		inject_agents_reference
		if is_feature_enabled manage_opencode_config 2>/dev/null; then
			update_opencode_config
		else
			print_info "OpenCode config management disabled via config (integrations.manage_opencode_config)"
		fi
		if is_feature_enabled manage_claude_config 2>/dev/null; then
			update_claude_config
		else
			print_info "Claude config management disabled via config (integrations.manage_claude_config)"
		fi
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
		confirm_step "Setup file discovery tools (fd, ripgrep, ripgrep-all)" && setup_file_discovery_tools
		confirm_step "Setup shell linting tools (shellcheck, shfmt)" && setup_shell_linting_tools
		setup_shellcheck_wrapper
		confirm_step "Setup Qlty CLI (multi-linter code quality)" && setup_qlty_cli
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
		confirm_step "Migrate pulse-repos.json into repos.json" && migrate_pulse_repos_to_repos_json
		confirm_step "Cleanup deprecated agent paths" && cleanup_deprecated_paths
		confirm_step "Cleanup deprecated MCP entries (hetzner, serper, etc.)" && cleanup_deprecated_mcps
		confirm_step "Cleanup stale bun opencode install" && cleanup_stale_bun_opencode
		confirm_step "Validate and repair OpenCode config schema" && validate_opencode_config
		confirm_step "Extract OpenCode prompts" && extract_opencode_prompts
		confirm_step "Check OpenCode prompt drift" && check_opencode_prompt_drift
		confirm_step "Deploy aidevops agents to ~/.aidevops/agents/" && deploy_aidevops_agents
		confirm_step "Sync agents from private repositories" && sync_agent_sources
		setup_shellcheck_wrapper
		confirm_step "Install Claude Code safety hooks (block destructive commands)" && setup_safety_hooks
		confirm_step "Initialize settings.json (canonical config file)" && init_settings_json
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
		# Run AFTER OpenCode config so Claude Code gets equivalent setup
		confirm_step "Update Claude Code configuration (slash commands, MCPs, settings)" && update_claude_config
		# Run AFTER all MCP setup functions to ensure disabled state persists
		confirm_step "Disable on-demand MCPs globally" && disable_ondemand_mcps
	fi

	echo ""
	print_success "🎉 Setup complete!"

	# Enable auto-update if not already enabled
	# Check both launchd (macOS) and cron (Linux) for existing installation
	# Respects config: aidevops config set updates.auto_update false
	local auto_update_script="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"
	if [[ -x "$auto_update_script" ]] && is_feature_enabled auto_update 2>/dev/null; then
		local _auto_update_installed=false
		if _launchd_has_agent "com.aidevops.aidevops-auto-update"; then
			_auto_update_installed=true
		elif _launchd_has_agent "com.aidevops.auto-update"; then
			# Old label — re-running enable will migrate to new label
			if bash "$auto_update_script" enable >/dev/null 2>&1; then
				print_info "Auto-update LaunchAgent migrated to new label"
			else
				print_warning "Auto-update label migration failed. Run: aidevops auto-update enable"
			fi
			_auto_update_installed=true
		elif crontab -l 2>/dev/null | grep -qF "aidevops-auto-update"; then
			if [[ "$(uname -s)" == "Darwin" ]]; then
				# macOS: cron entry exists but no launchd plist — migrate
				if bash "$auto_update_script" enable >/dev/null 2>&1; then
					print_info "Auto-update migrated from cron to launchd"
				else
					print_warning "Auto-update cron→launchd migration failed. Run: aidevops auto-update enable"
				fi
			fi
			_auto_update_installed=true
		fi
		if [[ "$_auto_update_installed" == "false" ]]; then
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

	# Supervisor pulse scheduler — consent-gated autonomous orchestration.
	# Uses pulse-wrapper.sh which handles dedup, orphan cleanup, and RAM-based concurrency.
	# macOS: launchd plist invoking wrapper | Linux: cron entry invoking wrapper
	# The plist is ALWAYS regenerated on setup.sh to pick up config changes (env vars,
	# thresholds). Only the first-install prompt is gated on consent state.
	#
	# Consent model (GH#2926):
	#   - Default OFF: supervisor_pulse defaults to false in all config layers
	#   - Explicit consent required: user must type "y" (prompt defaults to [y/N])
	#   - Consent persisted: written to config.jsonc so it survives updates
	#   - Never silently re-enabled: if config says false, skip entirely
	#   - Non-interactive: only installs if config explicitly says true
	local wrapper_script="$HOME/.aidevops/agents/scripts/pulse-wrapper.sh"
	local pulse_label="com.aidevops.aidevops-supervisor-pulse"
	local _aidevops_dir
	_aidevops_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# Read explicit user consent from config.jsonc (not merged defaults).
	# Empty = user never configured this; "true"/"false" = explicit choice.
	local _pulse_user_config=""
	if type _jsonc_get_raw &>/dev/null && [[ -f "${JSONC_USER:-$HOME/.config/aidevops/config.jsonc}" ]]; then
		_pulse_user_config=$(_jsonc_get_raw "${JSONC_USER:-$HOME/.config/aidevops/config.jsonc}" "orchestration.supervisor_pulse")
	fi

	# Also check legacy .conf user override
	if [[ -z "$_pulse_user_config" && -f "${FEATURE_TOGGLES_USER:-$HOME/.config/aidevops/feature-toggles.conf}" ]]; then
		local _legacy_val
		# Use awk instead of grep|tail|cut — grep exits 1 on no match, which
		# aborts the script under set -euo pipefail. awk always exits 0.
		_legacy_val=$(awk -F= '/^supervisor_pulse=/{val=$2} END{print val}' "${FEATURE_TOGGLES_USER:-$HOME/.config/aidevops/feature-toggles.conf}")
		if [[ -n "$_legacy_val" ]]; then
			_pulse_user_config="$_legacy_val"
		fi
	fi

	# Also check env var override (highest priority)
	if [[ -n "${AIDEVOPS_SUPERVISOR_PULSE:-}" ]]; then
		_pulse_user_config="$AIDEVOPS_SUPERVISOR_PULSE"
	fi

	# Determine action based on consent state
	local _do_install=false
	local _pulse_lower
	_pulse_lower=$(echo "$_pulse_user_config" | tr '[:upper:]' '[:lower:]')

	if [[ "$_pulse_lower" == "false" ]]; then
		# User explicitly declined — never prompt, never install
		_do_install=false
	elif [[ "$_pulse_lower" == "true" ]]; then
		# User explicitly consented — install/regenerate
		_do_install=true
	elif [[ -z "$_pulse_user_config" ]]; then
		# No explicit config — fresh install or never configured
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			# Non-interactive: default OFF, do not install without consent
			_do_install=false
		elif [[ -f "$wrapper_script" ]]; then
			# Interactive: prompt with default-no
			echo ""
			echo "The supervisor pulse enables autonomous orchestration."
			echo "It will act under your GitHub identity and consume API credits:"
			echo "  - Dispatches AI workers to implement tasks from GitHub issues"
			echo "  - Creates PRs, merges passing PRs, files improvement issues"
			echo "  - 4-hourly strategic review (opus-tier) for queue health"
			echo "  - Circuit breaker pauses dispatch on consecutive failures"
			echo ""
			read -r -p "Enable supervisor pulse? [y/N]: " enable_pulse
			if [[ "$enable_pulse" =~ ^[Yy]$ ]]; then
				_do_install=true
				# Record explicit consent
				if type cmd_set &>/dev/null; then
					cmd_set "orchestration.supervisor_pulse" "true" || true
				fi
			else
				_do_install=false
				# Record explicit decline so we never re-prompt on updates
				if type cmd_set &>/dev/null; then
					cmd_set "orchestration.supervisor_pulse" "false" || true
				fi
				print_info "Skipped. Enable later: aidevops config set orchestration.supervisor_pulse true && ./setup.sh"
			fi
		fi
	fi

	# Guard: wrapper must exist
	if [[ "$_do_install" == "true" && ! -f "$wrapper_script" ]]; then
		# Wrapper not deployed yet — skip (will install on next run after rsync)
		_do_install=false
	fi

	# Detect if pulse is already installed (for upgrade messaging)
	local _pulse_installed=false
	if [[ "$(uname -s)" == "Darwin" ]]; then
		local pulse_plist="$HOME/Library/LaunchAgents/${pulse_label}.plist"
		if _launchd_has_agent "$pulse_label"; then
			_pulse_installed=true
		fi
	fi
	if [[ "$_pulse_installed" == "false" ]] && crontab -l 2>/dev/null | grep -qF "pulse-wrapper"; then
		_pulse_installed=true
	fi

	# Detect opencode binary location
	local opencode_bin
	opencode_bin=$(command -v opencode 2>/dev/null || echo "/opt/homebrew/bin/opencode")

	if [[ "$_do_install" == "true" ]]; then
		mkdir -p "$HOME/.aidevops/logs"

		if [[ "$(uname -s)" == "Darwin" ]]; then
			# macOS: use launchd plist with wrapper
			local pulse_plist="$HOME/Library/LaunchAgents/${pulse_label}.plist"

			# Unload old plist if upgrading
			if _launchd_has_agent "$pulse_label"; then
				launchctl unload "$pulse_plist" || true
				pkill -f 'Supervisor Pulse' 2>/dev/null || true
			fi

			# Also clean up old label if present
			local old_plist="$HOME/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist"
			if [[ -f "$old_plist" ]]; then
				launchctl unload "$old_plist" || true
				rm -f "$old_plist"
			fi

			# XML-escape paths for safe plist embedding (prevents injection
			# if $HOME or paths contain &, <, > characters)
			local _xml_wrapper_script _xml_home _xml_opencode_bin _xml_aidevops_dir _xml_path
			_xml_wrapper_script=$(_xml_escape "$wrapper_script")
			_xml_home=$(_xml_escape "$HOME")
			_xml_opencode_bin=$(_xml_escape "$opencode_bin")
			_xml_aidevops_dir=$(_xml_escape "$_aidevops_dir")
			_xml_path=$(_xml_escape "$PATH")

			# Write the plist (always regenerated to pick up config changes)
			cat >"$pulse_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${pulse_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_wrapper_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>120</integer>
	<key>StandardOutPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-wrapper.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-wrapper.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_path}</string>
		<key>HOME</key>
		<string>${_xml_home}</string>
		<key>OPENCODE_BIN</key>
		<string>${_xml_opencode_bin}</string>
		<key>PULSE_DIR</key>
		<string>${_xml_aidevops_dir}</string>
		<key>PULSE_STALE_THRESHOLD</key>
		<string>1800</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST

			if launchctl load "$pulse_plist"; then
				if [[ "$_pulse_installed" == "true" ]]; then
					print_info "Supervisor pulse updated (launchd config regenerated)"
				else
					print_info "Supervisor pulse enabled (launchd, every 2 min)"
				fi
			else
				print_warning "Failed to load supervisor pulse LaunchAgent"
			fi
		else
			# Linux: use cron entry with wrapper
			# Remove old-style cron entries (direct opencode invocation)
			# Shell-escape all interpolated paths to prevent command injection
			# via $(…) or backticks if paths contain shell metacharacters
			local _cron_opencode_bin _cron_aidevops_dir _cron_wrapper_script
			_cron_opencode_bin=$(_cron_escape "$opencode_bin")
			_cron_aidevops_dir=$(_cron_escape "$_aidevops_dir")
			_cron_wrapper_script=$(_cron_escape "$wrapper_script")
			(
				crontab -l 2>/dev/null | grep -v 'aidevops: supervisor-pulse'
				echo "*/2 * * * * PATH=\"/usr/local/bin:/usr/bin:/bin\" OPENCODE_BIN=${_cron_opencode_bin} PULSE_DIR=${_cron_aidevops_dir} /bin/bash ${_cron_wrapper_script} >> \"\$HOME/.aidevops/logs/pulse-wrapper.log\" 2>&1 # aidevops: supervisor-pulse"
			) | crontab - || true
			if crontab -l 2>/dev/null | grep -qF "aidevops: supervisor-pulse"; then
				print_info "Supervisor pulse enabled (cron, every 2 min). Disable: crontab -e and remove the supervisor-pulse line"
			else
				print_warning "Failed to install supervisor pulse cron entry. See runners.md for manual setup."
			fi
		fi
	elif [[ "$_pulse_lower" == "false" && "$_pulse_installed" == "true" ]]; then
		# User explicitly disabled but pulse is still installed — clean up
		if [[ "$(uname -s)" == "Darwin" ]]; then
			local pulse_plist="$HOME/Library/LaunchAgents/${pulse_label}.plist"
			if _launchd_has_agent "$pulse_label"; then
				launchctl unload "$pulse_plist" || true
				rm -f "$pulse_plist"
				pkill -f 'Supervisor Pulse' 2>/dev/null || true
				print_info "Supervisor pulse disabled (launchd agent removed per config)"
			fi
		else
			if crontab -l 2>/dev/null | grep -qF "pulse-wrapper"; then
				crontab -l 2>/dev/null | grep -v 'aidevops: supervisor-pulse' | crontab - || true
				print_info "Supervisor pulse disabled (cron entry removed per config)"
			fi
		fi
	fi

	# Enable repo-sync scheduler if not already installed
	# Keeps local git repos up to date with daily ff-only pulls
	# Respects config: aidevops config set orchestration.repo_sync false
	local repo_sync_script="$HOME/.aidevops/agents/scripts/repo-sync-helper.sh"
	if [[ -x "$repo_sync_script" ]] && is_feature_enabled repo_sync 2>/dev/null; then
		local _repo_sync_installed=false
		if _launchd_has_agent "com.aidevops.aidevops-repo-sync"; then
			_repo_sync_installed=true
		elif crontab -l 2>/dev/null | grep -qF "aidevops-repo-sync"; then
			_repo_sync_installed=true
		fi
		if [[ "$_repo_sync_installed" == "false" ]]; then
			if [[ "$NON_INTERACTIVE" == "true" ]]; then
				bash "$repo_sync_script" enable >/dev/null 2>&1 || true
				print_info "Repo sync enabled (daily). Disable: aidevops repo-sync disable"
			else
				echo ""
				echo "Repo sync keeps your local git repos up to date by running"
				echo "git pull --ff-only daily on clean repos on their default branch."
				echo ""
				read -r -p "Enable daily repo sync? [Y/n]: " enable_repo_sync
				if [[ "$enable_repo_sync" =~ ^[Yy]?$ || -z "$enable_repo_sync" ]]; then
					bash "$repo_sync_script" enable
				else
					print_info "Skipped. Enable later: aidevops repo-sync enable"
				fi
			fi
		fi
	fi

	# Process guard — kills runaway AI processes (ShellCheck bloat, stuck workers)
	# before they exhaust memory and cause kernel panics. Always installed when the
	# script exists; no consent needed (safety net, not autonomous action).
	# macOS: launchd plist (30s interval, RunAtLoad=true) | Linux: cron (every minute)
	local guard_script="$HOME/.aidevops/agents/scripts/process-guard-helper.sh"
	local guard_label="sh.aidevops.process-guard"
	if [[ -x "$guard_script" ]]; then
		mkdir -p "$HOME/.aidevops/logs"

		if [[ "$(uname -s)" == "Darwin" ]]; then
			local guard_plist="$HOME/Library/LaunchAgents/${guard_label}.plist"

			# Unload old plist if upgrading
			if _launchd_has_agent "$guard_label"; then
				launchctl unload "$guard_plist" || true
			fi

			# XML-escape paths for safe plist embedding (prevents injection
			# if $HOME or paths contain &, <, > characters)
			local _xml_guard_script _xml_guard_home _xml_guard_path
			_xml_guard_script=$(_xml_escape "$guard_script")
			_xml_guard_home=$(_xml_escape "$HOME")
			_xml_guard_path=$(_xml_escape "$PATH")

			cat >"$guard_plist" <<GUARD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${guard_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${_xml_guard_script}</string>
		<string>kill-runaways</string>
	</array>
	<key>StartInterval</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>${_xml_guard_home}/.aidevops/logs/process-guard.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_guard_home}/.aidevops/logs/process-guard.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_guard_path}</string>
		<key>HOME</key>
		<string>${_xml_guard_home}</string>
		<key>SHELLCHECK_RSS_LIMIT_KB</key>
		<string>524288</string>
		<key>SHELLCHECK_RUNTIME_LIMIT</key>
		<string>120</string>
		<key>CHILD_RSS_LIMIT_KB</key>
		<string>8388608</string>
		<key>CHILD_RUNTIME_LIMIT</key>
		<string>7200</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
GUARD_PLIST

			if launchctl load "$guard_plist"; then
				print_info "Process guard enabled (launchd, every 30s, survives reboot)"
			else
				print_warning "Failed to load process guard LaunchAgent"
			fi
		else
			# Linux: cron entry (every minute — cron minimum granularity)
			# Always regenerate to pick up config changes (matches macOS behavior)
			# Shell-escape path to prevent command injection via metacharacters
			local _cron_guard_script
			_cron_guard_script=$(_cron_escape "$guard_script")
			(
				crontab -l 2>/dev/null | grep -v 'aidevops: process-guard'
				echo "* * * * * PATH=\"/usr/local/bin:/usr/bin:/bin\" SHELLCHECK_RSS_LIMIT_KB=524288 SHELLCHECK_RUNTIME_LIMIT=120 CHILD_RSS_LIMIT_KB=8388608 CHILD_RUNTIME_LIMIT=7200 /bin/bash ${_cron_guard_script} kill-runaways >> \"\$HOME/.aidevops/logs/process-guard.log\" 2>&1 # aidevops: process-guard"
			) | crontab - || true
			if crontab -l 2>/dev/null | grep -qF "aidevops: process-guard"; then
				print_info "Process guard enabled (cron, every minute)"
			else
				print_warning "Failed to install process guard cron entry"
			fi
		fi
	fi

	# Memory pressure monitor — process-focused memory watchdog (t1398.5, GH#2915).
	# Monitors individual process RSS, runtime, session count, and aggregate memory.
	# Auto-kills runaway ShellCheck (language server respawns them). Always installed
	# when the script exists; no consent needed (safety net, not autonomous action).
	# macOS: launchd plist (60s interval, RunAtLoad=true) | Linux: cron (every minute)
	local monitor_script="$HOME/.aidevops/agents/scripts/memory-pressure-monitor.sh"
	local monitor_label="sh.aidevops.memory-pressure-monitor"
	if [[ -x "$monitor_script" ]]; then
		mkdir -p "$HOME/.aidevops/logs"

		if [[ "$(uname -s)" == "Darwin" ]]; then
			local monitor_plist="$HOME/Library/LaunchAgents/${monitor_label}.plist"

			# Unload old plist if upgrading
			if _launchd_has_agent "$monitor_label"; then
				launchctl unload "$monitor_plist" 2>/dev/null || true
			fi

			cat >"$monitor_plist" <<MONITOR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${monitor_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${monitor_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>StandardOutPath</key>
	<string>${HOME}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${HOME}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${HOME}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
MONITOR_PLIST

			if launchctl load "$monitor_plist" 2>/dev/null; then
				print_info "Memory pressure monitor enabled (launchd, every 60s, survives reboot)"
			else
				print_warning "Failed to load memory pressure monitor LaunchAgent"
			fi
		else
			# Linux: cron entry (every minute — cron minimum granularity)
			(
				crontab -l 2>/dev/null | grep -v 'aidevops: memory-pressure-monitor'
				echo "* * * * * /bin/bash \"${monitor_script}\" >> \"\$HOME/.aidevops/logs/memory-pressure-launchd.log\" 2>&1 # aidevops: memory-pressure-monitor"
			) | crontab - 2>/dev/null || true
			if crontab -l 2>/dev/null | grep -qF "aidevops: memory-pressure-monitor" 2>/dev/null; then
				print_info "Memory pressure monitor enabled (cron, every minute)"
			else
				print_warning "Failed to install memory pressure monitor cron entry"
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
	echo "5. Enable orchestration: see runners.md 'Pulse Scheduler Setup' (autonomous task dispatch)"
	echo "6. Read documentation: ~/.aidevops/agents/AGENTS.md"
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
	echo "Autonomous Orchestration:"
	echo "• Supervisor pulse         - Dispatches workers, merges PRs, evaluates results"
	echo "• Auto-pickup              - Workers claim #auto-dispatch tasks from TODO.md"
	echo "• Cross-repo visibility    - Manages tasks across all repos in repos.json"
	echo "• Strategic review (opus)  - 4-hourly queue health, root cause analysis"
	echo "• Model routing            - Cost-aware: local>haiku>flash>sonnet>pro>opus"
	echo "• Budget tracking          - Per-provider spend limits, subscription-aware"
	echo "• Session miner            - Extracts learning from past sessions"
	echo "• Circuit breaker          - Pauses dispatch on consecutive failures"
	echo ""
	echo "  Supervisor pulse (autonomous orchestration) requires explicit consent."
	echo "  Enable: aidevops config set orchestration.supervisor_pulse true && ./setup.sh"
	echo ""
	echo "  Run /onboarding in your AI assistant to configure services interactively."
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
	# Respects config: aidevops config set ui.onboarding_prompt false
	if [[ "$NON_INTERACTIVE" != "true" ]] && [[ -z "${OPENCODE_SESSION:-}" ]] && is_feature_enabled onboarding_prompt 2>/dev/null && command -v opencode &>/dev/null; then
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
