#!/usr/bin/env bash
# Safe ShellCheck wrapper for language servers (shellcheck-wrapper.sh)
#
# The bash language server hardcodes --external-sources in every ShellCheck
# invocation (bash-language-server/out/shellcheck/index.js:82). Even though
# source-path=SCRIPTDIR has been removed from .shellcheckrc (and SC1091 is
# now globally disabled), this wrapper remains as defense-in-depth: it strips
# --external-sources to prevent any residual source-following expansion.
#
# Three defense layers in this wrapper:
#   1. Argument filtering: strips --external-sources / -x from args
#   2. RSS watchdog: background monitor kills shellcheck if RSS exceeds limit
#      (replaces ulimit -v which is broken on macOS ARM — setrlimit EINVAL)
#   3. Respawn rate limiter: exponential backoff prevents kill-respawn-grow
#      cycles where the language server immediately respawns killed processes
#
# Usage:
#   Set SHELLCHECK_PATH to this script's path, or place it earlier on PATH as
#   "shellcheck". The bash language server will use it instead of the real binary.
#
#   Environment variables:
#     SHELLCHECK_REAL_PATH    — Path to the real shellcheck binary (auto-detected)
#     SHELLCHECK_RSS_LIMIT_MB — RSS limit in MB before watchdog kills (default: 1024)
#     SHELLCHECK_WATCHDOG_SEC — Watchdog poll interval in seconds (default: 2)
#     SHELLCHECK_TIMEOUT_SEC  — Hard timeout in seconds (default: 120)
#     SHELLCHECK_BACKOFF_DIR  — Directory for rate-limit state (default: ~/.aidevops/.agent-workspace/tmp)
#
# GH#2915: https://github.com/marcusquinn/aidevops/issues/2915

set -uo pipefail

# --- Configuration ---
readonly RSS_LIMIT_MB="${SHELLCHECK_RSS_LIMIT_MB:-1024}"
readonly WATCHDOG_INTERVAL="${SHELLCHECK_WATCHDOG_SEC:-2}"
readonly HARD_TIMEOUT="${SHELLCHECK_TIMEOUT_SEC:-120}"
readonly BACKOFF_DIR="${SHELLCHECK_BACKOFF_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
readonly BACKOFF_FILE="${BACKOFF_DIR}/shellcheck-backoff"
readonly MAX_BACKOFF=300 # 5 minutes max backoff

# --- Find the real ShellCheck binary ---
_find_real_shellcheck() {
	local real_path="${SHELLCHECK_REAL_PATH:-}"

	if [[ -n "$real_path" && -x "$real_path" ]]; then
		printf '%s' "$real_path"
		return 0
	fi

	# Search PATH, skipping this wrapper script
	local self
	self="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

	local dir
	while IFS= read -r -d ':' dir || [[ -n "$dir" ]]; do
		local candidate="${dir}/shellcheck"
		if [[ -x "$candidate" ]]; then
			local resolved
			resolved="$(realpath "$candidate" 2>/dev/null || readlink -f "$candidate" 2>/dev/null || echo "$candidate")"
			if [[ "$resolved" != "$self" ]]; then
				printf '%s' "$candidate"
				return 0
			fi
		fi
	done <<<"$PATH"

	# Common locations
	local loc
	for loc in /opt/homebrew/bin/shellcheck /usr/local/bin/shellcheck /usr/bin/shellcheck; do
		if [[ -x "$loc" ]]; then
			local resolved
			resolved="$(realpath "$loc" 2>/dev/null || readlink -f "$loc" 2>/dev/null || echo "$loc")"
			if [[ "$resolved" != "$self" ]]; then
				printf '%s' "$loc"
				return 0
			fi
		fi
	done

	echo "shellcheck-wrapper: ERROR: cannot find real shellcheck binary" >&2
	return 1
}

# --- Filter arguments ---
_filter_args() {
	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--external-sources | -x)
			# Strip this flag — it causes unbounded source chain expansion
			;;
		*)
			args+=("$1")
			;;
		esac
		shift
	done
	printf '%s\n' "${args[@]}"
}

# --- Respawn rate limiter ---
# Tracks recent kills via a state file. If shellcheck was killed recently,
# delay before allowing the next invocation. Uses exponential backoff:
# 1st kill: 5s, 2nd: 10s, 3rd: 20s, ... up to MAX_BACKOFF (300s).
# Resets after MAX_BACKOFF seconds of no kills.
_check_rate_limit() {
	mkdir -p "$BACKOFF_DIR" 2>/dev/null || true

	if [[ ! -f "$BACKOFF_FILE" ]]; then
		return 0
	fi

	local kill_count last_kill_time
	# File format: "kill_count timestamp"
	read -r kill_count last_kill_time <"$BACKOFF_FILE" 2>/dev/null || return 0

	# Validate values are numeric
	[[ "$kill_count" =~ ^[0-9]+$ ]] || return 0
	[[ "$last_kill_time" =~ ^[0-9]+$ ]] || return 0

	local now
	now=$(date +%s)
	local elapsed=$((now - last_kill_time))

	# Reset if enough time has passed since last kill
	if [[ "$elapsed" -gt "$MAX_BACKOFF" ]]; then
		rm -f "$BACKOFF_FILE"
		return 0
	fi

	# Calculate required backoff: 5 * 2^(kill_count-1), capped at MAX_BACKOFF
	local backoff=5
	local i
	for ((i = 1; i < kill_count && backoff < MAX_BACKOFF; i++)); do
		backoff=$((backoff * 2))
	done
	if [[ "$backoff" -gt "$MAX_BACKOFF" ]]; then
		backoff="$MAX_BACKOFF"
	fi

	if [[ "$elapsed" -lt "$backoff" ]]; then
		local remaining=$((backoff - elapsed))
		# Return empty output (no diagnostics) instead of blocking
		# This prevents the language server from hanging while still
		# protecting against the kill-respawn-grow cycle
		echo '{"comments":[]}' 2>/dev/null || true
		return 1
	fi

	return 0
}

# Record that a kill happened (called by the watchdog)
_record_kill() {
	mkdir -p "$BACKOFF_DIR" 2>/dev/null || true

	local kill_count=0
	if [[ -f "$BACKOFF_FILE" ]]; then
		read -r kill_count _ <"$BACKOFF_FILE" 2>/dev/null || kill_count=0
		[[ "$kill_count" =~ ^[0-9]+$ ]] || kill_count=0
	fi

	kill_count=$((kill_count + 1))
	printf '%s %s\n' "$kill_count" "$(date +%s)" >"$BACKOFF_FILE"
}

# --- RSS watchdog ---
# Runs as a background process, polling the child's RSS every WATCHDOG_INTERVAL
# seconds. Kills the child if RSS exceeds RSS_LIMIT_MB.
# Also enforces a hard timeout.
#
# This replaces ulimit -v which is broken on macOS ARM (Apple Silicon):
#   $ ulimit -v 2097152
#   zsh:ulimit:2: setrlimit failed: invalid argument
# macOS ARM kernels don't support RLIMIT_AS (virtual memory limit).
# The watchdog approach is more reliable: it checks actual RSS (physical memory)
# rather than virtual memory, and works on all platforms.
_start_watchdog() {
	local child_pid="$1"
	local rss_limit_kb=$((RSS_LIMIT_MB * 1024))
	local start_time
	start_time=$(date +%s)

	while kill -0 "$child_pid" 2>/dev/null; do
		sleep "$WATCHDOG_INTERVAL"

		# Check if child still exists
		if ! kill -0 "$child_pid" 2>/dev/null; then
			break
		fi

		# Get RSS in KB (macOS ps reports in KB by default)
		local rss_kb
		rss_kb=$(ps -o rss= -p "$child_pid" 2>/dev/null | tr -d ' ') || break
		[[ "$rss_kb" =~ ^[0-9]+$ ]] || continue

		# Check RSS limit
		if [[ "$rss_kb" -gt "$rss_limit_kb" ]]; then
			local rss_mb=$((rss_kb / 1024))
			echo "shellcheck-wrapper: WATCHDOG: killing PID ${child_pid} — RSS ${rss_mb} MB exceeds ${RSS_LIMIT_MB} MB limit" >&2
			kill -KILL "$child_pid" 2>/dev/null || true
			_record_kill
			break
		fi

		# Check hard timeout
		local now
		now=$(date +%s)
		local elapsed=$((now - start_time))
		if [[ "$elapsed" -gt "$HARD_TIMEOUT" ]]; then
			echo "shellcheck-wrapper: WATCHDOG: killing PID ${child_pid} — exceeded ${HARD_TIMEOUT}s timeout" >&2
			kill -KILL "$child_pid" 2>/dev/null || true
			_record_kill
			break
		fi
	done
}

# --- Main ---
main() {
	local real_shellcheck
	real_shellcheck="$(_find_real_shellcheck)" || exit 1

	# Read filtered args into array
	local filtered_args=()
	while IFS= read -r arg; do
		filtered_args+=("$arg")
	done < <(_filter_args "$@")

	# Check respawn rate limit — if we were recently killed, return empty
	# results instead of running (prevents kill-respawn-grow cycle)
	if ! _check_rate_limit; then
		exit 0
	fi

	# Try ulimit -v as a first layer (works on Linux, no-op on macOS ARM)
	ulimit -v $((RSS_LIMIT_MB * 1024)) 2>/dev/null || true

	# Run shellcheck in background with RSS watchdog
	"$real_shellcheck" "${filtered_args[@]}" &
	local sc_pid=$!

	# Start watchdog in background
	_start_watchdog "$sc_pid" &
	local wd_pid=$!

	# Wait for shellcheck to finish (or be killed by watchdog)
	wait "$sc_pid" 2>/dev/null
	local sc_exit=$?

	# Clean up watchdog
	kill "$wd_pid" 2>/dev/null || true
	wait "$wd_pid" 2>/dev/null || true

	exit "$sc_exit"
}

main "$@"
