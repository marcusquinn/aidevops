#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${TEST_DIR}/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
HOME="$ROOT/home"
LOGFILE="$ROOT/pulse.log"
REPOS_JSON="$ROOT/repos.json"
mkdir -p "$HOME/.aidevops/cache"
printf '%s\n' '{"initialized_repos":[{"slug":"owner/one","pulse":true},{"slug":"owner/two","pulse":true},{"slug":"owner/local","pulse":true,"local_only":true}]}' >"$REPOS_JSON"
# shellcheck source=../pulse-wrapper-cycle.sh
source "${SCRIPT_DIR}/pulse-wrapper-cycle.sh"

CALLS=""
reconcile_stale_blocked_issues() {
	local repo="$1"
	CALLS="${CALLS}${CALLS:+ }$repo"
	return 0
}
_file_mtime_epoch() {
	printf '0\n'
	return 0
}

PULSE_STALE_BLOCKED_RECONCILE_INTERVAL=1800 _pulse_reconcile_stale_blocked_if_due
[[ "$CALLS" == "owner/one owner/two" ]] || {
	printf 'FAIL: expected both remote pulse repos, got %s\n' "$CALLS"
	exit 1
}
CALLS=""
_file_mtime_epoch() {
	date +%s
	return 0
}
_pulse_reconcile_stale_blocked_if_due
[[ -z "$CALLS" ]] || {
	printf 'FAIL: fresh cadence sentinel did not suppress reconciliation\n'
	exit 1
}
printf 'PASS: stale blocked reconciliation is pulse-wired and cadence bounded\n'
