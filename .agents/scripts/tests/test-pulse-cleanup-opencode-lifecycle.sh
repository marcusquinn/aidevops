#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pulse-cleanup-lifecycle.XXXXXX")"
export HOME="${TEST_ROOT}/home"
export LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "$HOME"
touch "$LOGFILE"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# shellcheck source=../shared-constants.sh
source "${REPO_ROOT}/.agents/scripts/shared-constants.sh"
# shellcheck source=../worker-lifecycle-common.sh
source "${REPO_ROOT}/.agents/scripts/worker-lifecycle-common.sh"
# shellcheck source=../pulse-cleanup.sh
source "${REPO_ROOT}/.agents/scripts/pulse-cleanup.sh"

TESTS_RUN=0
TESTS_FAILED=0
MOCK_CGROUP_OWNER="unmanaged"
MOCK_ACTIVITY_AGE=259201
MOCK_TREE_CPU=0
MOCK_AGE=259201
MOCK_PROCESS_LINE=""
MOCK_CURRENT_COMMAND=""
MOCK_KILLS=""

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n  expected=%s\n  actual=%s\n' "$name" "$expected" "$actual"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_pulse_orphan_lifecycle_owner() {
	local pid="$1"
	: "$pid"
	[[ "$MOCK_CGROUP_OWNER" != "unmanaged" ]] || return 1
	printf '%s' "$MOCK_CGROUP_OWNER"
}

_pulse_orphan_activity_age() {
	local cmd="$1"
	: "$cmd"
	[[ "$MOCK_ACTIVITY_AGE" != "unavailable" ]] || return 1
	printf '%s' "$MOCK_ACTIVITY_AGE"
}

_get_process_tree_cpu() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_TREE_CPU"
}

_get_process_age() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_AGE"
}

_pulse_list_opencode_candidates() {
	printf '%s\n' "$MOCK_PROCESS_LINE"
}

_pulse_process_command() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_CURRENT_COMMAND"
}

kill() {
	MOCK_KILLS="${MOCK_KILLS}${*};"
	return 0
}

decision_reason() {
	local decision="$1"
	printf '%s' "${decision#*|}" | cut -d '|' -f 1
}

export AIDEVOPS_PULSE_PROC_ROOT="${TEST_ROOT}/proc"
mkdir -p "${AIDEVOPS_PULSE_PROC_ROOT}/4001"
printf '%s\n' '13:pids:/user.slice/user-1000.slice' \
	'1:name=systemd:/user.slice/user@1000.service/app.slice/opencode-web.service' \
	'0::/user.slice/user@1000.service/app.slice/opencode-web.service' \
	>"${AIDEVOPS_PULSE_PROC_ROOT}/4001/cgroup"
assert_eq "hybrid cgroup selects systemd lifecycle path" \
	"/user.slice/user@1000.service/app.slice/opencode-web.service" \
	"$(_pulse_process_cgroup_path 4001)"
if _pulse_process_cgroup_path 4999 >/dev/null; then
	missing_cgroup_result="available"
else
	missing_cgroup_result="unavailable"
fi
assert_eq "missing cgroup evidence is explicit" "unavailable" "$missing_cgroup_result"

assert_eq "serve command is persistent" "persistent-command" \
	"$(decision_reason "$(_pulse_orphan_decision 4101 '/home/test/.opencode/bin/opencode serve --port 4096' 259201)")"

MOCK_CGROUP_OWNER="opencode-web-service"
assert_eq "managed web cgroup is lifecycle-owned" "lifecycle-owned" \
	"$(decision_reason "$(_pulse_orphan_decision 4102 '/home/test/.opencode/bin/opencode run task' 259201)")"

MOCK_CGROUP_OWNER="unmanaged"
MOCK_ACTIVITY_AGE="unavailable"
assert_eq "missing activity fails closed" "activity-unavailable" \
	"$(decision_reason "$(_pulse_orphan_decision 4103 '/home/test/.opencode/bin/opencode run task' 259201)")"

MOCK_ACTIVITY_AGE=60
assert_eq "active session is protected" "recent-session-activity" \
	"$(decision_reason "$(_pulse_orphan_decision 4104 '/home/test/.opencode/bin/opencode run task' 259201)")"

MOCK_ACTIVITY_AGE=259201
MOCK_TREE_CPU=4
assert_eq "active tool subtree is protected" "active-process-tree" \
	"$(decision_reason "$(_pulse_orphan_decision 4105 '/home/test/.opencode/bin/opencode run task' 259201)")"

MOCK_TREE_CPU=0
assert_eq "stale no-TTY run session is eligible" "kill|verified-stale-session|run|259201|session-db|unmanaged" \
	"$(_pulse_orphan_decision 4106 '/home/test/.opencode/bin/opencode run task' 259201)"
assert_eq "stale TTY run session is eligible" "kill|verified-stale-session|run|259201|session-db|unmanaged" \
	"$(_pulse_orphan_decision 4107 '/home/test/.opencode/bin/opencode run task' 259201)"

MOCK_PROCESS_LINE='4108 ? 3-00:00:01 2048 /home/test/.opencode/bin/opencode run task'
MOCK_CURRENT_COMMAND='/home/test/.opencode/bin/opencode run task'
MOCK_KILLS=""
cleanup_orphans
assert_eq "verified stale process receives one signal" "4108;" "$MOCK_KILLS"
assert_eq "kill telemetry includes ownership and activity evidence" "present" \
	"$([[ "$(<"$LOGFILE")" == *'owner=unmanaged action=kill reason=verified-stale-session'* ]] && printf '%s' present || printf '%s' missing)"

MOCK_PROCESS_LINE='4109 ? 3-00:00:01 2048 /home/test/.opencode/bin/opencode run task'
MOCK_CURRENT_COMMAND='/home/test/.opencode/bin/opencode run changed-task'
MOCK_KILLS=""
cleanup_orphans
assert_eq "identity drift prevents signal" "" "$MOCK_KILLS"

MOCK_PROCESS_LINE='4110 ? 3-00:00:01 2048 /home/test/.opencode/bin/opencode serve --port 4096'
MOCK_CURRENT_COMMAND='/home/test/.opencode/bin/opencode serve --port 4096'
MOCK_KILLS=""
cleanup_orphans
assert_eq "persistent service receives no signal" "" "$MOCK_KILLS"

MOCK_PROCESS_LINE='4111 pts/3 3-00:00:01 2048 /home/test/.opencode/bin/opencode run task'
MOCK_CURRENT_COMMAND='/home/test/.opencode/bin/opencode run task'
MOCK_KILLS=""
cleanup_orphans
assert_eq "verified stale TTY session receives only its own signal" "4111;" "$MOCK_KILLS"

printf 'Tests: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
