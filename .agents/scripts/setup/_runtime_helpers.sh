#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Setup Runtime Helpers
# =============================================================================
# Scheduler decision helpers plus generic install, prompt, spinner, and backup
# helpers used by setup.sh. Extracted to keep setup.sh under the file-size gate
# while preserving the existing setup.sh entrypoint and function names.
#
# Usage: source "${SETUP_MODULES_DIR}/_runtime_helpers.sh"
#
# Dependencies:
#   - setup.sh globals: colors, INTERACTIVE_MODE, NON_INTERACTIVE
#   - _scheduler_runtime.sh for _scheduler_detect_installed
#   - bash 3.2+, curl, npm, rsync/cp
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SETUP_RUNTIME_HELPERS_LOADED:-}" ]] && return 0
_SETUP_RUNTIME_HELPERS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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

# Complexity scan is part of the pulse-maintained quality-debt loop. It was
# split out of pulse dispatch into a standalone scheduler (t2903, GH#21049),
# so existing pulse-enabled installs need the same first-time non-interactive
# escape hatch as stats-wrapper and pulse-merge-routine. The generic scheduler
# gate only regenerates units that are already installed, which strands older
# Linux/systemd installs without aidevops-complexity-scan.timer (GH#24841).
_should_setup_noninteractive_complexity_scan() {
	if _should_setup_noninteractive_scheduler \
		"Complexity scan" \
		"sh.aidevops.complexity-scan" \
		"aidevops: complexity-scan" \
		"aidevops-complexity-scan"; then
		return 0
	fi

	# Pulse-dependency escape hatch: install the standalone complexity scan
	# whenever the supervisor pulse is (or will be) enabled. This preserves the
	# non-interactive consent gate while backfilling the new timer for existing
	# pulse users during update.
	if _should_setup_noninteractive_supervisor_pulse; then
		return 0
	fi

	return 1
}

# Pulse-merge-routine is a REQUIRED dependency of the supervisor pulse — it
# is the merge-side of pulse, running merge_ready_prs_all_repos() on a fast
# 120s cadence so green PRs land within ~3 min of CI completion instead of
# waiting for the next full pulse cycle (t2862, GH#20919). Without this
# escape hatch, auto-update on existing systems never installs the routine
# (the generic _should_setup_noninteractive_scheduler chicken-and-egg gate
# returns 0 only when the scheduler is ALREADY installed). The result on
# the wild was the deterministic_merge_pass running 1-2x/24h instead of
# every 2 min, leaving green PRs unmerged for 30+ hours (t3036, GH#21616).
# Mirrors the stats-wrapper escape hatch above (t2418, GH#20016).
_should_setup_noninteractive_pulse_merge_routine() {
	if _should_setup_noninteractive_scheduler \
		"Pulse merge routine" \
		"sh.aidevops.pulse-merge-routine" \
		"aidevops: pulse-merge-routine" \
		"aidevops-pulse-merge-routine"; then
		return 0
	fi

	# Pulse-dependency escape hatch: install the merge routine whenever the
	# supervisor pulse is (or will be) enabled. The routine is layered
	# defense for the in-cycle merge call in pulse-wrapper.sh, which is
	# kept as a safety net but short-circuits when this routine ran within
	# the last 60s.
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
	# t2997: drop .sh — XXXXXX must be at end for BSD mktemp.
	tmp_script=$(mktemp "${TMPDIR:-/tmp}/aidevops-install-XXXXXX") || {
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
# bootstrap from curl where .agents/scripts/setup/modules/ doesn't exist yet).
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
