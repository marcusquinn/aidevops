#!/usr/bin/env bash
# pulse-session-helper.sh - Session-based pulse control
#
# Enables/disables the supervisor pulse for bounded work sessions.
# Users start the pulse when they begin working and stop it when done,
# avoiding unattended overnight API spend and unreviewed PR accumulation.
#
# Usage:
#   pulse-session-helper.sh start    # Enable pulse (create session flag)
#   pulse-session-helper.sh stop     # Graceful stop (let workers finish, then disable)
#   pulse-session-helper.sh status   # Show pulse session state
#   pulse-session-helper.sh help     # Show usage
#
# How it works:
#   - `start` creates a session flag file that pulse-wrapper.sh checks
#   - `stop` removes the flag and optionally waits for in-flight workers
#   - pulse-wrapper.sh skips the pulse cycle when the flag is absent
#   - The launchd plist stays loaded — it just becomes a no-op when disabled
#
# Flag file: ~/.aidevops/logs/pulse-session.flag
# Contains: started_at ISO timestamp, started_by username

set -euo pipefail

export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

# Configuration
readonly SESSION_FLAG="${HOME}/.aidevops/logs/pulse-session.flag"
readonly LOGFILE="${HOME}/.aidevops/logs/pulse.log"
readonly PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
readonly MAX_WORKERS_FILE="${HOME}/.aidevops/logs/pulse-max-workers"
readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly STOP_GRACE_PERIOD="${PULSE_STOP_GRACE_SECONDS:-300}" # 5 min default

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

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
	count=$(ps axo command | grep '/full-loop' | grep -v grep | grep -c '\.opencode') || count=0
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
		pid=$(cat "$PIDFILE" 2>/dev/null || echo "")
		if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
			return 0
		fi
	fi
	return 1
}

#######################################
# Get pulse-enabled repo count
#######################################
get_pulse_repo_count() {
	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		jq '[.initialized_repos[] | select(.pulse == true)] | length' "$REPOS_JSON" 2>/dev/null || echo "0"
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
		last_line=$(grep 'Starting pulse at' "$LOGFILE" 2>/dev/null | tail -1)
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
	if is_session_active; then
		local started_at
		started_at=$(grep '^started_at=' "$SESSION_FLAG" 2>/dev/null | cut -d= -f2)
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
		max_workers=$(cat "$MAX_WORKERS_FILE" 2>/dev/null || echo "?")
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
# 1. Remove the session flag (prevents new pulse cycles)
# 2. Wait for in-flight workers to finish (up to grace period)
# 3. Optionally kill remaining workers if --force is passed
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

	if ! is_session_active; then
		print_info "Pulse session is not active"
		return 0
	fi

	local started_at
	started_at=$(grep '^started_at=' "$SESSION_FLAG" 2>/dev/null | cut -d= -f2)

	# Remove session flag — this prevents new pulse cycles immediately
	rm -f "$SESSION_FLAG"

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	echo "[pulse-session] Session stopped at ${now_iso} (was started: ${started_at:-unknown})" >>"$LOGFILE"

	print_success "Pulse session stopped (no new pulse cycles will start)"

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
		done < <(ps axo pid,command | grep '/full-loop' | grep '\.opencode' | grep -v grep)

		if [[ "$killed" -gt 0 ]]; then
			print_info "Sent SIGTERM to ${killed} worker(s)"
			sleep 3

			# Check if any survived
			local remaining
			remaining=$(count_workers)
			if [[ "$remaining" -gt 0 ]]; then
				print_warning "${remaining} worker(s) still running after SIGTERM"
				echo "  They will finish their current operation and exit."
				echo "  Force kill with: kill -9 \$(ps axo pid,command | grep '/full-loop' | grep '.opencode' | grep -v grep | awk '{print \$1}')"
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
	echo -e "${BOLD}Pulse Session Status${NC}"
	echo "─────────────────────"
	echo ""

	# Session state
	if is_session_active; then
		local started_at started_by
		started_at=$(grep '^started_at=' "$SESSION_FLAG" 2>/dev/null | cut -d= -f2)
		started_by=$(grep '^started_by=' "$SESSION_FLAG" 2>/dev/null | cut -d= -f2)
		echo -e "  Session:     ${GREEN}active${NC}"
		echo "  Started:     ${started_at:-unknown}"
		echo "  Started by:  ${started_by:-unknown}"
	else
		echo -e "  Session:     ${YELLOW}inactive${NC} (pulse will skip cycles)"
	fi
	echo ""

	# Pulse process
	if is_pulse_running; then
		local pulse_pid
		pulse_pid=$(cat "$PIDFILE" 2>/dev/null || echo "?")
		echo -e "  Pulse:       ${GREEN}running${NC} (PID ${pulse_pid})"
	else
		echo -e "  Pulse:       ${BLUE}idle${NC} (waiting for next launchd cycle)"
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
		max_workers=$(cat "$MAX_WORKERS_FILE" 2>/dev/null || echo "?")
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
		ps axo pid,etime,command | grep '/full-loop' | grep '\.opencode' | grep -v grep | while IFS= read -r line; do
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
	if is_session_active; then
		echo "  Stop:  aidevops pulse stop"
		echo "  Force: aidevops pulse stop --force"
	else
		echo "  Start: aidevops pulse start"
	fi
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
pulse-session-helper.sh - Session-based pulse control

USAGE:
    aidevops pulse <command> [options]

COMMANDS:
    start              Enable the pulse for this work session
    stop [--force]     Gracefully stop the pulse session
    status             Show pulse session state, workers, repos

STOP OPTIONS:
    --force, -f        Send SIGTERM to workers immediately instead of waiting

ENVIRONMENT:
    PULSE_STOP_GRACE_SECONDS   Grace period for workers on stop (default: 300)

HOW IT WORKS:
    The supervisor pulse runs every 2 minutes via launchd. When no session
    is active, pulse-wrapper.sh skips the cycle (no-op). Starting a session
    creates a flag file that enables the pulse. Stopping removes the flag
    and optionally waits for in-flight workers to finish.

    This gives you bounded automation: the pulse runs while you're available
    to monitor outcomes, and stops when you're not.

EXAMPLES:
    aidevops pulse start           # Begin work session
    aidevops pulse status          # Check what's running
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
