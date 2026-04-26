#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 3.11.17
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
# Python compatibility floor used by setup checks and skill/tool gating.
# Keep in sync with setup-modules/plugins.sh requirements.
PYTHON_REQUIRED_MAJOR=3
PYTHON_REQUIRED_MINOR=10
export PYTHON_REQUIRED_MAJOR PYTHON_REQUIRED_MINOR
# Platform constants — exported for sourced setup-modules (shell-env.sh,
# tool-install.sh) that reference them at runtime.
PLATFORM_MACOS=$([[ "$(uname -s)" == "Darwin" ]] && echo true || echo false)
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
# Repo constants — exported; consumed by setup-modules/core.sh, agent-deploy.sh
REPO_URL="https://github.com/marcusquinn/aidevops.git"
# INSTALL_DIR: resolve from the directory where setup.sh is executed (supports worktrees)
# For bootstrap (curl install), this will be /dev/fd/NN and trigger re-exec after clone
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_routines.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_privacy_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_complexity_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_task_id_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_canonical_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_worktree_exclusions.sh"
fi

print_info() { local _m="$1"; echo -e "${BLUE}[INFO]${NC} $_m"; return 0; }
print_success() { local _m="$1"; echo -e "${GREEN}[SUCCESS]${NC} $_m"; return 0; }
print_warning() { local _m="$1"; echo -e "${YELLOW}[WARNING]${NC} $_m"; return 0; }
print_error() { local _m="$1"; echo -e "${RED}[ERROR]${NC} $_m"; return 0; }

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
	str="${str//$'\n'/ }"
	str="${str//$'\r'/ }"
	# Replace each ' with '\'' (end quote, escaped quote, start quote)
	str="${str//\'/\'\\\'\'}"
	printf "'%s'" "$str"
	return 0
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

# Ensure the crontab has a single PATH= line at the top with the current $PATH.
# Individual cron entries must NOT set inline PATH= — it overrides the global one
# and hardcodes system-specific paths (nvm, bun, cargo, etc.). This function
# manages a tagged comment + PATH line pair; re-running setup.sh updates it
# idempotently. The marker must be a separate comment line because crontab does
# NOT support inline comments on environment variable lines — anything after
# PATH= is treated as part of the value.
_ensure_cron_path() {
	local current_crontab marker="# aidevops-path"
	current_crontab=$(crontab -l 2>/dev/null) || current_crontab=""

	# Deduplicate PATH entries (preserving order)
	# Bash 3.2 compat: no associative arrays — use string-based seen list
	local deduped_path=""
	local seen_dirs=" "
	local IFS=':'
	for dir in $PATH; do
		if [[ -n "$dir" && "$seen_dirs" != *" ${dir} "* ]]; then
			seen_dirs="${seen_dirs}${dir} "
			deduped_path="${deduped_path:+${deduped_path}:}${dir}"
		fi
	done
	unset IFS

	# Marker on its own line, PATH on the next — crontab treats everything
	# after PATH= as the value (no inline comments)
	local path_block="${marker}
PATH=${deduped_path}"

	# Remove only the aidevops-managed marker + PATH pair.
	# User-owned PATH= lines are left untouched.
	local filtered
	filtered=$(printf '%s\n' "$current_crontab" | awk -v marker="$marker" '
		$0 == marker { drop_next_path=1; next }
		drop_next_path && /^PATH=/ { drop_next_path=0; next }
		{ drop_next_path=0; print }
	')

	if [[ -n "$filtered" ]]; then
		current_crontab="${path_block}
${filtered}"
	else
		current_crontab="$path_block"
	fi

	printf '%s\n' "$current_crontab" | crontab - 2>/dev/null || true
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

# Install a launchd plist only if its content has changed.
# Avoids unnecessary unload/reload which resets StartInterval timers.
# Usage: _launchd_install_if_changed <label> <plist_path> <new_content>
# Returns: 0 = installed or unchanged, 1 = failed to load
_launchd_install_if_changed() {
	local label="$1"
	local plist_path="$2"
	local new_content="$3"

	# Compare with existing plist — skip reload if identical
	if [[ -f "$plist_path" ]]; then
		local existing_content
		existing_content=$(cat "$plist_path")
		if [[ "$existing_content" == "$new_content" ]]; then
			# Ensure it's loaded even if content unchanged
			if ! _launchd_has_agent "$label"; then
				launchctl load "$plist_path" 2>/dev/null || return 1
			fi
			return 0
		fi
		# Content changed — unload before replacing
		if _launchd_has_agent "$label"; then
			launchctl unload "$plist_path" 2>/dev/null || true
		fi
	fi

	# Atomic write: build at sibling tmp path, then rename into place.
	# If printf is killed mid-write, the destination is untouched.
	local tmp_plist="${plist_path}.tmp.$$"
	if ! printf '%s\n' "$new_content" >"$tmp_plist"; then
		rm -f "$tmp_plist"
		return 1
	fi
	# Defensive: refuse to install an empty file (should be guaranteed by the
	# caller's content check, but guard here too).
	if [[ ! -s "$tmp_plist" ]]; then
		rm -f "$tmp_plist"
		return 1
	fi
	mv -f "$tmp_plist" "$plist_path"
	launchctl load "$plist_path" 2>/dev/null || return 1
	return 0
}

# Detect whether a scheduler is already installed via launchd, cron, or systemd.
# Optionally migrates legacy launchd labels / cron entries to launchd on macOS.
# Args: arg1=scheduler_name, arg2=launchd_label, arg3=legacy_launchd_label,
#       arg4=cron_marker, arg5=migrate_script, arg6=migrate_arg, arg7=migrate_hint
#       arg8=systemd_unit (optional — base name without .timer suffix, e.g. "aidevops-supervisor-pulse")
_scheduler_detect_installed() {
	local scheduler_name="$1"
	local launchd_label="$2"
	local legacy_launchd_label="$3"
	local cron_marker="$4"
	local migrate_script="$5"
	local migrate_arg="$6"
	local migrate_hint="$7"
	local systemd_unit="${8:-}"
	local installed=false

	if _launchd_has_agent "$launchd_label"; then
		installed=true
	elif [[ -n "$legacy_launchd_label" ]] && _launchd_has_agent "$legacy_launchd_label"; then
		if [[ -n "$migrate_script" ]] && [[ -x "$migrate_script" ]]; then
			if bash "$migrate_script" "$migrate_arg" >/dev/null 2>&1; then
				print_info "$scheduler_name LaunchAgent migrated to new label"
			else
				print_warning "$scheduler_name label migration failed. Run: $migrate_hint"
			fi
		fi
		installed=true
	elif crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
		if [[ "$PLATFORM_MACOS" == "true" ]] && [[ -n "$migrate_script" ]] && [[ -x "$migrate_script" ]]; then
			if bash "$migrate_script" "$migrate_arg" >/dev/null 2>&1; then
				print_info "$scheduler_name migrated from cron to launchd"
			else
				print_warning "$scheduler_name cron->launchd migration failed. Run: $migrate_hint"
			fi
		fi
		installed=true
	elif [[ -n "$systemd_unit" ]] && command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled "${systemd_unit}.timer" >/dev/null 2>&1; then
		# Systemd user timer detected (GH#17381 — Linux systemd path was missing)
		installed=true
	fi

	if [[ "$installed" == "true" ]]; then
		return 0
	fi

	return 1
}

_should_setup_noninteractive_supervisor_pulse() {
	local pulse_label="com.aidevops.aidevops-supervisor-pulse"

	if _scheduler_detect_installed \
		"Supervisor pulse" \
		"$pulse_label" \
		"" \
		"pulse-wrapper" \
		"" \
		"" \
		"" \
		"aidevops-supervisor-pulse"; then
		return 0
	fi

	if type config_enabled &>/dev/null && config_enabled "orchestration.supervisor_pulse"; then
		return 0
	fi

	return 1
}

# Generic non-interactive scheduler detection (GH#17695 Finding B).
# Returns 0 if the named scheduler is already installed on any backend,
# meaning it should be regenerated during non-interactive setup.
# Args: arg1=name arg2=launchd_label arg3=cron_marker arg4=systemd_unit
_should_setup_noninteractive_scheduler() {
	local name="$1"
	local launchd_label="$2"
	local cron_marker="$3"
	local systemd_unit="${4:-}"

	if _scheduler_detect_installed \
		"$name" \
		"$launchd_label" \
		"" \
		"$cron_marker" \
		"" \
		"" \
		"" \
		"$systemd_unit"; then
		return 0
	fi

	return 1
}

# Stats-wrapper is a REQUIRED dependency of the supervisor pulse — the pulse
# delegates all health dashboard + quality sweep work to it (t1429). If the
# supervisor pulse is installed or consented, stats-wrapper must also be
# installed, even on first-time non-interactive runs. Without this escape
# hatch, auto-update on a fresh machine installs the pulse but not the
# stats-wrapper, leaving the health dashboard permanently stale (t2418,
# GH#20016 — canonical 11-day staleness on #10944 on 2026-04-20).
_should_setup_noninteractive_stats_wrapper() {
	if _should_setup_noninteractive_scheduler \
		"Stats wrapper" \
		"com.aidevops.aidevops-stats-wrapper" \
		"aidevops: stats-wrapper" \
		"aidevops-stats-wrapper"; then
		return 0
	fi

	# Pulse-dependency escape hatch: install stats-wrapper whenever the
	# supervisor pulse is (or will be) enabled. Pulse itself also honours
	# config consent in the non-interactive path, so following its gate
	# keeps the two schedulers in lockstep.
	if _should_setup_noninteractive_supervisor_pulse; then
		return 0
	fi

	return 1
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

# get_latest_homebrew_python_formula() and find_python3() are defined in
# _common.sh (sourced above). Not duplicated here — see GH#5239 review.

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

# Prompt the user for input, with non-interactive fallback.
# Canonical definition in .agents/scripts/setup/_common.sh; this fallback
# ensures the function exists even when _common.sh was not sourced (e.g.
# bootstrap from curl where setup-modules/ doesn't exist yet).
if ! type setup_prompt &>/dev/null; then
	setup_prompt() {
		local var_name="$1"
		local prompt_text="$2"
		local default_value="${3:-}"

		# Non-interactive: use default without prompting
		if [[ "${NON_INTERACTIVE:-false}" == "true" ]] || [[ ! -t 0 ]]; then
			# shellcheck disable=SC2059  # var_name is a variable name, not a format string
			printf -v "$var_name" '%s' "$default_value"
			return 0
		fi

		local _setup_prompt_reply=""
		read -r -p "$prompt_text" _setup_prompt_reply || _setup_prompt_reply="$default_value"
		# shellcheck disable=SC2059  # var_name is a variable name, not a format string
		printf -v "$var_name" '%s' "$_setup_prompt_reply"
		return 0
	}
fi

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

	# Copy source to backup (tolerant of broken symlinks / missing entries)
	if [[ -d "$source_path" ]]; then
		if command -v rsync >/dev/null 2>&1 && rsync --help 2>&1 | grep -q -- '--ignore-missing-args'; then
			# rsync >= 3.1.0: --ignore-missing-args skips missing/broken entries gracefully
			if ! rsync -a --ignore-missing-args "$source_path/" "$backup_dir/$(basename "$source_path")/" 2>/dev/null; then
				print_warning "Backup had partial failures (broken symlinks?), continuing"
			fi
		else
			# Fallback: cp -R may fail on broken symlinks under set -e,
			# so run in a subshell that tolerates errors
			if ! (cp -R "$source_path" "$backup_dir/" 2>/dev/null); then
				print_warning "Backup had partial failures (broken symlinks?), continuing"
			fi
		fi
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

	# Re-execute the local copy (which has setup-modules/ available)
	cd "$_bootstrap_install_dir" || exit 1
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
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/agent-runtime.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/tool-beads.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/config.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/plugins.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/schedulers.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/setup-modules/post-setup.sh"

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
			print_error "Unknown option: $_opt"
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

# GH#18950 (t2087) + GH#18965 (t2094): ensure modern bash is installed
# and up to date on macOS. Runs after platform detection, before deploy.
# Uses the canonical `ensure` subcommand which combines install + upgrade:
#   - Missing → interactive prompt for install (or silent with --yes)
#   - Installed but drifted → silent upgrade (brew upgrade bash)
#   - Current → no-op
# Rate-limits `brew update` to 24h internally. Always fail-open — never
# blocks setup on a bash upgrade failure.
#
# Opt-out: AIDEVOPS_AUTO_UPGRADE_BASH=0 disables install + upgrade entirely.
_setup_check_bash_upgrade() {
	# Only applies to macOS; Linux bash is already modern on any current distro.
	if [[ "${AIDEVOPS_PLATFORM:-}" != "macos" ]]; then
		return 0
	fi

	local helper="${INSTALL_DIR}/.agents/scripts/bash-upgrade-helper.sh"
	[[ -x "$helper" ]] || return 0

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		# Non-interactive: ensure does everything silently (install with
		# --yes, upgrade on drift, no-op when current). Same pattern as
		# `aidevops update` — fire-and-forget.
		"$helper" ensure --yes --quiet || print_warning "bash ensure failed (non-fatal) — advisory written"
		return 0
	fi

	# Interactive: ensure prompts on first install (inherited from
	# _bu_cmd_install's read path), runs silently on upgrade. Users don't
	# see a prompt on every `./setup.sh` run — only the first one.
	"$helper" ensure || print_warning "bash ensure failed (non-fatal) — advisory written"
	return 0
}

# GH#17769: Comment out deprecated model env vars in a single credentials file.
_comment_out_deprecated_model_vars() {
	local file="$1"
	local deprecated_vars="AIDEVOPS_HEADLESS_MODELS|PULSE_MODEL"
	local deprecation_note="# DEPRECATED by aidevops v3.7+ — model routing is now automatic (GH#17769)"
	[[ -f "$file" ]] || return 0
	# Only process lines that are active exports (not already commented)
	if grep -qE "^[[:space:]]*export[[:space:]]+(${deprecated_vars})=" "$file" 2>/dev/null; then
		sed -i.bak -E "s/^([[:space:]]*)(export[[:space:]]+(${deprecated_vars})=.*)$/\1${deprecation_note}\n\1# \2/" "$file"
		rm -f "${file}.bak"
		print_info "Commented out deprecated model env vars in $(basename "$file")"
	fi
	return 0
}

# GH#17769: Comment out deprecated model env vars from credentials.sh.
# Runs on every `aidevops update`. Uses sed to comment out (not delete) lines
# so the user's file history is preserved.
_cleanup_legacy_model_config() {
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	_comment_out_deprecated_model_vars "$creds_file"

	# Clean up tenant credentials files
	local tenant_dir="${HOME}/.config/aidevops/tenants"
	if [[ -d "$tenant_dir" ]]; then
		local tenant_creds=""
		while IFS= read -r -d '' tenant_creds; do
			_comment_out_deprecated_model_vars "$tenant_creds"
		done < <(find "$tenant_dir" -name "credentials.sh" -print0 2>/dev/null)
	fi
	return 0
}

# Deploy auto-hotfix.conf template to user-level configs if not already present.
# The template ships in .agents/configs/; this copies to ~/.aidevops/configs/
# where user edits survive `aidevops update`. Existing user config is preserved.
_deploy_hotfix_config() {
	local source_conf="${INSTALL_DIR:-.}/.agents/configs/auto-hotfix.conf"
	local target_dir="$HOME/.aidevops/configs"
	local target_conf="$target_dir/auto-hotfix.conf"

	if [[ ! -f "$source_conf" ]]; then
		return 0
	fi

	# Only deploy if the user doesn't have one yet (preserve user edits)
	if [[ -f "$target_conf" ]]; then
		return 0
	fi

	mkdir -p "$target_dir"
	cp "$source_conf" "$target_conf"
	chmod 600 "$target_conf"
	return 0
}

# t2919: Early pulse plist install. The pulse launchd agent is critical
# infrastructure — without it, every other pulse-driven feature (worker
# dispatch, issue routing, cross-repo coordination) is dead. Previously,
# setup_supervisor_pulse only ran inside _setup_post_setup_steps which
# executes AFTER ~25 other migration/setup steps. When `aidevops update`
# runs unattended and any earlier step times out (e.g. brew taps, MCP
# installs, slow repo scans), the pulse plist never gets installed/refreshed
# and the runner falls behind.
#
# Install immediately after deploy_aidevops_agents (so the scripts the plist
# references already exist on disk). The late install in _setup_post_setup_steps
# remains as the canonical regenerate-on-change path — _launchd_install_if_changed
# compares content and skips reload when identical, so the second call is a
# no-op when nothing changed. Failure here is non-fatal: the late path retries.
_setup_install_pulse_plist_early() {
	local _early_os
	_early_os="$(uname -s)"
	if _should_setup_noninteractive_supervisor_pulse; then
		setup_supervisor_pulse "$_early_os" || print_warning "Early pulse plist install failed (will retry late)"
	fi
	return 0
}

# Non-interactive path: deploy agents and run safe migrations only (no prompts).
_setup_run_non_interactive() {
	print_info "Non-interactive mode: deploying agents and running safe migrations only"
	verify_location
	check_requirements
	# Run quality tool detection in non-interactive mode too (warn-only path).
	check_quality_tools
	check_python_upgrade_available
	set_permissions
	migrate_old_backups
	migrate_loop_state_directories
	migrate_agent_to_agents_folder
	migrate_mcp_env_to_credentials
	migrate_pulse_repos_to_repos_json
	cleanup_deprecated_paths
	migrate_orphaned_supervisor
	backfill_issue_relationships
	cleanup_deprecated_mcps
	cleanup_stale_bun_opencode
	cleanup_stale_health_issue_caches
	cleanup_worktree_entries_in_repos_json
	_cleanup_legacy_model_config
	# t2888: install/heal opencode-ai. Companion to t2887's runtime canary
	# fail-fast -- t2887 detects when $OPENCODE_BIN_DEFAULT is wrong, this
	# one fixes it by reinstalling opencode-ai@latest (overwriting any bin
	# collision with @anthropic-ai/claude-code or similar). Skipping this
	# in non-interactive mode is the bug PR #20189 introduced and what
	# alex-solovyev's runner spam stemmed from.
	setup_opencode_cli
	validate_opencode_config
	deploy_aidevops_agents
	_setup_install_pulse_plist_early
	_deploy_hotfix_config
	sync_agent_sources
	install_aidevops_cli
	setup_shellcheck_wrapper
	if is_feature_enabled safety_hooks 2>/dev/null; then
		setup_safety_hooks
	fi
	init_settings_json

	# Parallelise independent skill operations (t1356: ~84s serial -> ~18s parallel)
	# generate_agent_skills must complete before create_skill_symlinks (symlinks
	# depend on generated SKILL.md files). scan_imported_skills is independent.
	local _pid_symlinks=""
	if generate_agent_skills; then
		create_skill_symlinks &
		_pid_symlinks=$!
	else
		print_warning "Agent skills generation failed — skipping skill symlinks"
	fi

	scan_imported_skills &
	local _pid_scan=$!

	if [[ -n "$_pid_symlinks" ]]; then
		wait "$_pid_symlinks" 2>/dev/null || print_warning "Skill symlink creation encountered issues (non-critical)"
	fi
	wait "$_pid_scan" 2>/dev/null || print_warning "Skill security scan encountered issues (non-critical)"

	inject_agents_reference
	deploy_agents_to_runtimes
	update_opencode_config
	update_claude_config
	update_codex_config
	update_cursor_config
	disable_ondemand_mcps
	# Scaffold personal routines repo if not already present (idempotent).
	# Creates local git repo + private GitHub remote for personal repo only.
	# Org repos require explicit: aidevops init-routines --org <name>
	setup_routines
	# Install/refresh the privacy-guard pre-push hook in every initialized
	# repo so TODO/todo/README/ISSUE_TEMPLATE pushes to public GitHub repos
	# are scanned for private slug leaks (t1968).
	setup_privacy_guard
	# Install/refresh the complexity-regression pre-push hook in every
	# initialized repo so pushes that introduce new function-complexity,
	# nesting-depth, or file-size violations are caught before CI (t2198).
	setup_complexity_guard
	# Install/refresh the canonical-on-main post-checkout hook in every
	# initialized repo so branch switches away from main in the canonical
	# directory are warned against (t1995). Complements pre-edit-check.sh's
	# t1990 edit-time check by catching the branch switch itself.
	setup_canonical_guard
	# Install/refresh the task-id collision guard commit-msg hook in every
	# initialized repo so invented t-IDs in commit subjects are rejected
	# at commit time (t2047). Belt-and-braces with the CI check in
	# .github/workflows/ta[redacted-credential].yml.
	setup_task_id_guard
	# Apply Spotlight + Time Machine exclusions to every worktree across
	# registered repos so the backup/index cascade triggered by node_modules
	# copies doesn't burn CPU (t2885). Idempotent. macOS only — Linux
	# indexers tracked separately.
	setup_worktree_exclusions
	return 0
}

# Interactive path: all optional steps gated behind confirm_step prompts.
_setup_run_interactive() {
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
	confirm_step "Check Python version (recommend upgrade if outdated)" && check_python_upgrade_available
	confirm_step "Setup recommended tools (Tabby, Zed, etc.)" && setup_recommended_tools
	confirm_step "Setup PIM tools (Reminders, Calendar, Contacts)" && setup_pim_tools
	confirm_step "Setup MiniSim (iOS/Android emulator launcher)" && setup_minisim
	confirm_step "Setup ClaudeBar (AI quota monitor in menu bar)" && setup_claudebar
	confirm_step "Setup Git CLIs (gh, glab, tea)" && setup_git_clis
	confirm_step "Setup file discovery tools (fd, ripgrep, ripgrep-all)" && setup_file_discovery_tools
	confirm_step "Setup rtk (token-optimized CLI output, 60-90% savings)" && setup_rtk
	confirm_step "Setup shell linting tools (shellcheck, shfmt)" && {
		setup_shell_linting_tools
		setup_shellcheck_wrapper
	}
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
	confirm_step "Migrate orphaned supervisor to pulse-wrapper" && migrate_orphaned_supervisor
	confirm_step "Backfill GitHub issue relationships (blocked-by, sub-issues)" && backfill_issue_relationships
	confirm_step "Cleanup deprecated MCP entries (hetzner, serper, etc.)" && cleanup_deprecated_mcps
	confirm_step "Cleanup stale bun opencode install" && cleanup_stale_bun_opencode
	# Silent one-shot migrations (idempotent, flag-guarded — no prompt needed).
	cleanup_stale_health_issue_caches; cleanup_worktree_entries_in_repos_json; _cleanup_legacy_model_config
	confirm_step "Validate and repair OpenCode config schema" && validate_opencode_config
	confirm_step "Extract OpenCode prompts" && extract_opencode_prompts
	confirm_step "Check OpenCode prompt drift" && check_opencode_prompt_drift
	confirm_step "Deploy aidevops agents to ~/.aidevops/agents/" && { deploy_aidevops_agents; _deploy_hotfix_config; }
	confirm_step "Sync agents from private repositories" && sync_agent_sources
	confirm_step "Set up routines repo (private repo for recurring operational jobs)" && setup_routines
	is_feature_enabled safety_hooks 2>/dev/null && confirm_step "Install Claude Code safety hooks (block destructive commands)" && setup_safety_hooks
	confirm_step "Initialize settings.json (canonical config file)" && init_settings_json
	confirm_step "Setup multi-tenant credential storage" && setup_multi_tenant_credentials
	confirm_step "Generate agent skills (SKILL.md files)" && generate_agent_skills
	confirm_step "Create symlinks for imported skills" && create_skill_symlinks
	confirm_step "Check for skill updates from upstream" && check_skill_updates
	confirm_step "Security scan imported skills" && scan_imported_skills
	confirm_step "Inject agents reference into AI configs" && inject_agents_reference
	confirm_step "Deploy aidevops agents to runtime agent directories" && deploy_agents_to_runtimes
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
	confirm_step "Setup Google Workspace CLI (Gmail, Calendar, Drive)" && setup_google_workspace_cli
	confirm_step "Setup OpenCode CLI (AI coding tool)" && setup_opencode_cli
	confirm_step "Setup OpenCode plugins" && setup_opencode_plugins
	confirm_step "Setup Codex CLI (OpenAI AI coding tool)" && setup_codex_cli
	confirm_step "Setup Droid CLI (Factory.AI coding tool)" && setup_droid_cli
	# Run AFTER CLI installs so config dirs may exist for agent config
	confirm_step "Update OpenCode configuration" && update_opencode_config
	# Run AFTER OpenCode config so Claude Code gets equivalent setup
	confirm_step "Update Claude Code configuration (slash commands, MCPs, settings)" && update_claude_config
	# Run AFTER Claude Code config so Codex/Cursor get equivalent setup
	confirm_step "Update Codex configuration (MCPs, instructions)" && update_codex_config
	confirm_step "Update Cursor configuration (MCPs)" && update_cursor_config
	# Deploy slash commands to the other installed runtimes (Codex, Cursor,
	# Droid, Gemini CLI, Continue, Kiro, Kimi, Qwen) via the unified generator.
	# OpenCode and Claude Code are already handled by their update_*_config
	# functions above. Closes GH#18106 / t15474.
	confirm_step "Deploy slash commands to remaining runtimes" && deploy_commands_to_all_runtimes
	# Run AFTER all MCP setup functions to ensure disabled state persists
	confirm_step "Disable on-demand MCPs globally" && disable_ondemand_mcps
	return 0
}

# Post-setup steps: schedulers, final instructions, optional tool update check.
# Non-interactive scheduler installation. Extracted from
# `_setup_post_setup_steps` (t2903) to keep the parent under the
# function-complexity gate threshold. Each `_should_setup_noninteractive_*`
# guard returns 0 when the corresponding scheduler is already installed
# (regenerate on update) or first-time install is consented via config.
_setup_noninteractive_schedulers() {
	local os="$1"

	# Auto-update handles non-interactive internally (systemd detection fixed in GH#17861)
	setup_auto_update
	if _should_setup_noninteractive_supervisor_pulse; then
		setup_supervisor_pulse "$os"
	fi
	# Regenerate other schedulers if already installed (GH#17695 Finding B).
	# Stats wrapper is a pulse dependency — also install on first run when
	# the supervisor pulse is consented (t2418, GH#20016).
	if _should_setup_noninteractive_stats_wrapper; then
		setup_stats_wrapper "${PULSE_ENABLED:-}"
	fi
	if _should_setup_noninteractive_scheduler "Failure miner" "sh.aidevops.routine-gh-failure-miner" "aidevops: gh-failure-miner" "aidevops-gh-failure-miner"; then
		setup_failure_miner "${PULSE_ENABLED:-}"
	fi
	if _should_setup_noninteractive_scheduler "Process guard" "sh.aidevops.process-guard" "aidevops: process-guard" "aidevops-process-guard"; then
		setup_process_guard
	fi
	if _should_setup_noninteractive_scheduler "Memory pressure" "sh.aidevops.memory-pressure-monitor" "aidevops: memory-pressure-monitor" "aidevops-memory-pressure-monitor"; then
		setup_memory_pressure_monitor
	fi
	if _should_setup_noninteractive_scheduler "Screen time" "sh.aidevops.screen-time-snapshot" "aidevops: screen-time-snapshot" "aidevops-screen-time-snapshot"; then
		setup_screen_time_snapshot
	fi
	if _should_setup_noninteractive_scheduler "Contribution watch" "sh.aidevops.contribution-watch" "aidevops: contribution-watch" "aidevops-contribution-watch"; then
		setup_contribution_watch
	fi
	# t2903 (#21049): complexity scan — extracted from pulse dispatch preflight
	if _should_setup_noninteractive_scheduler "Complexity scan" "sh.aidevops.complexity-scan" "aidevops: complexity-scan" "aidevops-complexity-scan"; then
		setup_complexity_scan
	fi
	# Repo sync handles non-interactive mode internally (systemd detection fixed in GH#17861)
	setup_repo_sync
	# r914 repo-aidevops-health — daily drift keeper (t2366)
	setup_repo_aidevops_health
	if _should_setup_noninteractive_scheduler "Profile README" "sh.aidevops.profile-readme-update" "aidevops: profile-readme-update" "aidevops-profile-readme-update"; then
		setup_profile_readme
	fi
	if _should_setup_noninteractive_scheduler "OAuth token refresh" "sh.aidevops.token-refresh" "aidevops: token-refresh" "aidevops-token-refresh"; then
		setup_oauth_token_refresh
	fi
	# opencode DB maintenance (r913, t2183). Helper self-noops on missing
	# DB — safe to install unconditionally in non-interactive mode too.
	setup_opencode_db_maintenance
	# Migrate cron entries to systemd after schedulers are installed (GH#17695 Finding D)
	migrate_cron_to_systemd
	setup_tabby
	return 0
}

_setup_post_setup_steps() {
	local os="$1"

	# Print setup summary before final success message (GH#5240)
	print_setup_summary

	echo ""
	print_success "Setup complete!"

	# Cache client request format constants if CLI is installed (~50ms)
	if command -v claude &>/dev/null && [[ -x "${INSTALL_DIR}/.agents/scripts/cch-extract.sh" ]]; then
		"${INSTALL_DIR}/.agents/scripts/cch-extract.sh" --cache >/dev/null 2>&1 || true
	else
		echo ""
		echo -e "${YELLOW}[TIP]${NC} Install Claude CLI for automatic request format alignment:"
		echo "      npm install -g @anthropic-ai/claude-code"
	fi

	# Non-interactive mode: deploy + migrations only — skip schedulers,
	# services, and optional post-setup work (CI/agent shells don't need them).
	# Tabby profile sync runs in both modes (has its own non-interactive path).
	#
	# Exceptions: regenerate existing schedulers (GH#17381, GH#17695 Finding B)
	# and allow first-time install when config consent is explicitly true (GH#17403).
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_noninteractive_schedulers "$os"
		return 0
	fi

	# Post-setup: auto-update, schedulers, final instructions (GH#5793)
	setup_auto_update
	setup_supervisor_pulse "$os"
	setup_stats_wrapper "${PULSE_ENABLED:-}"
	setup_failure_miner "${PULSE_ENABLED:-}"
	setup_repo_sync
	# r914 repo-aidevops-health — daily drift keeper (t2366)
	setup_repo_aidevops_health
	setup_process_guard
	setup_memory_pressure_monitor
	setup_screen_time_snapshot
	setup_contribution_watch
	setup_complexity_scan
	setup_draft_responses
	setup_profile_readme
	setup_oauth_token_refresh
	setup_opencode_db_maintenance
	# Migrate cron entries to systemd after schedulers are installed (GH#17695 Finding D)
	migrate_cron_to_systemd
	setup_tabby
	print_final_instructions

	# Check for tool updates if --update flag was passed
	if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
		echo ""
		check_tool_updates
	fi

	setup_onboarding_prompt
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

	_setup_print_header

	# GH#18950 (t2087): bash 3.2 → modern bash upgrade check. Runs before
	# the main setup flow so the user sees the prompt early. Fail-open —
	# never blocks setup even if bash install fails.
	_setup_check_bash_upgrade

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_run_non_interactive
	else
		_setup_run_interactive
	fi

	_setup_post_setup_steps "$_os"

	# t2579: restart pulse if running, so newly-deployed scripts take effect.
	# No-op if pulse is not running, or if AIDEVOPS_SKIP_PULSE_RESTART=1.
	# Uses the deployed helper (not the repo-local one) so the restart runs
	# against the agents directory setup.sh just populated.
	local _pulse_helper="${HOME}/.aidevops/agents/scripts/pulse-lifecycle-helper.sh"
	if [[ -x "$_pulse_helper" ]]; then
		"$_pulse_helper" restart-if-running || print_warning "Pulse restart failed (non-fatal)"
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
