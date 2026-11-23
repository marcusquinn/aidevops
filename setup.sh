#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

if [[ -z "${HOME:-}" ]]; then
	printf '%s\n' '[ERROR] HOME environment variable is unset or empty. setup.sh requires a valid HOME directory.' >&2
	exit 1
fi

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 3.39.272
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
SETUP_EXPLICIT_NON_INTERACTIVE="${AIDEVOPS_NON_INTERACTIVE:-false}"
UPDATE_TOOLS_MODE=false
SETUP_STAGE=""
SETUP_STAGE_OPENCODE="setup_opencode_cli"
SETUP_STAGE_OPENCODE_SERVICE="setup_opencode_service"
SETUP_STAGE_AGENTS="deploy_aidevops_agents"
SETUP_STAGE_HOOKS="setup_safety_hooks"
SETUP_STAGE_TABBY="setup_tabby"
SETUP_STAGE_PULSE="setup_supervisor_pulse"
SETUP_STAGE_GUI_DESKTOP="setup_gui_desktop_app"
SETUP_STAGE_AI_SESSION="setup_ai_session_incremental"
SETUP_STAGE_RUNTIME_CONFIG="reconcile_runtime_config"
SETUP_STAGE_SOURCE_ACCESS="setup_source_access_broker"
SETUP_STAGE_OPENCODE_PLUGINS="setup_opencode_plugins"
SETUP_STAGE_HOTFIX_CONFIG="_deploy_hotfix_config"
SETUP_GUI_APP_NAME="aidevops.app"
SETUP_OS_DARWIN="Darwin"
# Python compatibility floor used by setup checks and skill/tool gating.
# Keep in sync with .agents/scripts/setup/modules/plugins.sh requirements.
PYTHON_REQUIRED_MAJOR=3
PYTHON_REQUIRED_MINOR=10
export PYTHON_REQUIRED_MAJOR PYTHON_REQUIRED_MINOR
# Platform constants — exported for sourced .agents/scripts/setup/modules (shell-env.sh,
# tool-install.sh) that reference them at runtime.
PLATFORM_MACOS=$([[ "$(uname -s)" == "$SETUP_OS_DARWIN" ]] && echo true || echo false)
PLATFORM_ARM64=$([[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]] && echo true || echo false)
export PLATFORM_MACOS PLATFORM_ARM64
readonly PLATFORM_MACOS PLATFORM_ARM64
# Extended platform detection (t1748: Linux/WSL2 support).
# Sources platform-detect.sh when available to export AIDEVOPS_PLATFORM,
# AIDEVOPS_SCHEDULER, AIDEVOPS_CLIPBOARD_COPY, etc.
_platform_detect_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.agents/scripts/platform-detect.sh"
if [[ -f "$_platform_detect_script" ]]; then
	# shellcheck disable=SC1090  # dynamic path, exists at runtime
	source "$_platform_detect_script"
fi
unset _platform_detect_script
# Repo constants — exported; consumed by .agents/scripts/setup/modules/core.sh, agent-deploy.sh
REPO_URL="https://github.com/marcusquinn/aidevops.git"
# INSTALL_DIR: resolve from the directory where setup.sh is executed (supports worktrees)
# For bootstrap (curl install), this will be /dev/fd/NN and trigger re-exec after clone
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
export REPO_URL INSTALL_DIR AGENTS_DIR

# Source modular setup functions (t316.2)
# These modules are sourced only when setup.sh is run from the repo directory
# (not during bootstrap from curl, which re-execs after cloning)
SETUP_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.agents/scripts/setup" 2>/dev/null && pwd)" || true
if [[ -d "$SETUP_MODULES_DIR" ]]; then
	# shellcheck disable=SC1091  # Dynamic path via $SETUP_MODULES_DIR; files exist at runtime
	source "$SETUP_MODULES_DIR/_common.sh"
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
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_routines.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_scheduler_runtime.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_runtime_helpers.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_privacy_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_complexity_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_repo_verify_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_task_id_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_canonical_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_worktree_exclusions.sh"
fi

print_info() {
	local _m="$1"
	echo -e "${BLUE}[INFO]${NC} $_m"
	return 0
}
print_success() {
	local _m="$1"
	echo -e "${GREEN}[SUCCESS]${NC} $_m"
	return 0
}
print_warning() {
	local _m="$1"
	echo -e "${YELLOW}[WARNING]${NC} $_m"
	return 0
}
print_error() {
	local _m="$1"
	echo -e "${RED}[ERROR]${NC} $_m"
	return 0
}

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
	# Escape replacement ampersands so Bash 5.2+ with patsub_replacement
	# enabled does not turn "&apos;" into "'apos;" in generated plists.
	str="${str//&/\&amp;}"
	str="${str//</\&lt;}"
	str="${str//>/\&gt;}"
	str="${str//\"/\&quot;}"
	str="${str//\'/\&apos;}"
	printf '%s' "$str"
	return 0
}

# Escape a string for safe embedding in crontab entries.
# Wraps value in single quotes (prevents $(…), backtick, and variable expansion
# by cron's /bin/sh). Embedded single quotes are escaped via the '\'' idiom.
_cron_escape() {
	local str="$1"
	str="${str//$'\n'/ }"
	str="${str//$'\r'/ }"
	# Replace each ' with '\'' (end quote, escaped quote, start quote)
	str="${str//\'/\'\\\'\'}"
	printf "'%s'" "$str"
	return 0
}

# GH#21060 / t2911: Per-stage timing helper for non-interactive setup runs.
# Wraps a function call, records start/end time, and appends TSV lines to
# $HOME/.aidevops/logs/setup-stage-timings.log:
#   iso8601_utc <TAB> stage_name <TAB> duration_seconds <TAB> exit_code
# A RUNNING row is written before each stage starts so a tool/worker timeout
# still leaves the currently executing phase in the timing log.
# Usage: _time_step "stage_name" function_name [args...]
# ShellCheck: $@ is used deliberately (SC2068 not applicable; no word-splitting
# issue since we shift the stage-name arg first and pass the rest as a command).
_time_step_log() {
	local _ts_stage="$1"
	local _ts_duration="$2"
	local _ts_exit="$3"
	printf '%s\t%s\t%s\t%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$_ts_stage" \
		"$_ts_duration" \
		"$_ts_exit" \
		>>"$HOME/.aidevops/logs/setup-stage-timings.log" 2>/dev/null || true
	return 0
}

_time_step() {
	local _ts_stage="$1"
	shift
	local _ts_start _ts_end _ts_duration _ts_exit
	print_info "Starting setup stage: $_ts_stage"
	_time_step_log "$_ts_stage" "0.00" "RUNNING"
	_ts_start=$(date +%s.%N 2>/dev/null || date +%s)
	_ts_exit=0
	"$@" || _ts_exit=$?
	_ts_end=$(date +%s.%N 2>/dev/null || date +%s)
	_ts_duration=$(awk -v a="$_ts_start" -v b="$_ts_end" 'BEGIN { printf "%.2f", b - a }')
	_time_step_log "$_ts_stage" "$_ts_duration" "$_ts_exit"
	print_info "Finished setup stage: $_ts_stage (${_ts_duration}s, exit=${_ts_exit})"
	return "$_ts_exit"
}

# Resolve the canonical main worktree path for the current repo.
# When setup.sh is run from a linked worktree, launchd/cron should still point
# autonomous services at the main repo checkout, not the feature worktree.
_resolve_main_worktree_dir() {
	local repo_dir="$1"
	local main_worktree=""
	main_worktree=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}') || main_worktree=""
	if [[ -n "$main_worktree" && -d "$main_worktree" ]]; then
		printf '%s' "$main_worktree"
		return 0
	fi
	printf '%s' "$repo_dir"
	return 0
}

# Scheduler runtime helpers are sourced from .agents/scripts/setup/_scheduler_runtime.sh
# with the rest of the setup modules near the top of this file.

# Runtime helper functions are sourced from .agents/scripts/setup/_runtime_helpers.sh
# with the rest of the setup modules near the top of this file.

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
# .agents/scripts/setup/modules/ directory doesn't exist at that path. We must clone the repo
# first, then re-exec the local copy. This MUST run before any source lines.
# =============================================================================
_setup_script_dir="$(dirname "${BASH_SOURCE[0]}")"
if [[ ! -d "$_setup_script_dir/.agents/scripts/setup/modules" ]]; then
	# Running from curl pipe or process substitution — bootstrap the repo
	print_info "Remote install detected — bootstrapping repository..."

	# Auto-install git if missing
	if ! command -v git >/dev/null 2>&1; then
		if [[ "$(uname)" == "$SETUP_OS_DARWIN" ]]; then
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

	# Clone or update the repo (use hardcoded path for bootstrap)
	# After clone, INSTALL_DIR will be set correctly by the re-exec
	_bootstrap_install_dir="$HOME/Git/aidevops"
	mkdir -p "$(dirname "$_bootstrap_install_dir")"
	if [[ -d "$_bootstrap_install_dir/.git" ]]; then
		print_info "Existing installation found — updating..."
		cd "$_bootstrap_install_dir" || exit 1
		git pull --ff-only || {
			print_warning "Git pull failed — resetting to origin/main"
			git fetch origin
			git reset --hard origin/main
		}
	else
		if [[ -d "$_bootstrap_install_dir" ]]; then
			print_warning "Directory exists but is not a git repo — backing up"
			mv "$_bootstrap_install_dir" "$_bootstrap_install_dir.backup.$(date +%Y%m%d_%H%M%S)"
		fi
		print_info "Cloning aidevops to $_bootstrap_install_dir..."
		git clone "$REPO_URL" "$_bootstrap_install_dir" || {
			print_error "Failed to clone repository"
			exit 1
		}
	fi

	print_success "Repository ready at $_bootstrap_install_dir"

	# Re-execute the local copy (which has .agents/scripts/setup/modules/ available)
	cd "$_bootstrap_install_dir" || exit 1
	exec bash "./setup.sh" "$@"
fi
unset _setup_script_dir

# Source modularized setup functions from the canonical setup module tree.
# The sibling .agents/scripts/setup/_*.sh files above are bootstrap/fallback
# helpers loaded early by the root entrypoint; normal setup implementation
# modules live under modules/ so the repository root has no module directory.
SETUP_IMPL_MODULES_DIR="${SETUP_MODULES_DIR}/modules"
# shellcheck source=.agents/scripts/runtime-bundle-verifier.sh
source "${INSTALL_DIR}/.agents/scripts/runtime-bundle-verifier.sh"
# shellcheck source=.agents/scripts/pulse-runtime-pin.sh
source "${INSTALL_DIR}/.agents/scripts/pulse-runtime-pin.sh"
# shellcheck disable=SC1091  # Dynamic path via $SETUP_IMPL_MODULES_DIR
source "${SETUP_IMPL_MODULES_DIR}/core.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/migrations.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/migration-compaction-target.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/migration-sonnet-5-5.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/migration-haiku-5-5.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/shell-env.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/tool-install.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/mcp-setup.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/agent-deploy.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/agent-runtime.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/config.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/source-access.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/plugins.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/schedulers.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/post-setup.sh"
# shellcheck source=.agents/scripts/setup/modules/setup-interface.sh
# shellcheck disable=SC1091  # Resolved after bootstrap via the setup module directory
source "${SETUP_IMPL_MODULES_DIR}/setup-interface.sh"
# shellcheck source=.agents/scripts/setup/modules/setup-execution.sh
# shellcheck disable=SC1091  # Resolved after bootstrap via the setup module directory
source "${SETUP_IMPL_MODULES_DIR}/setup-execution.sh"
# shellcheck source=.agents/scripts/setup/modules/setup-postflight.sh
# shellcheck disable=SC1091  # Resolved after bootstrap via the setup module directory
source "${SETUP_IMPL_MODULES_DIR}/setup-postflight.sh"

parse_args() {
	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		case "$_opt" in
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
			SETUP_EXPLICIT_NON_INTERACTIVE=true
			shift
			;;
		--update | -u)
			UPDATE_TOOLS_MODE=true
			shift
			;;
		--stage)
			if [[ -z "${2:-}" ]]; then
				print_error "--stage requires a value"
				_setup_print_stage_help
				exit 1
			fi
			SETUP_STAGE="$2"
			NON_INTERACTIVE=true
			shift 2
			;;
		--stage=*)
			SETUP_STAGE="${_opt#--stage=}"
			if [[ -z "$SETUP_STAGE" ]]; then
				print_error "--stage requires a value"
				_setup_print_stage_help
				exit 1
			fi
			NON_INTERACTIVE=true
			shift
			;;
		--help | -h)
			echo "Usage: ./setup.sh [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --clean            Remove stale files before deploying (cleans ~/.aidevops/agents/)"
			echo "  --interactive, -i  Ask confirmation before each step"
			echo "  --non-interactive, -n  Deploy agents only, skip all optional installs (no prompts)"
			echo "  --stage <name>     Run one supported setup stage/scope without full setup"
			echo "  --update, -u       Check for and offer to update outdated tools after setup"
			echo "  --help             Show this help message"
			echo ""
			echo "Default behavior adds/overwrites files without removing deleted agents."
			echo "Use --clean after removing or renaming agents to sync deletions."
			echo "Use --interactive to control each step individually."
			echo "Use --non-interactive for CI/CD or AI agent shells (no stdin required)."
			echo "Use --stage for targeted updates: opencode, agents, runtime-config, source-access, hooks, tabby, pulse, gui-desktop, ai-session, full."
			echo "Stage aliases: ${SETUP_STAGE_OPENCODE}, ${SETUP_STAGE_AGENTS}, ${SETUP_STAGE_RUNTIME_CONFIG}, ${SETUP_STAGE_SOURCE_ACCESS}, ${SETUP_STAGE_HOOKS}, ${SETUP_STAGE_TABBY}, ${SETUP_STAGE_PULSE}, ${SETUP_STAGE_GUI_DESKTOP}, ${SETUP_STAGE_AI_SESSION}."
			echo "The source-access stage may request sudo when attached to an interactive terminal."
			echo "Install ${SETUP_GUI_APP_NAME} explicitly with --stage gui-desktop or AIDEVOPS_GUI_DESKTOP_INSTALL=true."
			echo "Use --update to check for tool updates after setup completes."
			exit 0
			;;
		*)
			print_error "Unknown option: $_opt"
			echo "Use --help for usage information"
			exit 1
			;;
		esac
	done
	if [[ -n "$SETUP_STAGE" ]]; then
		_setup_validate_stage "$SETUP_STAGE" || exit $?
	fi
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

# Print the setup header based on active mode flags.
_setup_print_header() {
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
	return 0
}

# GH#35788: surface stale/missing JS dependency install approvals for
# dispatch-enabled repos so headless workers are not stranded with
# runner_capability_unmet. Interactive setup offers renewal per repo;
# non-interactive setup/update only reports (never writes repos.json).
review_js_dependency_policies() {
	local helper="${BASH_SOURCE[0]%/*}/.agents/scripts/worktree-js-readiness-helper.sh"
	[[ -f "$helper" ]] || helper="$HOME/.aidevops/agents/scripts/worktree-js-readiness-helper.sh"
	[[ -f "$helper" ]] || return 0
	command -v jq &>/dev/null || return 0
	if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
		bash "$helper" review --report-only || print_warning "JS dependency policy review failed (non-fatal)"
	else
		bash "$helper" review || print_warning "JS dependency policy review failed (non-fatal)"
	fi
	return 0
}

# Provision knowledge planes for all repos in repos.json where knowledge != "off".
# Idempotent: already-provisioned directories are not modified.
# Called from the non-interactive setup path (update) and after interactive init.
setup_knowledge_planes() {
	local repos_file="$HOME/.config/aidevops/repos.json"
	local helper
	helper="${BASH_SOURCE[0]%/*}/.agents/scripts/knowledge-helper.sh"
	if [[ ! -f "$helper" ]]; then
		helper="$HOME/.aidevops/agents/scripts/knowledge-helper.sh"
	fi
	if [[ ! -f "$helper" ]]; then
		print_warning "knowledge-helper.sh not found — skipping knowledge plane provisioning"
		return 0
	fi
	if [[ ! -f "$repos_file" ]]; then
		return 0
	fi
	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed — skipping knowledge plane provisioning"
		return 0
	fi
	local repo_path mode
	while IFS=$'\t' read -r repo_path mode; do
		[[ -z "$repo_path" || "$mode" == "off" ]] && continue
		if [[ ! -d "$repo_path" ]]; then
			print_warning "knowledge-plane: repo path not found: $repo_path"
			continue
		fi
		bash "$helper" provision "$repo_path" || print_warning "knowledge-plane: provision failed for $repo_path"
	done < <(jq -r '.initialized_repos[] | select(.knowledge != null and .knowledge != "off") | [.path, .knowledge] | @tsv' "$repos_file" 2>/dev/null || true)
	return 0
}

# Provision cases planes for all repos in repos.json where cases != "off".
# Idempotent: already-provisioned directories are not modified.
# Called from the non-interactive setup path (update) and after interactive init.
setup_cases_planes() {
	local repos_file="$HOME/.config/aidevops/repos.json"
	local helper
	helper="${BASH_SOURCE[0]%/*}/.agents/scripts/case-helper.sh"
	if [[ ! -f "$helper" ]]; then
		helper="$HOME/.aidevops/agents/scripts/case-helper.sh"
	fi
	if [[ ! -f "$helper" ]]; then
		print_warning "case-helper.sh not found — skipping cases plane provisioning"
		return 0
	fi
	if [[ ! -f "$repos_file" ]]; then
		return 0
	fi
	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed — skipping cases plane provisioning"
		return 0
	fi
	local repo_path mode
	while IFS=$'\t' read -r repo_path mode; do
		[[ -z "$repo_path" || "$mode" == "off" ]] && continue
		if [[ ! -d "$repo_path" ]]; then
			print_warning "cases-plane: repo path not found: $repo_path"
			continue
		fi
		bash "$helper" init "$repo_path" || print_warning "cases-plane: init failed for $repo_path"
	done < <(jq -r '.initialized_repos[] | select(.cases != null and .cases != "off") | [.path, .cases] | @tsv' "$repos_file" 2>/dev/null || true)
	return 0
}

# Non-interactive setup singleton state. This lock only gates the deployment path;
# interactive setup remains prompt-driven and can still be used for first-run init.
SETUP_NONINTERACTIVE_LOCK_HELD=false
SETUP_NONINTERACTIVE_LOCK_DIR=""
SETUP_NONINTERACTIVE_CHILD_PIDS=""
SETUP_NONINTERACTIVE_TERMINATING=false

_setup_guard_active_release_lane() {
	local repo_slug=""
	local remote_url=""
	local lane_helper="${BASH_SOURCE[0]%/*}/.agents/scripts/release-lane-helper.sh"
	# Isolated CI smoke homes cannot replace a user's active runtime. Keep this
	# test-only bypass coupled to CI so normal setup cannot disable the lane.
	if [[ "${CI:-false}" == "true" && "${AIDEVOPS_RELEASE_LANE_ISOLATED_CI:-0}" == "1" ]]; then
		return 0
	fi
	[[ -f "$lane_helper" ]] || return 0
	remote_url=$(git -C "${BASH_SOURCE[0]%/*}" remote get-url origin 2>/dev/null || true)
	repo_slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	[[ "$repo_slug" == "marcusquinn/aidevops" ]] || return 0
	# shellcheck source=.agents/scripts/release-lane-helper.sh
	source "$lane_helper"
	release_lane_setup_guard "$repo_slug" "${BASH_SOURCE[0]%/*}"
	return $?
}

_setup_lock_pid_alive() {
	local pid="$1"
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null
	return $?
}

_setup_lock_pid_is_noninteractive_setup() {
	local pid="$1"
	local owner_args=""
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	owner_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
	[[ -n "$owner_args" ]] || return 0
	[[ "$owner_args" == *"setup.sh"* && ("$owner_args" == *"--non-interactive"* || "$owner_args" == *"--stage"*) ]]
	return $?
}

_setup_lock_dir_age_seconds() {
	local lock_dir="$1"
	local lock_mtime=""
	local now=""
	if ! [[ -d "$lock_dir" ]]; then
		printf '%s\n' 0
		return 0
	fi
	if type _file_mtime_epoch >/dev/null 2>&1; then
		lock_mtime=$(_file_mtime_epoch "$lock_dir" 2>/dev/null || true)
	elif [[ "$(uname -s 2>/dev/null || true)" == "$SETUP_OS_DARWIN" || "$(uname -s 2>/dev/null || true)" == "FreeBSD" ]]; then
		lock_mtime=$(stat -f %m "$lock_dir" 2>/dev/null || true)
	else
		lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || true)
	fi
	now=$(date +%s 2>/dev/null || true)
	if [[ "$lock_mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$now" -ge "$lock_mtime" ]]; then
		printf '%s\n' $((now - lock_mtime))
		return 0
	fi
	printf '%s\n' 0
	return 0
}

_setup_lock_started_age_seconds() {
	local lock_dir="$1"
	local started_str=""
	local started_epoch=""
	local now_epoch=""
	if [[ -r "$lock_dir/started_at" ]]; then
		started_str=$(tr -d '[:space:]' <"$lock_dir/started_at" 2>/dev/null || true)
		started_epoch=$(date -d "$started_str" +%s 2>/dev/null ||
			date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$started_str" +%s 2>/dev/null || true)
		now_epoch=$(date +%s 2>/dev/null || true)
		if [[ "$started_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ && "$now_epoch" -ge "$started_epoch" ]]; then
			printf '%s\n' $((now_epoch - started_epoch))
			return 0
		fi
	fi
	_setup_lock_dir_age_seconds "$lock_dir"
	return 0
}

_setup_pid_elapsed_seconds() {
	local pid="$1"
	local etime=""
	local first="" second="" third=""
	local days=0 hours=0 minutes=0 seconds=0
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	etime=$(ps -p "$pid" -o etime= 2>/dev/null || true)
	etime="${etime//[[:space:]]/}"
	[[ -n "$etime" ]] || return 1
	IFS=':' read -r first second third <<<"$etime"
	if [[ -n "$third" ]]; then
		seconds="$third"
		minutes="$second"
		if [[ "$first" == *"-"* ]]; then
			days="${first%%-*}"
			hours="${first#*-}"
		else
			hours="$first"
		fi
	else
		minutes="$first"
		seconds="$second"
	fi
	if [[ "$days" =~ ^[0-9]+$ && "$hours" =~ ^[0-9]+$ && "$minutes" =~ ^[0-9]+$ && "$seconds" =~ ^[0-9]+$ ]]; then
		printf '%s\n' $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
		return 0
	fi
	return 1
}

_setup_register_child_pid() {
	local pid="$1"
	[[ -n "$pid" ]] || return 0
	SETUP_NONINTERACTIVE_CHILD_PIDS="${SETUP_NONINTERACTIVE_CHILD_PIDS}${SETUP_NONINTERACTIVE_CHILD_PIDS:+ }${pid}"
	return 0
}

_setup_collect_child_pids() {
	local parent_pid="$1"
	local child_pid=""
	local child_pids=""
	local current_pid="${BASHPID:-$$}"
	child_pids=$(pgrep -P "$parent_pid" 2>/dev/null || true)
	for child_pid in $child_pids; do
		[[ -n "$child_pid" && "$child_pid" != "$current_pid" ]] || continue
		printf '%s\n' "$child_pid"
		_setup_collect_child_pids "$child_pid"
	done
	return 0
}

_setup_kill_pid_tree() {
	local signal_name="$1"
	local root_pid="$2"
	local child_pid=""
	local current_pid="${BASHPID:-$$}"
	[[ -n "$root_pid" && "$root_pid" != "$current_pid" ]] || return 0
	for child_pid in $(_setup_collect_child_pids "$root_pid"); do
		kill "-${signal_name}" "$child_pid" 2>/dev/null || true
	done
	kill "-${signal_name}" "$root_pid" 2>/dev/null || true
	return 0
}

_setup_cleanup_noninteractive_children() {
	local pid=""
	local current_pid="${BASHPID:-$$}"
	local grace_s="${AIDEVOPS_SETUP_CHILD_TERM_GRACE_S:-2}"
	local has_live_child=false
	[[ "$grace_s" =~ ^[0-9]+$ ]] || grace_s=2
	for pid in $(_setup_collect_child_pids "$current_pid"); do
		_setup_register_child_pid "$pid"
	done
	for pid in ${SETUP_NONINTERACTIVE_CHILD_PIDS:-}; do
		if _setup_lock_pid_alive "$pid"; then
			has_live_child=true
			_setup_kill_pid_tree TERM "$pid"
		fi
	done
	if [[ "$has_live_child" == "true" && "$grace_s" -gt 0 ]]; then
		sleep "$grace_s" 2>/dev/null || true
	fi
	for pid in ${SETUP_NONINTERACTIVE_CHILD_PIDS:-}; do
		if _setup_lock_pid_alive "$pid"; then
			_setup_kill_pid_tree KILL "$pid"
		fi
	done
	for pid in ${SETUP_NONINTERACTIVE_CHILD_PIDS:-}; do
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

_setup_run_noncritical_stage_bounded() {
	local stage_label="$1"
	local timeout_s="$2"
	shift 2
	local start_s=$SECONDS
	local pid=""
	local rc=0
	# Lets callers tell a timeout kill apart from a clean return (t19030).
	_SETUP_NONCRITICAL_STAGE_TIMED_OUT=false
	[[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=60
	"$@" &
	pid=$!
	_setup_register_child_pid "$pid"
	while _setup_lock_pid_alive "$pid"; do
		if ((SECONDS - start_s >= timeout_s)); then
			_setup_kill_pid_tree TERM "$pid"
			sleep "${AIDEVOPS_SETUP_CHILD_TERM_GRACE_S:-2}" 2>/dev/null || true
			_setup_kill_pid_tree KILL "$pid"
			wait "$pid" 2>/dev/null || true
			_SETUP_NONCRITICAL_STAGE_TIMED_OUT=true
			print_warning "${stage_label} exceeded ${timeout_s}s — skipping remaining non-critical work"
			return 0
		fi
		sleep 1
	done
	wait "$pid" 2>/dev/null || rc=$?
	return "$rc"
}

_setup_release_noninteractive_setup_lock() {
	local lock_dir="${SETUP_NONINTERACTIVE_LOCK_DIR:-}"
	local owner_pid=""
	if [[ "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}" != "true" || -z "$lock_dir" ]]; then
		return 0
	fi
	if [[ -r "$lock_dir/owner.pid" ]]; then
		owner_pid=$(tr -d '[:space:]' <"$lock_dir/owner.pid" 2>/dev/null || true)
	fi
	if [[ -z "$owner_pid" || "$owner_pid" == "$$" ]]; then
		rm -rf "$lock_dir" 2>/dev/null || true
	fi
	SETUP_NONINTERACTIVE_LOCK_HELD=false
	return 0
}

_setup_noninteractive_signal_exit() {
	local signal_name="$1"
	local exit_code=143
	[[ "$signal_name" == "INT" ]] && exit_code=130
	SETUP_NONINTERACTIVE_TERMINATING=true
	print_warning "setup.sh --non-interactive received ${signal_name}; cleaning up child deployment processes"
	_setup_cleanup_noninteractive_children
	_setup_release_noninteractive_setup_lock
	exit "$exit_code"
}

# Compute how many seconds the live lock owner has held the setup lock.
# Uses started_at_epoch when it agrees with the owner PID runtime; falls back to
# the PID runtime when an old lock timestamp points at a newer live setup owner.
# Prints the age in seconds on stdout; prints 0 when unknown.
_setup_lock_owner_age() {
	local lock_dir="$1"
	local owner_pid="$2"
	local _start_epoch="" _now_epoch="" _age_tmp="" _pid_age=""
	if [[ -r "$lock_dir/started_at_epoch" ]]; then
		_start_epoch=$(tr -d '[:space:]' <"$lock_dir/started_at_epoch" 2>/dev/null || true)
		_now_epoch=$(date +%s 2>/dev/null || printf '0')
		if [[ "$_start_epoch" =~ ^[0-9]+$ && "$_now_epoch" =~ ^[0-9]+$ && "$_now_epoch" -ge "$_start_epoch" ]]; then
			_age_tmp="$((_now_epoch - _start_epoch))"
			_pid_age=$(_setup_pid_elapsed_seconds "$owner_pid" 2>/dev/null || true)
			if [[ "$_pid_age" =~ ^[0-9]+$ && "$_age_tmp" -gt $((_pid_age + 300)) ]]; then
				printf '%s' "$_pid_age"
				return 0
			fi
			printf '%s' "$_age_tmp"
			return 0
		fi
	fi
	# Fallback: ps etimes (seconds elapsed since process start).
	_age_tmp=$(ps -p "$owner_pid" -o etimes= 2>/dev/null | tr -d '[:space:]')
	if [[ "$_age_tmp" =~ ^[0-9]+$ ]]; then
		printf '%s' "$_age_tmp"
		return 0
	fi
	printf '0'
	return 0
}

_setup_command_key_looks_secret() {
	local key="$1"
	key="${key#--}"
	key="${key#-}"
	case "$key" in
	*password* | *passwd* | *secret* | *token* | *credential* | *api-key* | *api_key* | *apikey* | *access-key* | *access_key* | *private-key* | *private_key* | bearer)
		return 0
		;;
	esac
	return 1
}

_setup_redact_secret_like_command_values() {
	local command_text="$1"
	local redacted=""
	local separator=""
	local word=""
	local lower_word=""
	local key_part=""
	local redact_next=false

	for word in $command_text; do
		lower_word=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
		if [[ "$redact_next" == "true" ]]; then
			word="[redacted]"
			redact_next=false
		elif [[ "$lower_word" == *=* ]]; then
			key_part="${lower_word%%=*}"
			if _setup_command_key_looks_secret "$key_part"; then
				word="${word%%=*}=[redacted]"
			fi
		elif _setup_command_key_looks_secret "$lower_word"; then
			redact_next=true
		fi
		redacted="${redacted}${separator}${word}"
		separator=" "
	done

	printf '%s' "$redacted"
	return 0
}

_setup_claim_noninteractive_setup_lock() {
	local lock_dir="$1"
	shift
	local lane_rc=0

	SETUP_NONINTERACTIVE_LOCK_DIR="$lock_dir"
	SETUP_NONINTERACTIVE_LOCK_HELD=true
	printf '%s\n' "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
	printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lock_dir/started_at" 2>/dev/null || true
	printf '%s\n' "$(date +%s 2>/dev/null || printf '0')" >"$lock_dir/started_at_epoch" 2>/dev/null || true
	printf '%s\n' "$0 $*" >"$lock_dir/command" 2>/dev/null || true
	_setup_guard_active_release_lane || lane_rc=$?
	if [[ "$lane_rc" -ne 0 ]]; then
		_setup_release_noninteractive_setup_lock
		return "$lane_rc"
	fi
	trap '_setup_cleanup_noninteractive_children; _setup_release_noninteractive_setup_lock' EXIT
	trap '_setup_noninteractive_signal_exit TERM' TERM
	trap '_setup_noninteractive_signal_exit INT' INT
	return 0
}

_setup_acquire_noninteractive_setup_lock() {
	local lock_dir="${AIDEVOPS_SETUP_LOCK_DIR:-$HOME/.aidevops/locks/setup-noninteractive.lock.d}"
	local wait_ceiling="${AIDEVOPS_SETUP_WAIT_TIMEOUT_S:-900}"
	local stale_ceiling="${AIDEVOPS_SETUP_STALE_TIMEOUT_S:-1800}"
	local owner_pid="" owner_cmd="" owner_age=0
	local reclaim_attempts=0 waited=0
	local _diag_stl="$HOME/.aidevops/logs/setup-stage-timings.log"
	local _diag_interval_s="${AIDEVOPS_SETUP_LOCK_DIAG_INTERVAL_S:-60}"
	_setup_guard_active_release_lane || return $?
	[[ "$_diag_interval_s" =~ ^[0-9]+$ && "$_diag_interval_s" -gt 0 ]] || _diag_interval_s=60
	mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || true
	while true; do
		if mkdir "$lock_dir" 2>/dev/null; then
			_setup_claim_noninteractive_setup_lock "$lock_dir" "$@"
			return $?
		fi

		owner_pid=""
		if [[ -r "$lock_dir/owner.pid" ]]; then
			owner_pid=$(tr -d '[:space:]' <"$lock_dir/owner.pid" 2>/dev/null || true)
		fi

		if [[ -z "$owner_pid" ]]; then
			local _lock_age="0"
			_lock_age=$(_setup_lock_dir_age_seconds "$lock_dir")
			if [[ "$_lock_age" -le 300 ]]; then
				print_error "Another setup.sh --non-interactive process is acquiring the deploy lock (lock: ${lock_dir}, age ${_lock_age}s). Exiting to avoid overlapping deployments."
				return 75
			fi
			print_warning "Removing stale setup.sh --non-interactive lock with no owner at ${lock_dir} (age ${_lock_age}s)"
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			if [[ "$reclaim_attempts" -ge 2 ]]; then
				print_error "Unable to acquire setup.sh --non-interactive lock at ${lock_dir} after ${reclaim_attempts} stale-lock removals"
				return 75
			fi
			continue
		fi

		if ! _setup_lock_pid_alive "$owner_pid"; then
			if [[ "$reclaim_attempts" -ge 2 ]]; then
				print_error "Unable to acquire setup.sh --non-interactive lock at ${lock_dir} after ${reclaim_attempts} stale-lock removals"
				return 75
			fi
			print_warning "Removing stale setup.sh --non-interactive lock at ${lock_dir}"
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			continue
		fi

		if ! _setup_lock_pid_is_noninteractive_setup "$owner_pid"; then
			local _owner_lock_age="0"
			_owner_lock_age=$(_setup_lock_dir_age_seconds "$lock_dir")
			if [[ "$_owner_lock_age" -le 300 ]]; then
				print_error "Another setup.sh --non-interactive process may be acquiring the deploy lock (pid ${owner_pid}; lock: ${lock_dir}, age ${_owner_lock_age}s). Exiting to avoid overlapping deployments."
				return 75
			fi
			print_warning "Removing stale setup.sh --non-interactive lock at ${lock_dir}; owner pid ${owner_pid} no longer appears to be setup.sh --non-interactive (age ${_owner_lock_age}s)"
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			continue
		fi

		owner_age=$(_setup_lock_owner_age "$lock_dir" "$owner_pid")
		owner_cmd=""
		[[ -r "$lock_dir/command" ]] && owner_cmd=$(tr '\n' ' ' <"$lock_dir/command" 2>/dev/null || true)
		[[ -n "$owner_cmd" ]] && owner_cmd=$(_setup_redact_secret_like_command_values "$owner_cmd")
		local _diag_stage=""
		if [[ -r "$_diag_stl" ]]; then
			local _diag_cur_stage=""
			_diag_cur_stage=$(awk -F'\t' '$4=="RUNNING"{s=$2} END{if(s)printf "%s",s}' "$_diag_stl" 2>/dev/null || true)
			[[ -n "$_diag_cur_stage" ]] && _diag_stage=", stage: ${_diag_cur_stage}"
		fi

		if [[ "$stale_ceiling" -gt 0 && "$owner_age" -ge "$stale_ceiling" ]]; then
			if [[ "$reclaim_attempts" -ge 2 ]]; then
				print_error "Unable to acquire setup.sh --non-interactive lock: owner (pid ${owner_pid}, age ${owner_age}s) exceeds stale ceiling but reclaim limit reached. Diagnose: ${_diag_stl}"
				return 75
			fi
			print_warning "setup.sh --non-interactive lock owner (pid ${owner_pid}) running ${owner_age}s — exceeds stale ceiling ${stale_ceiling}s (AIDEVOPS_SETUP_STALE_TIMEOUT_S)${owner_cmd:+; command: ${owner_cmd}}. Reclaiming lock."
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			continue
		fi

		if [[ "$waited" -ge "$wait_ceiling" ]]; then
			print_error "Timed out waiting ${waited}s for setup.sh --non-interactive lock (owner pid ${owner_pid}, age ${owner_age}s${_diag_stage}${owner_cmd:+, command: ${owner_cmd}}). Increase AIDEVOPS_SETUP_WAIT_TIMEOUT_S (current: ${wait_ceiling}s) or kill pid ${owner_pid} to unblock. Diagnose: ${_diag_stl}"
			return 75
		fi

		if [[ "$waited" -eq 0 ]]; then
			print_info "Another setup.sh --non-interactive is running (pid ${owner_pid}, age ${owner_age}s${_diag_stage}${owner_cmd:+, command: ${owner_cmd}}). Waiting up to ${wait_ceiling}s (AIDEVOPS_SETUP_WAIT_TIMEOUT_S). Diagnose: ${_diag_stl}"
		elif [[ $((waited % _diag_interval_s)) -eq 0 ]]; then
			print_info "Still waiting for setup lock (owner pid ${owner_pid}, age ${owner_age}s${_diag_stage}${owner_cmd:+, command: ${owner_cmd}}, waited ${waited}s of ${wait_ceiling}s max). Diagnose: ${_diag_stl}"
		fi

		sleep 10
		waited=$((waited + 10))
	done
}

# Non-interactive path: deploy agents and run safe migrations only (no prompts).
# GH#21060 / t2911: Every direct function call is wrapped with _time_step so
# that a one-line-per-stage TSV timing record is appended to
# $HOME/.aidevops/logs/setup-stage-timings.log for post-run diagnostics.
_setup_init_stage_timing_log() {
	# GH#21060: Initialise per-stage timing log; rotate if over 10K lines / 1MB.
	local _stl
	_stl="$HOME/.aidevops/logs/setup-stage-timings.log"
	mkdir -p "$(dirname "$_stl")" 2>/dev/null || true
	if [[ -f "$_stl" ]]; then
		local _stl_lines _stl_bytes
		_stl_lines=$(wc -l <"$_stl" 2>/dev/null || echo "0")
		_stl_bytes=$(wc -c <"$_stl" 2>/dev/null || echo "0")
		# Strip whitespace that wc adds on some platforms
		_stl_lines="${_stl_lines//[[:space:]]/}"
		_stl_bytes="${_stl_bytes//[[:space:]]/}"
		if [[ "${_stl_lines:-0}" -gt 10000 ]] || [[ "${_stl_bytes:-0}" -gt 1048576 ]]; then
			: >"$_stl" 2>/dev/null || true
			print_info "setup-stage-timings.log rotated (was ${_stl_lines} lines / ${_stl_bytes} bytes)"
		fi
	fi
	return 0
}

_setup_restart_pulse_if_running() {
	# Reconcile only after scheduler setup has established the effective consent
	# state. The activated helper serializes with deployment, resolves the active
	# immutable bundle under that lock, and never starts behind a disabled
	# supervisor. This also prevents a stale setup caller's INSTALL_DIR from
	# selecting the Pulse revision.
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" == "1" ]]; then
		return 0
	fi

	local activated_root="${_AIDEVOPS_ACTIVE_BUNDLE_ROOT:-}"
	local current_root=""
	local pin_rc=0
	local pulse_active_link="${HOME}/.aidevops/agents"
	local managed_enabled="${PULSE_ENABLED:-}"
	local configured_pulse_consent=""
	if [[ "$managed_enabled" != "true" && "$managed_enabled" != "false" ]]; then
		if type _resolve_pulse_consent >/dev/null 2>&1; then
			configured_pulse_consent=$(_resolve_pulse_consent)
		fi
		case "$(printf '%s' "$configured_pulse_consent" | tr '[:upper:]' '[:lower:]')" in
		true) managed_enabled=true ;;
		*) managed_enabled=false ;;
		esac
	fi
	if current_root=$(pulse_runtime_pin_resolve 2>/dev/null); then
		activated_root="$current_root"
		pulse_active_link="$current_root"
	else
		pin_rc=$?
		case "$pin_rc" in
		1 | 3)
			if current_root=$(resolve_aidevops_runtime_bundle_root "${HOME}/.aidevops/agents"); then
				activated_root="$current_root"
			fi
			;;
		*)
			print_error "Pulse reconciliation refused an invalid runtime pin; clear or repair the private pin file"
			return 1
			;;
		esac
	fi
	if [[ -z "$activated_root" ]]; then
		print_error "Pulse reconciliation failed because the activated runtime bundle could not be resolved"
		return 1
	fi
	if ! _restart_pulse_if_running \
		"$activated_root" \
		"$managed_enabled" \
		"$pulse_active_link"; then
		print_error "Pulse reconciliation failed; setup cannot verify the activated runtime bundle"
		return 1
	fi
	return 0
}

# Print the completion sentinel. This is the canonical "setup.sh finished all
# phases" marker — any caller that needs to detect silent early-termination
# (e.g., t2022-class bugs where a sourced helper's set -e propagates a
# readonly assignment failure and kills the parent) should grep log output
# for the literal "[SETUP_COMPLETE]" prefix.
#
# Format is intentionally stable and parseable. Do NOT add human-readable
# decoration or move this function without updating:
#   .agents/scripts/verify-setup-log.sh       (the consumer)
#   tests/test-setup-completion-sentinel.sh   (the contract guard)
#
# GH#18492 / t2026.
print_setup_complete_sentinel() {
	local _version="unknown"
	if [[ -r "${INSTALL_DIR}/VERSION" ]]; then
		_version="$(head -n1 "${INSTALL_DIR}/VERSION" 2>/dev/null || printf 'unknown')"
	fi
	local _mode="non-interactive"
	[[ "${NON_INTERACTIVE:-false}" != "true" ]] && _mode="interactive"
	printf '[SETUP_COMPLETE] aidevops setup.sh v%s finished all phases (mode=%s)\n' \
		"$_version" "$_mode"
	return 0
}

# Main setup function — orchestrates init, mode dispatch, and post-setup.
main() {
	# Bootstrap first (handles curl install)
	bootstrap_repo "$@"

	parse_args "$@"
	local _os
	_os="$(uname -s)"

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

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		# Full-loop release deployment uses this mutex. It remains held through
		# deploy_aidevops_agents and install_aidevops_cli, so agent and CLI
		# convergence are one serialized non-interactive deployment interval.
		# Direct interactive setup is intentionally outside this guarantee: holding
		# the mutex across prompts can block unattended full-loop deployments.
		_setup_acquire_noninteractive_setup_lock "$@" || exit $?
	fi

	_setup_print_header

	# GH#18950 (t2087): bash 3.2 → modern bash upgrade check. Runs before
	# the main setup flow so the user sees the prompt early. Fail-open —
	# never blocks setup even if bash install fails.
	_setup_check_bash_upgrade

	if [[ -n "$SETUP_STAGE" ]]; then
		_setup_run_scoped_stage "$_os"
	elif [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_run_non_interactive
	else
		_setup_run_interactive
	fi

	if [[ -z "$SETUP_STAGE" ]]; then
		_setup_post_setup_steps "$_os"
	fi

	_setup_restart_pulse_if_running

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_print_noninteractive_success
	fi

	# GH#18492 / t2026: completion sentinel. Must be the last output of a
	# successful run — any silent early-termination will leave this absent
	# from the log. Consumed by .agents/scripts/verify-setup-log.sh and
	# enforced as the regression contract by
	# tests/test-setup-completion-sentinel.sh.
	print_setup_complete_sentinel

	return 0
}

# Run setup
main "$@"
