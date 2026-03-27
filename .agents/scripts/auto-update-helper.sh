#!/usr/bin/env bash
# auto-update-helper.sh - Automatic update polling daemon for aidevops
#
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
# Detect scheduler backend for current platform
# Returns: "launchd" on macOS, "cron" on Linux/other
#######################################
_get_scheduler_backend() {
	if [[ "$(uname)" == "Darwin" ]]; then
		echo "launchd"
	else
		echo "cron"
	fi
	return 0
}

#######################################
# Check if the auto-update LaunchAgent is loaded
# Returns: 0 if loaded, 1 if not
#######################################
_launchd_is_loaded() {
	# Use a variable to avoid SIGPIPE (141) when grep -q exits early
	# under set -o pipefail (t1265)
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$LAUNCHD_LABEL"
	return $?
}

#######################################
# Generate auto-update LaunchAgent plist content
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#   $3 - env_path
#######################################
_generate_auto_update_plist() {
	local script_path="$1"
	local interval_seconds="$2"
	local env_path="$3"

	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${script_path}</string>
		<string>check</string>
	</array>
	<key>StartInterval</key>
	<integer>${interval_seconds}</integer>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${env_path}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
EOF
	return 0
}

#######################################
# Migrate existing cron entry to launchd (macOS only)
# Called automatically when cmd_enable runs on macOS
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#######################################
_migrate_cron_to_launchd() {
	local script_path="$1"
	local interval_seconds="$2"

	# Check if cron entry exists
	if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
		return 0
	fi

	# Skip migration if launchd agent already loaded (t1265)
	if _launchd_is_loaded; then
		log_info "LaunchAgent already loaded — removing stale cron entry only"
	else
		log_info "Migrating auto-update from cron to launchd..."

		# Generate and write plist
		mkdir -p "$LAUNCHD_DIR"
		_generate_auto_update_plist "$script_path" "$interval_seconds" "${PATH}" >"$LAUNCHD_PLIST"

		# Load into launchd
		if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
			log_info "LaunchAgent loaded: $LAUNCHD_LABEL"
		else
			log_error "Failed to load LaunchAgent during migration"
			return 1
		fi
	fi

	# Remove old cron entry
	local temp_cron
	temp_cron=$(mktemp)
	if crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron"; then
		crontab "$temp_cron"
	else
		crontab -r 2>/dev/null || true
	fi
	rm -f "$temp_cron"

	log_info "Migration complete: auto-update now managed by launchd"
	return 0
}

#######################################
# Lock management (prevents concurrent updates)
# Uses mkdir for atomic locking (POSIX-safe)
#######################################
acquire_lock() {
	local max_wait=30
	local waited=0

	while [[ $waited -lt $max_wait ]]; do
		if mkdir "$LOCK_FILE" 2>/dev/null; then
			echo $$ >"$LOCK_FILE/pid"
			return 0
		fi

		# Check for stale lock
		if [[ -f "$LOCK_FILE/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
			if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
				log_warn "Removing stale lock (PID $lock_pid dead)"
				rm -rf "$LOCK_FILE"
				continue
			fi
		fi

		# Check lock age (safety net for orphaned locks)
		if [[ -d "$LOCK_FILE" ]]; then
			local lock_age
			if [[ "$(uname)" == "Darwin" ]]; then
				lock_age=$(($(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo "0")))
			else
				lock_age=$(($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo "0")))
			fi
			if [[ $lock_age -gt 300 ]]; then
				log_warn "Removing stale lock (age ${lock_age}s > 300s)"
				rm -rf "$LOCK_FILE"
				continue
			fi
		fi

		sleep 1
		waited=$((waited + 1))
	done

	log_error "Failed to acquire lock after ${max_wait}s"
	return 1
}

release_lock() {
	rm -rf "$LOCK_FILE"
	return 0
}

#######################################
# Get local version
#######################################
get_local_version() {
	local version_file="$INSTALL_DIR/VERSION"
	if [[ -r "$version_file" ]]; then
		cat "$version_file"
	else
		echo "unknown"
	fi
	return 0
}

#######################################
# Get remote version (from GitHub API)
# Tries authenticated gh api first (5000 req/hr), then unauthenticated curl
# (60 req/hr), then raw.githubusercontent.com CDN fallback.
# See: #4142 — 106 "remote=unknown" failures from rate-limited unauth API
#######################################
get_remote_version() {
	local version=""

	# Prefer authenticated gh api (higher rate limit: 5000/hr vs 60/hr)
	# This avoids the "remote=unknown" failures seen during overnight polling
	# when unauthenticated API quota is exhausted.
	# See: https://github.com/marcusquinn/aidevops/issues/4142
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		version=$(gh api repos/marcusquinn/aidevops/contents/VERSION \
			--jq '.content' 2>/dev/null |
			base64 -d 2>/dev/null |
			tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi

	# Fallback: unauthenticated curl (60 req/hr limit)
	if command -v jq &>/dev/null; then
		version=$(curl --proto '=https' -fsSL --max-time 10 \
			"https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null |
			jq -r '.content // empty' 2>/dev/null |
			base64 -d 2>/dev/null |
			tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi

	# Last resort: raw.githubusercontent.com (CDN-cached, may be up to 5 min stale)
	curl --proto '=https' -fsSL --max-time 10 \
		"https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null |
		tr -d '\n' || echo "unknown"
	return 0
}

#######################################
# Check if setup.sh or aidevops update is already running
#######################################
is_update_running() {
	# Check for running setup.sh processes (not our own)
	# Use full path to avoid matching unrelated projects' setup.sh scripts
	if pgrep -f "${INSTALL_DIR}/setup\.sh" >/dev/null 2>&1; then
		return 0
	fi
	# Check for running aidevops update
	if pgrep -f "aidevops update" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Update state file with last check/update info
#######################################
update_state() {
	local action="$1"
	local version="${2:-}"
	local status="${3:-success}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			jq --arg action "$action" \
				--arg version "$version" \
				--arg status "$status" \
				--arg ts "$timestamp" \
				'. + {
                   last_action: $action,
                   last_version: $version,
                   last_status: $status,
                   last_timestamp: $ts
               } | if $action == "update" and $status == "success" then
                   . + {last_update: $ts, last_update_version: $version}
               else . end' "$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg action "$action" \
				--arg version "$version" \
				--arg status "$status" \
				--arg ts "$timestamp" \
				'{
                      enabled: true,
                      last_action: $action,
                      last_version: $version,
                      last_status: $status,
                      last_timestamp: $ts,
                      last_skill_check: null,
                      skill_updates_applied: 0
                  }' >"$STATE_FILE"
		fi
	fi
	return 0
}

#######################################
# Run all periodic freshness checks (skills, OpenClaw, tools, upstream watch).
# Extracted to avoid duplicating the same 4-call block at every exit point
# in cmd_check(). Each check has its own internal time gate.
#######################################
run_freshness_checks() {
	check_skill_freshness
	check_openclaw_freshness
	check_tool_freshness
	check_upstream_watch
	check_venv_health
}

#######################################
# Check skill freshness and auto-update if stale (24h gate)
# Called from cmd_check after the main aidevops update logic.
# Respects config: aidevops config set updates.skill_auto_update false
#######################################
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

#######################################
# Check openclaw freshness and auto-update if stale (24h gate)
# Called from cmd_check after skill freshness check.
# Respects config: aidevops config set updates.openclaw_auto_update false
# Only runs if openclaw CLI is installed.
#######################################
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

#######################################
# Check upstream-watched repos for new releases (24h gate)
# Called from cmd_check after tool freshness check.
# Respects config: aidevops config set updates.upstream_watch false
#######################################
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

#######################################
# Handle stale deployed agents when repo version matches remote.
# Checks VERSION mismatch and sentinel script hash drift; re-deploys if needed.
# Args: $1 = current version string
#######################################
_cmd_check_stale_agent_redeploy() {
	local current="$1"

	# Even when repo matches remote, deployed agents may be stale
	# (e.g., previous setup.sh was interrupted or failed silently)
	# See: https://github.com/marcusquinn/aidevops/issues/3980
	local deployed_version
	deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
	if [[ "$current" != "$deployed_version" ]]; then
		log_warn "Deployed agents stale ($deployed_version), re-deploying..."
		if bash "$INSTALL_DIR/setup.sh" --non-interactive >>"$LOG_FILE" 2>&1; then
			local redeployed_version
			redeployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
			if [[ "$current" == "$redeployed_version" ]]; then
				log_info "Agents re-deployed successfully ($deployed_version -> $redeployed_version)"
			else
				log_error "Agent re-deploy incomplete: repo=$current, deployed=$redeployed_version"
			fi
		else
			log_error "setup.sh failed during stale-agent re-deploy (exit code: $?)"
		fi
		return 0
	fi

	# VERSION matches but scripts may still differ — a script fix merged without
	# a version bump leaves the deployed copy stale until setup.sh is run manually.
	# Detect this by comparing SHA-256 of a sentinel script that is frequently
	# patched (gh-failure-miner-helper.sh). If it drifts, re-deploy all agents.
	# GH#4727: Codacy not_collected false-positive recurred because the fix in
	# PR #4704 was not deployed to ~/.aidevops/ before the next pulse cycle.
	local sentinel_repo="$INSTALL_DIR/.agents/scripts/gh-failure-miner-helper.sh"
	local sentinel_deployed="$HOME/.aidevops/agents/scripts/gh-failure-miner-helper.sh"
	if [[ -f "$sentinel_repo" && -f "$sentinel_deployed" ]]; then
		local hash_repo hash_deployed
		hash_repo=$(sha256sum "$sentinel_repo" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$sentinel_repo" 2>/dev/null | awk '{print $1}' || echo "")
		hash_deployed=$(sha256sum "$sentinel_deployed" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$sentinel_deployed" 2>/dev/null | awk '{print $1}' || echo "")
		if [[ -n "$hash_repo" && -n "$hash_deployed" && "$hash_repo" != "$hash_deployed" ]]; then
			log_warn "Script drift detected (sentinel hash mismatch at v$current) — re-deploying agents..."
			if bash "$INSTALL_DIR/setup.sh" --non-interactive >>"$LOG_FILE" 2>&1; then
				log_info "Agents re-deployed after script drift (v$current)"
			else
				log_error "setup.sh failed during script-drift re-deploy (exit code: $?)"
			fi
		fi
	fi
	return 0
}

#######################################
# Perform git fetch/pull/reset to bring INSTALL_DIR to origin/main.
# Handles dirty working tree, detached HEAD, and ff-only failures.
# Args: $1 = remote version (for state updates on failure)
# Returns: 0 on success, 1 on unrecoverable failure
#######################################
_cmd_check_git_update() {
	local remote="$1"

	# Clean up any working tree changes left by setup.sh or other processes
	# (e.g., chmod on tracked scripts, scan results written to repo)
	# This ensures git pull --ff-only won't be blocked by dirty files.
	# See: https://github.com/marcusquinn/aidevops/issues/2286
	if ! git -C "$INSTALL_DIR" diff --quiet 2>/dev/null || ! git -C "$INSTALL_DIR" diff --cached --quiet 2>/dev/null; then
		log_info "Cleaning up stale working tree changes..."
		if ! git -C "$INSTALL_DIR" reset HEAD -- . 2>>"$LOG_FILE"; then
			log_warn "git reset HEAD failed during working tree cleanup"
		fi
		if ! git -C "$INSTALL_DIR" checkout -- . 2>>"$LOG_FILE"; then
			log_warn "git checkout -- . failed during working tree cleanup"
		fi
	fi

	# Ensure we're on the main branch (detached HEAD or stale branch blocks pull)
	# Mirrors recovery logic from aidevops.sh cmd_update()
	# See: https://github.com/marcusquinn/aidevops/issues/4142
	local current_branch
	current_branch=$(git -C "$INSTALL_DIR" branch --show-current 2>/dev/null || echo "")
	if [[ "$current_branch" != "main" ]]; then
		log_info "Not on main branch ($current_branch), switching..."
		if ! git -C "$INSTALL_DIR" checkout main --quiet 2>>"$LOG_FILE" &&
			! git -C "$INSTALL_DIR" checkout -b main origin/main --quiet 2>>"$LOG_FILE"; then
			log_error "Failed to switch to main branch from '$current_branch' in $INSTALL_DIR"
			update_state "update" "$remote" "branch_switch_failed"
			return 1
		fi
	fi

	# Pull latest changes
	if ! git -C "$INSTALL_DIR" fetch origin main --quiet 2>>"$LOG_FILE"; then
		log_error "git fetch failed"
		update_state "update" "$remote" "fetch_failed"
		return 1
	fi

	if ! git -C "$INSTALL_DIR" pull --ff-only origin main --quiet 2>>"$LOG_FILE"; then
		# Fast-forward failed (diverged history or persistent dirty state).
		# Since we just fetched origin/main, reset to it — the repo is managed
		# by aidevops and should always track origin/main exactly.
		# See: https://github.com/marcusquinn/aidevops/issues/2288
		log_warn "git pull --ff-only failed — falling back to reset"
		if git -C "$INSTALL_DIR" reset --hard origin/main --quiet 2>>"$LOG_FILE"; then
			log_info "Reset to origin/main succeeded"
		else
			log_error "git reset --hard origin/main also failed"
			update_state "update" "$remote" "pull_failed"
			return 1
		fi
	fi
	return 0
}

#######################################
# Perform the actual update: git pull, setup.sh deploy, verify, cleanup.
# Args: $1 = current version, $2 = remote version
# Returns: 0 on success, 1 on failure
#######################################
_cmd_check_perform_update() {
	local current="$1"
	local remote="$2"

	log_info "Update available: v$current -> v$remote"
	update_state "update_start" "$remote" "in_progress"

	# Verify install directory exists and is a git repo
	if [[ ! -d "$INSTALL_DIR/.git" ]]; then
		log_error "Install directory is not a git repo: $INSTALL_DIR"
		update_state "update" "$remote" "no_git_repo"
		return 1
	fi

	if ! _cmd_check_git_update "$remote"; then
		return 1
	fi

	# Run setup.sh non-interactively to deploy agents
	log_info "Running setup.sh --non-interactive..."
	if ! bash "$INSTALL_DIR/setup.sh" --non-interactive >>"$LOG_FILE" 2>&1; then
		log_error "setup.sh failed (exit code: $?)"
		update_state "update" "$remote" "setup_failed"
		return 1
	fi

	# Verify agents were actually deployed (setup.sh may exit 0 without deploying)
	# See: https://github.com/marcusquinn/aidevops/issues/3980
	local new_version deployed_version
	new_version=$(get_local_version)
	deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
	if [[ "$new_version" != "$deployed_version" ]]; then
		log_warn "Update pulled v$new_version but agents at v$deployed_version — deployment incomplete"
		update_state "update" "$new_version" "agents_stale"
	else
		log_info "Update complete: v$current -> v$new_version (agents deployed)"
		update_state "update" "$new_version" "success"
	fi

	# Clean up any working tree changes setup.sh may have introduced
	# See: https://github.com/marcusquinn/aidevops/issues/2286
	if ! git -C "$INSTALL_DIR" checkout -- . 2>>"$LOG_FILE"; then
		log_warn "Post-setup working tree cleanup failed — next update cycle may see dirty state"
	fi
	return 0
}

#######################################
# One-shot check and update
# This is what the cron job calls
#######################################
#######################################
# Acquire lock and verify preconditions for cmd_check.
# Returns: 0 if ready to proceed, 1 if should skip
#######################################
_cmd_check_acquire() {
	# Respect config (env var or config file)
	if ! is_feature_enabled auto_update 2>/dev/null; then
		log_info "Auto-update disabled via config (updates.auto_update)"
		return 1
	fi

	# Skip if another update is already running
	if is_update_running; then
		log_info "Another update process is running, skipping"
		return 1
	fi

	# Acquire lock
	if ! acquire_lock; then
		log_warn "Could not acquire lock, skipping check"
		return 1
	fi
	return 0
}

cmd_check() {
	ensure_dirs

	if ! _cmd_check_acquire; then
		return 0
	fi
	trap 'release_lock' EXIT

	local current remote
	current=$(get_local_version)
	remote=$(get_remote_version)
	log_info "Version check: local=$current remote=$remote"

	if [[ "$current" == "unknown" || "$remote" == "unknown" ]]; then
		log_warn "Could not determine versions (local=$current, remote=$remote)"
		update_state "check" "$current" "version_unknown"
		run_freshness_checks
		return 0
	fi

	if [[ "$current" == "$remote" ]]; then
		log_info "Already up to date (v$current)"
		update_state "check" "$current" "up_to_date"
		_cmd_check_stale_agent_redeploy "$current"
		run_freshness_checks
		return 0
	fi

	if ! _cmd_check_perform_update "$current" "$remote"; then
		run_freshness_checks
		return 1
	fi

	run_freshness_checks
	return 0
}

#######################################
# Install auto-update as a macOS LaunchAgent
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success, 1 on failure
#######################################
_cmd_enable_launchd() {
	local script_path="$1"
	local interval="$2"
	local interval_seconds=$((interval * 60))

	# Migrate from old label if present (t1260)
	local old_label="com.aidevops.auto-update"
	local old_plist="${LAUNCHD_DIR}/${old_label}.plist"
	if launchctl list 2>/dev/null | grep -qF "$old_label"; then
		launchctl unload -w "$old_plist" 2>/dev/null || true
		log_info "Unloaded old LaunchAgent: $old_label"
	fi
	rm -f "$old_plist"

	# Auto-migrate existing cron entry if present
	_migrate_cron_to_launchd "$script_path" "$interval_seconds"

	mkdir -p "$LAUNCHD_DIR"

	# Create named symlink so macOS System Settings shows "aidevops-auto-update"
	# instead of the raw script name (t1260)
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-auto-update"
	ln -sf "$script_path" "$display_link"

	# Generate plist content and compare to existing (t1265)
	local new_content
	new_content=$(_generate_auto_update_plist "$display_link" "$interval_seconds" "${PATH}")

	# Skip if already loaded with identical config (avoids macOS notification)
	if _launchd_is_loaded && [[ -f "$LAUNCHD_PLIST" ]]; then
		local existing_content
		existing_content=$(cat "$LAUNCHD_PLIST" 2>/dev/null) || existing_content=""
		if [[ "$existing_content" == "$new_content" ]]; then
			print_info "Auto-update LaunchAgent already installed with identical config ($LAUNCHD_LABEL)"
			update_state "enable" "$(get_local_version)" "enabled"
			return 0
		fi
		# Loaded but config differs — don't overwrite while running
		print_info "Auto-update LaunchAgent already loaded ($LAUNCHD_LABEL)"
		update_state "enable" "$(get_local_version)" "enabled"
		return 0
	fi

	echo "$new_content" >"$LAUNCHD_PLIST"

	if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
		update_state "enable" "$(get_local_version)" "enabled"
		print_success "Auto-update enabled (every ${interval} minutes)"
		echo ""
		echo "  Scheduler: launchd (macOS LaunchAgent)"
		echo "  Label:     $LAUNCHD_LABEL"
		echo "  Plist:     $LAUNCHD_PLIST"
		echo "  Script:    $script_path"
		echo "  Logs:      $LOG_FILE"
		echo ""
		echo "  Disable with: aidevops auto-update disable"
		echo "  Check now:    aidevops auto-update check"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		return 1
	fi
	return 0
}

#######################################
# Install auto-update as a Linux cron entry
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success
#######################################
_cmd_enable_cron() {
	local script_path="$1"
	local interval="$2"

	# Build cron expression
	local cron_expr="*/${interval} * * * *"
	local cron_line="$cron_expr $script_path check >> $LOG_FILE 2>&1 $CRON_MARKER"

	# Get existing crontab (excluding our entry)
	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true

	# Add our entry and install
	echo "$cron_line" >>"$temp_cron"
	crontab "$temp_cron"
	rm -f "$temp_cron"

	update_state "enable" "$(get_local_version)" "enabled"

	print_success "Auto-update enabled (every ${interval} minutes)"
	echo ""
	echo "  Schedule: $cron_expr"
	echo "  Script:   $script_path"
	echo "  Logs:     $LOG_FILE"
	echo ""
	echo "  Disable with: aidevops auto-update disable"
	echo "  Check now:    aidevops auto-update check"
	return 0
}

#######################################
# Enable auto-update scheduler (platform-aware)
# On macOS: installs LaunchAgent plist
# On Linux: installs crontab entry
#######################################
cmd_enable() {
	ensure_dirs

	# Read from JSONC config (handles env var > user config > defaults priority)
	local interval
	interval=$(get_feature_toggle update_interval "$DEFAULT_INTERVAL")
	# Validate interval is a positive integer
	if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
		log_warn "updates.update_interval_minutes='${interval}' is not a positive integer — using default (${DEFAULT_INTERVAL}m)"
		interval="$DEFAULT_INTERVAL"
	fi
	local script_path="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"

	# Verify the script exists at the deployed location
	if [[ ! -x "$script_path" ]]; then
		# Fall back to repo location
		script_path="$INSTALL_DIR/.agents/scripts/auto-update-helper.sh"
		if [[ ! -x "$script_path" ]]; then
			print_error "auto-update-helper.sh not found"
			return 1
		fi
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		_cmd_enable_launchd "$script_path" "$interval"
		return $?
	fi

	_cmd_enable_cron "$script_path" "$interval"
	return $?
}

#######################################
# Disable auto-update scheduler (platform-aware)
# On macOS: unloads and removes LaunchAgent plist
# On Linux: removes crontab entry
#######################################
cmd_disable() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		local had_entry=false

		if _launchd_is_loaded; then
			had_entry=true
			launchctl unload -w "$LAUNCHD_PLIST" 2>/dev/null || true
		fi

		if [[ -f "$LAUNCHD_PLIST" ]]; then
			had_entry=true
			rm -f "$LAUNCHD_PLIST"
		fi

		# Also remove any lingering cron entry (migration cleanup)
		if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
			local temp_cron
			temp_cron=$(mktemp)
			crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron" || true
			crontab "$temp_cron"
			rm -f "$temp_cron"
			had_entry=true
		fi

		update_state "disable" "$(get_local_version)" "disabled"

		if [[ "$had_entry" == "true" ]]; then
			print_success "Auto-update disabled"
		else
			print_info "Auto-update was not enabled"
		fi
		return 0
	fi

	# Linux: cron backend
	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	local had_entry=false
	if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
		had_entry=true
	fi

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true
	crontab "$temp_cron"
	rm -f "$temp_cron"

	update_state "disable" "$(get_local_version)" "disabled"

	if [[ "$had_entry" == "true" ]]; then
		print_success "Auto-update disabled"
	else
		print_info "Auto-update was not enabled"
	fi
	return 0
}

#######################################
# Print scheduler section of status output (launchd or cron)
# Args: $1 = backend ("launchd" or "cron")
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
# View logs
#######################################
cmd_logs() {
	local tail_lines=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tail | -n)
			[[ $# -lt 2 ]] && {
				print_error "--tail requires a value"
				return 1
			}
			tail_lines="$2"
			shift 2
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
    enable              Install scheduler (launchd on macOS, cron on Linux)
    disable             Remove scheduler
    status              Show current auto-update state
    check               One-shot: check for updates and install if available
    logs [--tail N]     View update logs (default: last 50 lines)
    logs --follow       Follow log output in real-time
    help                Show this help

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
    Linux:  cron (crontab entry with # aidevops-auto-update marker)

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
