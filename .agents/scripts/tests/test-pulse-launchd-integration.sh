#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# Explicitly opt-in real-launchd verification.  This never targets the
# production Pulse label, wrapper, HOME, or runtime bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN=false
FIXTURE_ROOT=""
FIXTURE_LABEL=""
FIXTURE_DOMAIN=""
FIXTURE_WRAPPER=""
FIXTURE_PID=""
CLEANUP_FAILED=false

usage() {
	printf '%s\n' 'Usage: bash .agents/scripts/tests/test-pulse-launchd-integration.sh [--run]'
	printf '%s\n' 'Without --run this check SKIPs without calling launchctl.'
	return 0
}

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	return 1
}

fixture_disabled() {
	if launchctl print-disabled "$FIXTURE_DOMAIN" 2>/dev/null | tr -d '[:space:]' | grep -Fq "\"${FIXTURE_LABEL}\"=>true"; then
		return 0
	fi
	return 1
}

fixture_present() {
	if launchctl print "${FIXTURE_DOMAIN}/${FIXTURE_LABEL}" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

write_recovery_record() {
	[[ -n "$FIXTURE_ROOT" && -d "$FIXTURE_ROOT" ]] || return 0
	printf 'label=%s\ndomain=%s\n' "$FIXTURE_LABEL" "$FIXTURE_DOMAIN" >"$FIXTURE_ROOT/RECOVERY.txt"
	chmod 600 "$FIXTURE_ROOT/RECOVERY.txt"
	return 0
}

cleanup() {
	local original_status=$?
	local cleanup_status=0
	trap - EXIT INT TERM
	if [[ -n "$FIXTURE_LABEL" && -n "$FIXTURE_DOMAIN" ]]; then
		launchctl bootout "${FIXTURE_DOMAIN}/${FIXTURE_LABEL}" >/dev/null 2>&1 || true
		launchctl disable "${FIXTURE_DOMAIN}/${FIXTURE_LABEL}" >/dev/null 2>&1 || true
		launchctl enable "${FIXTURE_DOMAIN}/${FIXTURE_LABEL}" >/dev/null 2>&1 || cleanup_status=1
		fixture_present && cleanup_status=1
		fixture_disabled && cleanup_status=1
	fi
	if [[ "$FIXTURE_PID" =~ ^[0-9]+$ ]] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
		kill -TERM "$FIXTURE_PID" 2>/dev/null || cleanup_status=1
	fi
	if [[ -n "$FIXTURE_ROOT" ]] && pgrep -f "${FIXTURE_ROOT}/pulse-wrapper.sh" >/dev/null 2>&1; then
		cleanup_status=1
	fi
	if [[ "$cleanup_status" -ne 0 ]]; then
		CLEANUP_FAILED=true
		write_recovery_record
		printf 'FAIL: fixture cleanup was not proven; recovery record retained at fixture root\n' >&2
	else
		[[ -z "$FIXTURE_ROOT" || ! -d "$FIXTURE_ROOT" ]] || rm -rf "$FIXTURE_ROOT"
	fi
	if [[ "$original_status" -ne 0 || "$cleanup_status" -ne 0 ]]; then
		exit 1
	fi
	exit 0
}

while [[ "$#" -gt 0 ]]; do
	case "$1" in
	--run) RUN=true ;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
	shift
done

if [[ "$RUN" != true ]]; then
	printf 'SKIP: real launchd integration requires explicit --run\n'
	exit 0
fi

[[ "$(uname -s)" == Darwin ]] || fail 'requires macOS with an accessible GUI launchd domain' || exit 1
command -v launchctl >/dev/null 2>&1 || fail 'launchctl is unavailable' || exit 1
FIXTURE_DOMAIN="gui/$(id -u)"
launchctl print-disabled "$FIXTURE_DOMAIN" >/dev/null 2>&1 || fail "cannot access ${FIXTURE_DOMAIN}" || exit 1

# Do not allow a caller's production settings to redirect this fixture.
unset AIDEVOPS_AGENTS_DIR AIDEVOPS_ACTIVE_AGENTS_LINK AIDEVOPS_RUNTIME_BUNDLES_DIR
unset AIDEVOPS_PULSE_PROCESS_PATTERN AIDEVOPS_PULSE_MERGE_PROCESS_PATTERN
unset AIDEVOPS_PULSE_LAUNCHD_LABEL AIDEVOPS_SKIP_PULSE_RESTART
FIXTURE_ROOT=$(mktemp -d -t aidevops-pulse-launchd-integration)
chmod 700 "$FIXTURE_ROOT"
export HOME="$FIXTURE_ROOT"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.aidevops/agents/scripts" "$HOME/.aidevops/logs"
FIXTURE_LABEL="com.aidevops.test.pulse.$$.${RANDOM}${RANDOM}"
FIXTURE_WRAPPER="$FIXTURE_ROOT/pulse-wrapper.sh"
FIXTURE_PATTERN="${FIXTURE_ROOT//./\\.}/pulse-wrapper\\.sh( |$)"
export AIDEVOPS_AGENTS_DIR="$HOME/.aidevops/agents"
export AIDEVOPS_ACTIVE_AGENTS_LINK="$AIDEVOPS_AGENTS_DIR"
export AIDEVOPS_PULSE_PROCESS_PATTERN="$FIXTURE_PATTERN"
export AIDEVOPS_PULSE_LAUNCHD_LABEL="$FIXTURE_LABEL"
export AIDEVOPS_PULSE_OS_NAME=Darwin
export AIDEVOPS_PULSE_RESTART_WAIT=0
export AIDEVOPS_PULSE_SIGTERM_WAIT=1

trap cleanup EXIT INT TERM
if fixture_present; then
	fail "fixture label collision: ${FIXTURE_LABEL}"
	exit 1
fi
if fixture_disabled; then
	fail "fixture disabled-state collision: ${FIXTURE_LABEL}"
	exit 1
fi
cat >"$FIXTURE_WRAPPER" <<'WRAPPER'
#!/usr/bin/env bash
set -eu
deadline=$((SECONDS + 75))
while [[ "$SECONDS" -lt "$deadline" ]]; do sleep 1; done
WRAPPER
chmod 700 "$FIXTURE_WRAPPER"

# Source the checkout's production functions; do not copy their bodies here.
# shellcheck source=../setup/_scheduler_runtime.sh
source "$REPO_ROOT/.agents/scripts/setup/_scheduler_runtime.sh"
# shellcheck source=../setup/modules/schedulers-pulse.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/schedulers-pulse.sh"
# shellcheck source=../pulse-lifecycle-helper.sh
source "$REPO_ROOT/.agents/scripts/pulse-lifecycle-helper.sh"

launchctl disable "${FIXTURE_DOMAIN}/${FIXTURE_LABEL}"
_pulse_launchd_supervisor_disabled || fail 'production disabled-state parser did not detect fixture override'
_install_pulse_launchd "$FIXTURE_LABEL" "$FIXTURE_WRAPPER" "$(command -v bash)" false
if _pulse_launchd_supervisor_disabled; then fail 'production installer did not clear fixture disabled override'; fi
fixture_present || fail 'fixture was not registered by production installer'
_pulse_start_managed
FIXTURE_PID=$(_pulse_pids | awk 'NR == 1 { print; exit }')
[[ "$FIXTURE_PID" =~ ^[0-9]+$ ]] || fail 'production managed-start did not prove a new fixture runtime PID'

# Reinstalling an unchanged, loaded job must retain registration/runtime.
_install_pulse_launchd "$FIXTURE_LABEL" "$FIXTURE_WRAPPER" "$(command -v bash)" true
fixture_present || fail 'unchanged fixture registration disappeared after reinstall'
kill -0 "$FIXTURE_PID" 2>/dev/null || fail 'unchanged fixture runtime was unnecessarily replaced'
printf 'PASS: real launchd fixture repaired, started, retained, and will be cleaned up\n'
