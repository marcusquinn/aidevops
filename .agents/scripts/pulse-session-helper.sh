#!/usr/bin/env bash
# pulse-session-helper.sh - Pulse consent and session control
#
# Controls the supervisor pulse via a layered consent model:
#   1. Stop flag  (~/.aidevops/logs/pulse-session.stop)  — highest priority, pauses pulse
#   2. Session flag (~/.aidevops/logs/pulse-session.flag) — explicit start, doesn't survive reboots
#   3. Config consent (orchestration.supervisor_pulse=true) — persistent, survives reboots
#
# Usage:
#   pulse-session-helper.sh start    # Clear stop flag, create session flag
#   pulse-session-helper.sh stop     # Create stop flag, remove session flag, wait for workers
#   pulse-session-helper.sh status   # Show consent layers, workers, repos
#   pulse-session-helper.sh help     # Show usage
#
# The launchd plist stays loaded — pulse-wrapper.sh checks these consent
# layers on each cycle and skips if none grant permission.

set -euo pipefail

export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

# Source config-helper for _jsonc_get (shared JSONC config reader)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config-helper.sh
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true

# Configuration
readonly SESSION_FLAG="${HOME}/.aidevops/logs/pulse-session.flag"
readonly STOP_FLAG="${HOME}/.aidevops/logs/pulse-session.stop"
readonly LOGFILE="${HOME}/.aidevops/logs/pulse.log"
readonly PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
readonly MAX_WORKERS_FILE="${HOME}/.aidevops/logs/pulse-max-workers"
readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly STOP_GRACE_PERIOD="${PULSE_STOP_GRACE_SECONDS:-300}" # 5 min default

# Colors — shared-constants.sh (via config-helper.sh) may have already set these
# as readonly. Only define if not already present to avoid readonly collisions.
[[ -z "${GREEN+x}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${BLUE+x}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${YELLOW+x}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && readonly RED='\033[0;31m'
[[ -z "${BOLD+x}" ]] && readonly BOLD='\033[1m'
[[ -z "${NC+x}" ]] && readonly NC='\033[0m'

# Ensure log directory exists
mkdir -p "$(dirname "$SESSION_FLAG")"

#######################################
# Print helpers
#######################################
print_info() {
	echo -e "${BLUE}[INFO]${NC} $1"
	return 0
}
print_success() {
	echo -e "${GREEN}[OK]${NC} $1"
	return 0
}
print_warning() {
	echo -e "${YELLOW}[WARN]${NC} $1"
	return 0
}
print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
	return 0
}

#######################################
# Check if pulse session is active
# Returns: 0 if active, 1 if not
#######################################
is_session_active() {
	if [[ -f "$SESSION_FLAG" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Count active worker processes
# Returns: count via stdout
#######################################
count_workers() {
	local count
	count=$(ps axo command | grep '[/]full-loop' | grep -c '\.opencode') || count=0
	echo "$count"
	return 0
}

#######################################
# Check if a pulse process is currently running
# Returns: 0 if running, 1 if not
#######################################
is_pulse_running() {
	if [[ -f "$PIDFILE" ]]; then
		local pid
		pid=$(cat "$PIDFILE" || echo "")
		if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
			return 0
		fi
	fi
	return 1
}

#######################################
# Check if config consent is enabled
# Delegates to config_enabled from config-helper.sh (sourced above),
# which handles: env var override (AIDEVOPS_SUPERVISOR_PULSE) >
# user JSONC config > defaults JSONC config. Single canonical
# implementation shared with pulse-wrapper.sh via shared-constants.sh.
# Returns: 0 if enabled, 1 if not
#######################################
is_config_consent_enabled() {
	if type config_enabled &>/dev/null; then
		config_enabled "orchestration.supervisor_pulse"
		return $?
	fi
	# Fallback if config-helper.sh failed to load entirely
	return 1
}

#######################################
# Get pulse-enabled repo count
#######################################
get_pulse_repo_count() {
	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		jq '[.initialized_repos[] | select(.pulse == true)] | length' "$REPOS_JSON" || echo "0"
	else
		echo "?"
	fi
	return 0
}

#######################################
# Get last pulse timestamp from log
#######################################
get_last_pulse_time() {
	if [[ -f "$LOGFILE" ]]; then
		local last_line
		last_line=$(grep 'Starting pulse at' "$LOGFILE" | tail -1)
		if [[ -n "$last_line" ]]; then
			echo "$last_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | tail -1
			return 0
		fi
	fi
	echo "never"
	return 0
}

#######################################
# Start pulse session
#######################################
cmd_start() {
	# Remove stop flag if present (user is explicitly resuming)
	rm -f "$STOP_FLAG"

	if is_session_active; then
		local started_at
		started_at=$(grep '^started_at=' "$SESSION_FLAG" | cut -d= -f2)
		print_warning "Pulse session already active (started: ${started_at:-unknown})"
		echo ""
		echo "  To restart: aidevops pulse stop && aidevops pulse start"
		return 0
	fi

	# Create session flag
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local user
	user=$(whoami)

	cat >"$SESSION_FLAG" <<EOF
started_at=${now_iso}
started_by=${user}
EOF

	echo "[pulse-session] Session started at ${now_iso} by ${user}" >>"$LOGFILE"

	local repo_count
	repo_count=$(get_pulse_repo_count)
	local max_workers="?"
	if [[ -f "$MAX_WORKERS_FILE" ]]; then
		max_workers=$(cat "$MAX_WORKERS_FILE" || echo "?")
	fi

	print_success "Pulse session started"
	echo ""
	echo "  Repos in scope: ${repo_count}"
	echo "  Max workers:    ${max_workers}"
	echo "  Pulse interval: every 2 minutes (via launchd)"
	echo ""
	echo "  The pulse will run on the next launchd cycle."
	echo "  Stop with: aidevops pulse stop"
	return 0
}

#######################################
# Stop pulse session (graceful)
#
# 1. Create stop flag (overrides all consent layers)
# 2. Remove the session flag
# 3. Wait for in-flight workers to finish (up to grace period)
# 4. Optionally kill remaining workers if --force is passed
#######################################
cmd_stop() {
	local force=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force | -f)
			force=true
			shift
			;;
		*)
			shift
			;;
		esac
	done

	# Check if already stopped — but allow --force through so it can kill workers
	if [[ -f "$STOP_FLAG" ]] && ! is_session_active; then
		local worker_count_check
		worker_count_check=$(count_workers)
		if [[ "$force" != "true" ]] && [[ "$worker_count_check" -eq 0 ]] && ! is_pulse_running; then
			print_info "Pulse is already stopped"
			return 0
		fi
	fi

	# If no session flag and no config consent, nothing to stop
	if ! is_session_active && ! is_config_consent_enabled; then
		print_info "Pulse is not enabled (no session flag, no config consent)"
		return 0
	fi

	local started_at=""
	if is_session_active; then
		started_at=$(grep '^started_at=' "$SESSION_FLAG" | cut -d= -f2)
	fi

	# Create stop flag — this overrides all consent layers immediately
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local user
	user=$(whoami)
	cat >"$STOP_FLAG" <<EOF
stopped_at=${now_iso}
stopped_by=${user}
EOF

	# Also remove session flag for clean state
	rm -f "$SESSION_FLAG"

	echo "[pulse-session] Session stopped at ${now_iso} (was started: ${started_at:-unknown})" >>"$LOGFILE"

	print_success "Pulse stopped (no new pulse cycles will start)"

	# Check for in-flight workers
	local worker_count
	worker_count=$(count_workers)

	if [[ "$worker_count" -eq 0 ]]; then
		print_success "No active workers — clean shutdown"
		return 0
	fi

	echo ""
	print_info "${worker_count} worker(s) still running"

	if [[ "$force" == "true" ]]; then
		print_warning "Force mode: sending SIGTERM to all workers..."
		# Kill worker processes gracefully
		local killed=0
		while IFS= read -r line; do
			local pid
			pid=$(echo "$line" | awk '{print $1}')
			if [[ -n "$pid" ]]; then
				kill "$pid" 2>/dev/null || true
				killed=$((killed + 1))
			fi
		done < <(ps axo pid,command | grep '[/]full-loop' | grep '\.opencode')

		if [[ "$killed" -gt 0 ]]; then
			print_info "Sent SIGTERM to ${killed} worker(s)"
			sleep 3

			# Check if any survived
			local remaining
			remaining=$(count_workers)
			if [[ "$remaining" -gt 0 ]]; then
				print_warning "${remaining} worker(s) still running after SIGTERM"
				echo "  They will finish their current operation and exit."
				echo "  Force kill with: kill -9 \$(ps axo pid,command | grep '[/]full-loop' | grep '\\.opencode' | awk '{print \$1}')"
			else
				print_success "All workers stopped"
			fi
		fi
		return 0
	fi

	# Graceful mode: wait for workers to finish
	echo "  Workers will complete their current PR/commit cycle."
	echo "  No new work will be dispatched."
	echo ""
	echo "  Waiting up to ${STOP_GRACE_PERIOD}s for workers to finish..."
	echo "  (Ctrl+C to stop waiting — workers will continue in background)"
	echo "  (Use --force to send SIGTERM immediately)"
	echo ""

	local elapsed=0
	local poll_interval=10
	while [[ "$elapsed" -lt "$STOP_GRACE_PERIOD" ]]; do
		worker_count=$(count_workers)
		if [[ "$worker_count" -eq 0 ]]; then
			print_success "All workers finished — clean shutdown"
			return 0
		fi
		printf "\r  %d worker(s) still running... (%ds/%ds)" "$worker_count" "$elapsed" "$STOP_GRACE_PERIOD"
		sleep "$poll_interval"
		elapsed=$((elapsed + poll_interval))
	done

	echo ""
	worker_count=$(count_workers)
	if [[ "$worker_count" -gt 0 ]]; then
		print_warning "${worker_count} worker(s) still running after grace period"
		echo "  They will continue in the background until they finish."
		echo "  No new work will be dispatched."
		echo "  Force stop: aidevops pulse stop --force"
	else
		print_success "All workers finished — clean shutdown"
	fi
	return 0
}

#######################################
# Show pulse session status
#######################################
cmd_status() {
	echo -e "${BOLD}Pulse Status${NC}"
	echo "────────────"
	echo ""

	# Consent layers (mirrors check_session_gate() in pulse-wrapper.sh)
	local effective_state="disabled"
	local effective_reason=""

	# Layer 1: Stop flag (highest priority — overrides everything)
	local has_stop_flag=false
	if [[ -f "$STOP_FLAG" ]]; then
		has_stop_flag=true
	fi

	# Layer 2: Session flag (explicit user action)
	local has_session_flag=false
	if is_session_active; then
		has_session_flag=true
	fi

	# Layer 3: Config consent (persistent, survives reboots)
	local has_config_consent=false
	if is_config_consent_enabled; then
		has_config_consent=true
	fi

	# Determine effective state
	if [[ "$has_stop_flag" == "true" ]]; then
		effective_state="stopped"
		effective_reason="stop flag (aidevops pulse stop)"
	elif [[ "$has_session_flag" == "true" ]]; then
		effective_state="enabled"
		effective_reason="session flag (aidevops pulse start)"
	elif [[ "$has_config_consent" == "true" ]]; then
		effective_state="enabled"
		effective_reason="config consent (orchestration.supervisor_pulse=true)"
	else
		effective_state="disabled"
		effective_reason="no consent layer active"
	fi

	# Display effective state
	if [[ "$effective_state" == "enabled" ]]; then
		echo -e "  Pulse:       ${GREEN}enabled${NC} via ${effective_reason}"
	elif [[ "$effective_state" == "stopped" ]]; then
		echo -e "  Pulse:       ${RED}stopped${NC} via ${effective_reason}"
	else
		echo -e "  Pulse:       ${YELLOW}disabled${NC} (${effective_reason})"
	fi

	# Show consent layer details
	# Sanitize values from flag files to prevent terminal escape injection
	echo ""
	echo -e "  ${BOLD}Consent layers:${NC}"
	if [[ "$has_stop_flag" == "true" ]]; then
		local stopped_at
		stopped_at=$(grep '^stopped_at=' "$STOP_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]T:Z.+-')
		echo -e "    Stop flag:      ${RED}set${NC} (${stopped_at:-unknown})"
	else
		echo -e "    Stop flag:      ${GREEN}clear${NC}"
	fi
	if [[ "$has_session_flag" == "true" ]]; then
		local started_at started_by
		started_at=$(grep '^started_at=' "$SESSION_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]T:Z.+-')
		started_by=$(grep '^started_by=' "$SESSION_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]._-')
		echo -e "    Session flag:   ${GREEN}active${NC} (${started_at:-unknown} by ${started_by:-unknown})"
	else
		echo -e "    Session flag:   ${YELLOW}inactive${NC}"
	fi
	if [[ "$has_config_consent" == "true" ]]; then
		echo -e "    Config consent: ${GREEN}enabled${NC}"
	else
		echo -e "    Config consent: ${YELLOW}disabled${NC}"
	fi
	echo ""

	# Pulse process
	if is_pulse_running; then
		local pulse_pid
		pulse_pid=$(cat "$PIDFILE" || echo "?")
		echo -e "  Process:     ${GREEN}running${NC} (PID ${pulse_pid})"
	else
		echo -e "  Process:     ${BLUE}idle${NC} (waiting for next launchd cycle)"
	fi

	# Workers
	local worker_count
	worker_count=$(count_workers)
	if [[ "$worker_count" -gt 0 ]]; then
		echo -e "  Workers:     ${GREEN}${worker_count} active${NC}"
	else
		echo "  Workers:     0"
	fi

	# Max workers
	local max_workers="?"
	if [[ -f "$MAX_WORKERS_FILE" ]]; then
		max_workers=$(cat "$MAX_WORKERS_FILE" || echo "?")
	fi
	echo "  Max workers: ${max_workers}"

	# Repos
	local repo_count
	repo_count=$(get_pulse_repo_count)
	echo "  Repos:       ${repo_count} pulse-enabled"

	# Last pulse
	local last_pulse
	last_pulse=$(get_last_pulse_time)
	echo "  Last pulse:  ${last_pulse}"

	echo ""

	# Worker details (if any)
	if [[ "$worker_count" -gt 0 ]]; then
		echo -e "${BOLD}Active Workers${NC}"
		echo "──────────────"
		echo ""
		ps axo pid,etime,command | grep '[/]full-loop' | grep '\.opencode' | while IFS= read -r line; do
			local w_pid w_etime w_cmd
			read -r w_pid w_etime w_cmd <<<"$line"

			# Extract title
			local w_title="untitled"
			if [[ "$w_cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$w_cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
				w_title="${BASH_REMATCH[1]}"
			fi

			echo "  PID ${w_pid} (${w_etime}): ${w_title}"
		done
		echo ""
	fi

	# Hint
	if [[ "$effective_state" == "enabled" ]]; then
		echo "  Stop:  aidevops pulse stop"
		echo "  Force: aidevops pulse stop --force"
	elif [[ "$effective_state" == "stopped" ]]; then
		echo "  Resume: aidevops pulse start"
	else
		echo "  Start:  aidevops pulse start"
		echo "  Or set: orchestration.supervisor_pulse=true in config.jsonc"
	fi
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
pulse-session-helper.sh - Pulse consent and session control

USAGE:
    aidevops pulse <command> [options]

COMMANDS:
    start              Enable the pulse (clears stop flag, creates session flag)
    stop [--force]     Stop the pulse (creates stop flag, removes session flag)
    status             Show consent layers, workers, repos

STOP OPTIONS:
    --force, -f        Send SIGTERM to workers immediately instead of waiting

ENVIRONMENT:
    PULSE_STOP_GRACE_SECONDS   Grace period for workers on stop (default: 300)
    AIDEVOPS_SUPERVISOR_PULSE  Override config consent (true/false)

HOW IT WORKS:
    The supervisor pulse runs every 2 minutes via launchd/cron. Whether it
    actually does work depends on a layered consent model (checked in order):

    1. Stop flag (~/.aidevops/logs/pulse-session.stop)
       Highest priority. If present, pulse is paused regardless of other
       layers. Created by 'aidevops pulse stop', cleared by 'start'.

    2. Session flag (~/.aidevops/logs/pulse-session.flag)
       Explicit user action. Created by 'aidevops pulse start'.
       Does NOT survive reboots — use for bounded work sessions.

    3. Config consent (orchestration.supervisor_pulse=true)
       Persistent setting in ~/.config/aidevops/config.jsonc.
       Survives reboots — the pulse runs unattended after reboot.
       Set during 'aidevops init' or manually in config.

    If none of the above are set, the pulse skips (no-op).

    For unattended operation: set config consent and don't use start/stop.
    For bounded sessions: use 'aidevops pulse start' and 'stop'.
    To pause temporarily: 'aidevops pulse stop' (overrides config consent).

EXAMPLES:
    aidevops pulse start           # Enable pulse for this session
    aidevops pulse status          # Show consent layers and workers
    aidevops pulse stop            # Graceful stop (wait for workers)
    aidevops pulse stop --force    # Stop immediately

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
	start) cmd_start ;;
	stop) cmd_stop "$@" ;;
	status | s) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		echo "Run 'aidevops pulse help' for usage."
		return 1
		;;
	esac
}

main "$@"
