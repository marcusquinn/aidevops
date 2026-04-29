#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# auto-update-helper.sh -- Orchestrator for automatic update polling daemon
# =============================================================================
# Lightweight cron job that checks for new aidevops releases every 10 minutes
# and auto-installs them. Safe to run while AI sessions are active.
#
# Also runs a daily skill freshness check: calls skill-update-helper.sh
# --auto-update --quiet to pull upstream changes for all imported skills.
# The 24h gate ensures skills stay fresh without excessive network calls.
#
# Also runs a daily OpenClaw update check (if openclaw CLI is installed).
# Uses the same 24h gate pattern. Respects the user's configured channel.
#
# Also runs a 6-hourly tool freshness check: calls tool-version-check.sh
# --update --quiet to upgrade all installed tools (npm, brew, pip).
# Only runs when the user has been idle for 6+ hours (sleeping/away).
# macOS: uses IOKit HIDIdleTime. Linux: xprintidle, or /proc session idle,
# or assumes idle on headless servers (no display).
#
# Usage:
#   auto-update-helper.sh enable           Install cron job (every 10 min)
#   auto-update-helper.sh disable          Remove cron job
#   auto-update-helper.sh status           Show current state
#   auto-update-helper.sh check            One-shot: check and update if needed
#   auto-update-helper.sh logs [--tail N]  View update logs
#   auto-update-helper.sh help             Show this help
#
# Configuration:
#   All values can be set via JSONC config (aidevops config set <key> <value>)
#   or overridden per-session via environment variables (higher priority).
#
#   JSONC key                          Env override                    Default
#   updates.auto_update                AIDEVOPS_AUTO_UPDATE            true
#   updates.update_interval_minutes    AIDEVOPS_UPDATE_INTERVAL        10
#   updates.skill_auto_update          AIDEVOPS_SKILL_AUTO_UPDATE      true
#   updates.skill_freshness_hours      AIDEVOPS_SKILL_FRESHNESS_HOURS  24
#   updates.openclaw_auto_update       AIDEVOPS_OPENCLAW_AUTO_UPDATE   true
#   updates.openclaw_freshness_hours   AIDEVOPS_OPENCLAW_FRESHNESS_HOURS 24
#   updates.tool_auto_update           AIDEVOPS_TOOL_AUTO_UPDATE       true
#   updates.tool_freshness_hours       AIDEVOPS_TOOL_FRESHNESS_HOURS   6
#   updates.tool_idle_hours            AIDEVOPS_TOOL_IDLE_HOURS        6
#   updates.upstream_watch             AIDEVOPS_UPSTREAM_WATCH         true
#   updates.upstream_watch_hours       AIDEVOPS_UPSTREAM_WATCH_HOURS   24
#   updates.venv_health_check          AIDEVOPS_VENV_HEALTH_CHECK      true
#   updates.venv_health_hours          AIDEVOPS_VENV_HEALTH_HOURS      24
#
# Logs: ~/.aidevops/logs/auto-update.log

set -euo pipefail

# Resolve symlinks to find real script location (t1262)
# When invoked via symlink (e.g. ~/.aidevops/bin/aidevops-auto-update),
# BASH_SOURCE[0] is the symlink path. We must resolve it to find sibling scripts.
_resolve_script_path() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir="$(cd "$(dirname "$src")" && pwd)" || return 1
		src="$(readlink "$src")"
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_path)" || exit
unset -f _resolve_script_path
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# Configuration
readonly INSTALL_DIR="$HOME/Git/aidevops"
readonly LOCK_DIR="$HOME/.aidevops/locks"
readonly LOCK_FILE="$LOCK_DIR/auto-update.lock"
readonly LOG_FILE="$HOME/.aidevops/logs/auto-update.log"
readonly STATE_FILE="$HOME/.aidevops/cache/auto-update-state.json"
readonly CRON_MARKER="# aidevops-auto-update"
readonly DEFAULT_INTERVAL=10
readonly DEFAULT_SKILL_FRESHNESS_HOURS=24
readonly DEFAULT_OPENCLAW_FRESHNESS_HOURS=24
readonly DEFAULT_TOOL_FRESHNESS_HOURS=6
readonly DEFAULT_TOOL_IDLE_HOURS=6
readonly DEFAULT_UPSTREAM_WATCH_HOURS=24
readonly DEFAULT_VENV_HEALTH_HOURS=24
readonly LAUNCHD_LABEL="com.aidevops.aidevops-auto-update"
readonly LAUNCHD_DIR="$HOME/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly SYSTEMD_SERVICE_DIR="$HOME/.config/systemd/user"
readonly SYSTEMD_UNIT_NAME="aidevops-auto-update"

#######################################
# Logging
#######################################
log() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	echo "[$timestamp] [$level] $*" >>"$LOG_FILE"
	return 0
}

log_info() {
	log "INFO" "$@"
	return 0
}
log_warn() {
	log "WARN" "$@"
	return 0
}
log_error() {
	log "ERROR" "$@"
	return 0
}

#######################################
# Ensure directories exist
#######################################
ensure_dirs() {
	mkdir -p "$LOCK_DIR" "$HOME/.aidevops/logs" "$HOME/.aidevops/cache" 2>/dev/null || true
	return 0
}

#######################################
# Source sub-libraries — each domain extracted to keep this file under the
# file-size-debt threshold. Sourcing order matters: check first (lock,
# version, state), then scheduler (enable/disable, needs check functions),
# then freshness (periodic checks), then status (needs all the above).
#######################################

# shellcheck source=./auto-update-helper-check.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/auto-update-helper-check.sh"

# shellcheck source=./auto-update-helper-scheduler.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/auto-update-helper-scheduler.sh"

# shellcheck source=./auto-update-freshness-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/auto-update-freshness-lib.sh"

# shellcheck source=./auto-update-helper-status.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/auto-update-helper-status.sh"

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	enable) cmd_enable "$@" ;;
	disable) cmd_disable "$@" ;;
	status) cmd_status "$@" ;;
	check) cmd_check "$@" ;;
	health-check) cmd_health_check "$@" ;;
	logs) cmd_logs "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
