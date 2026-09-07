#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Regression tests for systemd-owned Pulse watchdog liveness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WATCHDOG="${SCRIPT_DIR}/../pulse-watchdog-tick.sh"
TEST_ROOT=$(mktemp -d -t pulse-watchdog-tick.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home/.aidevops/logs" "${TEST_ROOT}/agents/scripts"
SYSTEMCTL_LOG="${TEST_ROOT}/systemctl.log"
LIFECYCLE_STATE="${TEST_ROOT}/lifecycle.state"

cat >"${TEST_ROOT}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"--property=LoadState"* ]]; then
	printf 'loaded\n'
	exit 0
fi
if [[ "$*" == *"--property=ActiveState"* ]]; then
	printf 'inactive\n'
	exit 0
fi
if [[ "$*" == *" start "* ]]; then
	printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
	exit 0
fi
exit 1
SH
chmod +x "${TEST_ROOT}/bin/systemctl"

cat >"${TEST_ROOT}/agents/scripts/pulse-lifecycle-helper.sh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "is-running" ]] || exit 2
[[ "$(<"$LIFECYCLE_STATE")" == "running" ]]
SH
chmod +x "${TEST_ROOT}/agents/scripts/pulse-lifecycle-helper.sh"

run_watchdog() {
	PATH="${TEST_ROOT}/bin:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		AIDEVOPS_AGENTS_DIR="${TEST_ROOT}/agents" \
		AIDEVOPS_PULSE_WATCHDOG_GRACE=0 \
		SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
		LIFECYCLE_STATE="$LIFECYCLE_STATE" \
		"$WATCHDOG"
}

printf 'running\n' >"$LIFECYCLE_STATE"
: >"$SYSTEMCTL_LOG"
run_watchdog
if [[ -s "$SYSTEMCTL_LOG" ]]; then
	printf 'FAIL: inactive systemd unit revived despite live Pulse process\n' >&2
	exit 1
fi
printf 'PASS: inactive systemd unit accepts live Pulse process evidence\n'

printf 'stopped\n' >"$LIFECYCLE_STATE"
: >"$SYSTEMCTL_LOG"
run_watchdog
if [[ ! -s "$SYSTEMCTL_LOG" ]]; then
	printf 'FAIL: dead systemd-owned Pulse was not revived\n' >&2
	exit 1
fi
printf 'PASS: dead systemd-owned Pulse is revived\n'
