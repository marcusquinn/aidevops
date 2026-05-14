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
	printf '%s\n' "MainPID=${STUB_SYSTEMCTL_MAINPID:-0}"
	printf '%s\n' "ActiveState=${STUB_SYSTEMCTL_ACTIVE_STATE:-active}"
	printf '%s\n' "SubState=${STUB_SYSTEMCTL_SUB_STATE:-running}"
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
export LOGFILE="${TMP_DIR}/pulse.log"
export AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE=0

# shellcheck source=.agents/scripts/pulse-dispatch-worker-launch.sh
source "${REPO_ROOT}/.agents/scripts/pulse-dispatch-worker-launch.sh"

reset_logs() {
	: >"$STUB_SYSTEMD_RUN_LOG"
	: >"$STUB_SETSID_LOG"
	: >"$LOGFILE"
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
pid="$(_dlw_exec_detached "${TMP_DIR}/worker-happy.log" "23073" /bin/true)"

if [[ "$pid" != "424242" ]]; then
	printf 'FAIL expected systemd child pid 424242, got %s\n' "$pid" >&2
	exit 1
fi

assert_contains "$STUB_SYSTEMD_RUN_LOG" '--unit=aidevops-worker-23073-' 'expected worker transient unit launch'
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
assert_contains "$STUB_SETSID_LOG" 'nohup /bin/true' 'expected setsid fallback when unit has no MainPID'

printf 'PASS %s\n' "worker launch resolves systemd MainPID before setsid fallback"
