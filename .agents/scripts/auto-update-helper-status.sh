#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Auto-Update Status Sub-Library -- Status display, health check, logs viewer,
# and help text.
# =============================================================================
# Extracted from auto-update-helper.sh to keep the orchestrator under the
# 1500-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/auto-update-helper-status.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, GREEN, YELLOW, NC, BOLD,
#     get_feature_toggle, is_feature_enabled, get_user_idle_seconds)
#   - auto-update-helper-check.sh (get_local_version)
#   - auto-update-helper-scheduler.sh (_get_scheduler_backend, _launchd_is_loaded,
#     _print_linger_status, _daemon_is_loaded)
#   - Orchestrator constants: LAUNCHD_LABEL, LAUNCHD_PLIST, SYSTEMD_SERVICE_DIR,
#     SYSTEMD_UNIT_NAME, CRON_MARKER, LOG_FILE, STATE_FILE, DEFAULT_INTERVAL,
#     DEFAULT_TOOL_IDLE_HOURS, SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AUTO_UPDATE_STATUS_LIB_LOADED:-}" ]] && return 0
_AUTO_UPDATE_STATUS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

# --- Functions ---

#######################################
# Print scheduler section of status output (launchd, systemd, or cron)
# Args: $1 = backend ("launchd", "systemd", or "cron")
#######################################
_cmd_status_scheduler() {
	local backend="$1"

	if [[ "$backend" == "launchd" ]]; then
		# macOS: show LaunchAgent status
		if _launchd_is_loaded; then
			local launchctl_info
			launchctl_info=$(launchctl list 2>/dev/null | grep -F "$LAUNCHD_LABEL" || true)
			local pid exit_code interval
			pid=$(echo "$launchctl_info" | awk '{print $1}')
			exit_code=$(echo "$launchctl_info" | awk '{print $2}')
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${GREEN}loaded${NC}"
			echo "  Label:     $LAUNCHD_LABEL"
			echo "  PID:       ${pid:--}"
			echo "  Last exit: ${exit_code:--}"
			if [[ -f "$LAUNCHD_PLIST" ]]; then
				interval=$(grep -A1 'StartInterval' "$LAUNCHD_PLIST" 2>/dev/null | grep integer | grep -oE '[0-9]+' || true)
				if [[ -n "$interval" ]]; then
					echo "  Interval:  every ${interval}s"
				fi
				echo "  Plist:     $LAUNCHD_PLIST"
			fi
		else
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${YELLOW}not loaded${NC}"
			if [[ -f "$LAUNCHD_PLIST" ]]; then
				echo "  Plist:     $LAUNCHD_PLIST (exists but not loaded)"
			fi
		fi
		# Also check for any lingering cron entry
		if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
			echo -e "  ${YELLOW}Note: legacy cron entry found — run 'aidevops auto-update disable && enable' to migrate${NC}"
		fi
	elif [[ "$backend" != "cron" ]]; then
		# Linux: show systemd user timer status (backend is "systemd" or future variant)
		if ! command -v systemctl &>/dev/null; then
			echo -e "  Scheduler: systemd (not available on this host)"
		else
			local enabled_state
			enabled_state=$(systemctl --user is-enabled "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null || echo "unknown")
			local timer_props next_elapse last_trigger
			# Request all NextElapse variants: NextElapse (pre-255) and
			# NextElapseUSecRealtime/NextElapseUSecMonotonic (systemd 255+)
			timer_props=$(systemctl --user show -p NextElapse,NextElapseUSecRealtime,NextElapseUSecMonotonic,LastTriggerUSec "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null || true)
			# Guard each grep with || true — under set -euo pipefail a no-match
			# exit 1 propagates and kills the entire script (GH#21541)
			next_elapse=$(echo "$timer_props" | grep '^NextElapse=' | cut -d= -f2- || true)
			if [[ -z "$next_elapse" ]]; then
				next_elapse=$(echo "$timer_props" | grep '^NextElapseUSecRealtime=' | cut -d= -f2- || true)
			fi
			if [[ -z "$next_elapse" ]]; then
				next_elapse=$(echo "$timer_props" | grep '^NextElapseUSecMonotonic=' | cut -d= -f2- || true)
			fi
			last_trigger=$(echo "$timer_props" | grep '^LastTriggerUSec=' | cut -d= -f2- || true)
			echo -e "  Scheduler: systemd (user timer)"
			if [[ "$enabled_state" == "enabled" ]] || [[ "$enabled_state" == "enabled-runtime" ]]; then
				echo -e "  Status:    ${GREEN}${enabled_state}${NC}"
			else
				echo -e "  Status:    ${YELLOW}${enabled_state}${NC}"
			fi
			echo "  Unit:      ${SYSTEMD_UNIT_NAME}.timer"
			if [[ -n "$next_elapse" ]] && [[ "$next_elapse" != "0" ]]; then
				echo "  Next fire: $next_elapse"
			fi
			if [[ -n "$last_trigger" ]] && [[ "$last_trigger" != "0" ]]; then
				echo "  Last fire: $last_trigger"
			fi
			echo "  Timer:     ${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.timer"
			echo "  Service:   ${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.service"
			_print_linger_status
		fi
		# Also check for any lingering cron entry
		if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
			echo -e "  ${YELLOW}Note: legacy cron entry found — run 'aidevops auto-update disable && enable' to migrate${NC}"
		fi
	else
		# Linux: show cron status
		if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
			local cron_entry
			cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_MARKER")
			echo -e "  Scheduler: cron"
			echo -e "  Status:    ${GREEN}enabled${NC}"
			echo "  Schedule:  $(echo "$cron_entry" | awk '{print $1, $2, $3, $4, $5}')"
		else
			echo -e "  Scheduler: cron"
			echo -e "  Status:    ${YELLOW}disabled${NC}"
		fi
	fi
	return 0
}

#######################################
# Print state file section of status output (last check, updates, idle)
# Reads STATE_FILE; no-op if file absent or jq unavailable.
#######################################
_cmd_status_state() {
	if ! [[ -f "$STATE_FILE" ]] || ! command -v jq &>/dev/null; then
		return 0
	fi

	local last_action last_ts last_status last_update last_update_ver last_skill_check skill_updates
	last_action=$(jq -r '.last_action // "none"' "$STATE_FILE" 2>/dev/null)
	last_ts=$(jq -r '.last_timestamp // "never"' "$STATE_FILE" 2>/dev/null)
	last_status=$(jq -r '.last_status // "unknown"' "$STATE_FILE" 2>/dev/null)
	last_update=$(jq -r '.last_update // "never"' "$STATE_FILE" 2>/dev/null)
	last_update_ver=$(jq -r '.last_update_version // "n/a"' "$STATE_FILE" 2>/dev/null)
	last_skill_check=$(jq -r '.last_skill_check // "never"' "$STATE_FILE" 2>/dev/null)
	skill_updates=$(jq -r '.skill_updates_applied // 0' "$STATE_FILE" 2>/dev/null)

	echo ""
	echo "  Last check:         $last_ts ($last_action: $last_status)"
	if [[ "$last_update" != "never" ]]; then
		echo "  Last update:        $last_update (v$last_update_ver)"
	fi
	echo "  Last skill check:   $last_skill_check"
	echo "  Skill updates:      $skill_updates applied (lifetime)"

	local last_openclaw_check
	last_openclaw_check=$(jq -r '.last_openclaw_check // "never"' "$STATE_FILE" 2>/dev/null)
	echo "  Last OpenClaw check: $last_openclaw_check"
	if command -v openclaw &>/dev/null; then
		local openclaw_ver
		openclaw_ver=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")
		echo "  OpenClaw version:   $openclaw_ver"
	fi

	local last_tool_check tool_updates_applied
	last_tool_check=$(jq -r '.last_tool_check // "never"' "$STATE_FILE" 2>/dev/null)
	tool_updates_applied=$(jq -r '.tool_updates_applied // 0' "$STATE_FILE" 2>/dev/null)
	echo "  Last tool check:    $last_tool_check"
	echo "  Tool updates:       $tool_updates_applied applied (lifetime)"

	# Show current user idle time
	local idle_secs idle_h idle_m
	idle_secs=$(get_user_idle_seconds)
	idle_h=$((idle_secs / 3600))
	idle_m=$(((idle_secs % 3600) / 60))
	# Read from JSONC config (handles env var > user config > defaults priority)
	local idle_threshold
	idle_threshold=$(get_feature_toggle tool_idle_hours "$DEFAULT_TOOL_IDLE_HOURS")
	# Validate idle_threshold is a positive integer (mirrors check_tool_freshness)
	if ! [[ "$idle_threshold" =~ ^[0-9]+$ ]] || [[ "$idle_threshold" -eq 0 ]]; then
		idle_threshold="$DEFAULT_TOOL_IDLE_HOURS"
	fi
	if [[ $idle_secs -ge $((idle_threshold * 3600)) ]]; then
		echo -e "  User idle:          ${idle_h}h${idle_m}m (${GREEN}>=${idle_threshold}h — tool updates eligible${NC})"
	else
		echo -e "  User idle:          ${idle_h}h${idle_m}m (${YELLOW}<${idle_threshold}h — tool updates deferred${NC})"
	fi
	return 0
}

#######################################
# Show status (platform-aware)
#######################################
cmd_status() {
	ensure_dirs

	local current
	current=$(get_local_version)

	local backend
	backend="$(_get_scheduler_backend)"

	echo ""
	echo -e "${BOLD:-}Auto-Update Status${NC}"
	echo "-------------------"
	echo ""

	_cmd_status_scheduler "$backend"

	echo "  Version:   v$current"

	_cmd_status_state

	# Check config overrides (env var or config file)
	if ! is_feature_enabled auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.auto_update disabled (overrides scheduler)${NC}"
	fi
	if ! is_feature_enabled skill_auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.skill_auto_update disabled${NC}"
	fi
	if ! is_feature_enabled openclaw_auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.openclaw_auto_update disabled${NC}"
	fi
	if ! is_feature_enabled tool_auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.tool_auto_update disabled${NC}"
	fi

	echo ""
	return 0
}

#######################################
# Health-check subcommand (t2898).
# Verifies the auto-update daemon is registered with the active scheduler
# AND has run within a reasonable freshness window.
#
# Exit codes:
#   0 — healthy (daemon loaded, recent successful run within 2× interval)
#   1 — degraded (daemon loaded but state-file is stale or unparseable)
#   2 — not installed (daemon not registered with the active scheduler)
#
# Output: human-readable status line + remediation command on stderr.
# Quiet mode: --quiet suppresses output; only the exit code matters
# (used by `cmd_enable --idempotent` to detect "already healthy").
#######################################
cmd_health_check() {
	local quiet=0
	local arg
	for arg in "$@"; do
		case "$arg" in
		--quiet | -q) quiet=1 ;;
		*) ;;
		esac
	done

	# Helper that prints to stderr unless --quiet was passed.
	_hc_say() {
		if [[ "$quiet" -eq 0 ]]; then
			printf '%s\n' "$*" >&2
		fi
		return 0
	}

	if ! _daemon_is_loaded; then
		_hc_say "auto-update daemon: NOT INSTALLED"
		_hc_say "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh enable"
		return 2
	fi

	# Loaded — check freshness via state file. Field is `last_timestamp`
	# (set on every cmd_check run, regardless of update outcome). The brief
	# referenced `last_run`; this is the actual deployed name.
	if ! [[ -f "$STATE_FILE" ]] || ! command -v jq &>/dev/null; then
		# State file absent or jq missing — daemon is loaded but we cannot
		# verify freshness. Treat as soft-healthy: the loaded check is the
		# primary signal; freshness is the secondary signal.
		_hc_say "auto-update daemon: LOADED (state file absent — freshness unknown)"
		return 0
	fi

	local last_ts
	last_ts=$(jq -r '.last_timestamp // empty' "$STATE_FILE" 2>/dev/null || echo "")

	if [[ -z "$last_ts" ]]; then
		# Loaded but never ran — fresh install before first cycle.
		_hc_say "auto-update daemon: LOADED (never run yet)"
		return 0
	fi

	# Convert ISO-8601 to epoch (handles both GNU and BSD date).
	local now_ts last_run_epoch
	now_ts=$(date -u '+%s')
	if last_run_epoch=$(date -u -d "$last_ts" '+%s' 2>/dev/null); then
		: # GNU date worked
	elif last_run_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_ts" '+%s' 2>/dev/null); then
		: # BSD date worked
	else
		_hc_say "auto-update daemon: LOADED (state file unparseable: '${last_ts}')"
		_hc_say "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh check"
		return 1
	fi

	local age_sec
	age_sec=$((now_ts - last_run_epoch))

	# Resolve interval the same way cmd_enable does so the threshold tracks
	# user config. 2× interval is the staleness window.
	local interval
	interval=$(get_feature_toggle update_interval "$DEFAULT_INTERVAL")
	if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
		interval="$DEFAULT_INTERVAL"
	fi
	local interval_sec=$((interval * 60))
	local stale_threshold=$((2 * interval_sec))

	if [[ "$age_sec" -gt "$stale_threshold" ]]; then
		_hc_say "auto-update daemon: STALLED (last run ${age_sec}s ago, expected every ${interval_sec}s)"
		_hc_say "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh check"
		return 1
	fi

	_hc_say "auto-update daemon: HEALTHY (last run ${age_sec}s ago)"
	return 0
}

#######################################
# View logs
#######################################
cmd_logs() {
	local tail_lines=50
	local _arg

	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--tail | -n)
			shift
			[[ $# -lt 1 ]] && {
				print_error "--tail requires a value"
				return 1
			}
			tail_lines="$1"
			shift
			;;
		--follow | -f)
			tail -f "$LOG_FILE" 2>/dev/null || print_info "No log file yet"
			return 0
			;;
		*) shift ;;
		esac
	done

	if [[ -f "$LOG_FILE" ]]; then
		tail -n "$tail_lines" "$LOG_FILE"
	else
		print_info "No log file yet (auto-update hasn't run)"
	fi
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'EOF'
auto-update-helper.sh - Automatic update polling for aidevops

USAGE:
    auto-update-helper.sh <command> [options]
    aidevops auto-update <command> [options]

COMMANDS:
    enable [--idempotent]  Install scheduler (launchd on macOS, cron on Linux)
                           --idempotent: no-op if already loaded (used by setup.sh)
    disable                Remove scheduler
    status                 Show current auto-update state
    check                  One-shot: check for updates and install if available
    health-check [--quiet] Verify daemon is loaded and ran recently
                           Exit: 0 healthy, 1 stalled, 2 not installed
    logs [--tail N]        View update logs (default: last 50 lines)
    logs --follow          Follow log output in real-time
    help                   Show this help

CONFIGURATION:
    Persistent settings: aidevops config set <key> <value>
    Per-session overrides: set the corresponding environment variable.

    JSONC key                          Env override                     Default
    updates.auto_update                AIDEVOPS_AUTO_UPDATE             true
    updates.update_interval_minutes    AIDEVOPS_UPDATE_INTERVAL         10
    updates.skill_auto_update          AIDEVOPS_SKILL_AUTO_UPDATE       true
    updates.skill_freshness_hours      AIDEVOPS_SKILL_FRESHNESS_HOURS   24
    updates.openclaw_auto_update       AIDEVOPS_OPENCLAW_AUTO_UPDATE    true
    updates.openclaw_freshness_hours   AIDEVOPS_OPENCLAW_FRESHNESS_HOURS 24
    updates.tool_auto_update           AIDEVOPS_TOOL_AUTO_UPDATE        true
    updates.tool_freshness_hours       AIDEVOPS_TOOL_FRESHNESS_HOURS    6
    updates.tool_idle_hours            AIDEVOPS_TOOL_IDLE_HOURS         6
    updates.upstream_watch             AIDEVOPS_UPSTREAM_WATCH          true
    updates.upstream_watch_hours       AIDEVOPS_UPSTREAM_WATCH_HOURS    24

SCHEDULER BACKENDS:
    macOS:  launchd LaunchAgent (~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist)
            - Native macOS scheduler, survives reboots without cron
            - Auto-migrates existing cron entries on first 'enable'
    Linux:  systemd user timer preferred (~/.config/systemd/user/aidevops-auto-update.timer)
            - Falls back to cron when systemctl --user is unavailable
            - Requires loginctl enable-linger $USER to run when logged out
            - Without linger, the timer stops when your last session ends
            - See 'aidevops auto-update status' for current linger state
    Linux:  cron fallback (crontab entry with # aidevops-auto-update marker)

HOW IT WORKS:
    1. Scheduler runs 'auto-update-helper.sh check' every 10 minutes
    2. Checks GitHub API for latest version (no CDN cache)
    3. If newer version found:
       a. Acquires lock (prevents concurrent updates)
       b. Runs git pull --ff-only
       c. Runs setup.sh --non-interactive to deploy agents
    4. Safe to run while AI sessions are active
    5. Skips if another update is already in progress
    6. Runs daily skill freshness check (24h gate):
       a. Reads last_skill_check from state file
       b. If >24h since last check, calls skill-update-helper.sh check --auto-update --quiet
       c. Updates last_skill_check timestamp in state file
       d. Runs on every cmd_check invocation (gate prevents excessive network calls)
    7. Runs daily OpenClaw update check (24h gate, if openclaw CLI is installed):
       a. Reads last_openclaw_check from state file
       b. If >24h since last check, runs openclaw update --yes --no-restart
       c. Respects user's configured channel (beta/dev/stable)
       d. Opt-out: AIDEVOPS_OPENCLAW_AUTO_UPDATE=false
    8. Runs 6-hourly tool freshness check (idle-gated):
       a. Reads last_tool_check from state file
       b. If >6h since last check AND user idle >6h, runs tool-version-check.sh --update --quiet
       c. Covers all installed tools: npm (OpenCode, MCP servers, etc.),
          brew (gh, glab, shellcheck, jq, etc.), pip (DSPy, crawl4ai, etc.)
       d. Idle detection: macOS IOKit HIDIdleTime, Linux xprintidle/dbus/w(1),
          headless servers treated as always idle
       e. Opt-out: AIDEVOPS_TOOL_AUTO_UPDATE=false

RATE LIMITS:
    GitHub API: 60 requests/hour (unauthenticated)
    10-min interval = 6 requests/hour (well within limits)
    Skill check: once per 24h per user (configurable via updates.skill_freshness_hours)
    OpenClaw check: once per 24h per user (configurable via updates.openclaw_freshness_hours)
    Tool check: once per 6h per user, only when idle (configurable via updates.tool_freshness_hours)
    Upstream watch: once per 24h per user (configurable via updates.upstream_watch_hours)

LOGS:
    ~/.aidevops/logs/auto-update.log

EOF
	return 0
}
