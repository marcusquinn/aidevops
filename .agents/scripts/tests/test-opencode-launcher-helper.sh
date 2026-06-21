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
if [[ -n "${FAKE_OPENCODE_LOG:-}" ]]; then
    printf '%s|%s\n' "${XDG_DATA_HOME:-}" "$*" >>"${FAKE_OPENCODE_LOG}"
fi
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
fake_log="${tmp_root}/fake-opencode.log"
mkdir -p "${work_dir}" "${launch_dir}" "${home_dir}/.local/share/opencode"
make_fake_opencode "${fake_bin}"
printf '{"anthropic":{}}\n' >"${home_dir}/.local/share/opencode/auth.json"
desktop_source="${tmp_root}/OpenCode.app/Contents/MacOS/OpenCode"
mkdir -p "$(dirname "${desktop_source}")"
cat >"${desktop_source}" <<'SH'
#!/usr/bin/env bash
printf 'desktop source launched\n'
SH
chmod +x "${desktop_source}"

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" FAKE_OPENCODE_LOG="${fake_log}" \
    "${HELPER}" --dir "${launch_dir}" -- --version 2>&1)
line_count=0
prewarm_line=""
project_auth_count=0
while IFS= read -r line; do
    line_count=$((line_count + 1))
    if [[ ${line_count} -eq 1 ]]; then
        prewarm_line="${line}"
    fi
done <"${fake_log}"
for auth_file in "${work_dir}"/opencode-interactive/project-repo-*/opencode/auth.json; do
    [[ -f "${auth_file}" ]] || continue
    project_auth_count=$((project_auth_count + 1))
done
if [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB=1"* ]] \
    && [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-interactive/project-repo-"* ]] \
    && [[ "${output}" == *"PWD=${launch_dir}"* ]] \
    && [[ "${project_auth_count}" == "1" ]] \
    && [[ "${line_count}" == "2" ]] \
    && [[ "${prewarm_line}" == *"|db path" ]] \
    && [[ "${output}" != *"sqlite-migration"* ]]; then
    _pass "isolated launcher sets per-session data dir and copies auth"
else
    _fail "isolated launcher output unexpected: ${output}"
fi

rm -f "${fake_log}"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" FAKE_OPENCODE_LOG="${fake_log}" \
    "${HELPER}" --dir "${launch_dir}" --session-id test-session -- --version 2>&1)
if [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-interactive/test-session"* ]]; then
    _pass "explicit session-id still controls isolated data dir"
else
    _fail "explicit session-id output unexpected: ${output}"
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

desktop_app_dir="${tmp_root}/Applications"
output=$(HOME="${home_dir}" "${HELPER}" desktop install-shortcut --app-dir "${desktop_app_dir}" --source-binary "${desktop_source}" 2>&1)
desktop_app="${desktop_app_dir}/OpenCode AIDevOps.app"
desktop_wrapper="${desktop_app}/Contents/MacOS/opencode-aidevops"
desktop_plist="${desktop_app}/Contents/Info.plist"
if [[ -x "${desktop_wrapper}" ]] \
    && [[ -f "${desktop_plist}" ]] \
    && grep -q "sh.aidevops.opencode.desktop" "${desktop_plist}" \
    && grep -q "desktop launch --from-app" "${desktop_wrapper}" \
    && [[ "${output}" == *"Installed OpenCode AIDevOps.app"* ]]; then
    _pass "desktop install-shortcut creates macOS app wrapper"
else
    _fail "desktop app wrapper install unexpected: ${output}"
fi

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" desktop launch --source-binary "${desktop_source}" --dir "${launch_dir}" --dry-run 2>&1)
if [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-desktop/desktop-project-repo-"* ]] \
    && [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB=1"* ]] \
    && [[ "${output}" == *"${desktop_source}"* ]]; then
    _pass "desktop launch dry-run uses isolated per-project data dir"
else
    _fail "desktop launch dry-run output unexpected: ${output}"
fi

if ((fail_count > 0)); then
    printf '\n%b%d test(s) failed%b\n' "${TEST_RED}" "${fail_count}" "${TEST_NC}" >&2
    exit 1
fi

printf '\n%bAll %d tests passed%b\n' "${TEST_GREEN}" "${pass_count}" "${TEST_NC}"
