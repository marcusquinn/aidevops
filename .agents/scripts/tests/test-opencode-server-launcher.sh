#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-opencode-server-launcher.sh — one-owner OpenCode server launcher tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/opencode-launcher-helper.sh"

pass_count=0
fail_count=0

pass() {
    local message="$1"
    printf '  PASS: %s\n' "${message}"
    pass_count=$((pass_count + 1))
    return 0
}

fail() {
    local message="$1"
    printf '  FAIL: %s\n' "${message}" >&2
    fail_count=$((fail_count + 1))
    return 0
}

directory_is_empty() {
    local directory="$1"
    local candidate=""

    [[ -d "${directory}" ]] || return 1
    for candidate in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
        if [[ -e "${candidate}" || -L "${candidate}" ]]; then
            return 1
        fi
    done
    return 0
}

make_fake_tools() {
    local bin_dir="$1"

    mkdir -p "${bin_dir}"
    cat >"${bin_dir}/opencode" <<'SH'
#!/usr/bin/env bash
set -u

if [[ -n "${FAKE_OPENCODE_LOG:-}" ]]; then
    printf 'opencode|%s|%s|%s|%s\n' \
        "${XDG_DATA_HOME:-}" \
        "${AIDEVOPS_OPENCODE_ISOLATED_DB:-}" \
        "${AIDEVOPS_OPENCODE_SERVER_OWNER:-}" \
        "$*" >>"${FAKE_OPENCODE_LOG}"
fi
if [[ "${1:-}" == "--version" ]]; then
    printf '%s\n' "${FAKE_OPENCODE_VERSION:-1.18.3}"
    exit 0
fi
if [[ "${1:-}" == "db" && "${2:-}" == "path" ]]; then
    mkdir -p "${XDG_DATA_HOME}/opencode"
    : >"${XDG_DATA_HOME}/opencode/opencode.db"
    printf '%s\n' "${XDG_DATA_HOME}/opencode/opencode.db"
    exit 0
fi
if [[ "${1:-}" == "serve" && "${FAKE_SERVER_WAIT:-0}" == "1" ]]; then
    printf '%s\n' "$$" >"${FAKE_SERVER_PID_FILE}"
    trap 'exit 0' INT TERM HUP
    while :; do
        sleep 1
    done
fi
printf 'XDG_DATA_HOME=%s\n' "${XDG_DATA_HOME:-}"
printf 'AIDEVOPS_OPENCODE_ISOLATED_DB=%s\n' "${AIDEVOPS_OPENCODE_ISOLATED_DB:-}"
printf 'AIDEVOPS_OPENCODE_SERVER_OWNER=%s\n' "${AIDEVOPS_OPENCODE_SERVER_OWNER:-}"
printf 'PWD=%s\n' "$PWD"
printf 'ARGS=%s\n' "$*"
exit 0
SH
    cat >"${bin_dir}/lsof" <<'SH'
#!/usr/bin/env bash
set -u

if [[ -n "${FAKE_LSOF_LOG:-}" ]]; then
    printf 'lsof|%s\n' "$*" >>"${FAKE_LSOF_LOG}"
fi
if [[ "$*" == *"-iTCP:"* ]]; then
    [[ "${FAKE_PORT_BUSY:-0}" == "1" ]] && exit 0
    exit 1
fi
[[ "${FAKE_DB_BUSY:-0}" == "1" ]] && exit 0
exit 1
SH
    cat >"${bin_dir}/curl" <<'SH'
#!/usr/bin/env bash
set -u

health_json="${FAKE_HEALTH_JSON:-}"
if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
    printf 'curl|%s\n' "$*" >>"${FAKE_CURL_LOG}"
fi
[[ "${FAKE_CURL_FAIL:-0}" == "1" ]] && exit 22
[[ -n "${health_json}" ]] || health_json='{"healthy":true,"version":"1.18.3"}'
printf '%s\n' "${health_json}"
exit 0
SH
    chmod +x "${bin_dir}/opencode" "${bin_dir}/lsof" "${bin_dir}/curl"
    return 0
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT
fake_bin="${tmp_root}/bin"
launch_dir="${tmp_root}/repo"
home_dir="${tmp_root}/home"
server_work_dir="${tmp_root}/server-work"
dry_run_work_dir="${tmp_root}/dry-run-work"
collision_work_dir="${tmp_root}/collision-work"
invalid_work_dir="${tmp_root}/invalid-work"
holder_work_dir="${tmp_root}/holder-work"
signal_work_dir="${tmp_root}/signal-work"
opencode_log="${tmp_root}/opencode.log"
lsof_log="${tmp_root}/lsof.log"
curl_log="${tmp_root}/curl.log"
signal_pid_file="${tmp_root}/signal-child.pid"
signal_output="${tmp_root}/signal-output.log"

mkdir -p "${launch_dir}" "${home_dir}/.local/share/opencode" "${server_work_dir}" \
    "${dry_run_work_dir}" "${collision_work_dir}" "${invalid_work_dir}" "${holder_work_dir}" \
    "${signal_work_dir}"
make_fake_tools "${fake_bin}"
printf '{"test":{}}\n' >"${home_dir}/.local/share/opencode/auth.json"

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${dry_run_work_dir}" \
    FAKE_OPENCODE_LOG="${opencode_log}" FAKE_LSOF_LOG="${lsof_log}" FAKE_CURL_LOG="${curl_log}" \
    "${HELPER}" server --dir "${launch_dir}" --port 49036 --dry-run 2>&1)
if [[ "${output}" == *"XDG_DATA_HOME=${dry_run_work_dir}/opencode-server/project-repo-"* ]] \
    && [[ "${output}" == *"AIDEVOPS_OPENCODE_SERVER_OWNER=1 opencode serve --pure --hostname 127.0.0.1 --port 49036 --cors oc://renderer"* ]] \
    && directory_is_empty "${dry_run_work_dir}" \
    && [[ ! -e "${opencode_log}" && ! -e "${lsof_log}" && ! -e "${curl_log}" ]]; then
    pass "server dry-run is complete and observational"
else
    fail "server dry-run output or state was unexpected: ${output}"
fi

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${server_work_dir}" \
    FAKE_OPENCODE_LOG="${opencode_log}" FAKE_LSOF_LOG="${lsof_log}" \
    "${HELPER}" server --dir "${launch_dir}" --port 49036 2>&1)
server_data_dir=""
server_data_count=0
for candidate in "${server_work_dir}"/opencode-server/project-repo-*; do
    [[ -d "${candidate}" ]] || continue
    server_data_dir="${candidate}"
    server_data_count=$((server_data_count + 1))
done
if [[ "${output}" == *"AIDEVOPS_OPENCODE_SERVER_OWNER=1"* ]] \
    && [[ "${output}" == *"PWD=${launch_dir}"* ]] \
    && [[ "${output}" == *"ARGS=serve --pure --hostname 127.0.0.1 --port 49036 --cors oc://renderer"* ]] \
    && [[ "${server_data_count}" == "1" ]] \
    && [[ -f "${server_data_dir}/opencode/auth.json" ]] \
    && [[ -f "${server_data_dir}/opencode/opencode.db" ]] \
    && [[ ! -e "${server_data_dir}/.aidevops-server-owner" ]]; then
    pass "server mode prepares one isolated shard and releases its owner lock"
else
    fail "server mode output or shard state was unexpected: ${output}"
fi

PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${signal_work_dir}" \
    FAKE_SERVER_WAIT=1 FAKE_SERVER_PID_FILE="${signal_pid_file}" \
    "${HELPER}" server --dir "${launch_dir}" --port 59139 --session-id signal \
    >"${signal_output}" 2>&1 &
helper_pid=$!
signal_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -s "${signal_pid_file}" ]]; then
        signal_ready=1
        break
    fi
    sleep 0.1
done
child_pid=""
[[ -s "${signal_pid_file}" ]] && child_pid="$(<"${signal_pid_file}")"
kill -TERM "${helper_pid}" 2>/dev/null || true
wait "${helper_pid}" 2>/dev/null || true
child_alive=0
if [[ "${child_pid}" =~ ^[0-9]+$ ]] && kill -0 "${child_pid}" 2>/dev/null; then
    child_alive=1
    kill -KILL "${child_pid}" 2>/dev/null || true
fi
if ((signal_ready == 1 && child_alive == 0)) \
    && [[ ! -e "${signal_work_dir}/opencode-server/signal/.aidevops-server-owner" ]]; then
    pass "server mode forwards termination and releases the owner lock"
else
    fail "server signal forwarding or lock cleanup failed"
fi

rm -f "${opencode_log}" "${lsof_log}"
set +e
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${collision_work_dir}" \
    FAKE_PORT_BUSY=1 FAKE_OPENCODE_LOG="${opencode_log}" FAKE_LSOF_LOG="${lsof_log}" \
    "${HELPER}" server --dir "${launch_dir}" --port 49037 --session-id collision 2>&1)
status=$?
set -e
if ((status != 0)) \
    && [[ "${output}" == *"Port 49037 is already in use"* ]] \
    && directory_is_empty "${collision_work_dir}" \
    && [[ ! -e "${opencode_log}" ]]; then
    pass "server mode fails closed on a port collision before writing"
else
    fail "port collision did not fail closed: ${output}"
fi

set +e
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${invalid_work_dir}" \
    FAKE_OPENCODE_LOG="${opencode_log}" "${HELPER}" server --dir "${launch_dir}" --port 0 --dry-run 2>&1)
status=$?
set -e
if ((status != 0)) \
    && [[ "${output}" == *"Port must be an integer from 1 to 65535"* ]] \
    && directory_is_empty "${invalid_work_dir}" \
    && [[ ! -e "${opencode_log}" ]]; then
    pass "server mode rejects a zero port without writing"
else
    fail "invalid port handling was unexpected: ${output}"
fi

held_data_dir="${holder_work_dir}/opencode-server/held/opencode"
mkdir -p "${held_data_dir}"
: >"${held_data_dir}/opencode.db"
rm -f "${opencode_log}" "${lsof_log}"
set +e
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${holder_work_dir}" \
    FAKE_DB_BUSY=1 FAKE_OPENCODE_LOG="${opencode_log}" FAKE_LSOF_LOG="${lsof_log}" \
    "${HELPER}" server --dir "${launch_dir}" --port 49038 --session-id held 2>&1)
status=$?
set -e
if ((status != 0)) \
    && [[ "${output}" == *"Server shard already has database holders"* ]] \
    && [[ ! -e "${opencode_log}" && ! -e "${holder_work_dir}/opencode-server/held/.aidevops-server-owner" ]]; then
    pass "server mode rejects an existing shard with database holders"
else
    fail "database holder handling was unexpected: ${output}"
fi

rm -f "${opencode_log}" "${curl_log}"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" XDG_DATA_HOME="${server_data_dir}" \
    FAKE_OPENCODE_LOG="${opencode_log}" FAKE_CURL_LOG="${curl_log}" \
    "${HELPER}" attach http://127.0.0.1:49036 --dir "${launch_dir}" --session ses_dry --dry-run 2>&1)
if [[ "${output}" == *"unset XDG_DATA_HOME AIDEVOPS_OPENCODE_ISOLATED_DB AIDEVOPS_OPENCODE_SERVER_OWNER"* ]] \
    && [[ "${output}" == *"opencode attach http://127.0.0.1:49036 --dir ${launch_dir} --session ses_dry"* ]] \
    && [[ ! -e "${opencode_log}" && ! -e "${curl_log}" ]]; then
    pass "attach dry-run avoids health checks and direct shard access"
else
    fail "attach dry-run output or activity was unexpected: ${output}"
fi

rm -f "${opencode_log}" "${curl_log}"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" XDG_DATA_HOME="${server_data_dir}" \
    FAKE_OPENCODE_LOG="${opencode_log}" FAKE_CURL_LOG="${curl_log}" \
    FAKE_HEALTH_JSON='{"healthy":true,"version":"1.18.3"}' \
    "${HELPER}" attach http://127.0.0.1:49036/ --dir "${launch_dir}" --session ses_shared 2>&1)
attach_log=""
while IFS= read -r line; do
    [[ "${line}" == *"|attach "* ]] && attach_log="${line}"
done <"${opencode_log}"
if [[ "${output}" == *"XDG_DATA_HOME="* ]] \
    && [[ "${output}" != *"XDG_DATA_HOME=${server_data_dir}"* ]] \
    && [[ "${output}" == *"ARGS=attach http://127.0.0.1:49036 --dir ${launch_dir} --session ses_shared"* ]] \
    && [[ "${attach_log}" == "opencode||||attach http://127.0.0.1:49036 --dir ${launch_dir} --session ses_shared" ]] \
    && [[ -s "${curl_log}" ]]; then
    pass "attach validates health and clears direct database ownership state"
else
    fail "healthy attach behavior was unexpected: ${output}"
fi

rm -f "${opencode_log}" "${curl_log}"
set +e
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" FAKE_OPENCODE_LOG="${opencode_log}" \
    FAKE_CURL_LOG="${curl_log}" FAKE_HEALTH_JSON='{"healthy":true,"version":"1.18.2"}' \
    "${HELPER}" attach http://127.0.0.1:49036 --dir "${launch_dir}" 2>&1)
status=$?
set -e
opencode_calls="$(<"${opencode_log}")"
if ((status != 0)) \
    && [[ "${output}" == *"server version 1.18.2 does not match installed CLI version 1.18.3"* ]] \
    && [[ "${opencode_calls}" != *"|attach "* ]]; then
    pass "attach rejects a server version mismatch before starting the TUI"
else
    fail "version mismatch handling was unexpected: ${output}"
fi

rm -f "${opencode_log}" "${curl_log}"
set +e
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" FAKE_OPENCODE_LOG="${opencode_log}" \
    FAKE_CURL_LOG="${curl_log}" "${HELPER}" attach http://example.test:49036 --dir "${launch_dir}" 2>&1)
status=$?
set -e
if ((status != 0)) \
    && [[ "${output}" == *"Server URL must be an explicit loopback endpoint"* ]] \
    && [[ ! -e "${opencode_log}" && ! -e "${curl_log}" ]]; then
    pass "attach rejects non-loopback endpoints before network access"
else
    fail "non-loopback URL handling was unexpected: ${output}"
fi

if ((fail_count > 0)); then
    printf '\n%d test(s) failed\n' "${fail_count}" >&2
    exit 1
fi

printf '\nAll %d tests passed\n' "${pass_count}"
