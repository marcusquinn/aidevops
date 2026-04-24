#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-watchdog.sh — Detect and kill hung/idle headless AI workers (t1419)
#
# Solves: Headless workers dispatched manually (outside the pulse supervisor)
# have no monitoring. Workers that crash, hang, or enter the OpenCode idle-state
# bug sit indefinitely consuming resources and blocking issue re-dispatch.
#
# Five failure modes detected:
#   1. CPU idle: Worker completed but sits in file-watcher (OpenCode idle bug).
#      Signal: tree CPU < WORKER_IDLE_CPU_THRESHOLD for WORKER_IDLE_TIMEOUT.
#   2. Progress stall: Worker is running but producing no output (stuck on API,
#      rate-limited, spinning). Signal: no log growth for WORKER_PROGRESS_TIMEOUT,
#      then inspect recent transcript tail evidence before killing.
#   3. Zero-commit thrash: Worker runs for long time with heavy message volume
#      but no commits. Signal: elapsed >= WORKER_THRASH_ELAPSED_THRESHOLD,
#      commits == 0, messages >= WORKER_THRASH_MESSAGE_THRESHOLD.
#   4. Runtime ceiling: Worker has been running too long regardless of activity.
#      Signal: elapsed > WORKER_MAX_RUNTIME. Prevents infinite loops.
#   5. Provider backoff stall (GH#5650): Worker's provider hit auth_error or
#      rate-limit and is backed off in headless-runtime state DB. Worker process
#      stays alive but makes no progress. Signal: provider_backoff table has an
#      active entry for the worker's provider/model with retry_after in the future.
#      Kill immediately — no transcript gate needed (provider won't respond anyway).
#
# On kill:
#   - Posts a comment on the associated GitHub issue explaining the kill reason
#   - Removes the worker's status:in-progress label
#   - Adds status:available for recoverable exits (idle, stall, runtime, backoff)
#   - Adds status:blocked for zero-commit thrash to prevent blind relaunch loops
#   - Logs the action to the watchdog log file
#
# Usage:
#   worker-watchdog.sh                  # Single check (for scheduler)
#   worker-watchdog.sh --check          # Same as above
#   worker-watchdog.sh --status         # Show current worker state
#   worker-watchdog.sh --install        # Install scheduler (launchd on macOS, cron on Linux)
#   worker-watchdog.sh --uninstall      # Remove scheduler entry
#   worker-watchdog.sh --help           # Show usage
#
# Environment:
#   WORKER_IDLE_TIMEOUT          Seconds of low CPU before kill (default: 300)
#   WORKER_IDLE_CPU_THRESHOLD    CPU% below this = idle (default: 5)
#   WORKER_PROGRESS_TIMEOUT      Seconds without log growth = stuck (default: 600)
#   WORKER_THRASH_ELAPSED_THRESHOLD  Minimum runtime before thrash check (default: 3600)
#   WORKER_THRASH_MESSAGE_THRESHOLD  Minimum messages for thrash check (default: 120)
#   WORKER_THRASH_RATIO_THRESHOLD    Struggle ratio threshold for time-weighted check (default: 10)
#   WORKER_THRASH_RATIO_ELAPSED      Minimum elapsed seconds for ratio-only thrash (default: 25200 = 7h)
#   WORKER_MAX_RUNTIME           Hard ceiling in seconds (default: 10800 = 3h)
#   WORKER_DRY_RUN               Set to "true" to log but not kill (default: false)
#   WORKER_WATCHDOG_NOTIFY       Set to "false" to disable macOS notifications
#   WORKER_PROCESS_PATTERN       CLI name to match (default: opencode)
#   HEADLESS_RUNTIME_DB          Path to headless-runtime state.db (auto-detected)

set -euo pipefail

#######################################
# PATH normalisation
#######################################
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

#######################################
# Configuration
#######################################
readonly SCRIPT_NAME="worker-watchdog"
readonly SCRIPT_VERSION="1.0.0"

WORKER_IDLE_TIMEOUT="${WORKER_IDLE_TIMEOUT:-300}"                          # 5 min idle = completed, sitting in file watcher
WORKER_IDLE_CPU_THRESHOLD="${WORKER_IDLE_CPU_THRESHOLD:-5}"                # CPU% below this = idle
WORKER_PROGRESS_TIMEOUT="${WORKER_PROGRESS_TIMEOUT:-600}"                  # 10 min no log output = stuck
WORKER_THRASH_ELAPSED_THRESHOLD="${WORKER_THRASH_ELAPSED_THRESHOLD:-3600}" # 1h minimum runtime before zero-commit thrash checks (GH#4400: lowered from 2h)
WORKER_THRASH_MESSAGE_THRESHOLD="${WORKER_THRASH_MESSAGE_THRESHOLD:-120}"  # ~2 messages/min over 1h before thrash checks (GH#4400: lowered from 180)
WORKER_THRASH_RATIO_THRESHOLD="${WORKER_THRASH_RATIO_THRESHOLD:-10}"       # Struggle ratio threshold for time-weighted check (GH#5650)
WORKER_THRASH_RATIO_ELAPSED="${WORKER_THRASH_RATIO_ELAPSED:-25200}"        # 7h: ratio-only thrash check for long-running zero-commit workers (GH#5650)
WORKER_MAX_RUNTIME="${WORKER_MAX_RUNTIME:-10800}"                          # 3 hour hard ceiling
WORKER_DRY_RUN="${WORKER_DRY_RUN:-false}"
WORKER_WATCHDOG_NOTIFY="${WORKER_WATCHDOG_NOTIFY:-true}"
WORKER_PROCESS_PATTERN="${WORKER_PROCESS_PATTERN:-opencode}" # CLI name to match (update if CLI changes)

# Validate numeric config
WORKER_IDLE_TIMEOUT=$(_validate_int WORKER_IDLE_TIMEOUT "$WORKER_IDLE_TIMEOUT" 300 60)
WORKER_IDLE_CPU_THRESHOLD=$(_validate_int WORKER_IDLE_CPU_THRESHOLD "$WORKER_IDLE_CPU_THRESHOLD" 5)
WORKER_PROGRESS_TIMEOUT=$(_validate_int WORKER_PROGRESS_TIMEOUT "$WORKER_PROGRESS_TIMEOUT" 600 120)
WORKER_THRASH_ELAPSED_THRESHOLD=$(_validate_int WORKER_THRASH_ELAPSED_THRESHOLD "$WORKER_THRASH_ELAPSED_THRESHOLD" 3600 600)
WORKER_THRASH_MESSAGE_THRESHOLD=$(_validate_int WORKER_THRASH_MESSAGE_THRESHOLD "$WORKER_THRASH_MESSAGE_THRESHOLD" 120 30)
WORKER_THRASH_RATIO_THRESHOLD=$(_validate_int WORKER_THRASH_RATIO_THRESHOLD "$WORKER_THRASH_RATIO_THRESHOLD" 10 1)
WORKER_THRASH_RATIO_ELAPSED=$(_validate_int WORKER_THRASH_RATIO_ELAPSED "$WORKER_THRASH_RATIO_ELAPSED" 25200 3600)
WORKER_MAX_RUNTIME=$(_validate_int WORKER_MAX_RUNTIME "$WORKER_MAX_RUNTIME" 10800 600)

# Paths
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOG_FILE="${LOG_DIR}/worker-watchdog.log"
readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly IDLE_STATE_DIR="${STATE_DIR}/worker-idle-tracking"
# headless-runtime state DB — same default as headless-runtime-helper.sh
# Not readonly: must be overridable by HEADLESS_RUNTIME_DB env var and tests
HEADLESS_RUNTIME_DB="${HEADLESS_RUNTIME_DB:-${HOME}/.aidevops/.agent-workspace/headless-runtime/state.db}"

STALL_EVIDENCE_CLASS=""
STALL_EVIDENCE_SUMMARY=""
INTERVENTION_EVIDENCE_CLASS=""
INTERVENTION_EVIDENCE_SUMMARY=""
THRASH_RATIO=""
THRASH_COMMITS=""
THRASH_MESSAGES=""
THRASH_FLAG=""
BACKOFF_PROVIDER=""
BACKOFF_REASON=""
BACKOFF_RETRY_AFTER=""

readonly LAUNCHD_LABEL="sh.aidevops.worker-watchdog"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
readonly CRON_MARKER="# aidevops: worker-watchdog"
readonly SYSTEMD_SERVICE_NAME="aidevops-worker-watchdog"
readonly SYSTEMD_SERVICE_DIR="${HOME}/.config/systemd/user"

#######################################
# Detect scheduler backend for this OS
# Output: "launchd", "systemd", "cron", or "unsupported"
# Matches pulse-session-helper.sh:get_scheduler_name() (GH#17691)
#######################################
_get_scheduler_backend() {
	case "$(uname -s)" in
	Darwin) echo "launchd" ;;
	*)
		# Prefer systemd user services when available (GH#17369, GH#17691)
		# Use show-environment instead of status to avoid hangs when systemd user manager is unresponsive (GH#17724)
		if command -v systemctl >/dev/null 2>&1 &&
			systemctl --user show-environment >/dev/null 2>&1; then
			echo "systemd"
		else
			echo "cron"
		fi
		;;
	esac
	return 0
}

#######################################
# Silent check: is crontab available?
# Returns: 0 if available, 1 if not
#######################################
_has_crontab() {
	command -v crontab >/dev/null 2>&1
}

#######################################
# Require crontab to be available (with error message)
# Returns: 0 if available, 1 if not
#######################################
_require_crontab() {
	if ! _has_crontab; then
		echo "Error: crontab is not available on this system." >&2
		return 1
	fi
	return 0
}

#######################################
# Ensure directories exist
#######################################
ensure_dirs() {
	mkdir -p "$LOG_DIR" "$STATE_DIR" "$IDLE_STATE_DIR" 2>/dev/null || true
	return 0
}

#######################################
# Log a message with timestamp
# Arguments:
#   $1 - message
#######################################
log_msg() {
	local msg="$1"
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	echo "[${timestamp}] [${SCRIPT_NAME}] ${msg}" >>"$LOG_FILE"
	return 0
}

#######################################
# Send macOS notification
# Arguments:
#   $1 - title
#   $2 - message
#######################################
notify() {
	local title="$1"
	local message="$2"
	# macOS notification disabled — Notification Center alert sounds
	# cannot be suppressed per-notification; they cause system beeps.
	# if [[ "$WORKER_WATCHDOG_NOTIFY" == "true" ]] && command -v osascript &>/dev/null; then
	# 	osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true
	# fi
	return 0
}

#######################################
# Sub-library sources
# Each sub-library has an include guard and a defensive SCRIPT_DIR fallback.
# SC1091: paths resolved at runtime via $SCRIPT_DIR — cannot be statically followed.
#######################################
# shellcheck source=./worker-watchdog-detect.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worker-watchdog-detect.sh"
# shellcheck source=./worker-watchdog-checks.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worker-watchdog-checks.sh"
# shellcheck source=./worker-watchdog-ff.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worker-watchdog-ff.sh"
# shellcheck source=./worker-watchdog-kill.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worker-watchdog-kill.sh"
# shellcheck source=./worker-watchdog-cmd.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worker-watchdog-cmd.sh"

#######################################
# Main
#######################################
main() {
	local cmd="${1:-check}"

	case "${cmd}" in
	--check | -c | check)
		cmd_check
		;;
	--status | -s | status)
		cmd_status
		;;
	--install | -i | install)
		cmd_install
		;;
	--uninstall | -u | uninstall)
		cmd_uninstall
		;;
	--help | -h | help)
		cmd_help
		;;
	*)
		echo "Unknown command: ${cmd}" >&2
		echo "Run with --help for usage" >&2
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
