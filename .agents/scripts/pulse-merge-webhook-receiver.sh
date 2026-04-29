#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-webhook-receiver.sh — GitHub webhook → process_pr (t3038)
#
# Listens for GitHub webhook deliveries, validates the HMAC SHA-256
# signature, decodes the event payload, and dispatches the affected
# PR(s) to pulse-merge.sh::process_pr immediately — replacing the
# 120s polling latency in pulse-merge-routine.sh with seconds.
#
# Architecture:
#   - Bash entry point parses CLI flags (run, --port, --check, help).
#   - Configuration loaded from .agents/configs/webhook-receiver.conf.
#   - Secret loaded from the env var named in WEBHOOK_SECRET_ENV
#     (e.g. GITHUB_WEBHOOK_SECRET, set via gopass or credentials.sh).
#   - Embedded Python HTTP server (stdlib only) handles request loop:
#     reads body, validates HMAC, parses JSON, prints ACTION lines on
#     stdout that the bash parent reads via FIFO and dispatches.
#   - Each ACTION line: "PROCESS_PR <slug> <pr_number>".
#   - Unknown events / bad signatures → server returns 4xx, no ACTION.
#
# This split (Python parses, bash dispatches) keeps the gh + process_pr
# call path identical to the polling routine — no duplicated merge logic.
#
# Backstop: pulse-merge-routine.sh's 120s polling loop continues to run
# regardless of receiver state. If the receiver is down, eligible PRs
# still merge on the next polling cycle.
#
# Usage:
#   pulse-merge-webhook-receiver.sh [run]   Start the receiver (default)
#   pulse-merge-webhook-receiver.sh --check Validate config + secret only
#   pulse-merge-webhook-receiver.sh help    Show usage
#
# Webhook configuration on the GitHub side:
#   - Payload URL: https://<your-tunnel>/webhook (Cloudflare Tunnel etc.)
#   - Content type: application/json
#   - Secret: the value stored in WEBHOOK_SECRET_ENV
#   - Events: Check suites, Pull request reviews, Pull requests
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# =============================================================================
# Config + secret loading
# =============================================================================

WEBHOOK_CONF="${WEBHOOK_CONF:-${SCRIPT_DIR}/../configs/webhook-receiver.conf}"
if [[ ! -f "$WEBHOOK_CONF" ]]; then
	# Fallback to deployed location.
	WEBHOOK_CONF="${HOME}/.aidevops/agents/configs/webhook-receiver.conf"
fi
if [[ ! -f "$WEBHOOK_CONF" ]]; then
	printf 'webhook-receiver: config not found (looked at %s)\n' "$WEBHOOK_CONF" >&2
	exit 2
fi

# Source config, but allow caller env to override conf file values.
# Pattern: capture pre-set vars, source the conf, then restore overrides.
_WEBHOOK_OVERRIDE_HOST="${WEBHOOK_LISTEN_HOST:-}"
_WEBHOOK_OVERRIDE_PORT="${WEBHOOK_LISTEN_PORT:-}"
_WEBHOOK_OVERRIDE_EVENTS="${WEBHOOK_HANDLED_EVENTS:-}"
_WEBHOOK_OVERRIDE_MAX="${WEBHOOK_MAX_BODY_BYTES:-}"
_WEBHOOK_OVERRIDE_SECRET_ENV="${WEBHOOK_SECRET_ENV:-}"
_WEBHOOK_OVERRIDE_LOG="${WEBHOOK_LOG_FILE:-}"

# shellcheck source=/dev/null
source "$WEBHOOK_CONF"

[[ -n "$_WEBHOOK_OVERRIDE_HOST" ]] && WEBHOOK_LISTEN_HOST="$_WEBHOOK_OVERRIDE_HOST"
[[ -n "$_WEBHOOK_OVERRIDE_PORT" ]] && WEBHOOK_LISTEN_PORT="$_WEBHOOK_OVERRIDE_PORT"
[[ -n "$_WEBHOOK_OVERRIDE_EVENTS" ]] && WEBHOOK_HANDLED_EVENTS="$_WEBHOOK_OVERRIDE_EVENTS"
[[ -n "$_WEBHOOK_OVERRIDE_MAX" ]] && WEBHOOK_MAX_BODY_BYTES="$_WEBHOOK_OVERRIDE_MAX"
[[ -n "$_WEBHOOK_OVERRIDE_SECRET_ENV" ]] && WEBHOOK_SECRET_ENV="$_WEBHOOK_OVERRIDE_SECRET_ENV"
[[ -n "$_WEBHOOK_OVERRIDE_LOG" ]] && WEBHOOK_LOG_FILE="$_WEBHOOK_OVERRIDE_LOG"

# Load credentials.sh (provides the webhook secret env var if not from gopass).
if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
	# shellcheck source=/dev/null
	. "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null || true
fi

WEBHOOK_LOG_FILE="${WEBHOOK_LOG_FILE:-${HOME}/.aidevops/logs/pulse-merge-webhook.log}"
mkdir -p "$(dirname "$WEBHOOK_LOG_FILE")"

_whlog() {
	local level="$1"
	shift
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >>"$WEBHOOK_LOG_FILE"
	return 0
}

# Resolve the secret value from the env var named in WEBHOOK_SECRET_ENV.
# We never log the secret itself — only whether it is set.
_resolve_secret() {
	local env_var_name="${WEBHOOK_SECRET_ENV:-GITHUB_WEBHOOK_SECRET}"
	# shellcheck disable=SC2086
	local secret_val="${!env_var_name:-}"
	if [[ -z "$secret_val" ]]; then
		# Try gopass as a secondary source — best-effort, fail-quiet.
		if command -v gopass >/dev/null 2>&1; then
			secret_val=$(gopass show -o "aidevops/${env_var_name}" 2>/dev/null || true)
		fi
	fi
	printf '%s' "$secret_val"
	return 0
}

# =============================================================================
# Subcommand: --check (config + secret validation, no listener)
# =============================================================================

cmd_check() {
	local errors=0
	printf 'webhook-receiver config: %s\n' "$WEBHOOK_CONF"
	printf '  listen:  %s:%s\n' "${WEBHOOK_LISTEN_HOST:-127.0.0.1}" "${WEBHOOK_LISTEN_PORT:-9301}"
	printf '  events:  %s\n' "${WEBHOOK_HANDLED_EVENTS:-check_suite,pull_request_review,pull_request}"
	printf '  log:     %s\n' "$WEBHOOK_LOG_FILE"

	local secret
	secret=$(_resolve_secret)
	if [[ -n "$secret" ]]; then
		printf '  secret:  set (%s, %d chars)\n' "${WEBHOOK_SECRET_ENV}" "${#secret}"
	else
		printf '  secret:  MISSING — set with: aidevops secret set %s\n' "${WEBHOOK_SECRET_ENV}" >&2
		errors=$((errors + 1))
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		printf '  python3: MISSING — required for HTTP server\n' >&2
		errors=$((errors + 1))
	else
		printf '  python3: %s\n' "$(command -v python3)"
	fi

	if [[ "$errors" -gt 0 ]]; then
		printf 'webhook-receiver: %d configuration error(s)\n' "$errors" >&2
		return 1
	fi
	printf 'webhook-receiver: OK\n'
	return 0
}

# =============================================================================
# Subcommand: run (start listener)
# =============================================================================

cmd_run() {
	local secret
	secret=$(_resolve_secret)
	if [[ -z "$secret" ]]; then
		_whlog ERROR "Cannot start: webhook secret env var ${WEBHOOK_SECRET_ENV} not set"
		printf 'webhook-receiver: secret %s not set; refusing to start\n' "${WEBHOOK_SECRET_ENV}" >&2
		return 1
	fi

	# Make config available to the Python child via env vars (avoid arg leakage).
	export WEBHOOK_LISTEN_HOST="${WEBHOOK_LISTEN_HOST:-127.0.0.1}"
	export WEBHOOK_LISTEN_PORT="${WEBHOOK_LISTEN_PORT:-9301}"
	export WEBHOOK_HANDLED_EVENTS="${WEBHOOK_HANDLED_EVENTS:-check_suite,pull_request_review,pull_request}"
	export WEBHOOK_MAX_BODY_BYTES="${WEBHOOK_MAX_BODY_BYTES:-1048576}"
	export WEBHOOK_LOG_FILE
	# Pass the secret only via env to the python child (single-process; not exec'd).
	export _PULSE_WEBHOOK_SECRET="$secret"

	_whlog INFO "Starting receiver on ${WEBHOOK_LISTEN_HOST}:${WEBHOOK_LISTEN_PORT} (events=${WEBHOOK_HANDLED_EVENTS})"

	# Source pulse-merge.sh + dependencies inside this shell so process_pr is
	# callable from the dispatch loop below. We mirror pulse-merge-routine.sh.
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/shared-constants.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-wrapper-config.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-repo-meta.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-merge.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-merge-conflict.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-merge-feedback.sh"

	# The Python server prints one ACTION line per accepted webhook to stdout:
	#   PROCESS_PR <slug> <pr_number>
	# Lines starting with "#" are diagnostic logs we forward to the log file.
	# We pipe its stdout into a while-read loop that calls process_pr.
	while IFS= read -r line; do
		case "$line" in
		'#'*)
			_whlog INFO "${line#'# '}"
			;;
		PROCESS_PR\ *)
			# Parse: PROCESS_PR <slug> <pr_number>
			# shellcheck disable=SC2086
			set -- $line
			local _slug="${2:-}"
			local _pr="${3:-}"
			if [[ -z "$_slug" || -z "$_pr" ]]; then
				_whlog WARN "Malformed ACTION line: ${line}"
				continue
			fi
			_whlog INFO "Dispatching process_pr ${_slug}#${_pr}"
			# Run in a subshell so a failure inside process_pr cannot
			# crash the receiver loop (set -e considerations, etc.).
			(
				set +e
				process_pr "$_slug" "$_pr"
				_whlog INFO "process_pr ${_slug}#${_pr} returned ${?}"
			) &
			# Cap concurrency at 4 in-flight dispatches to avoid
			# saturating the GitHub API on bursty webhook deliveries.
			while [[ "$(jobs -rp | wc -l)" -ge 4 ]]; do
				sleep 0.2
			done
			;;
		'')
			:
			;;
		*)
			_whlog WARN "Unknown line from server: ${line}"
			;;
		esac
	done < <(python3 -u "${SCRIPT_DIR}/pulse-merge-webhook-receiver.sh" --__server)

	_whlog WARN "Server stdout loop exited"
	wait
	return 0
}

# =============================================================================
# Subcommand: --__server (internal, runs the python HTTP server)
# =============================================================================
# Logic lives in pulse-merge-webhook-server.py to keep this shell function
# under the function-complexity gate. Stdout = ACTION protocol.

cmd_server() {
	exec python3 "${SCRIPT_DIR}/pulse-merge-webhook-server.py"
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<EOF
pulse-merge-webhook-receiver.sh — GitHub webhook → process_pr (t3038)

Usage:
  pulse-merge-webhook-receiver.sh [run]    Start the listener (default)
  pulse-merge-webhook-receiver.sh --check  Validate config + secret, no listener
  pulse-merge-webhook-receiver.sh help     Show this help

Configuration:
  ${WEBHOOK_CONF}

Secret:
  Stored in env var named by WEBHOOK_SECRET_ENV (currently: ${WEBHOOK_SECRET_ENV:-GITHUB_WEBHOOK_SECRET}).
  Set with: aidevops secret set ${WEBHOOK_SECRET_ENV:-GITHUB_WEBHOOK_SECRET}
  Or in ~/.config/aidevops/credentials.sh (mode 600).

Events handled:
  - check_suite.completed (conclusion=success)
  - pull_request_review.submitted (state in: approved, changes_requested)
  - pull_request.labeled (auto-dispatch, coderabbit-nits-ok, ai-approved)

Backstop:
  pulse-merge-routine.sh's 120s polling loop continues to run regardless
  of receiver state. If the receiver is offline, eligible PRs still
  merge on the next polling cycle — webhook-driven merges are an
  optimization, not a replacement.

GitHub-side setup:
  Expose this listener via Cloudflare Tunnel (HTTPS termination), then
  configure the repo webhook with:
    - Payload URL: https://<your-tunnel>/webhook
    - Content type: application/json
    - Secret: same value as the env var above
    - Events: Check suites, Pull request reviews, Pull requests

Logs:
  ${WEBHOOK_LOG_FILE}
EOF
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

main() {
	local cmd="${1:-run}"
	case "$cmd" in
	run | --run | "")
		cmd_run
		;;
	--check | check)
		cmd_check
		;;
	--__server)
		# Internal: invoked by cmd_run via the python pipe.
		cmd_server
		;;
	help | -h | --help)
		cmd_help
		;;
	*)
		printf 'Unknown command: %s\n' "$cmd" >&2
		cmd_help >&2
		return 2
		;;
	esac
	return 0
}

main "$@"
exit $?
