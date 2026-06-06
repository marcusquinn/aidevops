#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-opencode-launcher-helper.sh — isolated OpenCode launcher regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/opencode-launcher-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_NC='\033[0m'

pass_count=0
fail_count=0

_pass() {
    local msg="$1"
    printf '%b  PASS:%b %s\n' "${TEST_GREEN}" "${TEST_NC}" "${msg}"
    pass_count=$((pass_count + 1))
    return 0
}

_fail() {
    local msg="$1"
    printf '%b  FAIL:%b %s\n' "${TEST_RED}" "${TEST_NC}" "${msg}" >&2
    fail_count=$((fail_count + 1))
    return 0
}

make_fake_opencode() {
    local bin_dir="$1"
    mkdir -p "${bin_dir}"
    cat >"${bin_dir}/opencode" <<'SH'
#!/usr/bin/env bash
printf 'XDG_DATA_HOME=%s\n' "${XDG_DATA_HOME:-}"
printf 'AIDEVOPS_OPENCODE_ISOLATED_DB=%s\n' "${AIDEVOPS_OPENCODE_ISOLATED_DB:-}"
printf 'PWD=%s\n' "$PWD"
printf 'ARGS=%s\n' "$*"
SH
    chmod +x "${bin_dir}/opencode"
    return 0
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT
fake_bin="${tmp_root}/bin"
work_dir="${tmp_root}/work"
launch_dir="${tmp_root}/repo"
home_dir="${tmp_root}/home"
mkdir -p "${work_dir}" "${launch_dir}" "${home_dir}/.local/share/opencode"
make_fake_opencode "${fake_bin}"
printf '{"anthropic":{}}\n' >"${home_dir}/.local/share/opencode/auth.json"

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" --dir "${launch_dir}" --session-id test-session -- --version 2>&1)
if [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB=1"* ]] \
    && [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-interactive/test-session"* ]] \
    && [[ "${output}" == *"PWD=${launch_dir}"* ]] \
    && [[ -f "${work_dir}/opencode-interactive/test-session/opencode/auth.json" ]]; then
    _pass "isolated launcher sets per-session data dir and copies auth"
else
    _fail "isolated launcher output unexpected: ${output}"
fi

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" --shared-db --dir "${launch_dir}" -- --version 2>&1)
if [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB="* ]] \
    && [[ "${output}" == *"XDG_DATA_HOME="* ]] \
    && [[ "${output}" == *"ARGS=--version"* ]]; then
    _pass "shared-db mode leaves OpenCode data dir untouched"
else
    _fail "shared-db launcher output unexpected: ${output}"
fi

if ((fail_count > 0)); then
    printf '\n%b%d test(s) failed%b\n' "${TEST_RED}" "${fail_count}" "${TEST_NC}" >&2
    exit 1
fi

printf '\n%bAll %d tests passed%b\n' "${TEST_GREEN}" "${pass_count}" "${TEST_NC}"
