#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="${TMP_DIR}/home"
mkdir -p "$HOME/.config/aidevops" "$HOME/.aidevops/agents/scripts"

repo_path="${TMP_DIR}/repo"
mkdir -p "$repo_path" "${TMP_DIR}/bin"
git -C "$repo_path" init --quiet

cat >"${TMP_DIR}/bin/jq" <<'JQ_STUB'
#!/usr/bin/env bash
printf '%s\n' "$TEST_REPO_PATH"
JQ_STUB
chmod +x "${TMP_DIR}/bin/jq"
export PATH="${TMP_DIR}/bin:${PATH}"
export TEST_REPO_PATH="$repo_path"
printf '{"initialized_repos":[{"path":"%s"}]}' "$repo_path" >"$HOME/.config/aidevops/repos.json"

print_info() { local _m="$1"; printf '[INFO] %s\n' "$_m"; return 0; }
print_warning() { local _m="$1"; printf '[WARN] %s\n' "$_m"; return 0; }
setup_track_configured() { local _m="$1"; printf '[CONFIGURED] %s\n' "$_m"; return 0; }
setup_track_skipped() { local _m="$1"; local _r="${2:-}"; printf '[SKIPPED] %s %s\n' "$_m" "$_r"; return 0; }

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/setup/_privacy_guard.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/setup/_complexity_guard.sh"

privacy_output=$(setup_privacy_guard)
complexity_output=$(setup_complexity_guard)

printf '%s\n' "$privacy_output" | grep -q 'Privacy guard: ok=1 conflict=0 skip=0 err=0'
printf '%s\n' "$complexity_output" | grep -q 'Complexity guard: ok=1 conflict=0 skip=0 err=0'

printf 'PASS setup-guard-install-summary\n'
