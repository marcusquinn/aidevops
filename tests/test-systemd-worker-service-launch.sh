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

if [[ -n "$pid_file" ]]; then
	printf '424242\n' >"$pid_file"
fi
exit 0
STUB_SYSTEMD_RUN
chmod +x "${TMP_DIR}/bin/systemd-run"

cat >"${TMP_DIR}/bin/setsid" <<'STUB_SETSID'
#!/usr/bin/env bash
printf 'setsid should not be used when systemd-run is available\n' >&2
exit 1
STUB_SETSID
chmod +x "${TMP_DIR}/bin/setsid"

export PATH="${TMP_DIR}/bin:${PATH}"
export STUB_SYSTEMD_RUN_LOG="${TMP_DIR}/systemd-run.log"
export LOGFILE="${TMP_DIR}/pulse.log"
export AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE=0

# shellcheck source=.agents/scripts/pulse-dispatch-worker-launch.sh
source "${REPO_ROOT}/.agents/scripts/pulse-dispatch-worker-launch.sh"

pid="$(_dlw_exec_detached "${TMP_DIR}/worker.log" "23073" /bin/true)"

if [[ "$pid" != "424242" ]]; then
	printf 'FAIL expected systemd child pid 424242, got %s\n' "$pid" >&2
	exit 1
fi

if ! grep -q -- '--unit=aidevops-worker-23073-' "$STUB_SYSTEMD_RUN_LOG"; then
	printf 'FAIL expected worker transient unit launch\n' >&2
	exit 1
fi

if ! grep -q 'systemd-run transient user service outside pulse cgroup' "$LOGFILE"; then
	printf 'FAIL expected systemd launch diagnostic in pulse log\n' >&2
	exit 1
fi

printf 'PASS %s\n' "worker launch uses systemd-run transient user service when available"
