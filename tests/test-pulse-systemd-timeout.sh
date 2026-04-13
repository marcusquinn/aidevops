#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULERS_SCRIPT="${REPO_ROOT}/setup-modules/schedulers.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

print_info() {
	return 0
}

print_warning() {
	return 0
}

_ensure_cron_path() {
	return 0
}

_scheduler_detect_installed() {
	return 1
}

_systemd_user_available() {
	return 0
}

systemctl() {
	local scope="${1:-}"
	local action="${2:-}"
	local target="${3:-}"

	if [[ "$scope" != "--user" ]]; then
		return 1
	fi

	if [[ "$action" == "daemon-reload" ]]; then
		return 0
	fi

	if [[ "$action" == "enable" && "$target" == "--now" ]]; then
		return 0
	fi

	return 1
}

export HOME="${TMP_DIR}/home"
export PATH="/usr/bin:/bin"
export NON_INTERACTIVE="true"
export AIDEVOPS_SUPERVISOR_PULSE="true"
mkdir -p "$HOME/.aidevops/agents/scripts" "$HOME/.aidevops/logs"

WRAPPER_SCRIPT="$HOME/.aidevops/agents/scripts/pulse-wrapper.sh"
touch "$WRAPPER_SCRIPT"
chmod +x "$WRAPPER_SCRIPT"

# shellcheck source=setup-modules/schedulers.sh
source "$SCHEDULERS_SCRIPT"

# Override sourced helpers for deterministic unit behavior.
_scheduler_detect_installed() {
	return 1
}

_systemd_user_available() {
	return 0
}

setup_supervisor_pulse "Linux"

SERVICE_FILE="$HOME/.config/systemd/user/aidevops-supervisor-pulse.service"

if ! grep -q '^TimeoutStartSec=1860$' "$SERVICE_FILE"; then
	echo "expected TimeoutStartSec=1860 in ${SERVICE_FILE}" >&2
	exit 1
fi

if ! grep -q '^Environment=PULSE_STALE_THRESHOLD="1800"$' "$SERVICE_FILE"; then
	echo "expected Environment=PULSE_STALE_THRESHOLD=1800 in ${SERVICE_FILE}" >&2
	exit 1
fi

printf 'PASS %s\n' "pulse systemd service timeout exceeds watchdog threshold"

# GH#18439 Bug 1 regression: _scheduler_systemd_env_lines() emits a trailing
# newline, but $() strips it. The caller MUST re-add the separator or
# Environment=PATH=... will concatenate with StandardOutput=... on the same
# line, breaking systemd parsing and producing opencode=unknown in canary.
if grep -qE 'PATH=.*StandardOutput' "$SERVICE_FILE"; then
	echo "GH#18439 Bug 1 regression: Environment=PATH concatenated with StandardOutput on same line" >&2
	echo "--- service file ---" >&2
	cat "$SERVICE_FILE" >&2
	echo "--- end ---" >&2
	exit 1
fi

if ! grep -qE '^Environment=PATH=' "$SERVICE_FILE"; then
	echo "GH#18439 Bug 1 regression: Environment=PATH= not found as its own directive line" >&2
	echo "--- service file ---" >&2
	cat "$SERVICE_FILE" >&2
	echo "--- end ---" >&2
	exit 1
fi

if ! grep -qE '^StandardOutput=' "$SERVICE_FILE"; then
	echo "GH#18439 Bug 1 regression: StandardOutput= not found as its own directive line" >&2
	echo "--- service file ---" >&2
	cat "$SERVICE_FILE" >&2
	echo "--- end ---" >&2
	exit 1
fi

printf 'PASS %s\n' "GH#18439 Bug 1 newline preserved between Environment= and StandardOutput="

# GH#18439 Bug 2 regression: the Linux install path must embed OPENCODE_BIN
# in the systemd service file (mirror of the macOS launchd plist) so
# pulse-wrapper.sh can find the dispatch binary even under systemd's minimal
# PATH after aidevops-auto-update.timer regenerates the unit.
if ! grep -qE '^Environment=OPENCODE_BIN=' "$SERVICE_FILE"; then
	echo "GH#18439 Bug 2 regression: Environment=OPENCODE_BIN= not found in Linux pulse service file" >&2
	echo "--- service file ---" >&2
	cat "$SERVICE_FILE" >&2
	echo "--- end ---" >&2
	exit 1
fi

printf 'PASS %s\n' "GH#18439 Bug 2 OPENCODE_BIN propagated to Linux systemd service"
