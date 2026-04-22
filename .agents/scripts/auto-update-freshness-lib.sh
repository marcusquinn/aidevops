#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Auto-Update Freshness Library -- Periodic freshness checks for skills,
# OpenClaw, tools, upstream watches, venv health, and launchd plist drift.
# =============================================================================
# Extracted from auto-update-helper.sh to keep the orchestrator under the
# file-size-debt threshold. All functions are called from run_freshness_checks()
# which is invoked by cmd_check after the main aidevops update logic.
#
# Usage: source "${SCRIPT_DIR}/auto-update-freshness-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (is_feature_enabled, get_feature_toggle, print_error, etc.)
#   - auto-update-helper.sh globals: INSTALL_DIR, STATE_FILE, LOG_FILE,
#     DEFAULT_SKILL_FRESHNESS_HOURS, DEFAULT_OPENCLAW_FRESHNESS_HOURS,
#     DEFAULT_TOOL_FRESHNESS_HOURS, DEFAULT_TOOL_IDLE_HOURS,
#     DEFAULT_UPSTREAM_WATCH_HOURS, DEFAULT_VENV_HEALTH_HOURS
#   - auto-update-helper.sh functions: log_info, log_warn, log_error
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AUTO_UPDATE_FRESHNESS_LIB_LOADED:-}" ]] && return 0
_AUTO_UPDATE_FRESHNESS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (for test harnesses and direct sourcing)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Orchestrator — runs all freshness checks in sequence
# =============================================================================

run_freshness_checks() {
	check_skill_freshness
	check_openclaw_freshness
	check_tool_freshness
	check_upstream_watch
	check_venv_health
	# t2119: closes the deployment gap where setup-modules/schedulers.sh
	# gets updated in-place (via git pull) without a VERSION bump, so the
	# "up to date" branch of cmd_check never re-runs setup.sh and the
	# installed launchd plists stay stale. PR #19079 was invisible to
	# users for hours for exactly this reason.
	check_launchd_plist_drift
}

# =============================================================================
# Shared helpers — validation, locate, time gate, idle gate
# =============================================================================

#######################################
# Validate a freshness-hours config value is a positive integer.
# Returns the validated value on stdout; falls back to default if invalid.
# Args: $1 = config_key (e.g. "skill_freshness_hours")
#       $2 = default_value
#       $3 = config_prefix for log message (e.g. "updates.skill_freshness_hours")
#######################################
_get_validated_freshness_hours() {
	local config_key="$1"
	local default_value="$2"
	local config_prefix="$3"

	local hours
	hours=$(get_feature_toggle "$config_key" "$default_value")
	if ! [[ "$hours" =~ ^[0-9]+$ ]] || [[ "$hours" -eq 0 ]]; then
		log_warn "${config_prefix}='${hours}' is not a positive integer — using default (${default_value}h)"
		hours="$default_value"
	fi
	echo "$hours"
	return 0
}

#######################################
# Locate a helper script with fallback paths.
# Tries: deployed path, SCRIPT_DIR, INSTALL_DIR.
# Outputs the found path on stdout, or empty string if not found.
# Args: $1 = script filename (e.g. "skill-update-helper.sh")
#######################################
_locate_helper_script() {
	local filename="$1"

	local candidate="$HOME/.aidevops/agents/scripts/${filename}"
	if [[ -x "$candidate" ]]; then
		echo "$candidate"
		return 0
	fi

	candidate="${SCRIPT_DIR}/${filename}"
	if [[ -x "$candidate" ]]; then
		echo "$candidate"
		return 0
	fi

	candidate="$INSTALL_DIR/.agents/scripts/${filename}"
	if [[ -x "$candidate" ]]; then
		echo "$candidate"
		return 0
	fi

	echo ""
	return 0
}

#######################################
# Generic freshness time gate — checks if enough time has elapsed since
# the last check of a given type. Reads the timestamp from STATE_FILE
# using the provided jq field name.
# Outputs "skip" to stdout if gate not elapsed, "run" if check needed.
# Args: $1 = jq_field (e.g. "last_tool_check", "last_skill_check")
#       $2 = freshness_seconds
#       $3 = label for log message (e.g. "Tools", "Skills")
#######################################
_check_freshness_time_gate() {
	local jq_field="$1"
	local freshness_seconds="$2"
	local label="$3"

	local last_check=""
	if [[ -f "$STATE_FILE" ]] && command -v jq &>/dev/null; then
		last_check=$(jq -r ".${jq_field} // empty" "$STATE_FILE" 2>/dev/null || true)
	fi

	if [[ -n "$last_check" ]]; then
		local last_epoch now_epoch elapsed
		if [[ "$(uname)" == "Darwin" ]]; then
			# TZ=UTC: stored timestamps are UTC — macOS date -j ignores the Z suffix
			last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_check" "+%s" 2>/dev/null || echo "0")
		else
			last_epoch=$(date -d "$last_check" "+%s" 2>/dev/null || echo "0")
		fi
		now_epoch=$(date +%s)
		elapsed=$((now_epoch - last_epoch))

		if [[ $elapsed -lt $freshness_seconds ]]; then
			log_info "${label} checked ${elapsed}s ago (gate: ${freshness_seconds}s) — skipping"
			echo "skip"
			return 0
		fi
	fi

	echo "run"
	return 0
}

#######################################
# Check tool idle gate — only update when user is away
# Returns 0 if idle enough to proceed, 1 if user is active (defer).
# Args: none (reads config internally)
#######################################
_check_tool_idle_gate() {
	local idle_hours
	idle_hours=$(get_feature_toggle tool_idle_hours "$DEFAULT_TOOL_IDLE_HOURS")
	if ! [[ "$idle_hours" =~ ^[0-9]+$ ]] || [[ "$idle_hours" -eq 0 ]]; then
		log_warn "updates.tool_idle_hours='${idle_hours}' is not a positive integer — using default (${DEFAULT_TOOL_IDLE_HOURS}h)"
		idle_hours="$DEFAULT_TOOL_IDLE_HOURS"
	fi
	local idle_threshold_seconds
	idle_threshold_seconds=$((idle_hours * 3600))

	local user_idle_seconds
	user_idle_seconds=$(get_user_idle_seconds)
	if [[ $user_idle_seconds -lt $idle_threshold_seconds ]]; then
		local idle_h idle_m
		idle_h=$((user_idle_seconds / 3600))
		idle_m=$(((user_idle_seconds % 3600) / 60))
		log_info "User idle ${idle_h}h${idle_m}m (need ${idle_hours}h) — deferring tool updates"
		return 1
	fi

	# Export idle seconds for caller to use in log message
	echo "$user_idle_seconds"
	return 0
}

# =============================================================================
# Launchd plist drift detection (t2119)
# =============================================================================

#######################################
# t2119: Detect drift between the installed launchd plists and the
# current setup-modules/schedulers.sh template, then auto-repair by
# re-running setup.sh --non-interactive.
#
# Strategy: hash setup-modules/schedulers.sh itself and compare against
# the hash recorded by the last setup.sh run. Whole-file hash is the
# simplest signal that any plist-generating change has occurred (FD
# limits, env vars, StartInterval, labels) — no per-plist hashing or
# subshell sourcing needed, and it naturally covers every LaunchAgent
# that schedulers.sh installs (supervisor-pulse, process-guard,
# memory-pressure, etc.).
#
# Bootstrap case: when no stored hash exists, we treat the state as
# drifted on first run. This self-heals existing installs that pre-date
# t2119 without requiring a user action.
#
# Rate-limited to once per 6 hours so auto-update cycles don't
# repeatedly run setup.sh — setup.sh is idempotent but does ~20
# scheduler operations per run and isn't free.
#
# macOS only — systemd-user and cron paths don't have the same
# deployment gap (setup.sh regenerates unit files on every run and
# users typically restart them explicitly).
#######################################
check_launchd_plist_drift() {
	[[ "$(uname -s)" == "Darwin" ]] || return 0

	local state_dir="$HOME/.aidevops/.agent-workspace/tmp"
	local check_stamp="$state_dir/plist-drift-check.stamp"
	mkdir -p "$state_dir" 2>/dev/null || return 0

	# Rate-limit to once per 6 hours. Overridable via env for tests and
	# opt-out scenarios.
	local drift_check_interval="${AIDEVOPS_PLIST_DRIFT_CHECK_INTERVAL:-21600}"
	if [[ -f "$check_stamp" ]]; then
		local last_check now
		last_check=$(cat "$check_stamp" 2>/dev/null || echo 0)
		now=$(date +%s)
		if ((now - last_check < drift_check_interval)); then
			return 0
		fi
	fi

	local schedulers_src="$INSTALL_DIR/setup-modules/schedulers.sh"
	local hash_state="$state_dir/schedulers-template-hash.state"

	if [[ ! -f "$schedulers_src" ]]; then
		date +%s >"$check_stamp"
		return 0
	fi

	local current_hash
	current_hash=$(shasum -a 256 "$schedulers_src" 2>/dev/null | awk '{print $1}')
	if [[ -z "$current_hash" ]]; then
		log_warn "Plist drift check: failed to hash $schedulers_src — skipping"
		date +%s >"$check_stamp"
		return 0
	fi

	local stored_hash=""
	if [[ -f "$hash_state" ]]; then
		stored_hash=$(cat "$hash_state" 2>/dev/null || echo "")
	fi

	if [[ -n "$stored_hash" && "$current_hash" == "$stored_hash" ]]; then
		log_info "Plist drift check: template hash unchanged (${current_hash:0:12}) — no drift"
		date +%s >"$check_stamp"
		return 0
	fi

	log_info "Plist drift detected: stored='${stored_hash:-<none>}' current='${current_hash:0:12}' — running setup.sh --non-interactive to regenerate (t2119)"
	local _setup_exit=0
	bash "$INSTALL_DIR/setup.sh" --non-interactive >>"$LOG_FILE" 2>&1 || _setup_exit=$?
	if [[ "$_setup_exit" -eq 0 ]]; then
		log_info "Plist drift repaired via setup.sh --non-interactive (t2119)"
	else
		log_warn "Plist drift repair: setup.sh --non-interactive exited $_setup_exit"
	fi
	date +%s >"$check_stamp"
	return 0
}

# =============================================================================
# Skill freshness (24h gate)
# =============================================================================

#######################################
# Execute skill update and return count of updates applied.
# Args: $1 = path to skill-update-helper.sh
# Outputs: update count on stdout
#######################################
_run_skill_update() {
	local skill_update_script="$1"
	local skill_updates=0

	if "$skill_update_script" check --auto-update --quiet >>"$LOG_FILE" 2>&1; then
		log_info "Skill freshness check complete (all up to date)"
	else
		# Exit code 1 means updates were available (and applied) — not an error
		# Count updated skills via JSON check (best-effort)
		skill_updates=$("$skill_update_script" check --json 2>/dev/null |
			jq -r '.updates_available // 0' 2>/dev/null || echo "1")
		log_info "Skill freshness check complete ($skill_updates updates applied)"
	fi
	echo "$skill_updates"
	return 0
}

check_skill_freshness() {
	# Opt-out via config (env var or config file)
	if ! is_feature_enabled skill_auto_update 2>/dev/null; then
		log_info "Skill auto-update disabled via config"
		return 0
	fi

	local freshness_hours
	freshness_hours=$(_get_validated_freshness_hours "skill_freshness_hours" "$DEFAULT_SKILL_FRESHNESS_HOURS" "updates.skill_freshness_hours")
	local freshness_seconds=$((freshness_hours * 3600))

	# Time gate: skip if checked recently
	local gate_result
	gate_result=$(_check_freshness_time_gate "last_skill_check" "$freshness_seconds" "Skills")
	if [[ "$gate_result" == "skip" ]]; then
		return 0
	fi

	# Locate skill-update-helper.sh
	local skill_update_script
	skill_update_script=$(_locate_helper_script "skill-update-helper.sh")
	if [[ -z "$skill_update_script" ]]; then
		log_warn "skill-update-helper.sh not found — skipping skill freshness check"
		return 0
	fi

	# Check if skill-sources.json exists (no skills imported = nothing to do)
	local skill_sources="$HOME/.aidevops/agents/configs/skill-sources.json"
	if [[ ! -f "$skill_sources" ]]; then
		log_info "No imported skills found — skipping skill freshness check"
		update_skill_check_timestamp
		return 0
	fi

	log_info "Running daily skill freshness check..."
	local skill_updates
	skill_updates=$(_run_skill_update "$skill_update_script")
	update_skill_check_timestamp "$skill_updates"
	return 0
}

#######################################
# Record last_skill_check timestamp and updates count in state file
# Args: $1 = number of skill updates applied (default: 0)
#######################################
update_skill_check_timestamp() {
	local updates_count="${1:-0}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			jq --arg ts "$timestamp" \
				--argjson count "$updates_count" \
				'. + {last_skill_check: $ts} |
				.skill_updates_applied = ((.skill_updates_applied // 0) + $count)' \
				"$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg ts "$timestamp" \
				--argjson count "$updates_count" \
				'{last_skill_check: $ts, skill_updates_applied: $count}' >"$STATE_FILE"
		fi
	fi
	return 0
}

# =============================================================================
# OpenClaw freshness (24h gate)
# =============================================================================

#######################################
# Execute the openclaw update command and log results.
# Handles channel detection and version comparison.
#######################################
_run_openclaw_update() {
	local before_version after_version
	before_version=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")

	# Determine update channel from openclaw config (default: current channel)
	local -a update_cmd=(openclaw update --yes --no-restart)
	local openclaw_channel=""
	openclaw_channel=$(openclaw update status 2>/dev/null | grep "Channel" | sed 's/[^a-zA-Z]*Channel[^a-zA-Z]*//' | awk '{print $1}' || true)
	if [[ "$openclaw_channel" =~ ^(beta|dev)$ ]]; then
		update_cmd=(openclaw update --channel "$openclaw_channel" --yes --no-restart)
	fi

	if "${update_cmd[@]}" >>"$LOG_FILE" 2>&1; then
		after_version=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")
		if [[ "$before_version" != "$after_version" ]]; then
			log_info "OpenClaw updated: $before_version -> $after_version"
		else
			log_info "OpenClaw already up to date ($before_version)"
		fi
	else
		log_warn "OpenClaw update failed (exit code: $?)"
	fi
	return 0
}

check_openclaw_freshness() {
	# Opt-out via config (env var or config file)
	if ! is_feature_enabled openclaw_auto_update 2>/dev/null; then
		log_info "OpenClaw auto-update disabled via config"
		return 0
	fi

	# Skip if openclaw is not installed
	if ! command -v openclaw &>/dev/null; then
		return 0
	fi

	local freshness_hours
	freshness_hours=$(_get_validated_freshness_hours "openclaw_freshness_hours" "$DEFAULT_OPENCLAW_FRESHNESS_HOURS" "updates.openclaw_freshness_hours")
	local freshness_seconds=$((freshness_hours * 3600))

	# Time gate: skip if checked recently
	local gate_result
	gate_result=$(_check_freshness_time_gate "last_openclaw_check" "$freshness_seconds" "OpenClaw")
	if [[ "$gate_result" == "skip" ]]; then
		return 0
	fi

	log_info "Running daily OpenClaw update check..."
	_run_openclaw_update
	update_openclaw_check_timestamp
	return 0
}

#######################################
# Record last_openclaw_check timestamp in state file
#######################################
update_openclaw_check_timestamp() {
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			jq --arg ts "$timestamp" \
				'. + {last_openclaw_check: $ts}' \
				"$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg ts "$timestamp" \
				'{last_openclaw_check: $ts}' >"$STATE_FILE"
		fi
	fi
	return 0
}

# =============================================================================
# User idle detection (cross-platform)
# =============================================================================

#######################################
# Get macOS idle time via IOKit HIDIdleTime (nanoseconds).
# Outputs idle seconds on stdout, or empty string if unavailable.
#######################################
_get_idle_seconds_macos() {
	local idle_ns
	idle_ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {gsub(/[^0-9]/, "", $NF); print $NF; exit}')
	if [[ -n "$idle_ns" && "$idle_ns" =~ ^[0-9]+$ ]]; then
		echo "$((idle_ns / 1000000000))"
		return 0
	fi
	echo "0"
	return 0
}

#######################################
# Get Linux idle time via xprintidle (X11) or dbus (Wayland).
# Outputs idle seconds on stdout, or empty string if unavailable.
#######################################
_get_idle_seconds_linux_desktop() {
	local idle_ms idle_secs

	# xprintidle: X11, most accurate for desktop
	if command -v xprintidle &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
		idle_ms=$(xprintidle 2>/dev/null || echo "")
		if [[ -n "$idle_ms" && "$idle_ms" =~ ^[0-9]+$ ]]; then
			echo "$((idle_ms / 1000))"
			return 0
		fi
	fi

	# dbus-send: GNOME/KDE screensaver (Wayland-compatible)
	if command -v dbus-send &>/dev/null && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
		idle_secs=$(dbus-send --session --dest=org.gnome.ScreenSaver \
			--type=method_call --print-reply /org/gnome/ScreenSaver \
			org.gnome.ScreenSaver.GetSessionIdleTime 2>/dev/null |
			awk '/uint32/ {print $2}')
		if [[ -n "$idle_secs" && "$idle_secs" =~ ^[0-9]+$ && "$idle_secs" -gt 0 ]]; then
			echo "$idle_secs"
			return 0
		fi
	fi

	echo ""
	return 0
}

#######################################
# Parse a single w(1) idle field into seconds.
# w IDLE formats: "3:42" (min:sec), "2days", "23:15m", "0.50s", "5s"
# Args: $1 = idle field string
# Outputs: seconds on stdout
#######################################
_parse_w_idle_field() {
	local idle_field="$1"
	local parsed=0

	if [[ "$idle_field" =~ ^([0-9]+)days$ ]]; then
		# Use 10# prefix to force base-10 (avoids octal interpretation of "08", "09")
		parsed=$((10#${BASH_REMATCH[1]} * 86400))
	elif [[ "$idle_field" =~ ^([0-9]+):([0-9]+)m$ ]]; then
		parsed=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60))
	elif [[ "$idle_field" =~ ^([0-9]+):([0-9]+)$ ]]; then
		parsed=$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
	elif [[ "$idle_field" =~ ^([0-9]+)\.([0-9]+)s$ ]]; then
		parsed=$((10#${BASH_REMATCH[1]}))
	elif [[ "$idle_field" =~ ^([0-9]+)s$ ]]; then
		parsed=$((10#${BASH_REMATCH[1]}))
	fi

	echo "$parsed"
	return 0
}

#######################################
# Get Linux idle time from w(1) — shortest session idle (TTY/SSH).
# Outputs idle seconds on stdout, or empty string if no users found.
#######################################
_get_idle_seconds_linux_w() {
	if ! command -v w &>/dev/null; then
		echo ""
		return 0
	fi

	local min_idle=999999
	local found_user=false
	local idle_field
	local _user _tty _from _login _jcpu _pcpu _what
	while read -r _user _tty _from _login idle_field _jcpu _pcpu _what; do
		[[ "$_user" == "USER" ]] && continue
		[[ -z "$idle_field" ]] && continue
		found_user=true

		local parsed
		parsed=$(_parse_w_idle_field "$idle_field")
		if [[ $parsed -lt $min_idle ]]; then
			min_idle=$parsed
		fi
	done < <(w -h 2>/dev/null || w 2>/dev/null)

	if [[ "$found_user" == "true" ]]; then
		echo "$min_idle"
		return 0
	fi

	echo ""
	return 0
}

#######################################
# Get user idle time in seconds (cross-platform dispatcher).
# Delegates to platform-specific sub-functions.
# Returns: idle seconds on stdout, 0 on error (safe default = "user active")
#######################################
get_user_idle_seconds() {
	# macOS: IOKit HIDIdleTime (always available, even over SSH)
	if [[ "$(uname)" == "Darwin" ]]; then
		_get_idle_seconds_macos
		return 0
	fi

	# Linux desktop: xprintidle (X11) or dbus (Wayland)
	local desktop_idle
	desktop_idle=$(_get_idle_seconds_linux_desktop)
	if [[ -n "$desktop_idle" ]]; then
		echo "$desktop_idle"
		return 0
	fi

	# Linux TTY/SSH: parse w(1) for shortest session idle
	local w_idle
	w_idle=$(_get_idle_seconds_linux_w)
	if [[ -n "$w_idle" ]]; then
		echo "$w_idle"
		return 0
	fi

	# Headless server: no display, no logged-in users — treat as idle
	if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
		echo "999999"
		return 0
	fi

	# Fallback: cannot determine — assume active (safe default)
	echo "0"
	return 0
}

# =============================================================================
# Tool freshness (6h gate, idle-gated)
# =============================================================================

#######################################
# Check tool freshness and auto-update if stale (6h gate)
# Only runs when user has been idle for AIDEVOPS_TOOL_IDLE_HOURS.
# Delegates to tool-version-check.sh --update --quiet.
# Called from cmd_check after other freshness checks.
# Respects config: aidevops config set updates.tool_auto_update false
#######################################
#######################################
# Execute tool-version-check.sh and count updates applied.
# Args: $1 = path to tool-version-check.sh
# Outputs: update count on stdout
#######################################
_run_tool_update() {
	local tool_check_script="$1"

	local update_output
	update_output=$("$tool_check_script" --update --quiet 2>&1) || true

	if [[ -n "$update_output" ]]; then
		echo "$update_output" >>"$LOG_FILE"
	fi

	# Count updates from output (best-effort: count lines with "Updated" or arrow)
	# Use a subshell to avoid pipefail issues: grep -c exits 1 on no match,
	# which under set -o pipefail would trigger || echo "0" and produce "0\n0"
	local tool_updates=0
	if [[ -n "$update_output" ]]; then
		tool_updates=$(echo "$update_output" | { grep -cE '(Updated|→|->)' || true; })
	fi

	echo "$tool_updates"
	return 0
}

check_tool_freshness() {
	# Opt-out via config (env var or config file)
	if ! is_feature_enabled tool_auto_update 2>/dev/null; then
		log_info "Tool auto-update disabled via config"
		return 0
	fi

	local freshness_hours
	freshness_hours=$(_get_validated_freshness_hours "tool_freshness_hours" "$DEFAULT_TOOL_FRESHNESS_HOURS" "updates.tool_freshness_hours")
	local freshness_seconds=$((freshness_hours * 3600))

	# Time gate: skip if checked recently
	local gate_result
	gate_result=$(_check_freshness_time_gate "last_tool_check" "$freshness_seconds" "Tools")
	if [[ "$gate_result" == "skip" ]]; then
		return 0
	fi

	# Idle gate: only update when user is away
	local user_idle_seconds
	user_idle_seconds=$(_check_tool_idle_gate) || return 0

	# Locate tool-version-check.sh
	local tool_check_script
	tool_check_script=$(_locate_helper_script "tool-version-check.sh")
	if [[ -z "$tool_check_script" ]]; then
		log_warn "tool-version-check.sh not found — skipping tool freshness check"
		return 0
	fi

	log_info "Running tool freshness check (user idle ${user_idle_seconds}s)..."
	local tool_updates
	tool_updates=$(_run_tool_update "$tool_check_script")

	if [[ $tool_updates -gt 0 ]]; then
		log_info "Tool freshness check complete ($tool_updates tools updated)"
	else
		log_info "Tool freshness check complete (all up to date)"
	fi

	update_tool_check_timestamp "$tool_updates"
	return 0
}

#######################################
# Record last_tool_check timestamp and updates count in state file
# Args: $1 = number of tool updates applied (default: 0)
#######################################
update_tool_check_timestamp() {
	local updates_count
	updates_count="${1:-0}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			jq --arg ts "$timestamp" \
				--argjson count "$updates_count" \
				'. + {last_tool_check: $ts} |
				.tool_updates_applied = ((.tool_updates_applied // 0) + $count)' \
				"$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg ts "$timestamp" \
				--argjson count "$updates_count" \
				'{last_tool_check: $ts, tool_updates_applied: $count}' >"$STATE_FILE"
		fi
	fi
	return 0
}

# =============================================================================
# Upstream watch (24h gate)
# =============================================================================

#######################################
# Locate upstream-watch-helper.sh and verify watchlist has repos.
# Outputs script path on stdout if ready, empty string if not.
# Also updates timestamp and returns early if no repos to watch.
#######################################
_locate_upstream_watch() {
	local agents_dir="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
	local upstream_watch_script="${agents_dir}/scripts/upstream-watch-helper.sh"
	if [[ ! -x "$upstream_watch_script" ]]; then
		upstream_watch_script="$INSTALL_DIR/.agents/scripts/upstream-watch-helper.sh"
	fi

	if [[ ! -x "$upstream_watch_script" ]]; then
		log_info "upstream-watch-helper.sh not found — skipping upstream watch check"
		echo ""
		return 0
	fi

	# Check if upstream-watch.json has any repos
	local watch_config="${agents_dir}/configs/upstream-watch.json"
	if [[ ! -f "$watch_config" ]]; then
		log_info "No upstream watch config found — skipping"
		update_upstream_watch_timestamp
		echo ""
		return 0
	fi

	local repo_count
	repo_count=$(jq '.repos | length' "$watch_config" 2>/dev/null || echo "0")
	if [[ "$repo_count" -eq 0 ]]; then
		log_info "No repos in upstream watchlist — skipping"
		update_upstream_watch_timestamp
		echo ""
		return 0
	fi

	echo "$upstream_watch_script"
	return 0
}

check_upstream_watch() {
	# Opt-out via config (env var or config file)
	if ! is_feature_enabled upstream_watch; then
		log_info "Upstream watch disabled via config"
		return 0
	fi

	local freshness_hours
	freshness_hours=$(_get_validated_freshness_hours "upstream_watch_hours" "$DEFAULT_UPSTREAM_WATCH_HOURS" "updates.upstream_watch_hours")
	local freshness_seconds=$((freshness_hours * 3600))

	# Time gate: skip if checked recently
	local gate_result
	gate_result=$(_check_freshness_time_gate "last_upstream_watch_check" "$freshness_seconds" "Upstream watch")
	if [[ "$gate_result" == "skip" ]]; then
		return 0
	fi

	local upstream_watch_script
	upstream_watch_script=$(_locate_upstream_watch)
	if [[ -z "$upstream_watch_script" ]]; then
		return 0
	fi

	local agents_dir="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
	local watch_config="${agents_dir}/configs/upstream-watch.json"
	local repo_count
	repo_count=$(jq '.repos | length' "$watch_config" 2>/dev/null || echo "0")

	log_info "Running daily upstream watch check (${repo_count} repos)..."
	if "$upstream_watch_script" check >>"$LOG_FILE" 2>&1; then
		log_info "Upstream watch check complete"
		update_upstream_watch_timestamp
	else
		log_warn "Upstream watch check had errors (exit code: $?) — will retry next run"
	fi
	return 0
}

#######################################
# Record last_upstream_watch_check timestamp in state file
#######################################
update_upstream_watch_timestamp() {
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			if ! jq --arg ts "$timestamp" \
				'. + {last_upstream_watch_check: $ts}' \
				"$STATE_FILE" >"$tmp_state" 2>&1; then
				log_warn "Failed to update upstream watch timestamp (jq error on state file)"
				return 1
			fi
			mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg ts "$timestamp" \
				'{last_upstream_watch_check: $ts}' >"$STATE_FILE"
		fi
	fi
	return 0
}

# =============================================================================
# Venv health (24h gate)
# =============================================================================

#######################################
# Check Python venv health across managed repos (24h gate).
# Delegates to venv-health-check-helper.sh scan --quiet.
# Logs broken/warning venvs; healthy venvs are silent.
# Called from run_freshness_checks after upstream watch.
# Respects config: aidevops config set updates.venv_health_check false
#######################################
check_venv_health() {
	# Opt-out via config (env var or config file)
	if ! is_feature_enabled venv_health_check 2>/dev/null; then
		log_info "Venv health check disabled via config"
		return 0
	fi

	local freshness_hours
	freshness_hours=$(_get_validated_freshness_hours "venv_health_hours" "$DEFAULT_VENV_HEALTH_HOURS" "updates.venv_health_hours")
	local freshness_seconds=$((freshness_hours * 3600))

	# Time gate: skip if checked recently
	local gate_result
	gate_result=$(_check_freshness_time_gate "last_venv_health_check" "$freshness_seconds" "Venv health")
	if [[ "$gate_result" == "skip" ]]; then
		return 0
	fi

	# Locate venv-health-check-helper.sh
	local venv_health_script
	venv_health_script=$(_locate_helper_script "venv-health-check-helper.sh")
	if [[ -z "$venv_health_script" ]]; then
		log_info "venv-health-check-helper.sh not found — skipping venv health check"
		return 0
	fi

	log_info "Running daily venv health check..."
	local venv_output
	local venv_rc=0
	venv_output=$("$venv_health_script" scan --quiet 2>&1) || venv_rc=$?

	if [[ -n "$venv_output" ]]; then
		echo "$venv_output" >>"$LOG_FILE"
	fi

	if [[ $venv_rc -ne 0 ]]; then
		log_warn "Venv health check found issues (exit code: $venv_rc) — see log for details"
	else
		log_info "Venv health check complete (all healthy)"
	fi

	update_venv_health_timestamp
	return 0
}

#######################################
# Record last_venv_health_check timestamp in state file
#######################################
update_venv_health_timestamp() {
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			if ! jq --arg ts "$timestamp" \
				'. + {last_venv_health_check: $ts}' \
				"$STATE_FILE" >"$tmp_state" 2>&1; then
				log_warn "Failed to update venv health timestamp (jq error on state file)"
				return 1
			fi
			mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg ts "$timestamp" \
				'{last_venv_health_check: $ts}' >"$STATE_FILE"
		fi
	fi
	return 0
}
