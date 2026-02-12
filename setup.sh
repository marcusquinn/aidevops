#!/usr/bin/env bash
set -euo pipefail

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 2.111.0
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

# Source modular setup functions (t316.2)
# These modules are sourced only when setup.sh is run from the repo directory
# (not during bootstrap from curl, which re-execs after cloning)
SETUP_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.agents/scripts/setup" 2>/dev/null && pwd)"
if [[ -d "$SETUP_MODULES_DIR" ]]; then
	# shellcheck source=.agents/scripts/setup/_common.sh
	source "$SETUP_MODULES_DIR/_common.sh"
	# shellcheck source=.agents/scripts/setup/_backup.sh
	source "$SETUP_MODULES_DIR/_backup.sh"
	# shellcheck source=.agents/scripts/setup/_validation.sh
	source "$SETUP_MODULES_DIR/_validation.sh"
	# shellcheck source=.agents/scripts/setup/_migration.sh
	source "$SETUP_MODULES_DIR/_migration.sh"
	# shellcheck source=.agents/scripts/setup/_shell.sh
	source "$SETUP_MODULES_DIR/_shell.sh"
	# shellcheck source=.agents/scripts/setup/_installation.sh
	source "$SETUP_MODULES_DIR/_installation.sh"
	# shellcheck source=.agents/scripts/setup/_deployment.sh
	source "$SETUP_MODULES_DIR/_deployment.sh"
	# shellcheck source=.agents/scripts/setup/_opencode.sh
	source "$SETUP_MODULES_DIR/_opencode.sh"
	# shellcheck source=.agents/scripts/setup/_tools.sh
	source "$SETUP_MODULES_DIR/_tools.sh"
	# shellcheck source=.agents/scripts/setup/_services.sh
	source "$SETUP_MODULES_DIR/_services.sh"
	# shellcheck source=.agents/scripts/setup/_bootstrap.sh
	source "$SETUP_MODULES_DIR/_bootstrap.sh"
fi

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

# Source modularized setup functions
# shellcheck source=setup-modules/core.sh
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/core.sh"
# shellcheck source=setup-modules/migrations.sh
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/migrations.sh"
# shellcheck source=setup-modules/shell-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/shell-env.sh"
# shellcheck source=setup-modules/tool-install.sh
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/tool-install.sh"
# shellcheck source=setup-modules/mcp-setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/mcp-setup.sh"
# shellcheck source=setup-modules/agent-deploy.sh
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/agent-deploy.sh"
# shellcheck source=setup-modules/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/config.sh"
# shellcheck source=setup-modules/plugins.sh
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
