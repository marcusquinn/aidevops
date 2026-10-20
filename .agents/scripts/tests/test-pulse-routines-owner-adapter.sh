#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Exercise production dispatch/state handling with an isolated owner host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../pulse-routines.sh
source "$SCRIPT_DIR/../pulse-routines.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR"
LOGFILE="$TEST_DIR/pulse.log"
ROUTINE_STATE_FILE="$TEST_DIR/state.json"
ROUTINE_LOG_HELPER="$TEST_DIR/no-lifecycle-helper"
mkdir -p "$HOME/.aidevops/agents/custom/scripts" "$TEST_DIR/repo"
printf '%s\n' '{"r001":{"last_run":"2026-10-19T00:00:00Z","consecutive_failures":15}}' >"$ROUTINE_STATE_FILE"

_routine_execute r001 report 'custom/scripts/report.sh --daily' '' "$TEST_DIR/repo"
jq -e '.r001.last_status == "skipped_not_owner" and .r001.consecutive_failures == 15 and .r001.last_run == "2026-10-19T00:00:00Z"' "$ROUTINE_STATE_FILE"
[[ $(wc -l <"$LOGFILE") -eq 1 ]]
grep -q 'routine r001: owner adapter not installed on this host; skipping' "$LOGFILE"
_routine_execute r002 report 'custom/scripts/missing.sh' '' "$TEST_DIR/repo"
jq -e '.r002.last_status == "skipped_not_owner" and (.r002 | has("consecutive_failures") | not) and (.r002 | has("last_run") | not)' "$ROUTINE_STATE_FILE"

# Present but non-executable, broken symlink, shared path and traversal all fail.
touch "$HOME/.aidevops/agents/custom/scripts/report.sh"
ln -s missing-target "$HOME/.aidevops/agents/custom/scripts/broken.sh"
for script in custom/scripts/report.sh custom/scripts/broken.sh scripts/missing.sh custom/scripts/../../missing.sh; do
	if _routine_execute r001 report "$script" '' "$TEST_DIR/repo"; then
		printf 'FAIL: expected dispatch failure for %s\n' "$script"
		exit 1
	fi
done
jq -e '.r001.last_status == "failure" and .r001.consecutive_failures == 19' "$ROUTINE_STATE_FILE"

# Run the real detached-runner body synchronously, keeping its traps isolated.
_routine_dispatch_script() {
	(_routine_run_detached_script "$@")
	return 0
}
printf '#!/usr/bin/env bash\nexit 1\n' >"$HOME/.aidevops/agents/custom/scripts/report.sh"
chmod +x "$HOME/.aidevops/agents/custom/scripts/report.sh"
_routine_execute r001 report custom/scripts/report.sh '' "$TEST_DIR/repo"
jq -e '.r001.last_status == "failure" and .r001.consecutive_failures == 20 and .r001.last_run == "2026-10-19T00:00:00Z"' "$ROUTINE_STATE_FILE"

# Installing the previously absent adapter enables execution immediately.
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.aidevops/agents/custom/scripts/report.sh"
_routine_execute r002 report custom/scripts/report.sh '' "$TEST_DIR/repo"
jq -e '.r002.last_status == "success" and (.r002 | has("consecutive_failures") | not) and (.r002 | has("last_run"))' "$ROUTINE_STATE_FILE"
printf 'PASS: missing-owner skip and installed-adapter outcomes\n'
