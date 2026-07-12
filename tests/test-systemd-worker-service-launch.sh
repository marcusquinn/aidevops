#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

mkdir -p "${TMP_DIR}/bin"

cat >"${TMP_DIR}/bin/systemctl" <<'STUB_SYSTEMCTL'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "status" ]]; then
	exit 0
fi

if [[ "${1:-}" == "--user" && "${2:-}" == "show" ]]; then
	count=0
	[[ -f "${STUB_SYSTEMCTL_COUNT_FILE:?}" ]] && read -r count <"$STUB_SYSTEMCTL_COUNT_FILE"
	count=$((count + 1))
	printf '%s\n' "$count" >"$STUB_SYSTEMCTL_COUNT_FILE"
	active_state="${STUB_SYSTEMCTL_ACTIVE_STATE:-active}"
	sub_state="${STUB_SYSTEMCTL_SUB_STATE:-running}"
	main_pid="${STUB_SYSTEMCTL_MAINPID:-0}"
	exec_status="${STUB_SYSTEMCTL_EXEC_STATUS:-0}"
	result="${STUB_SYSTEMCTL_RESULT:-success}"
	if [[ "${STUB_SYSTEMCTL_SEQUENCE:-stable}" == "active_then_failed" && "$count" -ge 2 ]]; then
		active_state="failed"
		sub_state="failed"
		main_pid=0
		exec_status=1
		result="exit-code"
	fi
	printf '%s\n' "Id=${3:-unknown}.service"
	printf '%s\n' "MainPID=$main_pid"
	printf '%s\n' "ActiveState=$active_state"
	printf '%s\n' "SubState=$sub_state"
	printf '%s\n' "ExecMainCode=exited"
	printf '%s\n' "ExecMainStatus=$exec_status"
	printf '%s\n' "Result=$result"
	exit 0
fi

exit 1
STUB_SYSTEMCTL
chmod +x "${TMP_DIR}/bin/systemctl"

cat >"${TMP_DIR}/bin/uname" <<'STUB_UNAME'
#!/usr/bin/env bash
printf 'Linux\n'
exit 0
STUB_UNAME
chmod +x "${TMP_DIR}/bin/uname"

cat >"${TMP_DIR}/bin/systemd-run" <<'STUB_SYSTEMD_RUN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_SYSTEMD_RUN_LOG:?}"

prev=""
pid_file=""
for arg in "$@"; do
	if [[ "$prev" == "_" ]]; then
		pid_file="$arg"
		break
	fi
	prev="$arg"
done

if [[ "${STUB_SYSTEMD_RUN_WRITE_PID:-1}" == "1" && -n "$pid_file" ]]; then
	printf '%s\n' "${STUB_SYSTEMD_RUN_PID:-424242}" >"$pid_file"
fi
exit 0
STUB_SYSTEMD_RUN
chmod +x "${TMP_DIR}/bin/systemd-run"

cat >"${TMP_DIR}/bin/setsid" <<'STUB_SETSID'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_SETSID_LOG:?}"
"$@"
exit $?
STUB_SETSID
chmod +x "${TMP_DIR}/bin/setsid"

export PATH="${TMP_DIR}/bin:${PATH}"
export STUB_SYSTEMD_RUN_LOG="${TMP_DIR}/systemd-run.log"
export STUB_SETSID_LOG="${TMP_DIR}/setsid.log"
export STUB_SYSTEMCTL_COUNT_FILE="${TMP_DIR}/systemctl.count"
export LOGFILE="${TMP_DIR}/pulse.log"
export AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE=0

# shellcheck source=.agents/scripts/pulse-dispatch-worker-launch.sh
source "${REPO_ROOT}/.agents/scripts/pulse-dispatch-worker-launch.sh"

reset_logs() {
	: >"$STUB_SYSTEMD_RUN_LOG"
	: >"$STUB_SETSID_LOG"
	: >"$LOGFILE"
	: >"$STUB_SYSTEMCTL_COUNT_FILE"
	export STUB_SYSTEMCTL_SEQUENCE=stable
	export STUB_SYSTEMCTL_ACTIVE_STATE=active
	export STUB_SYSTEMCTL_SUB_STATE=running
	export STUB_SYSTEMCTL_EXEC_STATUS=0
	export STUB_SYSTEMCTL_RESULT=success
	return 0
}

assert_contains() {
	local file_path="$1"
	local expected="$2"
	local message="$3"
	if ! grep -q -- "$expected" "$file_path"; then
		printf 'FAIL %s\n' "$message" >&2
		exit 1
	fi
	return 0
}

assert_eventually_contains() {
	local file_path="$1"
	local expected="$2"
	local message="$3"
	local attempt=0
	while ((attempt < 20)); do
		if grep -q -- "$expected" "$file_path"; then
			return 0
		fi
		sleep 0.05
		attempt=$((attempt + 1))
	done
	printf 'FAIL %s\n' "$message" >&2
	exit 1
}

assert_empty_file() {
	local file_path="$1"
	local message="$2"
	if [[ -s "$file_path" ]]; then
		printf 'FAIL %s\n' "$message" >&2
		exit 1
	fi
	return 0
}

reset_logs
export STUB_SYSTEMD_RUN_WRITE_PID=1
export STUB_SYSTEMD_RUN_PID=424242
export STUB_SYSTEMCTL_MAINPID=424242
pid="$(_dlw_exec_detached "${TMP_DIR}/worker-happy.log" "23073" /bin/true)"

if [[ "$pid" != "424242" ]]; then
	printf 'FAIL expected systemd child pid 424242, got %s\n' "$pid" >&2
	exit 1
fi

assert_contains "$STUB_SYSTEMD_RUN_LOG" '--unit=aidevops-worker-23073-' 'expected worker transient unit launch'
assert_contains "$STUB_SYSTEMD_RUN_LOG" '--unit=aidevops-worker-monitor-23073-' 'expected monitor transient unit launch'
assert_contains "$STUB_SYSTEMD_RUN_LOG" '--unit=aidevops-worker-observer-23073-' 'expected observer transient unit launch'
assert_contains "$LOGFILE" 'systemd-run transient user service outside pulse cgroup' 'expected systemd launch diagnostic in pulse log'
assert_contains "$LOGFILE" 'systemd unit aidevops-worker-23073-' 'expected systemd unit in launch diagnostic'
assert_empty_file "$STUB_SETSID_LOG" 'setsid should not be used on pid-file systemd success'

reset_logs
export STUB_SYSTEMD_RUN_WRITE_PID=0
export STUB_SYSTEMCTL_MAINPID=525252
export STUB_SYSTEMCTL_ACTIVE_STATE=active
export STUB_SYSTEMCTL_SUB_STATE=running
pid="$(_dlw_exec_detached "${TMP_DIR}/worker-mainpid.log" "23524" /bin/true)"

if [[ "$pid" != "525252" ]]; then
	printf 'FAIL expected resolved systemd MainPID 525252, got %s\n' "$pid" >&2
	exit 1
fi

assert_contains "$LOGFILE" 'resolved MainPID=525252' 'expected MainPID recovery diagnostic in pulse log'
assert_contains "$LOGFILE" 'aidevops-worker-monitor-23524-' 'expected monitor MainPID handoff fallback coverage'
assert_contains "$LOGFILE" 'aidevops-worker-observer-23524-' 'expected observer MainPID handoff fallback coverage'
assert_empty_file "$STUB_SETSID_LOG" 'setsid should not be used when systemctl resolves MainPID'

reset_logs
export STUB_SYSTEMD_RUN_WRITE_PID=0
export STUB_SYSTEMCTL_MAINPID=0
export STUB_SYSTEMCTL_ACTIVE_STATE=inactive
export STUB_SYSTEMCTL_SUB_STATE=dead
pid="$(_dlw_exec_detached "${TMP_DIR}/worker-fallback.log" "23524" /bin/true)"

if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
	printf 'FAIL expected numeric fallback pid, got %s\n' "$pid" >&2
	exit 1
fi

assert_contains "$LOGFILE" 'falling back to setsid/nohup' 'expected fallback diagnostic when unit has no MainPID'
assert_contains "$LOGFILE" 'systemd unit aidevops-worker-23524-' 'expected systemd unit in fallback diagnostic'
assert_eventually_contains "$STUB_SETSID_LOG" '/bin/true' 'expected setsid fallback when unit has no MainPID'

reset_logs
export STUB_SYSTEMD_RUN_WRITE_PID=1
export STUB_SYSTEMD_RUN_PID=626262
export STUB_SYSTEMCTL_MAINPID=626262
export STUB_SYSTEMCTL_SEQUENCE=active_then_failed
export STUB_SETSID_LOG="${TMP_DIR}/setsid-status-1.log"
: >"$STUB_SETSID_LOG"
if _dlw_exec_detached "${TMP_DIR}/worker-status-1.log" "27353" /bin/false >/dev/null; then
	printf 'FAIL expected active-then-status-1 launch to fail\n' >&2
	exit 1
fi
assert_contains "${TMP_DIR}/worker-status-1.log" 'classification=crash_during_startup' 'expected startup failure classification evidence'
assert_contains "${TMP_DIR}/worker-status-1.log" 'ExecMainStatus=1' 'expected authoritative systemd exit status evidence'
assert_contains "${TMP_DIR}/worker-status-1.log" 'Result=exit-code' 'expected authoritative systemd result evidence'
assert_contains "${TMP_DIR}/worker-status-1.log" 'Unit=aidevops-worker-27353-' 'expected transient unit identity evidence'
assert_empty_file "$STUB_SETSID_LOG" 'setsid must not duplicate an active-then-failed systemd worker'

reset_logs
export STUB_SYSTEMD_RUN_PID=737373
export STUB_SYSTEMCTL_MAINPID=838383
export STUB_SETSID_LOG="${TMP_DIR}/setsid-unconfirmed.log"
: >"$STUB_SETSID_LOG"
if _dlw_exec_detached "${TMP_DIR}/worker-unconfirmed.log" "27355" /bin/true >/dev/null; then
	printf 'FAIL expected mismatched provisional PID launch to remain unconfirmed\n' >&2
	exit 1
fi
assert_contains "${TMP_DIR}/worker-unconfirmed.log" 'classification=readiness_unconfirmed' 'expected provisional PID evidence'
assert_empty_file "$STUB_SETSID_LOG" 'setsid must not duplicate a provisional systemd worker'

reset_logs
export STUB_SETSID_LOG="${TMP_DIR}/setsid.log"
export AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE=1
pid="$(_dlw_exec_detached "${TMP_DIR}/worker-non-systemd.log" "27354" /bin/true)"
if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
	printf 'FAIL expected numeric non-systemd fallback pid, got %s\n' "$pid" >&2
	exit 1
fi
assert_empty_file "$STUB_SYSTEMD_RUN_LOG" 'non-systemd path must not invoke systemd-run'
assert_eventually_contains "$STUB_SETSID_LOG" '/bin/true' 'non-systemd path should retain setsid semantics'
export AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE=0

printf 'PASS %s\n' "systemd launch readiness, evidence, handoff, and fallback semantics"
